// Synthetic check of the reliability levels (MVP step 1.2), run on the Mac without ARKit.
// Each scenario is a timeline of camera conditions; frames arrive at 60 Hz without tracking (as from ARKit) and
// as analyses at 15 Hz with tracking, like on the iPhone 13. The voice is free unless it is speaking a reliability
// message (about 2 s each; a change of level may cut it short, as in the app) or an obstacle alert.
// Usage (from mobile/): scripts/guide/reliability-test/run.sh
import Foundation

struct Segment {
  let seconds: Double
  let status: FrameStatus
  let light: Float
  var scaleFresh = true
  var analysesPerSecond = 15.0
  var alertSpeaking = false  // the voice is busy with obstacle alerts, which are never cut
}

struct Spoken { let t: Double; let text: String }

func run(_ segments: [Segment]) -> (spoken: [Spoken], levels: [(t: Double, level: Reliability, reason: ReliabilityReason)]) {
  let m = ReliabilityMonitor(now: 0)
  var t = 0.0, voiceFreeAt = 0.0
  var spoken: [Spoken] = [], levels: [(Double, Reliability, ReliabilityReason)] = []
  for seg in segments {
    let end = t + seg.seconds
    let step = seg.status == .ok ? 1 / seg.analysesPerSecond : 1 / 60.0
    while t < end - 1e-9 {
      m.frame(seg.status, light: seg.light, now: t)
      if seg.status == .ok { m.analysis(scaleFresh: seg.scaleFresh, now: t) }
      if m.update(now: t) { levels.append((t, m.level, m.reason)) }
      let busy = seg.alertSpeaking || t < voiceFreeAt
      let cut = !seg.alertSpeaking && t < voiceFreeAt && m.changePending
      if !busy || cut, let text = m.takeMessage(now: t) {
        spoken.append(Spoken(t: t, text: text))
        voiceFreeAt = t + 2
      }
      t += step
    }
  }
  return (spoken, levels)
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
  print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
  if !ok { failures += 1 }
}
func describe(_ s: [Spoken]) -> String { s.map { String(format: "%.1f s \"%@\"", $0.t, $0.text) }.joined(separator: ", ") }

let lit: Float = 600, dark: Float = 6, dim: Float = 60

// 1. Normal start in a lit room: camera starting, floor found, then walking. No message at all.
do {
  let r = run([Segment(seconds: 1, status: .noTracking, light: lit), Segment(seconds: 1, status: .noFloor, light: lit),
               Segment(seconds: 60, status: .ok, light: lit)])
  check("start in light", r.spoken.isEmpty && r.levels.last?.level == .good, r.spoken.isEmpty ? "silent, good" : describe(r.spoken))
}

// 2. Walking into a dark room: suspended within 2 s, reminder every 15 s; back to light: good within 3 s + 1 s.
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 32, status: .noTracking, light: dark),
               Segment(seconds: 10, status: .ok, light: lit)])
  let suspended = r.spoken.filter { $0.text == "Guida sospesa: troppo buio" }
  check("dark room", suspended.first.map { $0.t - 10 <= 2 } ?? false, describe(r.spoken))
  let gaps = zip(suspended.dropFirst(), suspended).map { $0.t - $1.t }
  check("reminder every 15 s", suspended.count == 3 && gaps.allSatisfy { abs($0 - 15) < 0.1 },
        gaps.map { String(format: "%.1f", $0) }.joined(separator: ", "))
  let back = r.spoken.last { $0.text == "Avvisi di nuovo affidabili" }
  check("back to light", back.map { $0.t - 42 <= 3.5 } ?? false, back.map { String(format: "after %.1f s", $0.t - 42) } ?? "none")
}

// 3. Phone covered by the hand (dark, no tracking) for 3 s: suspended, then good again.
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 3, status: .noTracking, light: 2),
               Segment(seconds: 6, status: .ok, light: lit)])
  check("covered", r.spoken.map(\.text) == ["Guida sospesa: troppo buio", "Avvisi di nuovo affidabili"], describe(r.spoken))
}

