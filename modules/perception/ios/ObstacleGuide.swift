// MVP step 1.1: obstacles ahead, on the left and on the right, and low obstacles, with a short system voice.
// MVP step 1.2: reliability level (ReliabilityMonitor), spoken when it changes and shown on screen.
// MVP step 1.3: vibration per zone and directional sound with each alert, vibration when suspended (GuideFeedback).
// MVP step 1.4: warning before a passage from light to dark or back (LightAnalyzer), 5 times a second on every
// camera frame, also while the obstacle alerts are suspended (in a dark room the lit door is what matters).
// MVP step 1.5 (experimental): step down and step up ahead ("Gradino giù / su, un metro"), from the same analysis.
// MVP step 1.6: the user's settings (GuideSettings): alert distance, voice and/or vibration, sound with headphones.
// Everything runs natively; JavaScript only starts/stops the guide and receives a status once a second.
//
// Pipeline per frame:
//   ARKit frame → Depth Anything V2 Small (relative inverse depth, known only up to scale and shift)
//   → metric scale fitted on ARKit's 3D feature points (on the floor plane when there are too few of them)
//   → 3D point per sample → height above the floor, distance ahead, lateral offset from the walking line
//   → three zones (left / ahead / right) → debounce over a few frames → vibration, sound and voice message.
// User-facing strings (voice messages) are in Italian.
import ARKit
import AVFoundation
import CoreML
import ImageIO
import Vision
import simd

// MARK: - Voice

final class GuideVoice: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var current: AVSpeechUtterance?
  private var deadline: Double = 0
  private(set) var speakingZone: Zone?
  private(set) var speakingReliability = false  // the current message is a reliability one (step 1.2)
  private(set) var speakingLight = false  // the current message is a light-passage warning (step 1.4)
  var onEvent: ((String) -> Void)?  // for the log

  override init() {
    super.init()
    synth.delegate = self
  }

  /// Main thread only. True while our last message is being spoken. The 18/10 walking test showed that the
  /// synthesizer's own state can stay "speaking" forever and silence every alert, so there is also a time limit.
  var speaking: Bool {
    guard current != nil else { return false }
    if CACurrentMediaTime() < deadline { return true }
    onEvent?("watchdog")
    current = nil
    speakingZone = nil
    speakingReliability = false
    speakingLight = false
    return false
  }

  /// Main thread only. With VoiceOver on, the voice and rate chosen for VoiceOver are used.
  func say(_ text: String, zone: Zone? = nil, interrupt: Bool = false, reliability: Bool = false, light: Bool = false) {
    if interrupt { synth.stopSpeaking(at: .immediate) }
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice(language: "it-IT")
    u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.1)
    u.prefersAssistiveTechnologySettings = true
    current = u
    deadline = CACurrentMediaTime() + min(6, 1 + Double(text.count) * 0.1)  // generous: ~2.5 s for an alert
    speakingZone = zone
    speakingReliability = reliability
    speakingLight = light
    synth.speak(u)
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done(u, "finished") }
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done(u, "cancelled") }
  private func done(_ u: AVSpeechUtterance, _ how: String) {
    DispatchQueue.main.async {
      guard u === self.current else { return }  // an older, interrupted message
      self.onEvent?(how)
      self.current = nil
      self.speakingZone = nil
      self.speakingReliability = false
      self.speakingLight = false
    }
  }

  /// Distance step in half metres, as spoken: 1 = "mezzo metro" (up to 0.75 m) … 4 = "due metri".
  static func step(_ distance: Float) -> Int { max(1, min(4, Int((distance * 2).rounded()))) }

  /// Short on purpose: the user keeps walking while it is spoken (about half a second per word).
  static func message(_ zone: Zone, _ hit: ZoneHit) -> String {
    let dist = ["", "mezzo metro", "un metro", "un metro e mezzo", "due metri"][step(hit.distance)]
    if hit.stepUp { return "Gradino su, \(dist)" }
    let place = zone.spoken.prefix(1).uppercased() + zone.spoken.dropFirst()
    return "\(place)\(hit.low ? ", basso" : ""), \(dist)"
  }

  static func dropMessage(_ hit: DropHit) -> String {
    "Gradino giù, " + ["", "mezzo metro", "un metro", "un metro e mezzo", "due metri"][step(hit.distance)]
  }
}

// MARK: - Log (Documents/guide, fetched with scripts/guide/fetch-logs.sh)

final class GuideLog {
  private let queue = DispatchQueue(label: "guide.log")
  private var handle: FileHandle?
  private(set) var path = ""
  private let clock: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  func open() throws {
    let dir = Paths.documents.appendingPathComponent("guide")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HH-mm-ss"  // local time, as on the user's clock
    let url = dir.appendingPathComponent("guide-\(f.string(from: Date())).csv")
    FileManager.default.createFile(atPath: url.path, contents: Data("time,event,zone,distance_m,low,detail\n".utf8))
    handle = try FileHandle(forWritingTo: url)
    handle?.seekToEndOfFile()
    path = url.path
  }

