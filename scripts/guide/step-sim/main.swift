// Walking simulation of the step tests (MVP step 1.5), run on the Mac without ARKit: the user walks towards virtual
// stairs at 0.8 m/s, 15 analyses a second, with the phone swaying as when walking. Each frame goes through the app's
// own ObstacleAnalyzer; the alert decisions below mirror ObstacleGuide.alertIfNeeded / dropAlertIfNeeded (same
// thresholds, from GuideTuning and StepTuning), with the voice busy for 1.3 s after each message.
// Phone held as in the recordings of 18–19/10: tilted 35–65° down, 1.0–1.3 m above the floor.
// Depth Anything is imitated: soft edges (blur) and, in the "bent" runs, a far floor that sinks as with a wrong scale.
// The floor is always the right one here (in the app it comes from ARKit's planes, see ObstacleGuide.floorPlane).
// Usage (from mobile/): scripts/guide/step-sim/run.sh
import CoreGraphics
import Foundation
import simd

struct Message { let t: Double; let text: String; let trueDistance: Float }

/// Mirrors the alert logic of ObstacleGuide (main thread), without vibration and with a simple voice.
struct Alerts {
  var tracks: [[ZoneHit?]] = [[], [], []]
  var lastSpoken: [Double] = [-100, -100, -100], lastConfirmed: [Double] = [-100, -100, -100]
  var lastStep: [Int?] = [nil, nil, nil]
  var dropTrack: [DropHit?] = []
  var dropLastSpoken: Double = -100, dropLastConfirmed: Double = -100
  var dropLastStep: Int?
  var voiceUntil: Double = -1
  var speakingAhead = false

  static func step(_ d: Float) -> Int { max(1, min(4, Int((d * 2).rounded()))) }
  static let dist = ["", "mezzo metro", "un metro", "un metro e mezzo", "due metri"]

  mutating func frame(_ a: FrameAnalysis, now: Double) -> String? {
    for z in Zone.allCases {
      tracks[z.rawValue].append(a.zones[z.rawValue])
      if tracks[z.rawValue].count > GuideTuning.window { tracks[z.rawValue].removeFirst() }
    }
    dropTrack.append(a.drop)
    if dropTrack.count > StepTuning.window { dropTrack.removeFirst() }
    let speaking = now < voiceUntil

    // dropAlertIfNeeded
    let dhits = dropTrack.compactMap { $0 }
    if dhits.count >= StepTuning.hitsNeeded, let latest = dropTrack.last(where: { $0 != nil }) ?? nil {
      dropLastConfirmed = now
      let s = Self.step(latest.distance)
      if let last = dropLastStep, s >= last {
        dropLastStep = s
      } else if now - dropLastSpoken >= GuideTuning.zoneCooldown {
        if speaking { return nil }
        dropLastSpoken = now
        dropLastStep = s
        return say("Gradino giù, \(Self.dist[s])", now: now, ahead: true)
      }
    } else if now - dropLastConfirmed > GuideTuning.zoneClearAfter {
      dropLastStep = nil
    }

    // alertIfNeeded
    var cands: [(zone: Zone, hit: ZoneHit)] = []
    for z in Zone.allCases {
      let i = z.rawValue
      let hits = tracks[i].compactMap { $0 }
      guard hits.count >= GuideTuning.hitsNeeded, let latest = tracks[i].last(where: { $0 != nil }) ?? nil else {
        if now - lastConfirmed[i] > GuideTuning.zoneClearAfter { lastStep[i] = nil }
        continue
      }
      lastConfirmed[i] = now
      let low = hits.filter(\.low).count * 2 > hits.count
      let up = hits.filter(\.stepUp).count * 2 > hits.count
      cands.append((z, ZoneHit(distance: latest.distance, low: low, area: latest.area, stepUp: up)))
    }
    if let up = cands.first(where: { $0.zone == .ahead && $0.hit.stepUp }) {
      cands.removeAll { $0.zone != .ahead && $0.hit.low && abs($0.hit.distance - up.hit.distance) <= 0.3 }
    }
    cands.sort { ($0.hit.distance, $0.zone == .ahead ? 0 : 1) < ($1.hit.distance, $1.zone == .ahead ? 0 : 1) }
    for c in cands {
      let i = c.zone.rawValue
      let s = Self.step(c.hit.distance)
      if let last = lastStep[i], s >= last { lastStep[i] = s; continue }
      guard now - lastSpoken[i] >= GuideTuning.zoneCooldown else { continue }
      let urgent = c.zone == .ahead && c.hit.distance <= 1.0 && !speakingAhead
      if speaking && !urgent { return nil }
      lastSpoken[i] = now
      lastStep[i] = s
      let place = ["A sinistra", "Davanti", "A destra"][i]
      let text = c.hit.stepUp ? "Gradino su, \(Self.dist[s])" : "\(place)\(c.hit.low ? ", basso" : ""), \(Self.dist[s])"
      return say(text, now: now, ahead: c.zone == .ahead)
    }
    return nil
  }

  mutating func say(_ text: String, now: Double, ahead: Bool) -> String {
    voiceUntil = now + 1.3
    speakingAhead = ahead
    return text
  }
}