// 4. Fast movement in good light: suspended with "muovi piano".
do {
  let r = run([Segment(seconds: 5, status: .ok, light: lit), Segment(seconds: 2, status: .noTracking, light: lit),
               Segment(seconds: 5, status: .ok, light: lit)])
  check("fast movement", r.spoken.first?.text == "Guida sospesa: muovi piano il telefono", describe(r.spoken))
}

// 5. Short glitches (0.5 s without tracking, a few times): not announced.
do {
  var segs = [Segment(seconds: 5, status: .ok, light: lit)]
  for _ in 0..<5 { segs += [Segment(seconds: 0.5, status: .noTracking, light: lit), Segment(seconds: 5, status: .ok, light: lit)] }
  let r = run(segs)
  check("short glitches", r.spoken.isEmpty, r.spoken.isEmpty ? "silent" : describe(r.spoken))
}

// 6. Dim room with tracking: reduced, once only; light flickering around the threshold does not flap.
do {
  var segs = [Segment(seconds: 5, status: .ok, light: lit), Segment(seconds: 10, status: .ok, light: dim)]
  for i in 0..<40 { segs.append(Segment(seconds: 0.25, status: .ok, light: i % 2 == 0 ? 95 : 110)) }
  segs.append(Segment(seconds: 6, status: .ok, light: lit))
  let r = run(segs)
  check("dim room", r.spoken.map(\.text) == ["Visione ridotta, avvisi meno affidabili", "Avvisi di nuovo affidabili"],
        describe(r.spoken))
}

// 7. Scale fit failing in most frames: reduced; failing in one frame out of four: good.
do {
  let bad = run([Segment(seconds: 5, status: .ok, light: lit), Segment(seconds: 5, status: .ok, light: lit, scaleFresh: false)])
  check("scale failing", bad.levels.last.map { $0.level == .reduced && $0.reason == .scale } ?? false, describe(bad.spoken))
  var segs = [Segment(seconds: 5, status: .ok, light: lit)]
  for _ in 0..<60 { segs += [Segment(seconds: 0.2, status: .ok, light: lit), Segment(seconds: 1 / 15, status: .ok, light: lit, scaleFresh: false)] }
  let some = run(segs)
  check("scale failing sometimes", some.spoken.isEmpty, some.spoken.isEmpty ? "silent" : describe(some.spoken))
}

// 8. Slow analysis (6 per second): reduced.
do {
  let r = run([Segment(seconds: 5, status: .ok, light: lit), Segment(seconds: 5, status: .ok, light: lit, analysesPerSecond: 6)])
  check("slow analysis", r.levels.last.map { $0.level == .reduced && $0.reason == .slow } ?? false, describe(r.spoken))
}

// 9. Floor lost for long (phone pointing up): the floor message, then repeated.
do {
  let r = run([Segment(seconds: 5, status: .ok, light: lit), Segment(seconds: 20, status: .noFloor, light: lit)])
  let floor = r.spoken.filter { $0.text.hasPrefix("Cerco il pavimento") }
  check("no floor", floor.count == 2 && floor[0].t - 5 <= 2, describe(r.spoken))
}

// 10. Starting in the dark: told once the start grace is over (4 s), not "Avvisi di nuovo affidabili" first.
do {
  let r = run([Segment(seconds: 8, status: .noTracking, light: dark)])
  check("start in the dark", r.spoken.map(\.text) == ["Guida sospesa: troppo buio"] && abs(r.spoken[0].t - 4) < 0.1,
        describe(r.spoken))
}

// 11. Starting in a dim room with tracking: reduced after 1 s.
do {
  let r = run([Segment(seconds: 1, status: .noTracking, light: dim), Segment(seconds: 8, status: .ok, light: dim)])
  check("start in dim light", r.spoken.map(\.text) == ["Visione ridotta, avvisi meno affidabili"], describe(r.spoken))
}

