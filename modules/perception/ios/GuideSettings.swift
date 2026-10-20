// MVP step 1.6: the user's settings for the guide, kept on the phone (UserDefaults) and applied at once, also while
// the guide runs.
// - Alert distance: 1, 1.5 or 2 m (default 2, as tested in steps 1.1–1.5), for obstacles and steps. The analysis
//   still looks 2 m ahead (walls along the path need it); what is farther than the setting is just not announced.
//   The light-passage warning has no distance and is not affected.
// - Alert type: voice and vibration (default), vibration only, voice only. Reliability messages, "Inclina il telefono"
//   and "Guida avviata / fermata" are always spoken (agreed: without the voice "visione ridotta" has no signal).
// - Sound with headphones: on (default) or off. Never with "voice only".
import Foundation

enum AlertMode: String {
  case voiceAndVibration, vibrationOnly, voiceOnly
}

struct GuideSettings: Equatable {
  static let distances: [Float] = [1, 1.5, 2]
  /// Vibration only: no voice keeps two signals apart, so each one waits this long after the previous one
  /// (about as long as a short message; the longest pattern lasts 0.8 s).
  static let vibrationGap: Double = 1.0

  var alertDistance: Float = GuideTuning.alertDistance
  var mode: AlertMode = .voiceAndVibration
  var headphoneSound = true

  var voice: Bool { mode != .vibrationOnly }
  var vibration: Bool { mode != .voiceOnly }
  var sound: Bool { mode != .voiceOnly && headphoneSound }

  private static let key = "guideSettings"

  static func load() -> GuideSettings {
    GuideSettings(UserDefaults.standard.dictionary(forKey: key) ?? [:])
  }

  func save() { UserDefaults.standard.set(dictionary, forKey: Self.key) }

  /// Unknown or missing values keep their default.
  init(_ d: [String: Any] = [:]) {
    if let v = (d["alertDistance"] as? NSNumber)?.floatValue,
       let nearest = Self.distances.min(by: { abs($0 - v) < abs($1 - v) }) {
      alertDistance = nearest
    }
    if let m = (d["mode"] as? String).flatMap(AlertMode.init(rawValue:)) { mode = m }
    if let s = d["headphoneSound"] as? Bool { headphoneSound = s }
  }

  var dictionary: [String: Any] {
    ["alertDistance": alertDistance, "mode": mode.rawValue, "headphoneSound": headphoneSound]
  }

  var logText: String {
    String(format: "alert %.1f m, %@, headphone sound %@", alertDistance, mode.rawValue, headphoneSound ? "on" : "off")
  }
}