  func write(_ event: String, zone: String = "", distance: Float? = nil, low: Bool? = nil, _ detail: String = "") {
    let line = [clock.string(from: Date()), event, zone, distance.map { String(format: "%.2f", $0) } ?? "",
                low.map { $0 ? "1" : "0" } ?? "", detail.contains(",") ? "\"\(detail)\"" : detail]
      .joined(separator: ",") + "\n"
    queue.async { self.handle?.write(Data(line.utf8)) }
  }

  func close() {
    queue.sync {
      try? handle?.synchronize()
      try? handle?.close()
      handle = nil
    }
  }
}

// MARK: - Diagnostic recording (step 1.1 tuning)

/// Twice a second: a small camera image, the raw depth map, the camera pose, the floor plane and the analysis,
/// so that the Mac can replay the frames and draw what was taken for floor and for obstacle
/// (scripts/guide/replay). Personal images: they stay on the phone and on the Mac, never in the repository.
final class GuideRecorder {
  static let enabled = true
  private var dir: URL?
  private var count = 0
  private var last: Double = 0
  private let context = CIContext()

  func open(next logPath: String) {
    guard Self.enabled else { return }
    let name = URL(fileURLWithPath: logPath).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "guide-", with: "rec-")
    let url = URL(fileURLWithPath: logPath).deletingLastPathComponent().appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    dir = url
    count = 0
    last = 0
  }

  func close() { dir = nil }

  func maybeSave(image: CVPixelBuffer, depth: DepthMap, camera: CameraSnapshot, floor: FloorPlane,
                 features: [SIMD3<Float>], analysis: FrameAnalysis, light: LightAnalysis?) {
    guard let base = nextBase(image: image) else { return }
    depth.values.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: base.appendingPathExtension("depth")) }
    let zones: [Any] = analysis.zones.map { h -> Any in
      guard let h else { return NSNull() }
      return ["distance": h.distance, "low": h.low, "area": h.area, "stepUp": h.stepUp]
    }
    // Step 1.5: the step down as seen, before the checks, with the values the checks use
    let drop: Any = analysis.dropSeen.map { d -> Any in
      ["distance": d.distance, "depth": d.depth, "area": d.area, "floorBefore": d.floorBefore, "jump": d.jump,
       "featuresFloor": analysis.dropFeatures.floor, "featuresBelow": analysis.dropFeatures.below,
       "accepted": analysis.drop != nil]
    } ?? NSNull()
    let meta: [String: Any] = [
      "time": Date().timeIntervalSince1970,
      "depthWidth": depth.width, "depthHeight": depth.height,
      "floorY": floor.y, "floorClassified": floor.classified,
      // step 1.5: whether the floor is the plane under the phone, and its outline (world x, z), to check later
      // whether ARKit's floor goes on where a step down is seen
      "floorUnderUser": floor.underUser, "usualHeight": floor.usualHeight, "floorBoundary": floor.boundary.flatMap { [$0.x, $0.y] }, "drop": drop,
      "scaleOk": analysis.scaleOk, "scaleA": analysis.scaleA, "scaleB": analysis.scaleB,
      "scaleSource": analysis.scaleSource, "walls": analysis.walls,
      "walkDirection": camera.walkDirection.map { [$0.x, $0.y, $0.z] } ?? NSNull(),
      "fitInliers": analysis.fitInliers, "fitCandidates": analysis.fitCandidates,
      "nearestFloor": analysis.nearestFloor.isFinite ? analysis.nearestFloor : -1, "zones": zones,
      // ARKit feature points (world, metres): sparse but metric, to test a scale fit that does not rely on the floor
      "features": features.flatMap { [$0.x, $0.y, $0.z] },
    ]
    write(meta.merging(Self.cameraMeta(camera)) { a, _ in a }.merging(Self.lightMeta(light)) { a, _ in a }, base)
  }

  /// Step 1.4: frames without depth analysis too (tracking lost, no floor), for the light-passage warning: in a dark
  /// room the camera still sees a lit door. Image, pose and light only.
  func maybeSaveLightOnly(image: CVPixelBuffer, camera: CameraSnapshot, cameraHeight: Float, light: LightAnalysis,
                          arLight: Float?, tracking: String) {
    guard let base = nextBase(image: image) else { return }
    var meta: [String: Any] = ["time": Date().timeIntervalSince1970, "lightOnly": true, "cameraHeight": cameraHeight,
                               "tracking": tracking, "arLight": arLight ?? -1,
                               "walkDirection": camera.walkDirection.map { [$0.x, $0.y, $0.z] } ?? NSNull()]
    meta.merge(Self.cameraMeta(camera)) { a, _ in a }
    meta.merge(Self.lightMeta(light)) { a, _ in a }
    write(meta, base)
  }

  /// Saves the image and returns the base path of the frame, at most twice a second and for 5 minutes.
  private func nextBase(image: CVPixelBuffer) -> URL? {
    let now = CACurrentMediaTime()
    guard let dir, count < 600, now - last >= 0.5 else { return nil }
    last = now
    count += 1
    let base = dir.appendingPathComponent(String(format: "%04d", count))
    // Image in sensor orientation (landscape), long side 640: same pixel grid as the depth map.
    var img = CIImage(cvPixelBuffer: image)
    let k = 640 / img.extent.width
    img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
    if let jpg = context.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) {
      try? jpg.write(to: base.appendingPathExtension("jpg"))
    }
    return base
  }

  private static func cameraMeta(_ camera: CameraSnapshot) -> [String: Any] {
    let t = camera.transform, K = camera.intrinsics
    return ["transform": [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
            "intrinsics": [K.columns.0, K.columns.1, K.columns.2].flatMap { [$0.x, $0.y, $0.z] },
            "imageWidth": camera.imageSize.width, "imageHeight": camera.imageSize.height]
  }

  private static func lightMeta(_ a: LightAnalysis?) -> [String: Any] {
    guard let a else { return [:] }
    return ["light": ["ambient": a.ambient, "feet": a.feet, "darkShare": a.darkShare, "brightShare": a.brightShare,
                      "kind": a.kind?.rawValue ?? NSNull(), "front": a.front, "passage": a.passage] as [String: Any]]
  }

  private func write(_ meta: [String: Any], _ base: URL) {
    if let json = try? JSONSerialization.data(withJSONObject: meta) {
      try? json.write(to: base.appendingPathExtension("json"))
    }
  }
}

