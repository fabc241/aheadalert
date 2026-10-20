// MVP step 1.1: per-frame geometry of the obstacle guide (no ARKit here, so it can be tested on the Mac:
// scripts/guide/analyzer-test).
// Depth map + camera pose + floor height + ARKit feature points → obstacle hits in three zones (left / ahead / right).
// MVP step 1.5 (experimental): a step down (floor continuing lower on the walking line) and a step up (a low, wide
// obstacle straight ahead).
import CoreGraphics
import simd

/// Thresholds, tuned with the walking tests of 18/10 (step 1.1).
enum GuideTuning {
  static let alertDistance: Float = 2.0  // m ahead, analysed; the user may choose less (GuideSettings, step 1.6)
  static let minForward: Float = 0.25  // m from the phone: closer points are the user's hands, or out of view
  /// Added to the distance from the phone (held at the chest, in front of the body). 0.4 m was tried on 18/10 and
  /// removed at the user's request: distances are measured from the phone until further distance tests.
  static var bodyOffset: Float = 0
  static let centreHalfWidth: Float = 0.30  // m either side of the walking line: "davanti"
  static let sideHalfWidth: Float = 0.45  // beyond this a thing is not in the way. 0.60 caught the walls of
                                          // a 1.15 m corridor (test of 18/10)
  static let minHeight: Float = 0.10  // m above the floor; below this it is floor plus depth noise
  static let maxHeight: Float = 2.0
  static let lowHeight: Float = 0.5  // an obstacle whose top is below this is "basso"
  static let minArea: Float = 0.02  // m² of surface per zone: filters thin things such as the cane
  static let sampleStride = 2  // every 2nd pixel of the 518×392 depth map
  static let floorMinDist: Float = 0.5, floorMaxDist: Float = 3.5  // floor samples used for the scale fit
  static let fitTolerance: Float = 0.08  // a floor sample fits if its depth is within 8%
  static let featureTolerance: Float = 0.15  // ARKit feature points are noisier
  static let minFeatures = 15  // fewer in view: fall back to the floor fit
  // Side walls along the path (see sideWall)
  static let wallSearchWidth: Float = 1.0  // m either side: points used to find the walls
  static let wallMinOffset: Float = 0.15  // a side wall is at least this far from the walking line
  static let wallTolerance: Float = 0.05, wallMinLength: Float = 0.6, wallMaxSlope: Float = 0.35  // ±19°
  static let wallMinLengthAlongside: Float = 0.35
  static let wallThickness: Float = 0.08  // what sticks out of a side wall by less than this is the wall
  static let window = 5, hitsNeeded = 3  // frames (~0.3 s at 15 fps)
  static let zoneCooldown: Double = 2  // s between two messages for the same zone (agreed criterion)
  static let zoneClearAfter: Double = 1.5  // s without a hit before a zone counts as free again
  static let tiltDownDist: Float = 1.2  // floor not visible closer than this: phone held too upright
  static let hintEvery: Double = 10
}

/// Step 1.5: steps down and up. A stair is 15–18 cm high; below 10 cm (thresholds, low kerbs) nothing is promised.
enum StepTuning {
  static let dropMin: Float = 0.12  // m below the floor: a step down. Depth noise on a flat floor reaches 10 cm
  static let dropMax: Float = 1.5  // deeper than this it is a wrong scale, not a step
  static let halfWidth: Float = 0.30  // m either side of the walking line, as "davanti"
  static let minArea: Float = 0.03  // m² of lower floor
  /// ARKit feature points beyond the edge at the height of the floor mean the floor goes on: on a shiny floor the
  /// depth model sees the reflections of doors and furniture as a space below it (recordings of 18/10).
  static let featureFloorTol: Float = 0.05, featureFloorMin = 3
  /// A real edge has floor before it, and the height jumps there. Without these checks the 2,089 analysed frames of
  /// the flat home (18/10) gave a step down in 11% of them, mostly where a wrong scale bends the far floor downwards;
  /// with them 8 isolated frames remain. Synthetic stairs: jump 0.14–0.17 m. Provisional, to tune on real stairs.
  static let minFloorBefore: Float = 0.05  // m²
  static let minJump: Float = 0.10  // m
  /// Step up: the front of the nearest obstacle ahead (its first 20 cm) is low and spans the walking line.
  static let upFront: Float = 0.20, upMaxTop: Float = 0.30, upMinSpread: Float = 0.40
  static let window = 8, hitsNeeded = 5  // frames (~0.5 s at 15 fps) for a step down
  /// The phone's height above the floor it stands on, before the session has its own (see ObstacleGuide.floorPlane).
  static let usualHeight: Float = 1.15, heightTolerance: Float = 0.30
}

