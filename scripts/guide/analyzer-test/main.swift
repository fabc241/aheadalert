// Synthetic check of the obstacle geometry (MVP step 1.1) and of the steps down and up (step 1.5), run on the Mac
// without ARKit.
// A virtual corridor is ray-traced from an ARKit-like camera held in portrait at chest height and tilted down;
// its depth is turned into a Depth-Anything-like map (d = a/Z + b, with noise) and fed to ObstacleAnalyzer.
// Usage (from mobile/): scripts/guide/analyzer-test/run.sh
import CoreGraphics
import Foundation
import simd

func describe(_ a: FrameAnalysis) -> String {
  let z = Zone.allCases.map { zone -> String in
    guard let h = a.zones[zone.rawValue] else { return "\(zone.key) –" }
    return String(format: "%@ %.2f m%@ (%.3f m²)", zone.key, h.distance, h.low ? " LOW" : "", h.area)
  }
  let drop = a.dropSeen.map {
    String(format: " · drop %.2f m, %.2f below, %.3f m², floor before %.3f, jump %.2f, features %d/%d%@", $0.distance,
           $0.depth, $0.area, $0.floorBefore, $0.jump, a.dropFeatures.floor, a.dropFeatures.below,
           a.drop == nil ? " VETOED" : "")
  } ?? " · drop –"
  let up = a.zones[Zone.ahead.rawValue]?.stepUp == true ? " STEP UP" : ""
  return String(format: "scale %@ (%@), fit %d/%d, nearest floor %.2f m | ", a.scaleOk ? "ok" : "NO", a.scaleSource, a.fitInliers,
                a.fitCandidates, a.nearestFloor) + z.joined(separator: " · ") + up + drop
}

GuideTuning.bodyOffset = 0  // the scenes are measured from the phone
var failures = 0
func check(_ name: String, _ scene: Scene, tilt: Float = 30, yaw: Float = 0, walking: Bool = false,
           noise: Float = 0.02, featureCount: Int = 150, expect: [Zone: (dist: Float, low: Bool)?],
           drop: Float? = nil, stepUp: Bool = false) {
  let analyzer = ObstacleAnalyzer()
  var last = FrameAnalysis()
  let cam = camera(tilt: tilt, yaw: yaw, walking: walking)
  for f in 0..<3 {
    last = analyzer.analyze(depth: render(scene, camera: cam, noise: noise), camera: cam, floorY: 0,
                            features: features(scene, camera: cam, count: featureCount, noise: 0.05), now: Double(f) / 15)
  }
  var ok = last.scaleOk
  for (zone, e) in expect {
    let h = last.zones[zone.rawValue]
    if let e {
      guard let h, abs(h.distance - e.dist) <= 0.25, h.low == e.low else { ok = false; continue }
    } else if h != nil { ok = false }
  }
  // Step 1.5: a step down expected at this distance, or none; "ahead" named a step up, or not.
  if let drop {
    if let d = last.drop { if abs(d.distance - drop) > 0.25 { ok = false } } else { ok = false }
  } else if last.drop != nil { ok = false }
  if (last.zones[Zone.ahead.rawValue]?.stepUp ?? false) != stepUp { ok = false }
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\n     \(describe(last))")
}

let lowBoxAhead = Box(lo: SIMD3(-0.15, 0, -1.8), hi: SIMD3(0.15, 0.3, -1.5), name: "box 30 cm, 1.5 m ahead")
let cabinetLeft = Box(lo: SIMD3(-0.8, 0, -2.5), hi: SIMD3(-0.4, 1.0, -1.0), name: "cabinet left from 1 m")
let chairRight = Box(lo: SIMD3(0.35, 0, -1.4), hi: SIMD3(0.75, 0.9, -1.0), name: "chair right at 1 m")
let wallAhead = Box(lo: SIMD3(-0.8, 0, -1.3), hi: SIMD3(0.8, 2.6, -1.2), name: "wall 1.2 m ahead")
let cane = Box(lo: SIMD3(-0.006, 0, -1.0), hi: SIMD3(0.006, 0.8, -0.4), name: "cane-like pole")

check("empty corridor: no alerts", Scene(boxes: []), expect: [.left: nil, .ahead: nil, .right: nil])
check("low box ahead at 1.5 m", Scene(boxes: [lowBoxAhead]), expect: [.ahead: (1.5, true), .left: nil, .right: nil])
check("cabinet on the left at 1 m", Scene(boxes: [cabinetLeft]), expect: [.left: (1.0, false), .ahead: nil, .right: nil])
check("chair on the right at 1 m", Scene(boxes: [chairRight]), expect: [.right: (1.0, false), .left: nil])
check("box ahead + cabinet left", Scene(boxes: [lowBoxAhead, cabinetLeft]),
      expect: [.ahead: (1.5, true), .left: (1.0, false), .right: nil])
