// MVP step 1.1: obstacles ahead, on the left and on the right, and low obstacles, with a short system voice.
// MVP step 1.2: reliability level (ReliabilityMonitor), spoken when it changes and shown on screen.
// Everything runs natively; JavaScript only starts/stops the guide and receives a status once a second.
//
// Pipeline per frame:
//   ARKit frame → Depth Anything V2 Small (relative inverse depth, known only up to scale and shift)
//   → metric scale fitted on the ARKit floor plane (rays that hit the floor give the true depth there)
//   → 3D point per sample → height above the floor, distance ahead, lateral offset from the walking line
//   → three zones (left / ahead / right) → debounce over a few frames → voice message.
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
    return false
  }

  /// Main thread only. With VoiceOver on, the voice and rate chosen for VoiceOver are used.
  func say(_ text: String, zone: Zone? = nil, interrupt: Bool = false, reliability: Bool = false) {
    if interrupt { synth.stopSpeaking(at: .immediate) }
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice(language: "it-IT")
    u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.1)
    u.prefersAssistiveTechnologySettings = true
    current = u
    deadline = CACurrentMediaTime() + min(6, 1 + Double(text.count) * 0.1)  // generous: ~2.5 s for an alert
    speakingZone = zone
    speakingReliability = reliability
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
    }
  }

  /// Distance step in half metres, as spoken: 1 = "mezzo metro" (up to 0.75 m) … 4 = "due metri".
  static func step(_ distance: Float) -> Int { max(1, min(4, Int((distance * 2).rounded()))) }

  /// Short on purpose: the user keeps walking while it is spoken (about half a second per word).
  static func message(_ zone: Zone, _ hit: ZoneHit) -> String {
    let dist = ["", "mezzo metro", "un metro", "un metro e mezzo", "due metri"][step(hit.distance)]
    let place = zone.spoken.prefix(1).uppercased() + zone.spoken.dropFirst()
    return "\(place)\(hit.low ? ", basso" : ""), \(dist)"
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

  func maybeSave(image: CVPixelBuffer, depth: DepthMap, camera: CameraSnapshot, floor: (y: Float, floor: Bool),
                 features: [SIMD3<Float>], analysis: FrameAnalysis) {
    let now = CACurrentMediaTime()
    guard let dir, count < 600, now - last >= 0.5 else { return }  // at most 5 minutes
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
    depth.values.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: base.appendingPathExtension("depth")) }
    let t = camera.transform, K = camera.intrinsics
    let cols = [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    let kcols = [K.columns.0, K.columns.1, K.columns.2].flatMap { [$0.x, $0.y, $0.z] }
    let zones: [Any] = analysis.zones.map { h -> Any in
      guard let h else { return NSNull() }
      return ["distance": h.distance, "low": h.low, "area": h.area]
    }
    let meta: [String: Any] = [
      "time": Date().timeIntervalSince1970, "transform": cols, "intrinsics": kcols,
      "imageWidth": camera.imageSize.width, "imageHeight": camera.imageSize.height,
      "depthWidth": depth.width, "depthHeight": depth.height,
      "floorY": floor.y, "floorClassified": floor.floor,
      "scaleOk": analysis.scaleOk, "scaleA": analysis.scaleA, "scaleB": analysis.scaleB,
      "scaleSource": analysis.scaleSource, "walls": analysis.walls,
      "walkDirection": camera.walkDirection.map { [$0.x, $0.y, $0.z] } ?? NSNull(),
      "fitInliers": analysis.fitInliers, "fitCandidates": analysis.fitCandidates,
      "nearestFloor": analysis.nearestFloor.isFinite ? analysis.nearestFloor : -1, "zones": zones,
      // ARKit feature points (world, metres): sparse but metric, to test a scale fit that does not rely on the floor
      "features": features.flatMap { [$0.x, $0.y, $0.z] },
    ]
    if let json = try? JSONSerialization.data(withJSONObject: meta) {
      try? json.write(to: base.appendingPathExtension("json"))
    }
  }
}

// MARK: - Guide