/// The floor ARKit has found (step 1.5: preferably the plane under the user).
struct FloorPlane {
  let y: Float
  let classified: Bool  // ARKit classifies it as floor
  let underUser: Bool  // the phone is above its outline
  let boundary: [SIMD2<Float>]  // outline, world x and z
  let usualHeight: Float  // of the phone above the floor, when this plane was chosen
}

// MARK: - Guide

final class ObstacleGuide: NSObject, ARSessionDelegate {
  private let session = ARSession()
  private let frameQueue = DispatchQueue(label: "guide.ar.frames")
  private let inferQueue = DispatchQueue(label: "guide.depth.infer", qos: .userInitiated)
  private let analyzer = ObstacleAnalyzer()  // inferQueue
  private let voice = GuideVoice()  // main
  private let feedback = GuideFeedback()  // main
  private let log = GuideLog()
  private let recorder = GuideRecorder()  // inferQueue
  var onStatus: (([String: Any]) -> Void)?

  // frameQueue
  private var request: VNCoreMLRequest?
  private var busy = false
  private var trail: [(t: Double, p: SIMD3<Float>)] = []  // recent phone positions, for the walking direction
  private var lastWalk: SIMD3<Float>?
  private var lastLightRun: Double = 0
  private var cameraHeight = LightTuning.defaultCameraHeight  // above the floor, kept from the last frame with floor
  private var heights: [Float] = []  // step 1.5: recent heights of the phone above the floor (see floorPlane)
  private var latestLight: LightAnalysis?  // for the recording of the next analysed frame

  // main
  private(set) var running = false
  private var sessionStarted = false
  private var startTime: Double = 0
  private var tracks: [[ZoneHit?]] = [[], [], []]
  private var lastSpoken: [Double] = [-100, -100, -100]
  private var lastStep: [Int?] = [nil, nil, nil]  // distance step per zone while it stays occupied (see alertIfNeeded)
  private var lastConfirmed: [Double] = [-100, -100, -100]
  // step 1.5: step down, tracked like a fourth zone
  private var dropTrack: [DropHit?] = []
  private var dropLastSpoken: Double = -100
  private var dropLastStep: Int?
  private var dropLastConfirmed: Double = -100
  private var lastStepText = ""
  private var lastHint: Double = -100
  private var uprightSince: Double?
  private var reliability = ReliabilityMonitor(now: 0)
  private var lastStatus: Double = 0
  private var lastAlertText = ""
  private var lastSuspendBuzz: Double = -100
  private var lightWarning = LightWarning()
  private var pendingLight: (kind: LightKind, at: Double)?
  private var lastLightText = ""
  private var lightView: LightAnalysis?  // latest light analysis, for the stat line
  private var settings = GuideSettings.load()  // step 1.6
  private var signalQuietUntil: Double = 0  // step 1.6, vibration only: no new alert before this
  private var inferences = 0
  private var state = "starting"
  private var stat = (frames: 0, scaleOk: 0, fromFeatures: 0, fresh: 0, inliers: 0, candidates: 0, msSum: 0.0,
                      dropSeen: 0, drop: 0)

  func start(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard ARWorldTrackingConfiguration.isSupported else {
      return completion(.failure(Phase0Error("ARKit non supportato")))
    }
    DispatchQueue.main.async {
      guard !self.running else { return completion(.success(["logPath": self.log.path])) }
      self.running = true
      DispatchQueue.global(qos: .userInitiated).async { self.load(completion: completion) }
    }
  }

