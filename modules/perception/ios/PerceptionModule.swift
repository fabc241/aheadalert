// Native perception module. MVP features: obstacle guide (ObstacleGuide.swift, step 1.1), its vibrations and sounds (GuideFeedback.swift, step 1.3), light-passage warning (LightAnalyzer.swift, step 1.4), steps down and up (ObstacleAnalyzer.swift, step 1.5), settings (GuideSettings.swift, step 1.6), photo and voice for "Cosa ho davanti?" (SceneDescription.swift, step 1.8), microphone and echo cancellation for the voice commands (VoiceCommands.swift, step 1.9).
// Phase 0B (iPhone 13): on-device measurements to decide what goes into the MVP.
// - Depth Anything V2 Small (Core ML) on photos and live ARKit frames, per compute unit
// - memory (phys_footprint, the metric iOS uses for out-of-memory termination) and thermal state
// - current ARKit frame saved as JPEG for QVAC ("what is in front of me?")
// - WAV writing and playback for the Supertonic voice
// User-facing strings (errors, thermal and compute-unit labels) stay in Italian: the app shows them.
import ARKit
import AVFoundation
import CoreML
import ExpoModulesCore
import ImageIO
import UniformTypeIdentifiers
import Vision
import os

public class PerceptionModule: Module {
  private let live = LiveDepthRunner()
  private let guide = ObstacleGuide()
  private let feedbackTest = GuideFeedback()  // main
  private var player: AudioPlayback?
  private let describer = DescriptionVoice()  // main

