// Synthetic check of the light-passage warning (MVP step 1.4), run on the Mac without ARKit.
// A tiny ray caster draws what the iPhone 13 camera (intrinsics of a real frame) would see in a few scenes: a floor
// plus upright rectangles (walls, door openings, a window), each with its light in ARKit units (1000 = neutral) and its
// colour. The camera exposes for the mean light (the frame's ARKit estimate) and encodes with gamma 2.2. The user walks
// towards the scene at 0.6 m/s with the phone at the chest (1.15 m) tilted down; the analysis runs 5 times a second.
// The doors here are narrow openings in lit walls, a harder case than the flat of the 18/10 tests (where the dark
// filled more of the view and the warning came 2–6 s before the threshold): the distances checked are lower bounds.
// Usage (from mobile/): scripts/guide/light-test/run.sh
import CoreGraphics
import Foundation
import simd

struct CameraSnapshot {
  let transform: simd_float4x4
  let intrinsics: simd_float3x3
  let imageSize: CGSize
  var walkDirection: SIMD3<Float>? = nil
}

/// Upright rectangle across the path at `ahead` metres (world z = -ahead), lateral and height ranges in metres.
struct Panel { let ahead: Float; let lateral: ClosedRange<Float>; let height: ClosedRange<Float>; let light: Float; let chroma: Float }
/// Floor patch (lateral and ahead ranges), drawn over the base floor; a later patch covers an earlier one.
struct Patch { let ahead: ClosedRange<Float>; let lateral: ClosedRange<Float>; let light: Float; let chroma: Float }

struct Scene {
  var floor: (light: Float, chroma: Float) = (1000, 8)
  var patches: [Patch] = []
  var panels: [Panel] = []  // drawn in order: an earlier panel covers a later one at the same distance
  var sky: (light: Float, chroma: Float) = (1100, 5)  // above the horizon with nothing in the way
}

let K = simd_float3x3(SIMD3(1514.7, 0, 0), SIMD3(0, 1514.7, 0), SIMD3(963.5, 715.2, 1))
let imageSize = CGSize(width: 1920, height: 1440)

/// Phone held in portrait at the chest, facing world -z, tilted down by `pitch` degrees, at `z` (world).
func camera(pitch: Float, height: Float, z: Float) -> CameraSnapshot {
  let t = pitch * .pi / 180  // negative: down
  let c2 = SIMD3<Float>(0, -sin(t), cos(t))  // camera looks along -c2
  let c1 = SIMD3<Float>(1, 0, 0)
  let c0 = simd_cross(c1, c2)
  let T = simd_float4x4(SIMD4(c0, 0), SIMD4(c1, 0), SIMD4(c2, 0), SIMD4(0, height, z, 1))
  return CameraSnapshot(transform: T, intrinsics: K, imageSize: imageSize, walkDirection: SIMD3(0, 0, -1))
}

/// The camera image and the frame's ARKit light.
func render(_ scene: Scene, _ cam: CameraSnapshot) -> (grid: LumaGrid, ambient: Float) {
  let gw = LightTuning.gridWidth, gh = LightTuning.gridHeight
  var light = [Float](repeating: 0, count: gw * gh)
  var chroma = [UInt8](repeating: 0, count: gw * gh)
  let T = cam.transform
  let R = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z), SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                        SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
  let o = SIMD3(T.columns.3.x, T.columns.3.y, T.columns.3.z)
  let su = Float(imageSize.width) / Float(gw), sv = Float(imageSize.height) / Float(gh)
  for j in 0..<gh {
    for i in 0..<gw {
      let u = (Float(i) + 0.5) * su, v = (Float(j) + 0.5) * sv
      let ray = R * SIMD3((u - 963.5) / 1514.7, -(v - 715.2) / 1514.7, -1)
      var best: (t: Float, light: Float, chroma: Float) = (.infinity, scene.sky.light, scene.sky.chroma)
      if ray.y < 0 {
        let t = -o.y / ray.y, p = o + t * ray
        var c = scene.floor
        for patch in scene.patches where patch.ahead.contains(-p.z) && patch.lateral.contains(p.x) { c = (patch.light, patch.chroma) }
        best = (t, c.light, c.chroma)
      }
      for panel in scene.panels where ray.z < 0 {
        let t = (-panel.ahead - o.z) / ray.z
        guard t > 0, t < best.t else { continue }
        let p = o + t * ray
        if panel.lateral.contains(p.x) && panel.height.contains(p.y) { best = (t, panel.light, panel.chroma) }
      }
      light[j * gw + i] = best.light
      chroma[j * gw + i] = UInt8(max(0, min(255, best.chroma)))
    }
  }
  let mean = light.reduce(0, +) / Float(light.count)
  let luma = light.map { UInt8((255 * pow(min(1, 0.18 * $0 / mean), 1 / 2.2)).rounded()) }  // mean light → mid grey
  return (LumaGrid(values: luma, chroma: chroma, width: gw, height: gh), mean)
}

