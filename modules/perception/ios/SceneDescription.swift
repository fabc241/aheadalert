// MVP step 1.8: "Cosa ho davanti?" – the native half. JavaScript runs the models (QVAC: VisionPsy and Bergamot,
// src/assistant/describe.ts); here:
// - the photo: from the guide's camera when the guide runs (no wait), otherwise from a short ARKit session;
// - the voice (system voice, as the guide's alerts);
// - its interruption: a guide alert stops a description being spoken (alerts first, agreed for step 1.8).
// Phase 0B left 30–100 MB behind at each request: the photo path created a new ARSession and a new CIContext every
// time. Both are now created once and reused.
// User-facing strings (errors, short messages) are in Italian.
import ARKit
import AVFoundation

// MARK: - Photo

enum SceneShot {
  private static let context = CIContext()
  private static var session: ARSession?  // main
  private static var waiting = false  // main: a photo from the short session is on its way
  /// After the first frame of a short session: time for exposure and focus. 1.5 s in Phase 0B (the whole wait).
  static let settle: Double = 0.5

  /// A camera frame as a portrait JPEG, long side `maxSide` (1024, as in Phase 0B: same input to the model).
  static func save(_ pixelBuffer: CVPixelBuffer, light: Double?, maxSide: Int, source: String, t0: Double,
                   completion: @escaping (Result<[String: Any], Error>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        var img = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)  // portrait
        let scale = min(1, Double(maxSide) / Double(max(img.extent.width, img.extent.height)))
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let data = context.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
        else { throw Phase0Error("conversione JPEG non riuscita") }
        let dir = Paths.documents.appendingPathComponent("describe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One file, overwritten: the photos are not kept (only the log is).
        let url = dir.appendingPathComponent("shot.jpg")
        try data.write(to: url)
        var r: [String: Any] = ["path": url.path, "width": Int(img.extent.width), "height": Int(img.extent.height),
                                "source": source, "ms": (CACurrentMediaTime() - t0) * 1000,
                                "brightness": meanLuma(pixelBuffer)]
        if let light { r["light"] = light }
        completion(.success(r))
      } catch {
        completion(.failure(error))
      }
    }
  }

  /// Mean luma (0–255) on a 32×24 grid of the camera's Y plane: a black photo is not described.
  static func meanLuma(_ pb: CVPixelBuffer) -> Double {
    guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return 255 }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 255 }
    let p = base.assumingMemoryBound(to: UInt8.self)
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    var sum = 0
    for j in 0..<24 { for i in 0..<32 { sum += Int(p[(j * h / 24 + h / 48) * stride + i * w / 32 + w / 64]) } }
    return Double(sum) / 768
  }

  /// Guide stopped: a short ARKit session, the same object every time, paused right after the photo.
  static func capture(maxSide: Int, completion: @escaping (Result<[String: Any], Error>) -> Void) {
    DispatchQueue.main.async {
      guard ARWorldTrackingConfiguration.isSupported else { return completion(.failure(Phase0Error("ARKit non supportato"))) }
      guard !waiting else { return completion(.failure(Phase0Error("foto già in corso"))) }
      let t0 = CACurrentMediaTime()
      let s = session ?? ARSession()
      session = s
      let config = ARWorldTrackingConfiguration()
      config.isLightEstimationEnabled = true
      s.run(config, options: [.resetTracking, .removeExistingAnchors])
      waiting = true
      var firstFrame: Double?
      func poll() {
        let now = CACurrentMediaTime()
        if let frame = s.currentFrame {
          firstFrame = firstFrame ?? now
          if now - firstFrame! >= settle {
            let pb = frame.capturedImage  // do not retain the ARFrame
            let light = frame.lightEstimate.map { Double($0.ambientIntensity) }
            s.pause()
            waiting = false
            return save(pb, light: light, maxSide: maxSide, source: "camera", t0: t0, completion: completion)
          }
        }
        if now - t0 > 3 {
          s.pause()
          waiting = false
          return completion(.failure(Phase0Error("nessun fotogramma dalla fotocamera")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
      }
      poll()
    }
  }
}

// MARK: - Voice

/// Main thread only. Speaks the description and the short messages ("Un momento…", "Troppo buio per descrivere")
/// with the system voice, as the guide does (with VoiceOver on, its voice and rate). Supertonic was agreed first, but
/// on 20/10 its first sentence took 2.3–3.9 s (up to 17 s) and the 7 s target was not met: the fallback agreed.
final class DescriptionVoice: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var utterance: AVSpeechUtterance?  // the description being spoken
  private var ended: String?
  private var waiters: [(String) -> Void] = []
  /// From begin() to the end of the description.
  private(set) var active = false
  /// Its voice has started: from now on a guide alert stops it.
  private(set) var speaking = false
  /// The description ended before JavaScript asked (alert or user): JavaScript stops its work.
  var onStopped: ((String) -> Void)?

  override init() {
    super.init()
    synth.delegate = self
  }

  func begin() {
    if active { end("replaced") }
    ended = nil
    utterance = nil
    active = true
    speaking = false
  }

  /// Returns false when the description has already ended (stopped meanwhile).
  func speak(_ text: String) -> Bool {
    guard active, ended == nil else { return false }
    let u = Self.utterance(text)
    utterance = u
    speaking = true
    Self.activateAudio()
    synth.stopSpeaking(at: .immediate)  // "Un momento…"
    synth.speak(u)
    return true
  }

  /// Resolves with "done" once the description has been spoken, or with why it stopped ("alert", "user").
  func finish(_ completion: @escaping (String) -> Void) {
    guard active else { return completion(ended ?? "done") }
    waiters.append(completion)
    if utterance == nil { end("done") }
  }

  /// "Ferma descrizione".
  func stop() {
    synth.stopSpeaking(at: .immediate)
    if active { end("user") }
  }

  /// A guide alert or reliability message is about to be spoken: it goes first. Before the description speaks
  /// (photo, model at work) nothing is stopped: the alert is short and the description follows.
  func alert() {
    if active && speaking { end("alert") }
  }

  /// Short message, at once.
  func say(_ text: String) {
    Self.activateAudio()
    synth.stopSpeaking(at: .immediate)
    synth.speak(Self.utterance(text))
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    DispatchQueue.main.async {
      guard u === self.utterance else { return }
      self.utterance = nil
      if !self.waiters.isEmpty { self.end("done") }
    }
  }

  private func end(_ reason: String) {
    guard active else { return }
    ended = reason
    active = false
    speaking = false
    if utterance != nil {
      utterance = nil
      synth.stopSpeaking(at: .immediate)
    }
    let w = waiters
    waiters = []
    w.forEach { $0(reason) }
    if reason != "done" { onStopped?(reason) }
  }

  private static func utterance(_ text: String) -> AVSpeechUtterance {
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice(language: "it-IT")
    u.prefersAssistiveTechnologySettings = true
    return u
  }

  /// Same settings as the guide (ObstacleGuide.load): set again with the same values, the guide's audio engine
  /// is not disturbed.
  private static func activateAudio() {
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    try? audio.setActive(true)
  }
}
