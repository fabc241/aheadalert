// MVP step 1.2: how far the obstacle alerts can be trusted right now (no ARKit here, so it can be tested on the
// Mac: scripts/guide/reliability-test).
//
// good        tracking normal, fresh metric scale, enough light, enough analyses per second → alerts as usual
// reduced     low light, or the scale fit failing, or slow analysis → alerts go on, the user is told once
// unavailable tracking lost or no floor → no alerts at all (distances would be wrong); the user is told
//             why, again every 15 s. Without this the guide used to fall silent, which sounds like a free path.
// A level is announced only when it lasts (1 s, also to go back to good), so it does not flap.
// User-facing strings (voice messages) are in Italian.
import Foundation

enum ReliabilityTuning {
  /// ARKit ambientIntensity (lumens, 1000 = neutral light; not lux). Dim-light test of 18/10 evening: at 140–320
  /// tracking and scale fit worked; at 27–100 tracking held but the fit succeeded in only 20–70% of the frames.
  static let lowLight: Float = 100
  static let lowLightClear: Float = 130  // hysteresis: back above this to count as enough light
  /// Below this the camera frames are black (mean brightness 0–1 of 255 at 4–10, Phase 0B): suspended even while
  /// ARKit still reports normal tracking, which it did for 1–2 s on entering a dark room (test of 18/10 evening).
  static let darkLight: Float = 20
  static let darkLightClear: Float = 30
  static let lightWindow: Double = 0.5  // s of light samples averaged
  static let minAnalysesPerSecond = 8
  static let scaleWindow: Double = 1  // s; reduced when the fit failed in more than half of these frames
  static let settle: Double = 1.5  // s after tracking comes back before speed and scale are judged
  static let holdBad: Double = 1  // s a worse level must last before it is announced
  /// s good must last after a problem before it is announced. 3 s were agreed, then 2: with ARKit taking 0.5–1.5 s
  /// to recover and alerts speaking first, the message still came 3.3–4.5 s after the light (tests of 18/10
  /// evening), and no flapping was seen on the way back. The user chose 1 s.
  static let holdGood: Double = 1
  static let startupGrace: Double = 4  // s after start in which "camera starting / looking for the floor" is normal
  static let repeatUnavailable: Double = 15  // s between two messages while the guide is suspended
}

enum Reliability: String {
  case good, reduced, unavailable
}

enum ReliabilityReason: String {
  case none, starting
  case lowLight, scale, slow  // reduced
  case dark, motion, noFloor  // unavailable
}

/// What a camera frame allowed.
enum FrameStatus {
  case ok  // tracking normal and floor found: the frame goes to depth analysis
  case noFloor
  case noTracking  // ARKit tracking limited or not available
}

/// Main thread only (the guide's alert logic lives there).
final class ReliabilityMonitor {
  private(set) var level: Reliability = .unavailable
  private(set) var reason: ReliabilityReason = .starting
  /// Level the user was last told about. The start counts as good: "Guida avviata" promises working alerts.
  private var toldLevel: Reliability = .good
  private var candidate: (level: Reliability, since: Double)
  private var lastTold: Double = -100
  private var pending: String?
  private let startTime: Double

  private var frameStatus: FrameStatus = .noTracking
  private var usableSince: Double?  // since when frames are analysed with light (not suspended)
  private var lights: [(t: Double, v: Float)] = []
  private var dimLight = false
  private var darkLight = false
  private(set) var raw: Reliability = .unavailable  // level the signals point to at the last update, unheld
  private var analyses: [(t: Double, scaleFresh: Bool)] = []

  init(now: Double) {
    startTime = now
    candidate = (.unavailable, now)
  }

  /// Mean ARKit light over the last half second, if known.
  var light: Float? {
    lights.isEmpty ? nil : lights.reduce(0) { $0 + $1.v } / Float(lights.count)
  }

  /// Every frame that reaches the alert logic. light: ARKit ambientIntensity, nil when ARKit gives none.
  func frame(_ status: FrameStatus, light: Float?, now: Double) {
    frameStatus = status
    if let light {
      lights.append((now, light))
    }
    lights.removeAll { now - $0.t > ReliabilityTuning.lightWindow }
    if let l = self.light {
      dimLight = dimLight ? l < ReliabilityTuning.lowLightClear : l < ReliabilityTuning.lowLight
      darkLight = darkLight ? l < ReliabilityTuning.darkLightClear : l < ReliabilityTuning.darkLight
    }
  }

  /// Every depth analysis. scaleFresh: metric scale fitted on this frame (a scale reused from an earlier frame
  /// does not count).
  func analysis(scaleFresh: Bool, now: Double) {
    analyses.append((now, scaleFresh))
  }