/// A wall across the path at `at` m with an opening (door: from the floor; window: from 0.9 m) showing `inside`.
func wallWithOpening(at d: Float, wall: (Float, Float) = (1100, 6), opening: ClosedRange<Float> = -0.4...0.4,
                     openingHeight: ClosedRange<Float> = 0...2.0, inside: (Float, Float)) -> [Panel] {
  [Panel(ahead: d, lateral: -3 ... opening.lowerBound, height: 0...2.6, light: wall.0, chroma: wall.1),
   Panel(ahead: d, lateral: opening.upperBound...3, height: 0...2.6, light: wall.0, chroma: wall.1),
   Panel(ahead: d, lateral: opening, height: 0...openingHeight.lowerBound, light: wall.0, chroma: wall.1),
   Panel(ahead: d, lateral: opening, height: openingHeight.upperBound...2.6, light: wall.0, chroma: wall.1),
   Panel(ahead: d + 4, lateral: -3...3, height: 0...2.6, light: inside.0, chroma: inside.1)]  // back wall of the room
}

struct Walk { var from: Float = 4.0; var to: Float = 0.5; var speed: Float = 0.6; var pause: Double = 0 }

/// Walks towards a passage at 0 (world z = 0 is where the door is; the user starts `from` metres before it).
/// Returns the warnings spoken with the distance to the passage at that moment.
func walk(_ scene: (Float) -> Scene, pitch: Float, _ w: Walk = Walk()) -> [(kind: LightKind, distance: Float, t: Double)] {
  let warning = LightWarning()
  var out: [(LightKind, Float, Double)] = []
  var t = 0.0
  let dt = 1 / LightTuning.analysesPerSecond
  var d = w.from
  while d > w.to || t < w.pause {
    // the scene is built with the passage `d` metres ahead of a camera at z = 0
    let cam = camera(pitch: pitch, height: 1.15, z: 0)
    let (grid, ambient) = render(scene(d), cam)
    let a = LightAnalyzer.analyze(grid, camera: cam, cameraHeight: 1.15, ambient: ambient)
    if let k = warning.update(a, now: t) { out.append((k, d, t)) }
    t += dt
    if t >= w.pause { d -= w.speed * Float(dt) }
  }
  return out
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
  print("\(ok ? "ok  " : "FAIL") \(name): \(detail)")
  if !ok { failures += 1 }
}
func describe(_ ws: [(kind: LightKind, distance: Float, t: Double)]) -> String {
  ws.isEmpty ? "no warning" : ws.map { String(format: "\"%@\" at %.2f m", $0.kind.message, $0.distance) }.joined(separator: ", ")
}

