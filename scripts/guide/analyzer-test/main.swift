// Synthetic check of the obstacle geometry (MVP step 1.1), run on the Mac without ARKit.
// A virtual corridor is ray-traced from an ARKit-like camera held in portrait at chest height and tilted down;
// its depth is turned into a Depth-Anything-like map (d = a/Z + b, with noise) and fed to ObstacleAnalyzer.
// Usage (from mobile/): scripts/guide/analyzer-test/run.sh
import CoreGraphics
import Foundation
import simd

/// Stand-in for the module's DepthMap (that file needs Core ML and Vision).
struct DepthMap {
  let values: [Float]
  let width: Int
  let height: Int
}

struct Box { let lo: SIMD3<Float>; let hi: SIMD3<Float>; let name: String }

struct Scene {
  var boxes: [Box]
  var wallX: Float = 0.8  // corridor walls at ±0.8 m
  var endZ: Float = -5  // end wall 5 m ahead

  /// Distance t along a ray (origin o, direction dir) to the first surface.
  func hit(_ o: SIMD3<Float>, _ dir: SIMD3<Float>) -> Float {
    var t = Float.infinity
    if dir.y < 0 { t = min(t, -o.y / dir.y) }  // floor y = 0
    if dir.x > 0 { t = min(t, (wallX - o.x) / dir.x) }
    if dir.x < 0 { t = min(t, (-wallX - o.x) / dir.x) }
    if dir.z < 0 { t = min(t, (endZ - o.z) / dir.z) }
    if dir.y > 0 { t = min(t, (2.6 - o.y) / dir.y) }  // ceiling
    for b in boxes {  // slab method
      var t0: Float = 0, t1 = Float.infinity
      var ok = true
      for k in 0..<3 {
        if abs(dir[k]) < 1e-9 {
          if o[k] < b.lo[k] || o[k] > b.hi[k] { ok = false }
          continue
        }
        let a = (b.lo[k] - o[k]) / dir[k], c = (b.hi[k] - o[k]) / dir[k]
        t0 = max(t0, min(a, c)); t1 = min(t1, max(a, c))
      }
      if ok && t0 <= t1 && t0 > 0 { t = min(t, t0) }
    }
    return t
  }
}

/// ARKit camera in portrait: camera x points to the Home button (down), y to the user's right, z backwards.
func portraitCamera(height: Float, tiltDownDeg: Float, yawRightDeg: Float = 0) -> simd_float4x4 {
  let base = simd_float3x3(SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
  let th = -tiltDownDeg * .pi / 180
  let rx = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, cos(th), sin(th)), SIMD3(0, -sin(th), cos(th)))
  let ps = -yawRightDeg * .pi / 180  // about the vertical axis; positive turns the phone to the right
  let ry = simd_float3x3(SIMD3(cos(ps), 0, -sin(ps)), SIMD3(0, 1, 0), SIMD3(sin(ps), 0, cos(ps)))
  let r = ry * rx * base
  return simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, height, 0, 1))
}

func render(_ scene: Scene, camera: CameraSnapshot, noise: Float) -> DepthMap {
  let W = 518, H = 392
  let K = camera.intrinsics, T = camera.transform
  let R = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z),
                        SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                        SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
  let o = SIMD3(T.columns.3.x, T.columns.3.y, T.columns.3.z)
  var g = SystemRandomNumberGenerator()
  var values = [Float](repeating: 0, count: W * H)
  for j in 0..<H {
    for i in 0..<W {
      let u = (Float(i) + 0.5) * Float(camera.imageSize.width) / Float(W)
      let v = (Float(j) + 0.5) * Float(camera.imageSize.height) / Float(H)
      let ray = R * SIMD3((u - K.columns.2.x) / K.columns.0.x, -(v - K.columns.2.y) / K.columns.1.y, -1)
      let z = scene.hit(o, ray)  // ray has camera-z component −1, so t is the z-depth
      let n = 1 + Float.random(in: -noise...noise, using: &g)
      values[j * W + i] = (2.0 / z + 0.1) * n  // relative inverse depth, unknown scale and shift
    }
  }
  return DepthMap(values: values, width: W, height: H)
}

let intrinsics = simd_float3x3(SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1))
func camera(tilt: Float, yaw: Float = 0, walking: Bool = false) -> CameraSnapshot {
  CameraSnapshot(transform: portraitCamera(height: 1.3, tiltDownDeg: tilt, yawRightDeg: yaw), intrinsics: intrinsics,
                 imageSize: CGSize(width: 1920, height: 1440), walkDirection: walking ? SIMD3(0, 0, -1) : nil)
}

/// ARKit-like feature points: hits of random rays on the scene surfaces, with depth noise.
func features(_ scene: Scene, camera: CameraSnapshot, count: Int, noise: Float) -> [SIMD3<Float>] {
  let K = camera.intrinsics, T = camera.transform
  let R = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z),
                        SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                        SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
  let o = SIMD3(T.columns.3.x, T.columns.3.y, T.columns.3.z)
  return (0..<count).map { _ in
    let u = Float.random(in: 0..<Float(camera.imageSize.width)), v = Float.random(in: 0..<Float(camera.imageSize.height))
    let ray = R * SIMD3((u - K.columns.2.x) / K.columns.0.x, -(v - K.columns.2.y) / K.columns.1.y, -1)
    return o + scene.hit(o, ray) * (1 + Float.random(in: -noise...noise)) * ray
  }
}

func describe(_ a: FrameAnalysis) -> String {
  let z = Zone.allCases.map { zone -> String in
    guard let h = a.zones[zone.rawValue] else { return "\(zone.key) –" }
    return String(format: "%@ %.2f m%@ (%.3f m²)", zone.key, h.distance, h.low ? " LOW" : "", h.area)
  }
  return String(format: "scale %@ (%@), fit %d/%d, nearest floor %.2f m | ", a.scaleOk ? "ok" : "NO", a.scaleSource, a.fitInliers,
                a.fitCandidates, a.nearestFloor) + z.joined(separator: " · ")
}

GuideTuning.bodyOffset = 0  // the scenes are measured from the phone
var failures = 0
func check(_ name: String, _ scene: Scene, tilt: Float = 30, yaw: Float = 0, walking: Bool = false,
           noise: Float = 0.02, featureCount: Int = 150, expect: [Zone: (dist: Float, low: Bool)?]) {
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

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
