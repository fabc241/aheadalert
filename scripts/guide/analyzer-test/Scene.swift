// Shared by the synthetic checks on the Mac (analyzer-test, step-sim): a virtual corridor, optionally with
// stairs, ray-traced from an ARKit-like camera; its depth is turned into a Depth-Anything-like map (d = a/Z + b).
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
  /// Step 1.5: stairs going down across the whole corridor, from edgeZ onwards (count steps; the last level goes on).
  var stairsDown: (edgeZ: Float, rise: Float, tread: Float, count: Int)? = nil

  /// Distance t along a ray (origin o, direction dir) to the first surface.
  func hit(_ o: SIMD3<Float>, _ dir: SIMD3<Float>) -> Float {
    var t = Float.infinity
    if let s = stairsDown {
      for k in 0...s.count {  // level k: y = −k·rise, for z from edgeZ − (k−1)·tread to edgeZ − k·tread
        let near = k == 0 ? Float.infinity : s.edgeZ - Float(k - 1) * s.tread
        let far = k == 0 ? s.edgeZ : (k == s.count ? -Float.infinity : s.edgeZ - Float(k) * s.tread)
        if dir.y < 0 {
          let tl = (-Float(k) * s.rise - o.y) / dir.y
          let z = o.z + tl * dir.z
          if z <= near && z >= far { t = min(t, tl) }
        }
        if k > 0 && dir.z < 0 {  // riser k: the vertical face at the start of level k
          let tr = (near - o.z) / dir.z
          let y = o.y + tr * dir.y
          if y <= -Float(k - 1) * s.rise && y >= -Float(k) * s.rise { t = min(t, tr) }
        }
      }
    } else if dir.y < 0 { t = min(t, -o.y / dir.y) }  // floor y = 0
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
func portraitCamera(height: Float, tiltDownDeg: Float, yawRightDeg: Float = 0, x: Float = 0, z: Float = 0) -> simd_float4x4 {
  let base = simd_float3x3(SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
  let th = -tiltDownDeg * .pi / 180
  let rx = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, cos(th), sin(th)), SIMD3(0, -sin(th), cos(th)))
  let ps = -yawRightDeg * .pi / 180  // about the vertical axis; positive turns the phone to the right
  let ry = simd_float3x3(SIMD3(cos(ps), 0, -sin(ps)), SIMD3(0, 1, 0), SIMD3(sin(ps), 0, cos(ps)))
  let r = ry * rx * base
  return simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(x, height, z, 1))
}

/// noise: relative, per pixel. bend (step-sim): depth read as z·(1 + bend·(z − 1.5)), so that the far floor sinks
/// as in the home recordings when the scale is wrong. blur (step-sim): box blur radius in pixels, for the soft
/// edges of Depth Anything.
func render(_ scene: Scene, camera: CameraSnapshot, noise: Float, bend: Float = 0, blur: Int = 0) -> DepthMap {
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
      let zb = z.isFinite ? max(0.05, z * (1 + bend * (z - 1.5))) : z
      values[j * W + i] = (2.0 / zb + 0.1) * n  // relative inverse depth, unknown scale and shift
    }
  }
  if blur > 0 {  // separable box blur
    for pass in 0..<2 {
      let src = values
      for j in 0..<H {
        for i in 0..<W {
          var sum: Float = 0, n: Float = 0
          for k in -blur...blur {
            let ii = pass == 0 ? i + k : i, jj = pass == 0 ? j : j + k
            guard ii >= 0 && ii < W && jj >= 0 && jj < H else { continue }
            sum += src[jj * W + ii]; n += 1
          }
          values[j * W + i] = sum / n
        }
      }
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