let litFloor = Scene().floor
for pitch: Float in [-40, -50, -60] {
  print("— phone tilted down \(Int(-pitch))°")
  // 1. Lit corridor → open door on a dark room (floor inside dark too).
  let darkRoom = { (d: Float) in
    Scene(floor: litFloor, patches: [Patch(ahead: d...(d + 4), lateral: -0.4...0.4, light: 5, chroma: 3)],
          panels: wallWithOpening(at: d, inside: (5, 3)))
  }
  var ws = walk(darkRoom, pitch: pitch)
  check("1 open door, dark room", ws.count == 1 && ws[0].kind == .dark && ws[0].distance >= 1.0, describe(ws))
  // 1b. As in the first test of 18/10 evening: the corridor grows dimmer towards the door (1000 → 300) and the
  // corridor light falls on the first half metre inside the room.
  ws = walk({ d in
    Scene(floor: litFloor,
          patches: [Patch(ahead: (d - 3)...d, lateral: -3...3, light: 600, chroma: 8),
                    Patch(ahead: (d - 1.5)...d, lateral: -3...3, light: 300, chroma: 8),
                    Patch(ahead: d...(d + 4), lateral: -0.4...0.4, light: 15, chroma: 3),
                    Patch(ahead: d...(d + 0.5), lateral: -0.4...0.4, light: 100, chroma: 6)],
          panels: wallWithOpening(at: d, wall: (300, 6), inside: (15, 3)))
  }, pitch: pitch)
  check("1b dimming corridor, light spilling inside", ws.count == 1 && ws[0].kind == .dark && ws[0].distance >= 0.6, describe(ws))
  // 2. Dark room → open door on a lit corridor.
  ws = walk({ d in
    Scene(floor: (5, 3), patches: [Patch(ahead: d...(d + 4), lateral: -0.4...0.4, light: 1000, chroma: 8)],
          panels: wallWithOpening(at: d, wall: (5, 3), inside: (1100, 6)), sky: (5, 3))
  }, pitch: pitch)
  check("2 dark room → lit door", ws.count == 1 && ws[0].kind == .bright && ws[0].distance >= 1.0, describe(ws))
  // 2b. Dim room (150, as in the 18/10 test) → lit door.
  ws = walk({ d in
    Scene(floor: (150, 5), patches: [Patch(ahead: d...(d + 4), lateral: -0.4...0.4, light: 1000, chroma: 8)],
          panels: wallWithOpening(at: d, wall: (150, 5), inside: (1100, 6)), sky: (150, 5))
  }, pitch: pitch)
  check("2b dim room → lit door", ws.count == 1 && ws[0].kind == .bright && ws[0].distance >= 1.0, describe(ws))
  // 3. Closed door of dark wood across the corridor (as dark as a dark room in the camera image, but brown).
  ws = walk({ d in Scene(floor: litFloor, panels: [Panel(ahead: d, lateral: -0.4...0.4, height: 0...2.0, light: 15, chroma: 18)] + wallWithOpening(at: d, inside: (1100, 6))) }, pitch: pitch)
  check("3 dark wood door", ws.isEmpty, describe(ws))
  // 4. Black object on the floor (a bag, a coat: 40 × 40 cm), lit floor around and beyond.
  ws = walk({ d in Scene(floor: litFloor, patches: [Patch(ahead: d...(d + 0.4), lateral: -0.2...0.2, light: 10, chroma: 2)]) }, pitch: pitch)
  check("4 black object on the floor", ws.isEmpty, describe(ws))
  // 4b. Black rug across the whole path (1.2 × 0.6 m). Known limit with the phone tilted down 60°: the far view is then
  // only 1.2–1.8 m and the rug fills it.
  ws = walk({ d in Scene(floor: litFloor, patches: [Patch(ahead: d...(d + 0.6), lateral: -0.6...0.6, light: 10, chroma: 2)]) }, pitch: pitch)
  if pitch > -60 { check("4b black rug across the path", ws.isEmpty, describe(ws)) } else { print("info 4b black rug across the path (known limit at 60°): \(describe(ws))") }
  // 5. Window at night (from 0.9 m up) in a wall across the path.
  ws = walk({ d in Scene(floor: litFloor, panels: wallWithOpening(at: d, opening: -0.6...0.6, openingHeight: 0.9...2.1, inside: (3, 2))) }, pitch: pitch)
  check("5 window at night", ws.isEmpty, describe(ws))
  // 6. Room with the light on but dimmer (4 times).
  ws = walk({ d in
    Scene(floor: litFloor, patches: [Patch(ahead: d...(d + 4), lateral: -0.4...0.4, light: 250, chroma: 5)],
          panels: wallWithOpening(at: d, inside: (250, 5)))
  }, pitch: pitch)
  check("6 dimmer lit room", ws.isEmpty, describe(ws))
  // 7. Standing 2.5 m from the dark door for 30 s, then walking up to it.
  ws = walk(darkRoom, pitch: pitch, Walk(from: 2.5, pause: 30))
  check("7 standing 30 s at the dark door", ws.count == 1, describe(ws))
}
print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)
