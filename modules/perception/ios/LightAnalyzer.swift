// MVP step 1.4: warning before a passage from light to dark or from dark to light (no ARKit here, so it can be
// tested on the Mac: scripts/guide/light-test, scripts/guide/light-replay).
//
// Each sample of a small camera grid is mapped to where its ray meets the floor plane, which separates the floor at
// the user's feet (0.3–1 m ahead) from the far view (1.2–4 m ahead, up to 1 m either side). Held at the chest and
// tilted down about 50°, the camera sees the floor only up to 2–3 m (recordings of 18/10).
// Light is in ARKit units, as for the reliability levels of step 1.2: ARKit's estimate for the frame (exposure already
// accounted for) shared out by each sample's linear brightness. The camera image alone misleads: walking towards the
// dark bedroom the corridor grew darker and the camera brightened the image (first test of 18/10 evening).
// A dark passage is a large share of the far view much darker than the feet, wherever it lies in that view: in the
// user's flat the corridor light falls through the bedroom door on a pale bed right in the path and the dark is
// around it (second test). A bright passage is the same, much brighter, seen from dim light or the dark.
// Ruled out: the user's shadow (not dark enough), dark wood (as dark as a dark room, but brown where the room is grey),
// a black bag or rug (too small a share). Not ruled out: large black things in the way (an oven door, dark clothes on
// a rack, a black cabinet in the 18/10 recordings).
import CoreGraphics
import simd

enum LightTuning {
  static let gridWidth = 96, gridHeight = 72  // samples over the camera image (sensor orientation, landscape)
  static let analysesPerSecond: Double = 5
  static let nearFrom: Float = 0.3, nearTo: Float = 1.0, nearHalfWidth: Float = 0.6  // m: the floor at the feet
  static let minNearSamples = 20
  static let farFrom: Float = 1.2, farTo: Float = 4, farHalfWidth: Float = 1.0  // m: the far view
  static let minFarSamples = 60
  /// Dark passage: at most darkFar and darkRatio times darker than the feet, looked for when the feet are at least
  /// darkNearMin. In the first test the dark room measured 12–33 while the corridor by its door was at 200–500.
  /// A room 4 times dimmer is not a passage worth a warning.
  static let darkNearMin: Float = 50, darkFar: Float = 50, darkRatio: Float = 8
  /// Colour of a dark sample (distance from grey in Cb/Cr, 0–181): dark room 4 (median), dark wood door 18.
  static let darkChroma: Float = 12
  /// Bright passage: at least brightFar and brightRatio times brighter than the feet, looked for when the feet are at
  /// most brightNearMax (dim light: 140–320 in the 18/10 tests). From inside the dark bedroom the corridor by the door
  /// measured only 100–350; with 300 as the limit 5 of 7 ways out had no warning (third test). 150 is dim light in
  /// which the guide still works.
  static let brightNearMax: Float = 250, brightFar: Float = 150, brightRatio: Float = 5
  /// Share of the far view that must be dark (or bright). On the 2 109 frames recorded on 18/10, 0.35 warned 10 of the
  /// 11 walks into the dark room of the evening tests, 2–6 s before "Guida sospesa"; 0.4 only 8.
  static let minShare: Float = 0.35
  static let gamma: Float = 2.2  // camera luma → linear brightness (approximate: the camera's tone curve is not public)
  /// Seen without a break for this long (2 analyses at 5 per second). In seconds rather than analyses, so that the
  /// 2-per-second recordings replay the same way.
  static let confirmSeconds: Double = 0.2
  static let rearmAfter: Double = 3  // s the passage must be out of sight before it is announced again
  static let defaultCameraHeight: Float = 1.15  // m above the floor (median of the 18/10 recordings: 1.0–1.26)
  static let speakWithin: Double = 3  // s a warning may wait for the voice; later it is stale
}

enum LightKind: String, CaseIterable {
  case dark, bright

  var message: String { self == .dark ? "Zona buia davanti" : "Zona luminosa davanti" }
}

/// Camera brightness and colour, sampled on a grid over the whole image (sensor orientation).
struct LumaGrid {
  let values: [UInt8]  // luma Y, 0–255
  let chroma: [UInt8]  // distance from grey, √((Cb−128)² + (Cr−128)²)
  let width: Int
  let height: Int
}

/// Light values are in ARKit units (1000 = neutral light).
struct LightAnalysis {
  var ambient: Float = -1  // ARKit's estimate for the frame
  var feet: Float = -1  // median light of the floor at the feet; -1 when too little of it is in view
  var darkShare: Float = 0  // share of the far view that is dark as defined above (0 when not looked for)
  var brightShare: Float = 0
  var kind: LightKind?  // a passage ahead
  var front: Float = 0  // m ahead where the passage begins (its nearest tenth), for the log
  var passage: Float = -1  // median light of the passage
}

