// MVP step 1.9: hands-free voice commands, native side. The speech recognition (QVAC Whisper) runs in JavaScript
// (src/assistant/voiceCommands.ts); here:
// - the microphone, converted to 16 kHz mono float32 and collected until JavaScript reads it (every ~100 ms);
// - echo cancellation (iOS voice processing), so that the app's own voice is not heard as the user's. iOS only
//   removes what the same audio engine plays, so while listening the app's system voice (alerts, description) is
//   played through this engine (SpeechOutput); without that, a "Basta" said over the description would only be
//   heard when the description ends (no pause in the sound for the voice detector);
// - the one audio session of the app (AppAudio): play and record while listening, playback otherwise (steps 1.1–1.8).
// The iPhone's microphone is used also with AirPods (Bluetooth A2DP output kept: the directional sound needs it).
// Main thread only, except the microphone tap (audio thread) and read() (any thread, locked).
import AVFoundation
import UIKit

// MARK: - Audio session

enum AppAudio {
  /// Set by VoiceEngine: the microphone is wanted.
  static var recording = false

  /// The session every part of the app uses before playing. Set again with the same values, nothing changes.
  static func activate() {
    let s = AVAudioSession.sharedInstance()
    // Voice processing sets the session's mode itself; setting it back made iOS change the configuration again,
    // stopping the engine, about once a second (iPhone, 21/10): once in play and record, it is left as it is.
    if recording && s.category == .playAndRecord {
      try? s.setActive(true)
      return
    }
    if recording {
      do {
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers, .interruptSpokenAudioAndMixWithOthers])
      } catch {
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
      }
      // Without this iOS mutes the vibrations while the microphone records.
      try? s.setAllowHapticsAndSystemSoundsDuringRecording(true)
    } else {
      try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }
    try? s.setActive(true)
  }

  static var routeText: String {
    let r = AVAudioSession.sharedInstance().currentRoute
    let ports = { (p: [AVAudioSessionPortDescription]) in p.map { $0.portType.rawValue }.joined(separator: "+") }
    return "in \(ports(r.inputs)) out \(ports(r.outputs))"
  }
}

// MARK: - What the app says (to tell its own voice from the user's)

enum AppSpeech {
  private struct Entry { let text: String; let start: Double; var end: Double? }
  private static var entries: [ObjectIdentifier: Entry] = [:]
  private static var order: [ObjectIdentifier] = []

  static func began(_ u: AVSpeechUtterance) {
    let id = ObjectIdentifier(u)
    entries[id] = Entry(text: u.speechString, start: nowMs(), end: nil)
    order.append(id)
    if order.count > 30 { entries[order.removeFirst()] = nil }
  }

  static func ended(_ u: AVSpeechUtterance) { entries[ObjectIdentifier(u)]?.end = nowMs() }

  /// A message dropped from iOS's queue may never report its end: after this long it counts as ended.
  private static let longest: Double = 30_000

  /// Texts being spoken or ended after `since` (Unix ms).
  static func since(_ since: Double) -> [String] {
    order.compactMap { entries[$0] }.filter { ($0.end ?? $0.start + longest) >= since }.map(\.text)
  }

  static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

// MARK: - Engine: microphone with echo cancellation, and the app's voice

final class VoiceEngine {
  static let shared = VoiceEngine()
  static let sampleRate: Double = 16000
  /// Microphone audio kept when JavaScript does not read it (app busy): older audio is dropped.
  private static let maxPendingSeconds: Double = 10

  private var engine = AVAudioEngine()
  private var players: [String: AVAudioPlayerNode] = [:]
  /// The system voice's buffers (Italian voice, iPhone 13, 21/10: 22050 Hz mono float32). The players take them as
  /// they are and the mixer converts them: converting each 10 ms buffer on its own crackled ("interferenza").
  private var playerFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
  private let micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
  private var micConverter: AVAudioConverter?
  private var observers: [NSObjectProtocol] = []