  private func load(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    do {
      let (model, _) = try DepthModel.load(.cpuAndNeuralEngine)  // Neural Engine: fastest on the iPhone 13 (Phase 0B)
      let request = try VNCoreMLRequest(model: VNCoreMLModel(for: model))
      request.imageCropAndScaleOption = .scaleFill
      try self.log.open()
      self.inferQueue.sync { self.recorder.open(next: self.log.path) }
      self.frameQueue.sync {
        self.request = request
        self.busy = false
        self.lastWalk = nil
        self.lastLightRun = 0
        self.cameraHeight = LightTuning.defaultCameraHeight
        self.heights = []
        self.latestLight = nil
      }
      DispatchQueue.main.async {
        guard self.running else {  // stopped while the model was loading
          self.frameQueue.async { self.request = nil }
          self.log.close()
          return completion(.success(["logPath": self.log.path]))
        }
        self.resetMainState()
        self.voice.onEvent = { [weak self] e in self?.log.write("voice", e) }
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? audio.setActive(true)
        self.feedback.onEvent = { [weak self] e in self?.log.write("feedback", e) }
        self.feedback.start()
        UIApplication.shared.isIdleTimerDisabled = true
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.isLightEstimationEnabled = true
        self.session.delegate = self
        self.session.delegateQueue = self.frameQueue
        self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        self.log.write("start", "device \(PerceptionModule.modelIdentifier()), \(self.settings.logText) from the body, phone offset \(GuideTuning.bodyOffset) m")
        self.voice.say("Guida avviata")
        self.sessionStarted = true
        completion(.success(["logPath": self.log.path]))
      }
    } catch {
      DispatchQueue.main.async {
        self.running = false
        completion(.failure(error))
      }
    }
  }

  func stop(completion: @escaping () -> Void) {
    DispatchQueue.main.async {
      guard self.running else { return completion() }
      self.running = false
      guard self.sessionStarted else { return completion() }  // still loading: load() cleans up
      self.sessionStarted = false
      self.session.pause()
      self.feedback.stop()
      UIApplication.shared.isIdleTimerDisabled = false
      self.voice.say("Guida fermata", interrupt: true)
      self.log.write("stop")
      self.frameQueue.async {
        self.request = nil
        self.inferQueue.async {  // after the last inference
          self.recorder.close()
          self.log.close()
          DispatchQueue.main.async {
            self.onStatus?(["state": "stopped"])
            completion()
          }
        }
      }
    }
  }

  /// Step 1.6: new settings from the settings screen (already saved), used from the next frame on.
  func apply(_ new: GuideSettings) {
    DispatchQueue.main.async {
      guard new != self.settings else { return }
      self.settings = new
      if self.running { self.log.write("settings", new.logText) }
    }
  }

  private func resetMainState() {
    startTime = CACurrentMediaTime()
    tracks = [[], [], []]
    lastSpoken = [-100, -100, -100]
    lastStep = [nil, nil, nil]
    lastConfirmed = [-100, -100, -100]
    dropTrack = []
    dropLastSpoken = -100
    dropLastStep = nil
    dropLastConfirmed = -100
    lastStepText = ""
    lastHint = -100
    uprightSince = nil
    reliability = ReliabilityMonitor(now: startTime)
    lastStatus = startTime
    lastAlertText = ""
    lastSuspendBuzz = -100
    lightWarning = LightWarning()
    pendingLight = nil
    lastLightText = ""
    lightView = nil
    signalQuietUntil = 0
    inferences = 0
    state = "starting"
    stat = (0, 0, 0, 0, 0, 0, 0, 0, 0)
  }