/// No state: callable from any queue.
enum LightAnalyzer {
  /// Linear brightness of each luma value.
  private static let linear: [Float] = (0..<256).map { Float(pow(Double($0) / 255, Double(LightTuning.gamma))) }

  /// cameraHeight: m above the floor. ambient: ARKit ambientIntensity of the same frame.
  /// camera.walkDirection: horizontal, or nil for where the camera points.
  static func analyze(_ grid: LumaGrid, camera: CameraSnapshot, cameraHeight: Float, ambient: Float) -> LightAnalysis {
    var out = LightAnalysis()
    out.ambient = ambient
    let meanLinear = grid.values.reduce(Float(0)) { $0 + linear[Int($1)] } / Float(max(1, grid.values.count))
    let perLinear = ambient / max(meanLinear, 1e-4)
    let T = camera.transform, K = camera.intrinsics
    let R = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z),
                          SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                          SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
    var fwd = camera.walkDirection ?? -SIMD3(T.columns.2.x, 0, T.columns.2.z)
    fwd.y = 0
    guard simd_length(fwd) > 0.2 else { return out }  // phone pointing straight down or up
    fwd = simd_normalize(fwd)
    let right = SIMD3<Float>(-fwd.z, 0, fwd.x)
    let fx = K.columns.0.x, fy = K.columns.1.y, cx = K.columns.2.x, cy = K.columns.2.y
    let su = Float(camera.imageSize.width) / Float(grid.width), sv = Float(camera.imageSize.height) / Float(grid.height)

    typealias Sample = (light: Float, chroma: Float, ahead: Float)
    var feet: [Float] = []
    var far: [Sample] = []
    for j in 0..<grid.height {
      let v = (Float(j) + 0.5) * sv
      for i in 0..<grid.width {
        let u = (Float(i) + 0.5) * su
        let ray = R * SIMD3((u - cx) / fx, -(v - cy) / fy, -1)
        guard ray.y < -0.035 * simd_length(ray) else { continue }  // at least 2° below the horizon
        let p = (cameraHeight / -ray.y) * ray  // where the ray meets the floor, from the phone
        let ahead = simd_dot(p, fwd), lateral = abs(simd_dot(p, right))
        let k = j * grid.width + i
        let light = perLinear * linear[Int(grid.values[k])]
        if ahead >= LightTuning.nearFrom && ahead <= LightTuning.nearTo && lateral <= LightTuning.nearHalfWidth {
          feet.append(light)
        } else if ahead >= LightTuning.farFrom && ahead < LightTuning.farTo && lateral <= LightTuning.farHalfWidth {
          far.append((light, Float(grid.chroma[k]), ahead))
        }
      }
    }
    guard feet.count >= LightTuning.minNearSamples, far.count >= LightTuning.minFarSamples else { return out }
    out.feet = median(feet)

    var candidates: [(kind: LightKind, isPassage: (Sample) -> Bool)] = []
    if out.feet >= LightTuning.darkNearMin {
      let limit = min(LightTuning.darkFar, out.feet / LightTuning.darkRatio)
      candidates.append((.dark, { $0.light <= limit && $0.chroma <= LightTuning.darkChroma }))
    }
    if out.feet <= LightTuning.brightNearMax {
      let limit = max(LightTuning.brightFar, LightTuning.brightRatio * max(out.feet, ReliabilityTuning.darkLight))
      candidates.append((.bright, { $0.light >= limit }))
    }
    for (kind, isPassage) in candidates {
      let hits = far.filter(isPassage)
      let share = Float(hits.count) / Float(far.count)
      if kind == .dark { out.darkShare = share } else { out.brightShare = share }
      guard out.kind == nil, share >= LightTuning.minShare else { continue }
      out.kind = kind
      out.front = hits.map(\.ahead).sorted()[hits.count / 10]
      out.passage = median(hits.map(\.light))
    }
    return out
  }

  private static func median(_ xs: [Float]) -> Float {
    let s = xs.sorted()
    return s[s.count / 2]
  }
}

/// When to speak: once per passage. A passage seen without a break for LightTuning.confirmSeconds is announced; it is
/// not announced again until it has been out of sight for LightTuning.rearmAfter (standing at the door, or walking up
/// to it, gives one warning only).
final class LightWarning {
  private var streak: (kind: LightKind, since: Double)?
  private var armed: [LightKind: Bool] = [.dark: true, .bright: true]
  private var lastSeen: [LightKind: Double] = [:]

  func update(_ a: LightAnalysis, now: Double) -> LightKind? {
    for k in LightKind.allCases where k != a.kind {
      if let seen = lastSeen[k], now - seen >= LightTuning.rearmAfter { armed[k] = true }
    }
    guard let kind = a.kind else {
      streak = nil
      return nil
    }
    lastSeen[kind] = now
    if streak?.kind != kind { streak = (kind, now) }
    guard now - streak!.since >= LightTuning.confirmSeconds - 1e-6, armed[kind] == true else { return nil }
    armed[kind] = false
    return kind
  }
}