/// A step down ahead: where the floor ends (the edge), and how much lower the floor beyond it is.
struct DropHit {
  let distance: Float  // m ahead, to the edge
  let depth: Float  // m below the floor (median of what is seen beyond the edge)
  let area: Float  // m²
  var floorBefore: Float = 0  // m² of floor seen on the walking line in the 60 cm before the edge
  var jump: Float = 0  // m: floor height in the 30 cm before the edge minus the height in the 40 cm after it
}

enum Zone: Int, CaseIterable {
  case left, ahead, right
  var key: String { ["left", "ahead", "right"][rawValue] }
  var spoken: String { ["a sinistra", "davanti", "a destra"][rawValue] }
}

struct ZoneHit {
  let distance: Float  // m ahead, nearest part of the obstacle
  let low: Bool
  let area: Float  // m²
  var stepUp = false  // step 1.5: low and as wide as the walking line, only for "ahead"
}

/// Camera values copied out of the ARFrame (never retain the frame itself: ARKit runs out of buffers).
struct CameraSnapshot {
  let transform: simd_float4x4
  let intrinsics: simd_float3x3
  let imageSize: CGSize
  /// Horizontal direction the user is actually walking (from the phone's recent movement), if known.
  var walkDirection: SIMD3<Float>? = nil
}

struct FrameAnalysis {
  var zones: [ZoneHit?] = [nil, nil, nil]
  var scaleOk = false
  var scaleA: Float = 0, scaleB: Float = 0  // d = a/Z + b used for this frame (for the diagnostic recording)
  var scaleSource = "none"  // features, floor, previous
  var walls = [false, false]  // side wall found on the left, on the right
  var fitInliers = 0
  var fitCandidates = 0
  var nearestFloor: Float = .infinity  // m ahead (horizontal): closest floor point in view, to detect an upright phone
  var drop: DropHit?  // step 1.5
  var dropSeen: DropHit?  // before the check on the ARKit feature points (for the recording)
  var dropFeatures = (floor: 0, below: 0)  // ARKit feature points beyond the edge: at floor height, below it
}

// MARK: - Per-frame geometry

struct ObstaclePoint {
  let ahead: Float  // m along the walking direction
  let lateral: Float  // m from the walking line, negative on the left
  let height: Float  // m above the floor
  let area: Float  // m² of surface this sample stands for
}

/// Turns one depth map into zone hits. Lives on the inference queue; buffers are reused across frames.
final class ObstacleAnalyzer {
  /// Depth Anything output d ≈ a / Z + b (affine in inverse depth).
  private struct Scale { var a: Float; var b: Float }
  private var lastScale: Scale?
  private var lastScaleTime: Double = 0

  private var rays: [SIMD3<Float>] = []
  private var disparities: [Float] = []
  private var floorW: [Float] = []  // 1/Z of the floor along the ray
  private var floorD: [Float] = []
  private var featW: [Float] = []  // 1/Z of the ARKit feature points in view
  private var featD: [Float] = []

  func analyze(depth: DepthMap, camera: CameraSnapshot, floorY: Float, features: [SIMD3<Float>],
               now: Double) -> FrameAnalysis {
    var out = FrameAnalysis()
    let W = depth.width, H = depth.height, s = GuideTuning.sampleStride
    let imgW = Float(camera.imageSize.width), imgH = Float(camera.imageSize.height)
    let K = camera.intrinsics
    let fx = K.columns.0.x, fy = K.columns.1.y, cx = K.columns.2.x, cy = K.columns.2.y
    let T = camera.transform
    let R = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z),
                          SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                          SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
    let origin = SIMD3(T.columns.3.x, T.columns.3.y, T.columns.3.z)