  // MARK: ARSessionDelegate (frameQueue)

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard request != nil else { return }
    lightStep(frame)
    guard !busy, let request else { return }
    let light = frame.lightEstimate.map { Float($0.ambientIntensity) }
    let tracking = frame.camera.trackingState
    guard case .normal = tracking else {
      let reason: String
      switch tracking {
      case .limited(let r): reason = "\(r)"
      default: reason = "notAvailable"
      }
      DispatchQueue.main.async { self.handle(nil, state: "tracking", detail: reason, light: light, ms: 0) }
      return
    }
    guard let floor = floorPlane(frame: frame) else {
      DispatchQueue.main.async { self.handle(nil, state: "searchingFloor", detail: "", light: light, ms: 0) }
      return
    }
    let floorY = floor.y
    let features = frame.rawFeaturePoints?.points ?? []
    busy = true
    let pixelBuffer = frame.capturedImage  // do not retain the ARFrame
    lastWalk = walkDirection(frame)
    let camera = CameraSnapshot(transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                                imageSize: frame.camera.imageResolution, walkDirection: lastWalk)
    let lightForRecording = latestLight
    inferQueue.async {
      let t0 = DispatchTime.now().uptimeNanoseconds
      let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
      try? handler.perform([request])
      var depth: DepthMap?
      if let obs = request.results?.first as? VNPixelBufferObservation {
        depth = DepthMap(pixelBuffer: obs.pixelBuffer)
      } else if let obs = request.results?.first as? VNCoreMLFeatureValueObservation {
        depth = DepthMap(obs.featureValue)
      }
      let analysis = depth.map { self.analyzer.analyze(depth: $0, camera: camera, floorY: floorY, features: features,
                                                          now: CACurrentMediaTime()) }
      let ms = elapsedMs(since: t0)
      if let depth, let analysis {
        self.recorder.maybeSave(image: pixelBuffer, depth: depth, camera: camera, floor: floor, features: features,
                                analysis: analysis, light: lightForRecording)
      }
      self.frameQueue.async { self.busy = false }
      DispatchQueue.main.async { self.handle(analysis, state: "active", detail: "", light: light, ms: ms) }
    }
  }

  /// Step 1.4, 5 times a second on any frame with a camera pose: brightness of the floor ahead. The phone's height
  /// above the floor comes from the last frame where ARKit had the floor (in the dark it has none).
  private func lightStep(_ frame: ARFrame) {
    guard frame.timestamp - lastLightRun >= 1 / LightTuning.analysesPerSecond else { return }
    lastLightRun = frame.timestamp
    let tracking = frame.camera.trackingState
    var normal = false, trackingText = "notAvailable"
    switch tracking {
    case .notAvailable: return  // no pose at all
    case .limited(let r): trackingText = "\(r)"
    case .normal: normal = true; trackingText = "normal"
    }
    let floor = normal ? floorPlane(frame: frame) : nil
    if let floor { cameraHeight = frame.camera.transform.columns.3.y - floor.y }
    let pixelBuffer = frame.capturedImage
    guard let ambient = frame.lightEstimate.map({ Float($0.ambientIntensity) }), let grid = Self.lumaGrid(pixelBuffer) else { return }
    // The walking direction needs a reliable position: without tracking, where the camera points.
    let camera = CameraSnapshot(transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                                imageSize: frame.camera.imageResolution, walkDirection: normal ? lastWalk : nil)
    let analysis = LightAnalyzer.analyze(grid, camera: camera, cameraHeight: cameraHeight, ambient: ambient)
    latestLight = analysis
    if floor == nil {  // no depth analysis for this frame: recorded here
      let height = cameraHeight
      inferQueue.async {
        self.recorder.maybeSaveLightOnly(image: pixelBuffer, camera: camera, cameraHeight: height, light: analysis,
                                         arLight: ambient, tracking: trackingText)
      }
    }
    DispatchQueue.main.async { self.handleLight(analysis) }
  }

  /// Luma and colour on the LightTuning grid, read straight from the camera's YCbCr planes (no conversion).
  private static func lumaGrid(_ pb: CVPixelBuffer) -> LumaGrid? {
    guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
    let yp = yBase.assumingMemoryBound(to: UInt8.self), cp = cBase.assumingMemoryBound(to: UInt8.self)
    let yw = CVPixelBufferGetWidthOfPlane(pb, 0), yh = CVPixelBufferGetHeightOfPlane(pb, 0)
    let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    // ARKit gives full range ('420f'); video range is converted to the same scale, as the thresholds expect.
    let video = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let gw = LightTuning.gridWidth, gh = LightTuning.gridHeight
    var luma = [UInt8](repeating: 0, count: gw * gh), chroma = luma
    for j in 0..<gh {
      let y = min(yh - 1, Int((Float(j) + 0.5) * Float(yh) / Float(gh)))
      let cy = min(ch - 1, y * ch / yh)
      for i in 0..<gw {
        let x = min(yw - 1, Int((Float(i) + 0.5) * Float(yw) / Float(gw)))
        let cx = min(cw - 1, x * cw / yw)
        var l = Float(yp[y * yStride + x])
        var cb = Float(cp[cy * cStride + 2 * cx]) - 128, cr = Float(cp[cy * cStride + 2 * cx + 1]) - 128
        if video {
          l = (l - 16) * 255 / 219
          cb *= 255 / 224
          cr *= 255 / 224
        }
        luma[j * gw + i] = UInt8(max(0, min(255, l.rounded())))
        chroma[j * gw + i] = UInt8(min(255, (cb * cb + cr * cr).squareRoot().rounded()))
      }
    }
    return LumaGrid(values: luma, chroma: chroma, width: gw, height: gh)
  }

  /// Horizontal direction of the last second of movement, when the user has moved at least 15 cm; otherwise nil
  /// (standing or turning on the spot: the camera direction is used).
  private func walkDirection(_ frame: ARFrame) -> SIMD3<Float>? {
    let c = frame.camera.transform.columns.3
    let now = frame.timestamp
    trail.append((now, SIMD3(c.x, 0, c.z)))
    trail.removeAll { now - $0.t > 1.2 }
    guard let first = trail.first, now - first.t >= 0.6 else { return nil }
    let d = trail[trail.count - 1].p - first.p
    return simd_length(d) >= 0.15 ? simd_normalize(d) : nil  // 0.25 m missed slow walking (test of 18/10)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    log.write("error", error.localizedDescription)
  }

  /// The floor the user stands on. Step 1.5: the phone is held at about the same height all the time, so the floor
  /// is a plane at that distance below it (±30 cm), and a plane much lower or higher is not it. On the stairs of
  /// 19/10 the lowest plane was the floor below: the phone seemed 2 m above it, railing, wall and the landing all
  /// stood "above the floor" (false alerts on the sides, a "Gradino su" while looking down). With no plane at the
  /// right height there is no floor (no alerts, "Cerco il pavimento"). Among the planes at that height: classified
  /// as floor first, then under the phone, then the nearest to the usual height. The usual height is the median of
  /// the last 300 floors chosen (1.15 m at the start: 1.0–1.25 m in the home tests of 18/10).
  private func floorPlane(frame: ARFrame) -> FloorPlane? {
    let cam = frame.camera.transform.columns.3
    let usual = heights.isEmpty ? StepTuning.usualHeight : heights.sorted()[heights.count / 2]
    var best: (plane: FloorPlane, rank: (Int, Int, Float))?
    for case let p as ARPlaneAnchor in frame.anchors where p.alignment == .horizontal {
      let y = (p.transform * SIMD4(p.center, 1)).y
      guard abs(cam.y - y - usual) <= StepTuning.heightTolerance else { continue }
      var isFloor = false
      if case .floor = p.classification { isFloor = true }
      let boundary = p.geometry.boundaryVertices.map { v -> SIMD2<Float> in
        let w = p.transform * SIMD4(v, 1)
        return SIMD2(w.x, w.z)
      }
      let plane = FloorPlane(y: y, classified: isFloor, underUser: Self.inside(SIMD2(cam.x, cam.z), boundary),
                             boundary: boundary, usualHeight: usual)
      let rank = (isFloor ? 1 : 0, plane.underUser ? 1 : 0, -abs(cam.y - y - usual))
      if let b = best, b.rank >= rank { continue }
      best = (plane, rank)
    }
    if let best {
      heights.append(cam.y - best.plane.y)
      if heights.count > 300 { heights.removeFirst() }
    }
    return best?.plane
  }

  /// Point in polygon (even-odd rule).
  private static func inside(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
      let a = poly[i], b = poly[j]
      if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
      j = i
    }
    return inside
  }

  // MARK: Alerts (main)

  private func handle(_ analysis: FrameAnalysis?, state newState: String, detail: String, light: Float?, ms: Double) {
    guard running else { return }
    let now = CACurrentMediaTime()
    if newState != state {
      log.write("state", newState == "tracking" ? "tracking \(detail)" : newState)
      state = newState
    }

    // Reliability (step 1.2) is updated first: it decides whether this frame may produce alerts.
    reliability.frame(newState == "active" ? .ok : newState == "searchingFloor" ? .noFloor : .noTracking,
                      light: light, now: now)
    if let a = analysis {
      inferences += 1
      stat.frames += 1
      stat.msSum += ms
      if a.scaleOk { stat.scaleOk += 1 }
      if a.scaleSource == "features" { stat.fromFeatures += 1 }
      let fresh = a.scaleSource == "features" || a.scaleSource == "floor"
      if fresh { stat.fresh += 1 }
      reliability.analysis(scaleFresh: fresh, now: now)
      stat.inliers += a.fitInliers
      stat.candidates += a.fitCandidates
      if a.dropSeen != nil { stat.dropSeen += 1 }
      if a.drop != nil { stat.drop += 1 }
    }
    let changed = reliability.update(now: now)
    if changed {
      log.write("reliability", "\(reliability.level.rawValue) \(reliability.reason.rawValue); light \(lightText)")
      // Felt at once, also where the voice is not heard; the voice may come later, after an alert.
      if reliability.level == .unavailable { buzzSuspended(now: now) }
    }

    if let a = analysis, reliability.raw != .unavailable {
      // Step 1.6: what is farther than the distance set does not count, so that it is announced as new once it
      // comes within that distance.
      let limit = settings.alertDistance
      for zone in Zone.allCases {
        tracks[zone.rawValue].append(a.zones[zone.rawValue].flatMap { $0.distance <= limit ? $0 : nil })
        if tracks[zone.rawValue].count > GuideTuning.window { tracks[zone.rawValue].removeFirst() }
      }
      dropTrack.append(a.drop.flatMap { $0.distance <= limit ? $0 : nil })
      if dropTrack.count > StepTuning.window { dropTrack.removeFirst() }
      uprightSince = a.nearestFloor > GuideTuning.tiltDownDist ? (uprightSince ?? now) : nil
      // Alerts need an analysed frame with light: while the guide is suspended (no tracking, no floor, or black
      // frames) nothing is announced. They resume with the first good frame, before "Avvisi di nuovo affidabili"
      // (1 s later), so that an obstacle met right then is not kept silent.
      alertIfNeeded(now: now)
    } else if analysis != nil {
      // black frames although ARKit still tracks: what they show is not trusted, not even a moment later
      tracks = [[], [], []]
      dropTrack = []
      uprightSince = nil
    } else {
      // no depth this frame (no tracking or no floor yet): zones decay
      for zone in Zone.allCases where !tracks[zone.rawValue].isEmpty { tracks[zone.rawValue].removeFirst() }
      if !dropTrack.isEmpty { dropTrack.removeFirst() }
    }

    speakLightIfPossible(now: now)

    // Reliability messages wait for the voice to be free, so they never cut an alert short.
    let cut = voice.speaking && voice.speakingReliability && reliability.changePending
    if !voice.speaking || cut, let text = reliability.takeMessage(now: now) {
      voice.say(text, interrupt: cut, reliability: true)
      log.write("reliability-voice", cut ? "\(text) (cut the previous one)" : text)
      // the reminder every 15 s while suspended (the change itself has buzzed already)
      if reliability.level == .unavailable && now - lastSuspendBuzz > 5 { buzzSuspended(now: now) }
    }

    // Spoken hint: the phone is held too upright to see the floor close by.
    let upright = uprightSince.map { now - $0 > 3 } ?? false
    if upright && now - lastHint >= GuideTuning.hintEvery && !voice.speaking {
      lastHint = now
      voice.say("Inclina il telefono verso il basso")
      log.write("hint", "upright")
    }

    if changed || now - lastStatus >= 1 { sendStatus(now: now) }
  }

  private func alertIfNeeded(now: Double) {
    // A zone is confirmed when it was hit in at least 3 of the last 5 frames. It is announced when it becomes
    // occupied and then only when the user gets a step closer (2 m → 1.5 m → 1 m → half a metre): with a message
    // every 2 s per zone the voice never stopped in a narrow flat (tests of 18/10).
    // The step remembered is where the obstacle is now, not the nearest one announced: when the zone moves farther
    // (another obstacle, or a false hit gone), getting closer again is announced. With the nearest one, a false hit
    // half a metre ahead kept "davanti" silent for a whole walk in the kitchen (test of 18/10 night: 1 message ahead,
    // 52 on the sides).
    if !dropAlertIfNeeded(now: now) { return }  // step 1.5: a step down goes first
    var candidates: [(zone: Zone, hit: ZoneHit)] = []
    for zone in Zone.allCases {
      let i = zone.rawValue
      let hits = tracks[i].compactMap { $0 }
      guard hits.count >= GuideTuning.hitsNeeded, let latest = tracks[i].last(where: { $0 != nil }) ?? nil else {
        if now - lastConfirmed[i] > GuideTuning.zoneClearAfter { lastStep[i] = nil }
        continue
      }
      lastConfirmed[i] = now
      let low = hits.filter(\.low).count * 2 > hits.count
      let stepUp = hits.filter(\.stepUp).count * 2 > hits.count
      candidates.append((zone, ZoneHit(distance: latest.distance, low: low, area: latest.area, stepUp: stepUp)))  // latest: less delay
    }
    // A step up spans the walking line: its ends on the sides are the same step, not two more low obstacles.
    if let up = candidates.first(where: { $0.zone == .ahead && $0.hit.stepUp }) {
      candidates.removeAll { $0.zone != .ahead && $0.hit.low && abs($0.hit.distance - up.hit.distance) <= 0.3 }
    }
    // Nearest first; "ahead" wins a tie.
    candidates.sort { ($0.hit.distance, $0.zone == .ahead ? 0 : 1) < ($1.hit.distance, $1.zone == .ahead ? 0 : 1) }
    for c in candidates {
      let i = c.zone.rawValue
      let step = GuideVoice.step(c.hit.distance)
      if let last = lastStep[i], step >= last {  // nothing new: same distance or farther
        lastStep[i] = step
        continue
      }
      guard now - lastSpoken[i] >= GuideTuning.zoneCooldown else { continue }
      // Only something close straight ahead may cut a message short; never a light warning (agreed for step 1.4).
      // With vibration only nothing is cut: two vibrations at once would be felt as one.
      let urgent = settings.voice && c.zone == .ahead && c.hit.distance <= 1.0 && voice.speakingZone != .ahead
        && !voice.speakingLight
      if signalBusy(now: now) && !urgent { return }
      let text = GuideVoice.message(c.zone, c.hit)
      let played = signal(c.hit.stepUp ? .step : FeedbackKind(c.zone), step: step, low: c.hit.low, text: text,
                          zone: c.zone, interrupt: voice.speaking, now: now)
      lastSpoken[i] = now
      lastStep[i] = step
      lastAlertText = text
      if c.hit.stepUp { lastStepText = "su, " + text.dropFirst("Gradino su, ".count) }
      log.write("alert", zone: c.zone.key, distance: c.hit.distance, low: c.hit.low,
                String(format: "%@; area %.3f m2; reliability %@; haptic %d sound %d in %.1f ms", text, c.hit.area,
                       reliability.level.rawValue, played.haptic ? 1 : 0, played.sound ? 1 : 0, played.ms))
      return
    }
  }

  /// Step 1.5: a step down is confirmed in 5 of the last 8 frames (half a second: a false one on a flat floor lasts
  /// less) and announced like an obstacle: when it appears and at each half metre closer. It goes before the
  /// obstacles, but never cuts a message short. Returns false when it has spoken, or while it waits for the voice:
  /// no obstacle message starts then.
  private func dropAlertIfNeeded(now: Double) -> Bool {
    let hits = dropTrack.compactMap { $0 }
    guard hits.count >= StepTuning.hitsNeeded, let latest = dropTrack.last(where: { $0 != nil }) ?? nil else {
      if now - dropLastConfirmed > GuideTuning.zoneClearAfter { dropLastStep = nil }
      return true
    }
    dropLastConfirmed = now
    let step = GuideVoice.step(latest.distance)
    if let last = dropLastStep, step >= last {
      dropLastStep = step
      return true
    }
    guard now - dropLastSpoken >= GuideTuning.zoneCooldown else { return true }
    if signalBusy(now: now) { return false }
    let text = GuideVoice.dropMessage(latest)
    let played = signal(.step, step: step, text: text, zone: .ahead, now: now)
    dropLastSpoken = now
    dropLastStep = step
    lastAlertText = text
    lastStepText = "giù, " + text.dropFirst("Gradino giù, ".count)
    log.write("step", zone: "down", distance: latest.distance,
              String(format: "%@; %.2f m lower, jump %.2f m, floor before %.3f m2, area %.3f m2; reliability %@; haptic %d sound %d in %.1f ms",
                     text, latest.depth, latest.jump, latest.floorBefore, latest.area, reliability.level.rawValue,
                     played.haptic ? 1 : 0, played.sound ? 1 : 0, played.ms))
    return false
  }

  // MARK: Light passages (main, step 1.4)

  private func handleLight(_ a: LightAnalysis) {
    guard running && sessionStarted else { return }
    let now = CACurrentMediaTime()
    lightView = a
    if let kind = lightWarning.update(a, now: now) {
      log.write("light", zone: kind.rawValue, distance: a.front,
                String(format: "%@; feet %.0f, passage %.0f, share %.0f%%; light %@; reliability %@", kind.message,
                       a.feet, a.passage, 100 * (kind == .dark ? a.darkShare : a.brightShare), lightText,
                       reliability.level.rawValue))
      pendingLight = (kind, now)
    }
    speakLightIfPossible(now: now)
  }

  /// A light warning waits for the voice to be free (it never cuts a message short) and is dropped when stale.
  private func speakLightIfPossible(now: Double) {
    guard let p = pendingLight else { return }
    if now - p.at > LightTuning.speakWithin {
      pendingLight = nil
      log.write("light-dropped", p.kind.message)
      return
    }
    guard !signalBusy(now: now) else { return }
    pendingLight = nil
    let played = signal(.light, text: p.kind.message, light: true, now: now)
    lastLightText = p.kind.message
    log.write("light-voice", "\(p.kind.message); haptic \(played.haptic ? 1 : 0); waited \(String(format: "%.1f", now - p.at)) s")
  }

  /// Step 1.6: whether a new alert must wait: while a message is spoken or, with vibration only, until the previous
  /// vibration has been felt.
  private func signalBusy(now: Double) -> Bool {
    settings.voice ? voice.speaking : now < signalQuietUntil
  }

  /// Plays an alert as set (step 1.6): vibration and sound first, felt while the voice is still starting, then the
  /// voice. Returns what was played and how long the vibration took to start.
  private func signal(_ kind: FeedbackKind, step: Int = 2, low: Bool = false, text: String, zone: Zone? = nil,
                      interrupt: Bool = false, light: Bool = false, now: Double) -> (haptic: Bool, sound: Bool, ms: Double) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let played = feedback.play(kind, step: step, low: low, haptic: settings.vibration, sound: settings.sound)
    let ms = elapsedMs(since: t0)
    if settings.voice { voice.say(text, zone: zone, interrupt: interrupt, light: light) }
    signalQuietUntil = now + GuideSettings.vibrationGap
    return (played.haptic, played.sound, ms)
  }

  private func buzzSuspended(now: Double) {
    lastSuspendBuzz = now
    guard settings.vibration else { return }  // step 1.6, voice only: the message is spoken all the same
    let played = feedback.play(.suspended)
    log.write("feedback", "suspended haptic \(played.haptic ? 1 : 0)")
  }

  private func sendStatus(now: Double) {
    let secs = now - lastStatus
    lastStatus = now
    let fps = Double(stat.frames) / max(secs, 0.001)
    let zones = Zone.allCases.map { z -> String in
      guard let h = tracks[z.rawValue].last ?? nil else { return "\(z.key) -" }
      return String(format: "%@ %.2f%@", z.key, h.distance, h.low ? " low" : "")
    }.joined(separator: "; ")
    // Written every second, also without analyses: the evening test reads light against tracking and scale here.
    let n = max(stat.frames, 1)
    // Light ahead (step 1.4): at the feet, and the share of the far view that is dark / bright.
    let view = lightView.map { v in
      String(format: "feet %.0f, dark %.0f%%, bright %.0f%%%@", v.feet, 100 * v.darkShare, 100 * v.brightShare,
             v.kind.map { ", \($0.rawValue) passage" } ?? "")
    } ?? "-"
    log.write("stat", String(format: "fps %.1f; infer+analysis %.0f ms; scale ok %d/%d (features %d, fresh %d); fit %d/%d; %@; %@; voice %@; light %@; tracking %@; reliability %@ %@; light passage %@; step down %d/%d frames (seen/accepted)",
                             fps, stat.msSum / Double(n), stat.scaleOk, stat.frames, stat.fromFeatures, stat.fresh,
                             stat.inliers / n, stat.candidates / n, zones, MemoryProbe.thermal(),
                             voice.speaking ? "busy" : "free", lightText, state,
                             reliability.level.rawValue, reliability.reason.rawValue, view, stat.dropSeen, stat.drop))
    let upright = uprightSince.map { now - $0 > 3 } ?? false
    var status: [String: Any] = [
      "state": upright && state == "active" ? "upright" : state, "fps": fps, "lastAlert": lastAlertText,
      "thermal": MemoryProbe.thermal(), "reliability": reliability.level.rawValue,
      "reliabilityReason": reliability.reason.rawValue, "lastLight": lastLightText, "lastStep": lastStepText,
    ]
    if let l = reliability.light { status["light"] = l }
    onStatus?(status)
    stat = (0, 0, 0, 0, 0, 0, 0, 0, 0)
  }

  private var lightText: String { reliability.light.map { String(format: "%.0f", $0) } ?? "-" }
}