check("wall 1.2 m ahead fills the view", Scene(boxes: [wallAhead]), expect: [.ahead: (1.2, false)])
check("thin pole (cane) ahead: ignored", Scene(boxes: [cane]), expect: [.ahead: nil])
check("phone tilted 15°: low box", Scene(boxes: [lowBoxAhead]), tilt: 15, expect: [.ahead: (1.5, true)])
check("phone tilted 45°: low box", Scene(boxes: [lowBoxAhead]), tilt: 45, expect: [.ahead: (1.5, true)])
check("phone upright (0°): floor seen only from ~2 m", Scene(boxes: []), tilt: 0, expect: [.ahead: nil])
check("no feature points: floor fallback, low box", Scene(boxes: [lowBoxAhead]), featureCount: 0,
      expect: [.ahead: (1.5, true)])
let bedAhead = Box(lo: SIMD3(-0.8, 0, -2.6), hi: SIMD3(0.8, 0.55, -0.6), name: "bed 55 cm high from 0.6 m")
check("bed filling the view at 0.6 m", Scene(boxes: [bedAhead]), tilt: 50, expect: [.ahead: (0.6, false)])
check("narrow corridor (walls at ±0.58 m): no alerts", Scene(boxes: [], wallX: 0.58),
      expect: [.left: nil, .ahead: nil, .right: nil])
check("very narrow corridor (walls at ±0.40 m): no alerts", Scene(boxes: [], wallX: 0.40),
      expect: [.left: nil, .ahead: nil, .right: nil])
let shelfInNarrow = Box(lo: SIMD3(-0.40, 0, -1.6), hi: SIMD3(-0.15, 1.2, -1.3), name: "shelf sticking out at 1.3 m")
check("narrow corridor + shelf sticking out into the path: ahead", Scene(boxes: [shelfInNarrow], wallX: 0.40),
      expect: [.ahead: (1.3, false), .right: nil])
check("90 cm corridor, phone turned 12° right, walking straight: no alerts", Scene(boxes: [], wallX: 0.45),
      yaw: 12, walking: true, expect: [.left: nil, .ahead: nil, .right: nil])
check("same, standing still (direction from the phone): right wall ahead", Scene(boxes: [], wallX: 0.45),
      yaw: 12, expect: [.left: nil])
check("90 cm corridor, phone turned, box ahead at 1.5 m", Scene(boxes: [lowBoxAhead], wallX: 0.45),
      yaw: 10, walking: true, expect: [.ahead: (1.5, true), .left: nil])
let fridgeAlongside = Box(lo: SIMD3(0.35, 0, -1.0), hi: SIMD3(1.0, 1.9, -0.2), name: "fridge column alongside")
check("tall cabinet alongside on the right (to 1 m): no alert", Scene(boxes: [fridgeAlongside]),
      expect: [.right: nil, .ahead: nil])
check("noise 5%: empty corridor", Scene(boxes: []), noise: 0.05, expect: [.left: nil, .ahead: nil, .right: nil])

// Step 1.5: steps (a stair is 15–18 cm high, 28–30 cm deep)
check("stairs down from 1.5 m", Scene(boxes: [], stairsDown: (-1.5, 0.17, 0.29, 6)), walking: true,
      expect: [.ahead: nil], drop: 1.5)
check("stairs down from 1 m, phone tilted 45°", Scene(boxes: [], stairsDown: (-1.0, 0.17, 0.29, 6)), tilt: 45,
      walking: true, expect: [.ahead: nil], drop: 1.0)
check("single step down (15 cm) at 1.8 m", Scene(boxes: [], stairsDown: (-1.8, 0.15, 0.3, 1)), walking: true,
      expect: [.ahead: nil], drop: 1.8)
check("8 cm threshold down at 1.2 m: not a step", Scene(boxes: [], stairsDown: (-1.2, 0.08, 0.3, 1)), walking: true,
      expect: [.ahead: nil])
let stepUp = Box(lo: SIMD3(-0.8, 0, -5), hi: SIMD3(0.8, 0.17, -1.4), name: "step up 17 cm at 1.4 m")
check("single step up (17 cm) at 1.4 m", Scene(boxes: [stepUp]), walking: true, expect: [.ahead: (1.4, true)],
      stepUp: true)
let stairsUp = (0..<5).map { k in
  Box(lo: SIMD3(-0.8, 0, -5), hi: SIMD3(0.8, 0.17 * Float(k + 1), -1.2 - 0.29 * Float(k)), name: "stair \(k)")
}
check("stairs up from 1.2 m", Scene(boxes: stairsUp), walking: true, expect: [.ahead: (1.2, true)], stepUp: true)
check("low box ahead (30 cm wide): not a step", Scene(boxes: [lowBoxAhead]), walking: true,
      expect: [.ahead: (1.5, true)], stepUp: false)

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