    // Walking direction: where the user is going; when standing still, where the camera points, flattened on the
    // floor (world y is up, gravity aligned). The phone alone turns 10° easily, and in a 90 cm corridor that puts
    // a wall "ahead" within a metre (test of 18/10).
    var fwd = camera.walkDirection ?? -SIMD3(T.columns.2.x, 0, T.columns.2.z)
    fwd.y = 0
    guard simd_length(fwd) > 0.2 else { return out }  // phone pointing straight down or up
    fwd = simd_normalize(fwd)
    let right = SIMD3<Float>(-fwd.z, 0, fwd.x)

    // 1. A ray per sample (camera space: x right, y up, looking along -z; image v grows downwards).
    rays.removeAll(keepingCapacity: true)
    disparities.removeAll(keepingCapacity: true)
    floorW.removeAll(keepingCapacity: true)
    floorD.removeAll(keepingCapacity: true)
    let su = imgW / Float(W), sv = imgH / Float(H)
    for j in stride(from: 0, to: H, by: s) {
      let v = (Float(j) + 0.5) * sv
      for i in stride(from: 0, to: W, by: s) {
        let u = (Float(i) + 0.5) * su
        let ray = R * SIMD3((u - cx) / fx, -(v - cy) / fy, -1)  // z-depth Z gives the point origin + Z·ray
        let d = depth.values[j * W + i]
        rays.append(ray)
        disparities.append(d)
        if ray.y < -1e-3 {
          let zFloor = (floorY - origin.y) / ray.y
          out.nearestFloor = min(out.nearestFloor, simd_dot(zFloor * ray, fwd))
          if zFloor >= GuideTuning.floorMinDist && zFloor <= GuideTuning.floorMaxDist {
            floorW.append(1 / zFloor)
            floorD.append(d)
          }
        }
      }
    }

    // 2. Metric scale. First choice: the ARKit feature points, metric and on any surface. The floor alone is
    // not enough: close to a chair or a bed, their large surfaces fitted the floor model better than the floor
    // itself, and every distance went wrong (test of 18/10).
    featW.removeAll(keepingCapacity: true)
    featD.removeAll(keepingCapacity: true)
    for p in features {
      let c = R.transpose * (p - origin)  // camera coordinates
      let z = -c.z
      guard z > 0.15 else { continue }
      let i = Int((cx + fx * c.x / z) / su), j = Int((cy - fy * c.y / z) / sv)
      guard i >= 1 && i < W - 1 && j >= 1 && j < H - 1 else { continue }
      var nb: [Float] = []  // 3×3 median: the map is smooth, edges are not
      for dj in -1...1 { for di in -1...1 { nb.append(depth.values[(j + dj) * W + i + di]) } }
      featW.append(1 / z)
      featD.append(nb.sorted()[4])
    }
    var scale: Scale?
    if featW.count >= GuideTuning.minFeatures,
       let (fit, inliers) = Self.fitScale(w: featW, d: featD, tol: GuideTuning.featureTolerance, prior: lastScale,
                                          iterations: 200, minCount: 12),
       Float(inliers) >= 0.4 * Float(featW.count) {
      scale = fit
      out.scaleSource = "features"
      out.fitInliers = inliers
      out.fitCandidates = featW.count
    } else if let (fit, inliers) = Self.fitScale(w: floorW, d: floorD, tol: GuideTuning.fitTolerance,
                                                 prior: lastScale, iterations: 80, minCount: 150),
              Float(inliers) >= 0.5 * Float(floorW.count) {
      // Fallback: the floor, only when it clearly dominates the view.
      scale = fit
      out.scaleSource = "floor"
      out.fitInliers = inliers
      out.fitCandidates = floorW.count
    }
    if let scale {
      lastScale = scale
      lastScaleTime = now
    } else if let last = lastScale, now - lastScaleTime < 1 {
      scale = last
      out.scaleSource = "previous"
    }
    guard let scale else { return out }
    out.scaleOk = true
    out.scaleA = scale.a
    out.scaleB = scale.b