  /// Listening is wanted (between start and stop); it may be held up meanwhile (background, phone call).
  private(set) var wanted = false
  private(set) var running = false
  private var startedAt: Double = 0
  /// Speech played through the engine is cut when it stops or restarts: each SpeechOutput ends it.
  var onReset: [() -> Void] = []
  var onEvent: ((String) -> Void)?

  private let lock = NSLock()
  private var pending = Data()
  private var pendingEndMs: Double = 0
  private var dropped = 0  // samples lost because nobody read them
  private var taps = 0, converted = 0  // diagnostics: microphone buffers received and converted since the last read

  /// Asks for the microphone the first time. Main thread.
  func start(completion: @escaping (Result<Void, Error>) -> Void) {
    AVAudioApplication.requestRecordPermission { granted in
      DispatchQueue.main.async {
        guard granted else { return completion(.failure(Phase0Error("Microfono non autorizzato: consentilo in Impostazioni di iOS, AheadAlert"))) }
        self.wanted = true
        AppAudio.recording = true
        self.observe()
        do {
          try self.run()
          completion(.success(()))
        } catch {
          self.stop()
          completion(.failure(error))
        }
      }
    }
  }

  func stop() {
    wanted = false
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    halt()
    AppAudio.recording = false
    AppAudio.activate()
    lock.lock(); pending = Data(); lock.unlock()
  }

  func log(_ text: String) { onEvent?(text) }

  /// The player for one voice ("guide", "description") while the engine runs, otherwise nil (spoken as before).
  func player(_ name: String) -> AVAudioPlayerNode? { running ? players[name] : nil }

  var format: AVAudioFormat { playerFormat }

  /// The microphone audio since the last call: 16 kHz mono float32, and the Unix ms time of its last sample.
  func read() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let out: [String: Any] = ["audio": pending, "endMs": pendingEndMs, "running": running, "dropped": dropped,
                              "taps": taps, "converted": converted, "engineRunning": engine.isRunning]
    pending = Data()
    dropped = 0
    taps = 0
    converted = 0
    return out
  }