  public func definition() -> ModuleDefinition {
    Name("Perception")

    Events("onLiveProgress", "onGuideStatus", "onDescriptionStopped", "onVoiceEvent")

    OnCreate {
      // Step 1.8: the guide's alerts stop a description being spoken; its hint to tilt the phone waits meanwhile.
      self.guide.onAlert = { [weak self] in self?.describer.alert() }
      self.guide.describing = { [weak self] in self?.describer.active ?? false }
      self.describer.onStopped = { [weak self] reason in self?.sendEvent("onDescriptionStopped", ["reason": reason]) }
    }

    // MVP step 1.1: obstacle guide with short voice messages. Resolves once the camera is running.
    AsyncFunction("startGuide") { (promise: Promise) in
      self.guide.onStatus = { [weak self] s in self?.sendEvent("onGuideStatus", s) }
      self.guide.start { result in
        switch result {
        case .success(let r): promise.resolve(r)
        case .failure(let e): promise.reject("E_GUIDE", e.localizedDescription)
        }
      }
    }

    AsyncFunction("stopGuide") { (promise: Promise) in
      self.guide.stop { promise.resolve(nil) }
    }

    // MVP step 1.6: the guide's settings, kept on the phone. Applied at once, also while the guide runs.
    Function("guideSettings") { () -> [String: Any] in GuideSettings.load().dictionary }

    Function("setGuideSettings") { (values: [String: Any]) -> [String: Any] in
      let settings = GuideSettings(values)
      settings.save()
      self.guide.apply(settings)
      return settings.dictionary
    }

    // MVP step 1.3: the guide's vibrations and sounds on their own, to learn them standing still and to check that
    // they are told apart (src/app/feedback-test.tsx). The guide must be stopped (it owns the same hardware).
    AsyncFunction("startFeedbackTest") { () -> [String: Any] in
      AppAudio.activate()
      self.feedbackTest.stop()
      self.feedbackTest.start()
      return ["haptics": GuideFeedback.hapticsSupported, "headphones": GuideFeedback.headphones]
    }.runOnQueue(.main)

    AsyncFunction("playFeedback") { (kind: String, step: Int, low: Bool, haptic: Bool, sound: Bool) -> [String: Any] in
      guard let k = FeedbackKind(rawValue: kind) else { throw Phase0Error("Segnale sconosciuto: \(kind)") }
      let played = self.feedbackTest.play(k, step: step, low: low, haptic: haptic, sound: sound)
      return ["haptic": played.haptic, "sound": played.sound, "headphones": GuideFeedback.headphones]
    }.runOnQueue(.main)

    AsyncFunction("stopFeedbackTest") {
      self.feedbackTest.stop()
    }.runOnQueue(.main)

    // MVP step 1.8: "Cosa ho davanti?". The models run in JavaScript (src/assistant/describe.ts).
    // Photo: from the guide's camera when it runs, otherwise a short camera session.
    AsyncFunction("describeShot") { (maxSide: Int, promise: Promise) in
      let done: (Result<[String: Any], Error>) -> Void = { result in
        switch result {
        case .success(let r): promise.resolve(r)
        case .failure(let e): promise.reject("E_SHOT", e.localizedDescription)
        }
      }
      if self.guide.cameraRunning { self.guide.shot(maxSide: maxSide, completion: done) }
      else { SceneShot.capture(maxSide: maxSide, completion: done) }
    }.runOnQueue(.main)

    AsyncFunction("describeBegin") { self.describer.begin() }.runOnQueue(.main)

    /// Speaks the description; false when it has been stopped meanwhile.
    AsyncFunction("describeSpeak") { (text: String) -> Bool in self.describer.speak(text) }.runOnQueue(.main)

    AsyncFunction("describeFinish") { (promise: Promise) in
      self.describer.finish { reason in promise.resolve(reason) }
    }.runOnQueue(.main)

    AsyncFunction("describeStop") { self.describer.stop() }.runOnQueue(.main)

    AsyncFunction("describeSay") { (text: String) in self.describer.say(text) }.runOnQueue(.main)

    // MVP step 1.9: voice commands. JavaScript reads the microphone (echo-cancelled, 16 kHz mono float32) about every
    // 100 ms and runs Whisper on it (src/assistant/voiceCommands.ts).
    AsyncFunction("voiceStart") { (promise: Promise) in
      VoiceEngine.shared.onEvent = { [weak self] e in self?.sendEvent("onVoiceEvent", ["event": e]) }
      VoiceEngine.shared.start { result in
        switch result {
        case .success: promise.resolve(nil)
        case .failure(let e): promise.reject("E_VOICE", e.localizedDescription)
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("voiceStop") { VoiceEngine.shared.stop() }.runOnQueue(.main)

    Function("voiceRead") { () -> [String: Any] in VoiceEngine.shared.read() }

    /// What the app said (guide, description) from `since` (Unix ms) on, or is saying.
    AsyncFunction("appSpeechSince") { (since: Double) -> [String] in AppSpeech.since(since) }.runOnQueue(.main)

    Constant("documentsPath") { Paths.documents.path }

    // Tests to run at launch, comma-separated (set from the Mac with devicectl --environment-variables).
    Constant("autoRun") { ProcessInfo.processInfo.environment["PHASE0_AUTO"] ?? "" }

    Function("deviceInfo") { () -> [String: Any] in
      var info = MemoryProbe.snapshot()
      info["model"] = Self.modelIdentifier()
      info["system"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
      info["physicalMemoryMB"] = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
      info["thermal"] = MemoryProbe.thermal()
      info["lidar"] = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
      info["arkit"] = ARWorldTrackingConfiguration.isSupported
      return info
    }

    Function("memory") { () -> [String: Any] in
      var m = MemoryProbe.snapshot()
      m["thermal"] = MemoryProbe.thermal()
      return m
    }

    Function("startMemorySampler") { MemoryProbe.startSampler() }
    Function("stopMemorySampler") { () -> Double in MemoryProbe.stopSampler() }

    // The screen must stay on during measurements (ARKit would stop otherwise).
    Function("setKeepAwake") { (on: Bool) in
      DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
    }

    Function("fileExists") { (path: String) -> Bool in
      FileManager.default.fileExists(atPath: path)
    }

    AsyncFunction("writeText") { (path: String, text: String) in
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }

    AsyncFunction("appendText") { (path: String, text: String) in
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
      let h = try FileHandle(forWritingTo: url)
      defer { try? h.close() }
      try h.seekToEnd()
      try h.write(contentsOf: Data(text.utf8))
    }

    AsyncFunction("readFile") { (path: String) -> Data in
      try Data(contentsOf: URL(fileURLWithPath: path))
    }

    // Compiles the .mlpackage copied into Documents/phase0 (once) and returns the timing.
    AsyncFunction("prepareDepthModel") { () -> [String: Any] in
      try DepthModel.prepare()
    }

    // Same protocol as on the Mac (Phase 0A): 3 warm-up + 30 inferences over the photos, per unit.
    AsyncFunction("benchDepthPhotos") { () -> [[String: Any]] in
      try DepthModel.benchPhotos()
    }

    // Live ARKit frames for `seconds` seconds on the given compute unit.
    AsyncFunction("benchDepthLive") { (units: String, seconds: Double, promise: Promise) in
      self.live.run(units: units, seconds: seconds, progress: { p in
        self.sendEvent("onLiveProgress", p)
      }, completion: { result in
        switch result {
        case .success(let r): promise.resolve(r)
        case .failure(let e): promise.reject("E_LIVE", e.localizedDescription)
        }
      })
    }

    // Saves the current ARKit frame as a portrait JPEG (long side `maxSide`).
    AsyncFunction("captureFrame") { (maxSide: Int, promise: Promise) in
      FrameCapture.capture(maxSide: maxSide) { result in
        switch result {
        case .success(let r): promise.resolve(r)
        case .failure(let e): promise.reject("E_CAPTURE", e.localizedDescription)
        }
      }
    }

    // Apple OCR (Vision), the fallback foreseen in the plan: Italian, "accurate" level.
    AsyncFunction("recognizeText") { (path: String) -> [String: Any] in
      guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Phase0Error("immagine non leggibile") }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["it-IT"]
      request.usesLanguageCorrection = true
      let t0 = DispatchTime.now().uptimeNanoseconds
      try VNImageRequestHandler(cgImage: cg).perform([request])
      let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        .map { ["text": $0.string, "confidence": Double($0.confidence)] as [String: Any] }
      return ["ms": elapsedMs(since: t0), "lines": lines]
    }

    // 16-bit mono PCM samples (as returned by QVAC textToSpeech) → WAV file.
    AsyncFunction("writeWav") { (path: String, samples: [Double], sampleRate: Int) in
      try Wav.write(path: path, samples: samples, sampleRate: sampleRate)
    }

    AsyncFunction("playAudio") { (path: String, promise: Promise) in
      DispatchQueue.main.async {
        do {
          let p = try AudioPlayback(url: URL(fileURLWithPath: path)) {
            self.player = nil
            promise.resolve(nil)
          }
          self.player = p
          p.start()
        } catch {
          promise.reject("E_AUDIO", error.localizedDescription)
        }
      }
    }
  }

  static func modelIdentifier() -> String {
    var sys = utsname()
    uname(&sys)
    return withUnsafeBytes(of: &sys.machine) { buf in
      String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }
}

// MARK: - Paths

enum Paths {
  static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  static let phase0 = documents.appendingPathComponent("phase0")
  static let modelPackage = phase0.appendingPathComponent("DepthAnythingV2SmallF16.mlpackage")
  static let photos = phase0.appendingPathComponent("real-photos")
  static let results = phase0.appendingPathComponent("results")
  static let shots = phase0.appendingPathComponent("shots")
  static var compiledModel: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc")
  }
}

struct Phase0Error: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

func elapsedMs(since start: UInt64) -> Double {
  Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

func median(_ v: [Double]) -> Double {
  guard !v.isEmpty else { return 0 }
  let s = v.sorted()
  return s[s.count / 2]
}

func p90(_ v: [Double]) -> Double {
  guard !v.isEmpty else { return 0 }
  let s = v.sorted()
  return s[min(s.count - 1, Int(Double(s.count) * 0.9))]
}

// MARK: - Memory and thermal state

enum MemoryProbe {
  private static var timer: DispatchSourceTimer?
  private static var peak: Double = 0
  private static let lock = NSLock()

  /// phys_footprint: the same metric iOS uses to terminate apps that use too much memory.
  static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  static func snapshot() -> [String: Any] {
    ["footprintMB": footprintMB(), "availableMB": Double(os_proc_available_memory()) / 1_048_576]
  }

  static func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "normale"
    case .fair: return "tiepido"
    case .serious: return "caldo"
    case .critical: return "critico"
    @unknown default: return "sconosciuto"
    }
  }

  static func startSampler() {
    lock.lock(); defer { lock.unlock() }
    timer?.cancel()
    peak = footprintMB()
    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    t.schedule(deadline: .now(), repeating: .milliseconds(200))
    var lastLogged = peak
    t.setEventHandler {
      let v = footprintMB()
      lock.lock(); peak = max(peak, v); lock.unlock()
      // Console trace (devicectl --console): useful when iOS kills the app for memory
      if abs(v - lastLogged) >= 100 {
        lastLogged = v
        NSLog("[phase0] app memory %.0f MB, available %.0f MB", v, Double(os_proc_available_memory()) / 1_048_576)
      }
    }
    t.resume()
    timer = t
  }

  static func stopSampler() -> Double {
    lock.lock(); defer { lock.unlock() }
    timer?.cancel()
    timer = nil
    return max(peak, footprintMB())
  }
}

// MARK: - Depth Anything V2 Small (Core ML)

enum DepthModel {
  static let unitsTable: [(key: String, label: String, units: MLComputeUnits)] = [
    ("cpu", "Solo CPU", .cpuOnly),
    ("gpu", "CPU + GPU", .cpuAndGPU),
    ("ane", "CPU + Neural Engine", .cpuAndNeuralEngine),
    ("all", "Tutte (.all)", .all),
  ]

  static func units(for key: String) throws -> (label: String, units: MLComputeUnits) {
    guard let u = unitsTable.first(where: { $0.key == key }) else { throw Phase0Error("unità sconosciuta: \(key)") }
    return (u.label, u.units)
  }

  static func prepare() throws -> [String: Any] {
    let fm = FileManager.default
    if fm.fileExists(atPath: Paths.compiledModel.path) {
      return ["compiled": false, "compileMs": 0]
    }
    guard fm.fileExists(atPath: Paths.modelPackage.path) else {
      throw Phase0Error("Modello non trovato in Documents/phase0: va copiato dal Mac (scripts/phase0/copy-to-iphone.sh)")
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let tmp = try MLModel.compileModel(at: Paths.modelPackage)
    try fm.createDirectory(at: Paths.compiledModel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: tmp, to: Paths.compiledModel)
    return ["compiled": true, "compileMs": elapsedMs(since: t0)]
  }

  static func load(_ units: MLComputeUnits) throws -> (model: MLModel, loadMs: Double) {
    _ = try prepare()
    let config = MLModelConfiguration()
    config.computeUnits = units
    let t0 = DispatchTime.now().uptimeNanoseconds
    let model = try MLModel(contentsOf: Paths.compiledModel, configuration: config)
    return (model, elapsedMs(since: t0))
  }

  static func benchPhotos() throws -> [[String: Any]] {
    let files = try FileManager.default.contentsOfDirectory(at: Paths.photos, includingPropertiesForKeys: nil)
      .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw Phase0Error("Nessuna foto in Documents/phase0/real-photos") }
    let images: [CGImage] = files.compactMap { url in
      guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    let outDir = Paths.results.appendingPathComponent("depth-iphone")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    var rows: [[String: Any]] = []
    for u in unitsTable {
      let (model, loadMs) = try load(u.units)
      let inputName = model.modelDescription.inputDescriptionsByName.keys.first!
      let outputName = model.modelDescription.outputDescriptionsByName.keys.first!
      guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else {
        throw Phase0Error("l'input del modello non è un'immagine")
      }
      let inputs: [MLDictionaryFeatureProvider] = try images.map { cg in
        let fv = try MLFeatureValue(cgImage: cg, constraint: constraint,
                                    options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        return try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
      }
      for i in 0..<3 { _ = try model.prediction(from: inputs[i % inputs.count]) }
      var times: [Double] = []
      for i in 0..<30 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let out = try model.prediction(from: inputs[i % inputs.count])
        times.append(elapsedMs(since: t0))
        // Neural Engine maps saved for a visual comparison with the Mac ones (Float16 on the ANE)
        if u.units == .cpuAndNeuralEngine && i < inputs.count, let v = out.featureValue(for: outputName),
           let d = DepthMap(v) {
          let name = files[i].deletingPathExtension().lastPathComponent
          d.savePNG(to: outDir.appendingPathComponent("\(name)-depth-ane.png"))
        }
      }
      rows.append([
        "units": u.key, "label": u.label, "loadMs": loadMs,
        "medianMs": median(times), "p90Ms": p90(times), "fps": 1000 / median(times),
        "input": "\(constraint.pixelsWide)x\(constraint.pixelsHigh)",
        "thermal": MemoryProbe.thermal(), "footprintMB": MemoryProbe.footprintMB(),
      ])
    }
    return rows
  }
}

/// Relative depth map (Depth Anything: high values = near).
struct DepthMap {
  let values: [Float]
  let width: Int
  let height: Int

  init(values: [Float], width: Int, height: Int) {
    self.values = values
    self.width = width
    self.height = height
  }

  init?(_ value: MLFeatureValue) {
    if let pb = value.imageBufferValue {
      self.init(pixelBuffer: pb)
    } else if let arr = value.multiArrayValue {
      let shape = arr.shape.map { $0.intValue }
      let h = shape[shape.count - 2], w = shape[shape.count - 1]
      self.init(values: (0..<(w * h)).map { arr[$0].floatValue }, width: w, height: h)
    } else {
      return nil
    }
  }

  init?(pixelBuffer pb: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let format = CVPixelBufferGetPixelFormatType(pb)
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      let row = base.advanced(by: y * rowBytes)
      for x in 0..<w {
        switch format {
        case kCVPixelFormatType_OneComponent16Half:
          out[y * w + x] = Float(row.assumingMemoryBound(to: Float16.self)[x])
        case kCVPixelFormatType_OneComponent32Float:
          out[y * w + x] = row.assumingMemoryBound(to: Float.self)[x]
        case kCVPixelFormatType_OneComponent8:
          out[y * w + x] = Float(row.assumingMemoryBound(to: UInt8.self)[x])
        default:
          return nil
        }
      }
    }
    self.init(values: out, width: w, height: h)
  }

  /// Mean of the lower half in left/centre/right thirds, normalised 0–1 over the map:
  /// the kind of post-processing the MVP will need, here only to measure its cost.
  func zones() -> [Double] {
    let lo = values.min() ?? 0, hi = values.max() ?? 1
    let range = max(hi - lo, 1e-6)
    var sums = [Double](repeating: 0, count: 3), counts = [Double](repeating: 0, count: 3)
    for y in (height / 2)..<height {
      for x in 0..<width {
        let z = min(2, x * 3 / width)
        sums[z] += Double((values[y * width + x] - lo) / range)
        counts[z] += 1
      }
    }
    return (0..<3).map { counts[$0] > 0 ? sums[$0] / counts[$0] : 0 }
  }

  func savePNG(to url: URL) {
    let lo = values.min() ?? 0, hi = values.max() ?? 1
    let range = max(hi - lo, 1e-6)
    var bytes = values.map { UInt8(max(0, min(255, (($0 - lo) / range) * 255))) }
    let w = width, h = height
    let img: CGImage? = bytes.withUnsafeMutableBytes { buf in
      CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
    }
    guard let img, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
  }
}

// MARK: - Live depth on ARKit frames

final class LiveDepthRunner: NSObject, ARSessionDelegate {
  private let session = ARSession()
  private let frameQueue = DispatchQueue(label: "phase0.ar.frames")
  private let inferQueue = DispatchQueue(label: "phase0.depth.infer", qos: .userInitiated)
  // The measurement loop (waiting, progress, teardown) runs on its own queue: on inferQueue it would
  // block the inferences, and the final sync on inferQueue would crash the app.
  private let controlQueue = DispatchQueue(label: "phase0.depth.control")
  private var running = false

  // measurement state (accessed on frameQueue)
  private var request: VNCoreMLRequest?
  private var busy = false
  private var arFrames = 0
  private var inferTimes: [Double] = []
  private var postTimes: [Double] = []
  private var trackingNormal = 0
  private var lightValues: [Double] = []
  private var lastZones: [Double] = []
  private var started: UInt64 = 0

  func run(units key: String, seconds: Double,
           progress: @escaping ([String: Any]) -> Void,
           completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard ARWorldTrackingConfiguration.isSupported else {
      return completion(.failure(Phase0Error("ARKit non supportato")))
    }
    guard !running else { return completion(.failure(Phase0Error("misura già in corso"))) }
    running = true

    controlQueue.async {
      do {
        let u = try DepthModel.units(for: key)
        let (model, loadMs) = try DepthModel.load(u.units)
        let request = try VNCoreMLRequest(model: VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        self.frameQueue.sync { self.reset(request) }

        let thermalStart = MemoryProbe.thermal()
        MemoryProbe.startSampler()
        DispatchQueue.main.sync {
          let config = ARWorldTrackingConfiguration()
          config.planeDetection = [.horizontal]
          config.isLightEstimationEnabled = true
          self.session.delegate = self
          self.session.delegateQueue = self.frameQueue
          self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
          Thread.sleep(forTimeInterval: 1)
          progress(self.frameQueue.sync { self.summary(final: false) })
        }

        DispatchQueue.main.sync { self.session.pause() }
        // wait for any inference still running
        self.inferQueue.sync {}
        var result = self.frameQueue.sync { self.summary(final: true) }
        result["units"] = key
        result["label"] = u.label
        result["loadMs"] = loadMs
        result["peakFootprintMB"] = MemoryProbe.stopSampler()
        result["thermalStart"] = thermalStart
        result["thermalEnd"] = MemoryProbe.thermal()
        self.frameQueue.sync { self.request = nil }
        self.running = false
        completion(.success(result))
      } catch {
        _ = MemoryProbe.stopSampler()
        self.running = false
        completion(.failure(error))
      }
    }
  }

  private func reset(_ request: VNCoreMLRequest) {
    self.request = request
    busy = false
    arFrames = 0
    inferTimes = []
    postTimes = []
    trackingNormal = 0
    lightValues = []
    lastZones = []
    started = DispatchTime.now().uptimeNanoseconds
  }

  private func summary(final: Bool) -> [String: Any] {
    let secs = max(elapsedMs(since: started) / 1000, 0.001)
    var r: [String: Any] = [
      "elapsedS": secs,
      "inferences": inferTimes.count,
      "depthFps": Double(inferTimes.count) / secs,
      "arFps": Double(arFrames) / secs,
      "medianMs": median(inferTimes),
      "p90Ms": p90(inferTimes),
      "postMedianMs": median(postTimes),
      "footprintMB": MemoryProbe.footprintMB(),
      "thermal": MemoryProbe.thermal(),
      "zones": lastZones,
    ]
    if final {
      r["trackingNormalPct"] = arFrames > 0 ? Double(trackingNormal) * 100 / Double(arFrames) : 0
      if !lightValues.isEmpty {
        r["lightMin"] = lightValues.min()
        r["lightMedian"] = median(lightValues)
        r["lightMax"] = lightValues.max()
      }
    }
    return r
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // on frameQueue
    arFrames += 1
    if case .normal = frame.camera.trackingState { trackingNormal += 1 }
    if let le = frame.lightEstimate { lightValues.append(Double(le.ambientIntensity)) }
    guard !busy, let request else { return }
    busy = true
    let pixelBuffer = frame.capturedImage  // do not retain the ARFrame
    inferQueue.async {
      let t0 = DispatchTime.now().uptimeNanoseconds
      let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
      try? handler.perform([request])
      let inferMs = elapsedMs(since: t0)
      let t1 = DispatchTime.now().uptimeNanoseconds
      var zones: [Double] = []
      if let obs = request.results?.first as? VNPixelBufferObservation,
         let d = DepthMap(pixelBuffer: obs.pixelBuffer) {
        zones = d.zones()
      } else if let obs = request.results?.first as? VNCoreMLFeatureValueObservation,
                let d = DepthMap(obs.featureValue) {
        zones = d.zones()
      }
      let postMs = elapsedMs(since: t1)
      self.frameQueue.async {
        self.inferTimes.append(inferMs)
        self.postTimes.append(postMs)
        self.lastZones = zones
        self.busy = false
      }
    }
  }
}

// MARK: - ARKit frame → JPEG

enum FrameCapture {
  private static var session: ARSession?

  static func capture(maxSide: Int, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    DispatchQueue.main.async {
      guard ARWorldTrackingConfiguration.isSupported else {
        return completion(.failure(Phase0Error("ARKit non supportato")))
      }
      let s = ARSession()
      session = s
      let config = ARWorldTrackingConfiguration()
      config.isLightEstimationEnabled = true
      s.run(config)
      // one and a half seconds for exposure and focus to settle
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        defer { s.pause(); session = nil }
        guard let frame = s.currentFrame else {
          return completion(.failure(Phase0Error("nessun fotogramma dalla fotocamera")))
        }
        let pixelBuffer = frame.capturedImage
        let light = frame.lightEstimate.map { Double($0.ambientIntensity) }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            var img = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)  // portrait
            let scale = min(1, Double(maxSide) / Double(max(img.extent.width, img.extent.height)))
            if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            let ctx = CIContext()
            guard let data = ctx.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
            else { throw Phase0Error("conversione JPEG non riuscita") }
            try FileManager.default.createDirectory(at: Paths.shots, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970)
            let url = Paths.shots.appendingPathComponent("shot-\(stamp).jpg")
            try data.write(to: url)
            var r: [String: Any] = ["path": url.path, "width": Int(img.extent.width), "height": Int(img.extent.height)]
            if let light { r["light"] = light }
            completion(.success(r))
          } catch {
            completion(.failure(error))
          }
        }
      }
    }
  }
}

// MARK: - Audio

enum Wav {
  static func write(path: String, samples: [Double], sampleRate: Int) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let dataLength = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLength)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(dataLength)
    for s in samples {
      let v = Int16(max(-32768, min(32767, s.rounded())))
      withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }
}

final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
  private let player: AVAudioPlayer
  private let onDone: () -> Void

  init(url: URL, onDone: @escaping () -> Void) throws {
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try AVAudioSession.sharedInstance().setActive(true)
    player = try AVAudioPlayer(contentsOf: url)
    self.onDone = onDone
    super.init()
    player.delegate = self
  }

  func start() { player.play() }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onDone() }
}