struct Walk {
  let name: String
  let scene: Scene
  let edgeZ: Float  // where the step is (z of the edge or of the first riser); the user starts at z = 0
  let stopAt: Float  // m before the edge
  var seconds: Double? = nil  // for the flat corridor
}

/// One walk; returns the messages with the true distance from the phone to the edge when each was spoken.
func run(_ w: Walk, tilt: Float, height: Float, bend: Float, seed: UInt64) -> [Message] {
  srand48(Int(seed))
  let speed: Float = 0.8, fps = 15.0
  let phase = Float(drand48()) * 6.28
  let frames = Int((w.seconds ?? Double((-w.edgeZ - w.stopAt) / speed)) * fps)
  let analyzer = ObstacleAnalyzer()
  var alerts = Alerts()
  var out: [Message] = []
  for f in 0..<frames {
    let t = Double(f) / fps, tf = Float(t)
    let z = -speed * tf
    // sway of a walking user: up and down at each step, the phone tilting and turning a little
    let cam = CameraSnapshot(
      transform: portraitCamera(height: height + 0.03 * sin(2 * .pi * 1.8 * tf + phase),
                                tiltDownDeg: tilt + 3 * sin(2 * .pi * 0.9 * tf + phase),
                                yawRightDeg: 4 * sin(2 * .pi * 0.5 * tf + 2 * phase),
                                x: 0.03 * sin(2 * .pi * 0.9 * tf + phase), z: z),
      intrinsics: intrinsics, imageSize: CGSize(width: 1920, height: 1440), walkDirection: SIMD3(0, 0, -1))
    let depth = render(w.scene, camera: cam, noise: 0.03, bend: bend, blur: 2)
    let a = analyzer.analyze(depth: depth, camera: cam, floorY: 0,
                             features: features(w.scene, camera: cam, count: 150, noise: 0.03), now: t)
    if let text = alerts.frame(a, now: t) { out.append(Message(t: t, text: text, trueDistance: z - w.edgeZ)) }
  }
  return out
}

GuideTuning.bodyOffset = 0  // distances from the phone
let stairsUp = (0..<6).map { k in
  Box(lo: SIMD3(-0.8, 0, -9), hi: SIMD3(0.8, 0.17 * Float(k + 1), -4 - 0.29 * Float(k)), name: "stair \(k)")
}
let walks = [
  Walk(name: "Discesa, pianerottolo corto (da 1,8 m)", scene: Scene(boxes: [], wallX: 0.6, endZ: -9, stairsDown: (-1.8, 0.17, 0.29, 8)),
       edgeZ: -1.8, stopAt: 0.3),
  Walk(name: "Discesa, corridoio (da 4 m)", scene: Scene(boxes: [], wallX: 0.6, endZ: -9, stairsDown: (-4, 0.17, 0.29, 8)),
       edgeZ: -4, stopAt: 0.3),
  Walk(name: "Gradino singolo giù, 15 cm (da 4 m)", scene: Scene(boxes: [], wallX: 0.6, endZ: -9, stairsDown: (-4, 0.15, 0.3, 1)),
       edgeZ: -4, stopAt: 0.3),
  Walk(name: "Salita (da 4 m)", scene: Scene(boxes: stairsUp, wallX: 0.6, endZ: -9), edgeZ: -4, stopAt: 0.3),
  Walk(name: "Soglia giù 8 cm (da 4 m): nessun gradino atteso", scene: Scene(boxes: [], wallX: 0.6, endZ: -9, stairsDown: (-4, 0.08, 0.3, 1)),
       edgeZ: -4, stopAt: 0.3),
  Walk(name: "Corridoio piano largo 1,2 m, 30 s: nessun gradino atteso", scene: Scene(boxes: [], wallX: 0.6, endZ: -40),
       edgeZ: -100, stopAt: 0, seconds: 30),
]
let holds: [(tilt: Float, height: Float)] = [(35, 1.0), (35, 1.3), (51, 1.13), (65, 1.0), (65, 1.3)]
let bends: [Float] = [0, 0.04]

struct Job { let walk: Int; let hold: Int; let bend: Int }
var jobs: [Job] = []
for w in walks.indices { for h in holds.indices { for b in bends.indices { jobs.append(Job(walk: w, hold: h, bend: b)) } } }
var results = [[Message]](repeating: [], count: jobs.count)
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
  let j = jobs[k]
  let r = run(walks[j.walk], tilt: holds[j.hold].tilt, height: holds[j.hold].height, bend: bends[j.bend],
              seed: UInt64(k + 1))
  lock.lock(); results[k] = r; lock.unlock()
}

for (k, j) in jobs.enumerated() {
  if j.hold == 0 && j.bend == 0 { print("\n== \(walks[j.walk].name)") }
  let h = holds[j.hold]
  let msgs = results[k].map {
    walks[j.walk].seconds == nil ? String(format: "%@ (a %.2f m)", $0.text, $0.trueDistance) : String(format: "%.0f s %@", $0.t, $0.text)
  }
  print(String(format: "  %2.0f° %.2f m %@: ", h.tilt, h.height, bends[j.bend] == 0 ? "dritto " : "piegato"),
        msgs.isEmpty ? "(nessun messaggio)" : msgs.joined(separator: " · "))
}