    // 3. Points that stand above the floor, in front of the user, within the walking corridor.
    let pixelArea = (Float(s) * su / fx) * (Float(s) * sv / fy)  // m² per sample at 1 m
    var points: [ObstaclePoint] = []
    var floorPoints: [SIMD2<Float>] = []  // (ahead, lateral) of visible free floor
    let camHeight = origin.y - floorY
    var lower: [(edge: Float, depth: Float, area: Float, ahead: Float)] = []  // step 1.5: floor seen below the floor
    var line: [(ahead: Float, h: Float, area: Float)] = []  // step 1.5: floor level on the walking line
    for k in 0..<rays.count {
      let inv = (disparities[k] - scale.b) / scale.a
      guard inv > 0.125 else { continue }  // farther than 8 m, or invalid
      let z = 1 / inv
      let rel = z * rays[k]
      let fromPhone = simd_dot(rel, fwd)
      guard fromPhone >= GuideTuning.minForward else { continue }
      let ahead = fromPhone + GuideTuning.bodyOffset  // from the body
      let h = origin.y + rel.y - floorY
      let lateral = simd_dot(rel, right)
      // A point below the floor is seen past an edge: the edge is where its ray crosses the height of the floor.
      if h <= -StepTuning.dropMin && h >= -StepTuning.dropMax && abs(lateral) <= StepTuning.halfWidth {
        let edge = fromPhone * camHeight / (camHeight - h) + GuideTuning.bodyOffset
        if edge <= GuideTuning.alertDistance { lower.append((edge, -h, z * z * pixelArea, ahead)) }
      } else if h > -StepTuning.dropMin && h < GuideTuning.minHeight && abs(lateral) <= StepTuning.halfWidth {
        line.append((ahead, h, z * z * pixelArea))
      }
      guard ahead <= GuideTuning.alertDistance else { continue }
      guard abs(lateral) <= GuideTuning.wallSearchWidth else { continue }
      if h < GuideTuning.minHeight {
        if h > -GuideTuning.minHeight { floorPoints.append(SIMD2(ahead, lateral)) }
        continue
      }
      guard h <= GuideTuning.maxHeight else { continue }
      points.append(ObstaclePoint(ahead: ahead, lateral: lateral, height: h, area: z * z * pixelArea))
    }

    // Walls along the path are not obstacles: what sticks out of them towards the walking line is.
    let nearEdge = max(out.nearestFloor, GuideTuning.minForward) + GuideTuning.bodyOffset  // nearest ahead in view
    let walls = [-1, 1].map { Self.sideWall(points, floor: floorPoints, sign: Float($0), nearEdge: nearEdge) }
    out.walls = walls.map { $0 != nil }
    var byZone: [[ObstaclePoint]] = [[], [], []]
    for p in points where abs(p.lateral) <= GuideTuning.sideHalfWidth {
      let side = p.lateral < 0 ? 0 : 1
      if abs(p.lateral) > GuideTuning.centreHalfWidth, let w = walls[side] {
        let wallLateral = w.c + w.k * p.ahead  // signed
        if (side == 0 && p.lateral <= wallLateral + GuideTuning.wallThickness)
            || (side == 1 && p.lateral >= wallLateral - GuideTuning.wallThickness) { continue }
      }
      let zone: Zone = abs(p.lateral) <= GuideTuning.centreHalfWidth ? .ahead : (p.lateral < 0 ? .left : .right)
      byZone[zone.rawValue].append(p)
    }

    for zone in Zone.allCases {
      let pts = byZone[zone.rawValue]
      let area = pts.reduce(0) { $0 + $1.area }
      guard area >= GuideTuning.minArea, !pts.isEmpty else { continue }
      let sorted = pts.map(\.ahead).sorted()
      let dist = sorted[sorted.count / 10]  // nearest part, robust to a few stray points
      // Height of the nearest object only (points within 30 cm behind its front).
      let heights = pts.filter { $0.ahead <= dist + 0.3 }.map(\.height).sorted()
      let top = heights.isEmpty ? 0 : heights[min(heights.count - 1, heights.count * 9 / 10)]
      var hit = ZoneHit(distance: dist, low: top < GuideTuning.lowHeight, area: area)
      if zone == .ahead && hit.low { hit.stepUp = Self.isStepUp(pts, front: dist) }
      out.zones[zone.rawValue] = hit
    }