  private func run() throws {
    halt()
    AppAudio.activate()
    engine = AVAudioEngine()  // a fresh one: an engine that was running keeps its old route
    let input = engine.inputNode
    try input.setVoiceProcessingEnabled(true)
    // The other sounds (the directional click of step 1.3) are lowered as little as iOS allows.
    input.voiceProcessingOtherAudioDuckingConfiguration =
      AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
    players = [:]
    for name in ["guide", "description"] {
      let p = AVAudioPlayerNode()
      engine.attach(p)
      engine.connect(p, to: engine.mainMixerNode, format: playerFormat)
      players[name] = p
    }
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Phase0Error("Microfono non disponibile") }
    micConverter = AVAudioConverter(from: inFormat, to: micFormat)
    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in self?.collect(buffer) }
    engine.prepare()
    try engine.start()
    running = true
    startedAt = CACurrentMediaTime()
    onEvent?("listening, mic \(Int(inFormat.sampleRate)) Hz \(inFormat.channelCount) ch, \(AppAudio.routeText)")
  }

  private func halt() {
    let was = running
    running = false
    if was || engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      players.values.forEach { $0.stop() }
      engine.stop()
    }
    onReset.forEach { $0() }
  }

  /// Audio thread.
  private func collect(_ buffer: AVAudioPCMBuffer) {
    lock.lock(); taps += 1; lock.unlock()
    guard let converter = micConverter else { return }
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * micFormat.sampleRate / buffer.format.sampleRate) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
    var given = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if given { status.pointee = .noDataNow; return nil }
      given = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
    let bytes = Data(bytes: ch, count: Int(out.frameLength) * 4)
    let max = Int(Self.maxPendingSeconds * micFormat.sampleRate) * 4
    lock.lock()
    converted += 1
    pending.append(bytes)
    if pending.count > max {
      dropped += (pending.count - max) / 4
      pending.removeFirst(pending.count - max)
    }
    pendingEndMs = AppSpeech.nowMs()
    lock.unlock()
  }

  /// iOS stops the engine for a phone call, in the background, or when the route changes (AirPods): started again
  /// when possible.
  private func observe() {
    guard observers.isEmpty else { return }
    let c = NotificationCenter.default
    let restart: (String) -> Void = { [weak self] why in self?.restart(why, attempt: 1) }
    observers = [
      c.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
        // Turning on voice processing changes the configuration right after the start and stops the engine (first
        // test on the iPhone, 21/10: microphone on, no audio): started again whenever it is no longer running.
        guard let self, (n.object as AnyObject?) === self.engine else { return }
        if self.engine.isRunning && CACurrentMediaTime() - self.startedAt < 1 { return }
        restart("audio configuration change")
      },
      c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
        let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
        if type == .began { self?.halt(); self?.onEvent?("interrupted") }
        else { restart("interruption ended") }
      },
      c.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        self?.halt()
        self?.onEvent?("paused (background)")
      },
      c.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        if self?.running == false { restart("back in the app") }
      },
    ]
  }

  /// Right after a configuration change the microphone may not be ready yet (first test on the iPhone, 21/10:
  /// "Microfono non disponibile"): a few more tries, 0.3 s apart.
  private var restarts: [Double] = []

  /// After a configuration change: the same engine started again (a new one with voice processing changes the
  /// configuration once more: on the iPhone, 21/10, that made a loop, one restart a second, and no audio).
  private func resume() throws {
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Phase0Error("Microfono non disponibile") }
    input.removeTap(onBus: 0)
    micConverter = AVAudioConverter(from: inFormat, to: micFormat)
    input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in self?.collect(buffer) }
    engine.prepare()
    try engine.start()
    running = true
    startedAt = CACurrentMediaTime()
    onEvent?("resumed, mic \(Int(inFormat.sampleRate)) Hz \(inFormat.channelCount) ch, \(AppAudio.routeText)")
  }

  private func restart(_ why: String, attempt: Int) {
    guard wanted, UIApplication.shared.applicationState != .background else { return }
    if attempt == 1 {
      let now = CACurrentMediaTime()
      restarts = restarts.filter { now - $0 < 10 } + [now]
      // Never a loop of restarts: more than 5 in 10 s means something keeps stopping the engine.
      guard restarts.count <= 5 else {
        onEvent?("too many restarts (\(why)), microphone left off")
        return
      }
    }
    if attempt == 1 && running {
      running = false
      players.values.forEach { $0.stop() }
      onReset.forEach { $0() }  // the speech being played is cut
    }
    do {
      // The same engine first; a new one (and a new session setup) only after three tries, or when coming back.
      if attempt <= 3 && why == "audio configuration change" { try resume() } else { try run() }
      onEvent?("restarted (\(why), try \(attempt))")
    } catch {
      onEvent?("restart failed (\(why), try \(attempt)): \(error.localizedDescription)")
      guard attempt < 6 else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.restart(why, attempt: attempt + 1) }
    }
  }

  // MARK: Speech format

  /// A voice with another format (a different voice chosen in VoiceOver): every player is connected again with it.
  func use(_ format: AVAudioFormat) {
    guard format != playerFormat, running else { return }
    playerFormat = format
    for p in players.values {
      p.stop()
      engine.disconnectNodeOutput(p)
      engine.connect(p, to: engine.mainMixerNode, format: format)
    }
    onEvent?("speech format \(Int(format.sampleRate)) Hz \(format.channelCount) ch")
  }
}

// MARK: - The app's system voice