  /// The level these signals point to right now, before any holding time.
  func current(now: Double) -> (Reliability, ReliabilityReason) {
    analyses.removeAll { now - $0.t > ReliabilityTuning.scaleWindow }
    let suspended: ReliabilityReason?
    switch frameStatus {
    case .noTracking: suspended = dimLight ? .dark : .motion
    case .noFloor: suspended = dimLight ? .dark : .noFloor
    case .ok: suspended = darkLight ? .dark : nil
    }
    if let suspended {
      // What was analysed in the dark says nothing about the scale once back in the light: on 18/10 evening those
      // frames kept the level at "reduced, scale" for a second after the return and delayed "good" past 3 s.
      usableSince = nil
      analyses.removeAll()
      return (.unavailable, suspended)
    }
    let since = usableSince ?? now
    usableSince = since
    // Right after the guide resumes there are few analyses yet: speed and scale are judged after a moment.
    let settled = now - since >= ReliabilityTuning.settle
    let scaleFailing = analyses.count >= ReliabilityTuning.minAnalysesPerSecond / 2
      && analyses.filter({ !$0.scaleFresh }).count * 2 > analyses.count
    if dimLight {
      // Low light and no metric scale either: the frames are too dark to measure anything, and what they show is
      // made up. With the camera half covered (light 30–34) ARKit kept tracking for 3–6 s and the guide said
      // "Davanti, basso, mezzo metro" about the hand (test of 18/10 evening).
      if settled && scaleFailing { return (.unavailable, .dark) }
      return (.reduced, .lowLight)
    }
    guard settled else { return (.good, .none) }
    if analyses.count < ReliabilityTuning.minAnalysesPerSecond { return (.reduced, .slow) }
    if scaleFailing { return (.reduced, .scale) }
    return (.good, .none)
  }

  /// Updates the level. Returns true when it changed (for the log and the screen).
  @discardableResult
  func update(now: Double) -> Bool {
    let (raw, rawReason) = current(now: now)
    self.raw = raw
    if sameRun(raw, candidate.level) { candidate.level = raw } else { candidate = (raw, now) }
    let starting = reason == .starting
    if raw == level && !starting {
      reason = rawReason  // e.g. dark → motion while still suspended: told at the next reminder
      return false
    }
    let hold: Double
    switch raw {
    case .good: hold = starting ? 0 : ReliabilityTuning.holdGood
    case .reduced: hold = ReliabilityTuning.holdBad
    case .unavailable: hold = ReliabilityTuning.holdBad
    }
    guard now - candidate.since >= hold else { return false }
    if starting && raw == .unavailable && now - startTime < ReliabilityTuning.startupGrace { return false }
    level = raw
    reason = rawReason
    pending = level == toldLevel && level != .unavailable ? nil : Self.message(level, reason)
    return true
  }

  /// Whether two raw levels count as one run for the holding time. From good, reduced and unavailable together are
  /// one problem; back from unavailable, reduced and good together are one recovery. Otherwise a level flickering
  /// between two others was never held long enough: in light 38–47, with the scale fit at the 50% limit, the level
  /// stayed "good" for 3 s while reduced and unavailable alternated (test of 18/10 evening).
  private func sameRun(_ a: Reliability, _ b: Reliability) -> Bool {
    switch level {
    case .good: return (a == .good) == (b == .good)
    case .unavailable: return (a == .unavailable) == (b == .unavailable)
    case .reduced: return a == b
    }
  }

  /// True when a change of level waits to be told: it may cut short an older reliability message (never an alert).
  /// On entering a dark room "Visione ridotta…" used to delay "Guida sospesa…" by 2 s (test of 18/10 evening).
  var changePending: Bool { pending != nil }

  /// The message to speak now, if any: a change of level, or the reminder while suspended. Call it only when the
  /// voice is free (or speaking an older reliability message, see changePending), so that it never cuts an alert.
  func takeMessage(now: Double) -> String? {
    // Suspended again before the voice was free: "Avvisi di nuovo affidabili", delayed by alerts, was once spoken
    // while the user was already back in the dark (test of 18/10 evening). Only that case waits: waiting for any
    // flicker (raw == level) lost the message altogether in the second test.
    if raw == .unavailable && level != .unavailable { return nil }
    if pending == nil, level == .unavailable, reason != .starting,
       now - lastTold >= ReliabilityTuning.repeatUnavailable {
      pending = Self.message(level, reason)
    }
    guard let text = pending else { return nil }
    pending = nil
    toldLevel = level
    lastTold = now
    return text
  }

  static func message(_ level: Reliability, _ reason: ReliabilityReason) -> String {
    switch level {
    case .good: return "Avvisi di nuovo affidabili"
    case .reduced: return "Visione ridotta, avvisi meno affidabili"
    case .unavailable:
      switch reason {
      case .dark: return "Guida sospesa: troppo buio"
      case .noFloor: return "Cerco il pavimento. Inclina il telefono verso il basso"
      default: return "Guida sospesa: muovi piano il telefono"
      }
    }
  }
}