final class ObstacleGuide: NSObject, ARSessionDelegate {
  private let session = ARSession()
  private let frameQueue = DispatchQueue(label: "guide.ar.frames")
  private let inferQueue = DispatchQueue(label: "guide.depth.infer", qos: .userInitiated)
  private let analyzer = ObstacleAnalyzer()  // inferQueue
  private let voice = GuideVoice()  // main
  private let log = GuideLog()
  private let recorder = GuideRecorder()  // inferQueue
  var onStatus: (([String: Any]) -> Void)?

  // frameQueue
  private var request: VNCoreMLRequest?
  private var busy = false
  private var trail: [(t: Double, p: SIMD3<Float>)] = []  // recent phone positions, for the walking direction

  // main
  private(set) var running = false
  private var sessionStarted = false
  private var startTime: Double = 0
  private var tracks: [[ZoneHit?]] = [[], [], []]
  private var lastSpoken: [Double] = [-100, -100, -100]
  private var lastStep: [Int?] = [nil, nil, nil]  // distance step last announced per zone, while it stays occupied
  private var lastConfirmed: [Double] = [-100, -100, -100]
  private var lastHint: Double = -100
  private var uprightSince: Double?
  private var reliability = ReliabilityMonitor(now: 0)
  private var lastStatus: Double = 0
  private var lastAlertText = ""
  private var inferences = 0
  private var state = "starting"
  private var stat = (frames: 0, scaleOk: 0, fromFeatures: 0, fresh: 0, inliers: 0, candidates: 0, msSum: 0.0)

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
      self.frameQueue.sync { self.request = request; self.busy = false }
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
        UIApplication.shared.isIdleTimerDisabled = true
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.isLightEstimationEnabled = true
        self.session.delegate = self
        self.session.delegateQueue = self.frameQueue
        self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        self.log.write("start", "device \(PerceptionModule.modelIdentifier()), alert \(GuideTuning.alertDistance) m from the body, phone offset \(GuideTuning.bodyOffset) m")
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

  private func resetMainState() {
    startTime = CACurrentMediaTime()
    tracks = [[], [], []]
    lastSpoken = [-100, -100, -100]
    lastStep = [nil, nil, nil]
    lastConfirmed = [-100, -100, -100]
    lastHint = -100
    uprightSince = nil
    reliability = ReliabilityMonitor(now: startTime)
    lastStatus = startTime
    lastAlertText = ""
    inferences = 0
    state = "starting"
    stat = (0, 0, 0, 0, 0, 0, 0)
  }