    if var drop = Self.drop(lower) {
      var before: [Float] = [], after: [Float] = []
      for p in line where p.ahead >= drop.distance - 0.6 && p.ahead <= drop.distance + 0.5 {
        if abs(p.h) <= 0.05 && p.ahead <= drop.distance { drop.floorBefore += p.area }
        if p.ahead >= drop.distance - 0.3 && p.ahead < drop.distance { before.append(p.h) }
        if p.ahead >= drop.distance && p.ahead <= drop.distance + 0.4 { after.append(p.h) }
      }
      for p in lower where p.ahead >= drop.distance && p.ahead <= drop.distance + 0.4 { after.append(-p.depth) }
      if !before.isEmpty && !after.isEmpty {
        drop.jump = before.sorted()[before.count / 2] - after.sorted()[after.count / 2]
      }
      out.dropSeen = drop
      out.dropFeatures = Self.featuresBeyond(drop, features: features, origin: origin, fwd: fwd, right: right,
                                             floorY: floorY)
      let f = out.dropFeatures
      let floorGoesOn = f.floor >= StepTuning.featureFloorMin && f.floor > 2 * f.below
      if !floorGoesOn && drop.floorBefore >= StepTuning.minFloorBefore && drop.jump >= StepTuning.minJump {
        out.drop = drop
      }
    }
    return out
  }

  /// Step 1.5: the lower floor beyond an edge, if there is enough of it.
  private static func drop(_ lower: [(edge: Float, depth: Float, area: Float, ahead: Float)]) -> DropHit? {
    let area = lower.reduce(0) { $0 + $1.area }
    guard area >= StepTuning.minArea, !lower.isEmpty else { return nil }
    let edges = lower.map(\.edge).sorted(), depths = lower.map(\.depth).sorted()
    return DropHit(distance: edges[edges.count / 10], depth: depths[depths.count / 2], area: area)
  }

  /// ARKit feature points from 10 cm to 1 m beyond the edge, on the walking line: at the floor's height, and below it.
  private static func featuresBeyond(_ drop: DropHit, features: [SIMD3<Float>], origin: SIMD3<Float>,
                                     fwd: SIMD3<Float>, right: SIMD3<Float>, floorY: Float) -> (floor: Int, below: Int) {
    var n = (floor: 0, below: 0)
    for p in features {
      let rel = p - origin
      let ahead = simd_dot(rel, fwd) + GuideTuning.bodyOffset
      guard ahead >= drop.distance + 0.1 && ahead <= drop.distance + 1.0,
            abs(simd_dot(rel, right)) <= StepTuning.halfWidth + 0.1 else { continue }
      let h = p.y - floorY
      if abs(h) <= StepTuning.featureFloorTol { n.floor += 1 } else if h <= -StepTuning.dropMin / 2 { n.below += 1 }
    }
    return n
  }

  /// Step 1.5: the front of the nearest obstacle ahead is low and spans the walking line (a box or a bag is narrower).
  private static func isStepUp(_ pts: [ObstaclePoint], front: Float) -> Bool {
    let near = pts.filter { $0.ahead <= front + StepTuning.upFront }
    guard near.count >= 10 else { return false }
    let heights = near.map(\.height).sorted(), laterals = near.map(\.lateral).sorted()
    let top = heights[heights.count * 9 / 10]
    let spread = laterals[laterals.count * 9 / 10] - laterals[laterals.count / 10]
    return top <= StepTuning.upMaxTop && spread >= StepTuning.upMinSpread
  }

  /// A wall along the path on one side (sign −1 left, +1 right): a line lateral = c + k·ahead through the points,
  /// running at least 0.8 m and roughly parallel to the walking direction. In the 18/10 tests the walls of the
  /// corridor were only 0.37–0.47 m from the walking line, inside any useful side zone.
  /// Something parallel to the path that begins in front of the user (a long cabinet, a narrowing) is not such a
  /// wall: before it, on its side, free floor is visible farther out than its line.
  /// A shorter stretch counts too when it starts at the near edge of the view: the user is walking alongside it
  /// (the fridge column in the 18/10 test).
  private static func sideWall(_ points: [ObstaclePoint], floor: [SIMD2<Float>], sign: Float,
                               nearEdge: Float) -> (c: Float, k: Float)? {
    let cand = points.filter { $0.lateral * sign >= GuideTuning.wallMinOffset }
    guard cand.count >= 100 else { return nil }
    let sample = cand.count <= 1500 ? cand : (0..<1500).map { _ in cand[Int.random(in: 0..<cand.count)] }
    let tol = GuideTuning.wallTolerance
    var best: (c: Float, k: Float)?
    var bestCount = 0
    for _ in 0..<60 {
      let p = sample[Int.random(in: 0..<sample.count)], q = sample[Int.random(in: 0..<sample.count)]
      guard abs(q.ahead - p.ahead) > 0.3 else { continue }
      let k = (q.lateral - p.lateral) / (q.ahead - p.ahead)
      guard abs(k) <= GuideTuning.wallMaxSlope else { continue }
      let c = p.lateral - k * p.ahead
      let n = sample.reduce(0) { $0 + (abs($1.lateral - (c + k * $1.ahead)) <= tol ? 1 : 0) }
      if n > bestCount { best = (c, k); bestCount = n }
    }
    guard let line = best, bestCount >= 60 else { return nil }
    let along = sample.filter { abs($0.lateral - (line.c + line.k * $0.ahead)) <= tol }.map(\.ahead).sorted()
    let start = along[along.count / 10]
    let minLength = start <= nearEdge + 0.3 ? GuideTuning.wallMinLengthAlongside : GuideTuning.wallMinLength
    guard along[along.count * 9 / 10] - start >= minLength else { return nil }
    let floorOutside = floor.filter {
      $0.x < start - 0.1 && $0.x > start - 0.6 && ($0.y - (line.c + line.k * $0.x)) * sign > 0.1
    }.count
    guard floorOutside < 30 else { return nil }
    return line
  }

  /// RANSAC on (1/Z, d) pairs, then least squares on the inliers. The previous fit is tried too.
  private static func fitScale(w: [Float], d: [Float], tol: Float, prior: Scale?, iterations: Int,
                               minCount: Int) -> (Scale, Int)? {
    let n = w.count
    guard n >= minCount else { return nil }
    func inlier(_ m: Scale, _ i: Int) -> Bool {
      let x = (d[i] - m.b) / m.a
      return abs(x - w[i]) <= tol * w[i]
    }
    let sample: [Int] = n <= 2000 ? Array(0..<n) : (0..<2000).map { _ in Int.random(in: 0..<n) }
    func score(_ m: Scale) -> Int { sample.reduce(0) { $0 + (inlier(m, $1) ? 1 : 0) } }

    var best: Scale?
    var bestScore = 0
    if let prior { best = prior; bestScore = score(prior) }
    for _ in 0..<iterations {
      let i = sample[Int.random(in: 0..<sample.count)], j = sample[Int.random(in: 0..<sample.count)]
      let dw = w[j] - w[i]
      guard abs(dw) > 0.05 * max(w[i], w[j]) else { continue }
      let a = (d[j] - d[i]) / dw
      guard a > 0 else { continue }  // nearer must mean larger disparity
      let m = Scale(a: a, b: d[i] - a * w[i])
      let sc = score(m)
      if sc > bestScore { best = m; bestScore = sc }
    }
    guard let rough = best else { return nil }

    // Least squares d = a·w + b on all inliers of the best hypothesis.
    var sw: Double = 0, sd: Double = 0, sww: Double = 0, swd: Double = 0, cnt = 0
    for i in 0..<n where inlier(rough, i) {
      let x = Double(w[i]), y = Double(d[i])
      sw += x; sd += y; sww += x * x; swd += x * y; cnt += 1
    }
    guard cnt >= minCount else { return nil }
    let c = Double(cnt)
    let den = sww - sw * sw / c
    guard den > 1e-9 else { return (rough, cnt) }
    let a = (swd - sw * sd / c) / den
    guard a > 0 else { return (rough, cnt) }
    let refined = Scale(a: Float(a), b: Float((sd - a * sw) / c))
    var total = 0
    for i in 0..<n where inlier(refined, i) { total += 1 }
    return total >= cnt ? (refined, total) : (rough, cnt)
  }
}
