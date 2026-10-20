// MVP step 1.3: vibration per zone (Core Haptics) and a directional sound (3D audio, headphones only), played
// together with each obstacle alert, and a vibration of its own when the guide is suspended.
//
// Vibration: left = one short tap, right = two short taps, ahead = one long buzz, suspended = two long buzzes.
// Step 1.4: light passage ahead (dark or bright) = three short, quick taps, without sound.
// Step 1.5: step down or up ahead = one strong tap, then a long buzz (the same for both: the voice says which); the
// sound is the low click ahead.
// Stronger as the obstacle gets closer (distance step 4 = 2 m … 1 = half a metre). The voice takes about a second
// to say "Davanti, un metro": the vibration arrives before it.
// Sound: a short click placed on the left, ahead or on the right (HRTF), lower in pitch for a low obstacle. Only with
// headphones: with the phone at the chest its two speakers are one above the other, not left and right.
// Main thread only.
import AVFoundation
import CoreHaptics

enum FeedbackKind: String {
  case left, ahead, right, suspended, light, step

  init(_ zone: Zone) {
    switch zone {
    case .left: self = .left
    case .ahead: self = .ahead
    case .right: self = .right
    }
  }
}

enum FeedbackTuning {
  /// Haptic intensity per distance step (index 1 = half a metre … 4 = two metres).
  static let intensity: [Float] = [0, 1.0, 0.8, 0.6, 0.45]
  /// Left and right taps: stronger, they were too weak with the table above (first test of 18/10).
  static let tapIntensity: [Float] = [0, 1.0, 0.95, 0.85, 0.75]
  /// A tap is a short buzz with a click at its start: a bare transient was too weak, and two of them 0.15 s
  /// apart were felt as one (first test of 18/10).
  static let tap: Double = 0.12
  static let tapGap: Double = 0.2  // s of stillness between the two taps of "right"
  static let buzz: Double = 0.4  // s, "ahead" and each buzz of "suspended"
  static let buzzGap: Double = 0.25
  /// Light passage: quicker than the taps of "right", so that three of them are not taken for two.
  static let quickTap: Double = 0.07, quickTapGap: Double = 0.1
  static let stepGap: Double = 0.12  // s between the strong tap and the long buzz of a step
  /// Sound direction, degrees from straight ahead. Not ±90: a source exactly at the side sounds "inside the ear".
  static let azimuth: [FeedbackKind: Float] = [.left: -70, .ahead: 0, .right: 70, .step: 0]
  static let clickHz: Double = 1200, lowClickHz: Double = 500
  static let clickSeconds: Double = 0.07
  static let clickVolume: Float = 0.6
}

final class GuideFeedback {
  private var haptics: CHHapticEngine?
  private var hapticsRunning = false
  private let audio = AVAudioEngine()
  private let env = AVAudioEnvironmentNode()
  private let player = AVAudioPlayerNode()
  private var clicks: [Bool: AVAudioPCMBuffer] = [:]  // key: low
  private var audioReady = false
  private var observers: [NSObjectProtocol] = []
  var onEvent: ((String) -> Void)?  // for the log

  static var hapticsSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

  /// Headphones of any kind (wired, AirPods and other Bluetooth). With one AirPod only, iOS cannot tell us:
  /// the sound side may then be lost, the vibration and the voice still give it.
  static var headphones: Bool {
    let ports: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
    return AVAudioSession.sharedInstance().currentRoute.outputs.contains { ports.contains($0.portType) }
  }