// 12. Dark room where ARKit keeps "normal" tracking on black frames for 1.5 s (test of 18/10 evening): suspended
// straight away, without "Visione ridotta" first.
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 1.5, status: .ok, light: 4),
               Segment(seconds: 5, status: .noTracking, light: 4)])
  check("black frames, tracking still normal", r.spoken.map(\.text) == ["Guida sospesa: troppo buio"] && r.spoken[0].t - 10 <= 2,
        describe(r.spoken))
}

// 13. Dim light just before the dark (light 60, then 4): "Visione ridotta" is cut short by "Guida sospesa".
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 1.6, status: .ok, light: dim),
               Segment(seconds: 5, status: .noTracking, light: 4)])
  let sosp = r.spoken.first { $0.text == "Guida sospesa: troppo buio" }
  check("reduced cut by suspended", sosp.map { $0.t - 11.6 <= 1.6 } ?? false, describe(r.spoken))
}

// 14. Back in the light while alerts keep the voice busy, then dark again: the stale "Avvisi di nuovo affidabili"
// is not spoken (it was, once, on 18/10 evening).
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 4, status: .noTracking, light: 4),
               Segment(seconds: 3, status: .ok, light: lit, alertSpeaking: true), Segment(seconds: 4, status: .noTracking, light: 4)])
  check("stale good message dropped", !r.spoken.contains { $0.text == "Avvisi di nuovo affidabili" }, describe(r.spoken))
}

// 15. Back in the light with the scale fit failing for the first second (features rebuilt; test of 18/10 evening,
// second run): good within 3 s all the same.
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 4, status: .ok, light: 4, scaleFresh: false),
               Segment(seconds: 1, status: .ok, light: lit, scaleFresh: false), Segment(seconds: 5, status: .ok, light: lit)])
  let back = r.spoken.last { $0.text == "Avvisi di nuovo affidabili" }
  check("back with scale recovering", back.map { $0.t - 14 <= 3 } ?? false, describe(r.spoken))
}

// 16. Good reached while alerts keep the voice busy, then the scale flickers: the message is still told once the
// voice is free (it was lost once in the second test).
do {
  var segs = [Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 4, status: .noTracking, light: 4),
              Segment(seconds: 3, status: .ok, light: lit, alertSpeaking: true)]
  for _ in 0..<10 { segs += [Segment(seconds: 0.3, status: .ok, light: lit), Segment(seconds: 0.3, status: .ok, light: lit, scaleFresh: false)] }
  let r = run(segs)
  check("good told despite flicker", r.spoken.last?.text == "Avvisi di nuovo affidabili", describe(r.spoken))
}

// 17. Camera half covered by the hand: light 30, ARKit still tracking, scale fit failing (test of 18/10 evening):
// suspended within 2 s, not just "reduced".
do {
  let r = run([Segment(seconds: 10, status: .ok, light: lit), Segment(seconds: 5, status: .ok, light: 30, scaleFresh: false)])
  check("half covered", r.spoken.map(\.text) == ["Guida sospesa: troppo buio"] && r.spoken[0].t - 10 <= 2, describe(r.spoken))
}

// 18. Light around 40 with the scale fit at the 50% limit, so that reduced and unavailable alternate (test of
// 18/10 evening, when the level stayed "good"): a problem is told within 2 s all the same.
do {
  var segs = [Segment(seconds: 10, status: .ok, light: lit)]
  for _ in 0..<10 { segs += [Segment(seconds: 0.4, status: .ok, light: 40), Segment(seconds: 0.4, status: .ok, light: 40, scaleFresh: false)] }
  let r = run(segs)
  check("flicker between reduced and unavailable", r.spoken.first.map { $0.t - 10 <= 2 && $0.text != "Avvisi di nuovo affidabili" } ?? false,
        describe(r.spoken))
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