/// One voice of the app (guide alerts, description). Spoken as in steps 1.1–1.8 (AVSpeechSynthesizer.speak) when the
/// voice commands do not listen; while they listen, synthesized into buffers and played through the VoiceEngine, so
/// that echo cancellation removes it from the microphone. Like AVSpeechSynthesizer, a new message waits for the one
/// being spoken. onDone(utterance, finished) on the main thread, after the end or the stop of each message.
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
  private let name: String
  private let synth = AVSpeechSynthesizer()  // spoken directly
  private let writer = AVSpeechSynthesizer()  // into buffers, for the engine
  private var routed: AVSpeechUtterance?  // being played through the engine
  private var synthesisDone = false
  private var scheduled = (buffers: 0, seconds: 0.0, format: "")  // diagnostics of the message being played
  private var queue: [AVSpeechUtterance] = []
  var onDone: ((AVSpeechUtterance, Bool) -> Void)?

  init(_ name: String) {
    self.name = name
    super.init()
    synth.delegate = self
    writer.delegate = self
    VoiceEngine.shared.onReset.append { [weak self] in self?.stopRouted() }
  }

  func speak(_ u: AVSpeechUtterance) {
    AppSpeech.began(u)
    if VoiceEngine.shared.player(name) != nil {
      if routed == nil { play(u) } else { queue.append(u) }
    } else {
      AppAudio.activate()
      synth.speak(u)
    }
  }

  /// Stops the message being spoken and the ones waiting.
  func stop() {
    synth.stopSpeaking(at: .immediate)
    stopRouted()
  }

  private func stopRouted() {
    let cut = (routed.map { [$0] } ?? []) + queue
    routed = nil
    queue = []
    writer.stopSpeaking(at: .immediate)
    VoiceEngine.shared.player(name)?.stop()
    for u in cut { DispatchQueue.main.async { self.done(u, false) } }
  }

  private func play(_ u: AVSpeechUtterance) {
    guard let player = VoiceEngine.shared.player(name) else {
      synth.speak(u)
      return
    }
    routed = u
    synthesisDone = false
    scheduled = (0, 0, "")
    player.play()
    writer.write(u) { [weak self] buffer in
      guard let pcm = buffer as? AVAudioPCMBuffer else { return }
      DispatchQueue.main.async {
        guard let self, self.routed === u else { return }
        if pcm.frameLength == 0 { self.synthesisEnded(u) }
        else {
          let out = pcm
          if self.scheduled.buffers == 0 {
            if pcm.format != VoiceEngine.shared.format {
              VoiceEngine.shared.use(pcm.format)
              player.play()
            }
            let f = pcm.format
            self.scheduled.format = "\(Int(f.sampleRate)) Hz \(f.channelCount) ch \(f.commonFormat.rawValue)\(f.isInterleaved ? " interleaved" : "")"
          }
          self.scheduled.buffers += 1
          self.scheduled.seconds += Double(out.frameLength) / out.format.sampleRate
          player.scheduleBuffer(out)
        }
      }
    }
  }

  /// All the buffers are scheduled: the message ends once they have been played.
  private func synthesisEnded(_ u: AVSpeechUtterance) {
    guard routed === u, !synthesisDone, let player = VoiceEngine.shared.player(name),
          let marker = AVAudioPCMBuffer(pcmFormat: VoiceEngine.shared.format, frameCapacity: 1) else { return }
    synthesisDone = true
    VoiceEngine.shared.log(String(format: "speech %@ \"%@\": %d buffers, %.2f s of audio, from %@", name, u.speechString,
                                  scheduled.buffers, scheduled.seconds, scheduled.format))
    marker.frameLength = 1
    player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.routed === u else { return }
        self.routed = nil
        self.done(u, true)
        if !self.queue.isEmpty { self.play(self.queue.removeFirst()) }
      }
    }
  }

  private func done(_ u: AVSpeechUtterance, _ finished: Bool) {
    AppSpeech.ended(u)
    onDone?(u, finished)
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
    DispatchQueue.main.async {
      if s === self.writer { self.synthesisEnded(u) }  // in case the last, empty buffer does not come
      else { self.done(u, true) }
    }
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
    guard s === synth else { return }  // the writer's are ended by stopRouted
    DispatchQueue.main.async { self.done(u, false) }
  }
}