  /// Starts the haptic engine, and the sound if headphones are connected (again on every route change).
  /// The app's audio session must already be set to playback.
  func start() {
    // Haptics are muted while an app records from the microphone; this app never does (ARKit without
    // providesAudioData), but the flag costs nothing.
    try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    startHaptics()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
        self?.prepareAudio(reason: "route change")
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
        self?.prepareAudio(reason: "audio configuration change")
      },
    ]
    prepareAudio(reason: "start")
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    haptics?.stop()
    haptics = nil
    hapticsRunning = false
    stopAudio()
  }

  /// Plays the signal. step: distance step as spoken (1 = half a metre … 4 = two metres); ignored for suspended.
  /// Returns what was actually played.
  @discardableResult
  func play(_ kind: FeedbackKind, step: Int = 2, low: Bool = false, haptic: Bool = true, sound: Bool = true)
    -> (haptic: Bool, sound: Bool) {
    var played = (haptic: false, sound: false)
    if haptic { played.haptic = playHaptic(kind, step: step) }
    if sound && FeedbackTuning.azimuth[kind] != nil { played.sound = playClick(kind, low: low || kind == .step) }  // obstacles and steps only
    return played
  }

  // MARK: Haptics

  private func startHaptics() {
    guard Self.hapticsSupported else {
      onEvent?("haptics not supported")
      return
    }
    do {
      let engine = try CHHapticEngine()
      engine.playsHapticsOnly = true  // never touches the audio session of the voice
      engine.isAutoShutdownEnabled = false
      engine.stoppedHandler = { [weak self] reason in
        DispatchQueue.main.async {
          self?.hapticsRunning = false
          self?.onEvent?("haptics stopped \(reason.rawValue)")
        }
      }
      engine.resetHandler = { [weak self] in
        DispatchQueue.main.async {
          self?.hapticsRunning = false
          self?.onEvent?("haptics reset")
        }
      }
      haptics = engine
      try engine.start()
      hapticsRunning = true
    } catch {
      onEvent?("haptics error \(error.localizedDescription)")
    }
  }

  private func playHaptic(_ kind: FeedbackKind, step: Int) -> Bool {
    guard let engine = haptics else { return false }
    do {
      if !hapticsRunning {  // stopped by the system (e.g. the app went to the background): start again
        try engine.start()
        hapticsRunning = true
      }
      let player = try engine.makePlayer(with: Self.pattern(kind, step: step))
      try player.start(atTime: CHHapticTimeImmediate)
      return true
    } catch {
      hapticsRunning = false
      onEvent?("haptics error \(error.localizedDescription)")
      return false
    }
  }

  static func pattern(_ kind: FeedbackKind, step: Int) throws -> CHHapticPattern {
    let s = max(1, min(4, step))
    let i = kind == .suspended ? 1 : FeedbackTuning.intensity[s]
    let ti = kind == .light || kind == .step ? 1 : FeedbackTuning.tapIntensity[s]
    func tap(_ t: Double, _ duration: Double = FeedbackTuning.tap) -> [CHHapticEvent] {
      [CHHapticEvent(eventType: .hapticTransient, parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: ti),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
      ], relativeTime: t),
       CHHapticEvent(eventType: .hapticContinuous, parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: ti),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
      ], relativeTime: t, duration: duration)]
    }
    func buzz(_ t: Double, sharpness: Float) -> CHHapticEvent {
      CHHapticEvent(eventType: .hapticContinuous, parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
      ], relativeTime: t, duration: FeedbackTuning.buzz)
    }
    let events: [CHHapticEvent]
    switch kind {
    case .left: events = tap(0)
    case .right: events = tap(0) + tap(FeedbackTuning.tap + FeedbackTuning.tapGap)
    case .ahead: events = [buzz(0, sharpness: 0.5)]
    case .suspended:
      events = [buzz(0, sharpness: 0.2), buzz(FeedbackTuning.buzz + FeedbackTuning.buzzGap, sharpness: 0.2)]
    case .light:
      let every = FeedbackTuning.quickTap + FeedbackTuning.quickTapGap
      events = (0..<3).flatMap { tap(Double($0) * every, FeedbackTuning.quickTap) }
    case .step: events = tap(0) + [buzz(FeedbackTuning.tap + FeedbackTuning.stepGap, sharpness: 0.5)]
    }
    return try CHHapticPattern(events: events, parameters: [])
  }

  // MARK: Directional sound

  private func prepareAudio(reason: String) {
    stopAudio()
    guard Self.headphones else {
      onEvent?("sound off: no headphones (\(reason))")
      return
    }
    let rate = audio.outputNode.outputFormat(forBus: 0).sampleRate
    guard rate > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
      onEvent?("sound error: no output format")
      return
    }
    if player.engine == nil {
      audio.attach(env)
      audio.attach(player)
    }
    audio.connect(player, to: env, format: mono)  // 3D placement works on mono sources only
    audio.connect(env, to: audio.mainMixerNode, format: stereo)
    env.outputType = .headphones
    env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)  // facing -z
    env.distanceAttenuationParameters.referenceDistance = 1  // same loudness in every direction
    player.renderingAlgorithm = .HRTFHQ
    clicks = [false: Self.click(FeedbackTuning.clickHz, format: mono), true: Self.click(FeedbackTuning.lowClickHz, format: mono)]
      .compactMapValues { $0 }
    do {
      audio.prepare()
      try audio.start()
      player.play()
      audioReady = true
      onEvent?("sound on: headphones (\(reason))")
    } catch {
      onEvent?("sound error \(error.localizedDescription)")
    }
  }

  private func stopAudio() {
    audioReady = false
    player.stop()
    audio.stop()
  }

  private func playClick(_ kind: FeedbackKind, low: Bool) -> Bool {
    guard audioReady, audio.isRunning, let buffer = clicks[low], let deg = FeedbackTuning.azimuth[kind] else { return false }
    let a = deg * .pi / 180
    player.position = AVAudio3DPoint(x: sin(a), y: 0, z: -cos(a))
    player.volume = FeedbackTuning.clickVolume
    // .interrupts: a new click replaces one still playing, it never queues up behind it
    player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    if !player.isPlaying { player.play() }
    return true
  }

  /// A short tone with a soft attack and decay (no crackle at the edges).
  private static func click(_ hz: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let n = AVAudioFrameCount(format.sampleRate * FeedbackTuning.clickSeconds)
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let data = buf.floatChannelData?[0] else { return nil }
    buf.frameLength = n
    let attack = Int(format.sampleRate * 0.005)
    for i in 0..<Int(n) {
      let t = Double(i) / format.sampleRate
      let env = min(1, Double(i) / Double(attack)) * exp(-t / (FeedbackTuning.clickSeconds / 3))
      data[i] = Float(sin(2 * .pi * hz * t) * env)
    }
    return buf
  }
}