  // MARK: ARSessionDelegate (frameQueue)

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
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
    guard let floor = Self.floorPlane(frame: frame) else {
      DispatchQueue.main.async { self.handle(nil, state: "searchingFloor", detail: "", light: light, ms: 0) }
      return
    }
    let floorY = floor.y
    let features = frame.rawFeaturePoints?.points ?? []
    busy = true
    let pixelBuffer = frame.capturedImage  // do not retain the ARFrame
    let camera = CameraSnapshot(transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                                imageSize: frame.camera.imageResolution, walkDirection: walkDirection(frame))
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
        self.recorder.maybeSave(image: pixelBuffer, depth: depth, camera: camera, floor: floor, features: features, analysis: analysis)
      }
      self.frameQueue.async { self.busy = false }
      DispatchQueue.main.async { self.handle(analysis, state: "active", detail: "", light: light, ms: ms) }
    }
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

  /// World height of the floor: the lowest plane ARKit classifies as floor, otherwise the lowest horizontal
  /// plane at least 50 cm below the phone.
  private static func floorPlane(frame: ARFrame) -> (y: Float, floor: Bool)? {
    let camY = frame.camera.transform.columns.3.y
    var best: (y: Float, floor: Bool)?
    for case let p as ARPlaneAnchor in frame.anchors where p.alignment == .horizontal {
      let y = (p.transform * SIMD4(p.center, 1)).y
      guard camY - y >= 0.5 && camY - y <= 2.2 else { continue }
      var isFloor = false
      if case .floor = p.classification { isFloor = true }
      if let b = best, (b.floor && !isFloor) || (b.floor == isFloor && b.y <= y) { continue }
      best = (y, isFloor)
    }
    return best
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
    }
    let changed = reliability.update(now: now)
    if changed {
      log.write("reliability", "\(reliability.level.rawValue) \(reliability.reason.rawValue); light \(lightText)")
    }

    if let a = analysis, reliability.raw != .unavailable {
      for zone in Zone.allCases {
        tracks[zone.rawValue].append(a.zones[zone.rawValue])
        if tracks[zone.rawValue].count > GuideTuning.window { tracks[zone.rawValue].removeFirst() }
      }
      uprightSince = a.nearestFloor > GuideTuning.tiltDownDist ? (uprightSince ?? now) : nil
      // Alerts need an analysed frame with light: while the guide is suspended (no tracking, no floor, or black
      // frames) nothing is announced. They resume with the first good frame, before "Avvisi di nuovo affidabili"
      // (1 s later), so that an obstacle met right then is not kept silent.
      alertIfNeeded(now: now)
    } else if analysis != nil {
      // black frames although ARKit still tracks: what they show is not trusted, not even a moment later
      tracks = [[], [], []]
      uprightSince = nil
    } else {
      // no depth this frame (no tracking or no floor yet): zones decay
      for zone in Zone.allCases where !tracks[zone.rawValue].isEmpty { tracks[zone.rawValue].removeFirst() }
    }

    // Reliability messages wait for the voice to be free, so they never cut an alert short.
    let cut = voice.speaking && voice.speakingReliability && reliability.changePending
    if !voice.speaking || cut, let text = reliability.takeMessage(now: now) {
      voice.say(text, interrupt: cut, reliability: true)
      log.write("reliability-voice", cut ? "\(text) (cut the previous one)" : text)
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
      candidates.append((zone, ZoneHit(distance: latest.distance, low: low, area: latest.area)))  // latest: less delay
    }
    // Nearest first; "ahead" wins a tie.
    candidates.sort { ($0.hit.distance, $0.zone == .ahead ? 0 : 1) < ($1.hit.distance, $1.zone == .ahead ? 0 : 1) }
    for c in candidates {
      let i = c.zone.rawValue
      let step = GuideVoice.step(c.hit.distance)
      if let last = lastStep[i], step >= last { continue }  // nothing new: same distance or farther
      guard now - lastSpoken[i] >= GuideTuning.zoneCooldown else { continue }
      // Only something close straight ahead may cut a message short.
      let urgent = c.zone == .ahead && c.hit.distance <= 1.0 && voice.speakingZone != .ahead
      if voice.speaking && !urgent { return }
      let text = GuideVoice.message(c.zone, c.hit)
      voice.say(text, zone: c.zone, interrupt: voice.speaking)
      lastSpoken[i] = now
      lastStep[i] = step
      lastAlertText = text
      log.write("alert", zone: c.zone.key, distance: c.hit.distance, low: c.hit.low,
                String(format: "%@; area %.3f m2; reliability %@", text, c.hit.area, reliability.level.rawValue))
      return
    }
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
    log.write("stat", String(format: "fps %.1f; infer+analysis %.0f ms; scale ok %d/%d (features %d, fresh %d); fit %d/%d; %@; %@; voice %@; light %@; tracking %@; reliability %@ %@",
                             fps, stat.msSum / Double(n), stat.scaleOk, stat.frames, stat.fromFeatures, stat.fresh,
                             stat.inliers / n, stat.candidates / n, zones, MemoryProbe.thermal(),
                             voice.speaking ? "busy" : "free", lightText, state,
                             reliability.level.rawValue, reliability.reason.rawValue))
    let upright = uprightSince.map { now - $0 > 3 } ?? false
    var status: [String: Any] = [
      "state": upright && state == "active" ? "upright" : state, "fps": fps, "lastAlert": lastAlertText,
      "thermal": MemoryProbe.thermal(), "reliability": reliability.level.rawValue,
      "reliabilityReason": reliability.reason.rawValue,
    ]
    if let l = reliability.light { status["light"] = l }
    onStatus?(status)
    stat = (0, 0, 0, 0, 0, 0, 0)
  }

  private var lightText: String { reliability.light.map { String(format: "%.0f", $0) } ?? "-" }
}
