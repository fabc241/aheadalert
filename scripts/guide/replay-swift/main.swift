// Runs the app's own ObstacleAnalyzer (MVP step 1.1) on a diagnostic recording from the iPhone, frame by frame,
// so that a change to the analysis can be checked on real camera data before a new walking test.
// Usage (from mobile/): scripts/guide/replay-swift/run.sh scripts/guide/logs/rec-<date>
import CoreGraphics
import Foundation
import simd

/// Stand-in for the module's DepthMap (that file needs Core ML and Vision).
struct DepthMap {
  let values: [Float]
  let width: Int
  let height: Int
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
  .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
let analyzer = ObstacleAnalyzer()
var sources: [String: Int] = [:]
var trail: [(t: Double, p: SIMD3<Float>)] = []
print("frame | scale (source, fit) | zones (as the phone would see them, before the 3-of-5 debounce)")
for n in names {
  let m = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("\(n).json"))) as! [String: Any]
  if m["lightOnly"] != nil { continue }  // step 1.4: frame without depth (tracking lost or no floor)
  let f = { (k: String) in (m[k] as! [NSNumber]).map { $0.floatValue } }
  let t = f("transform"), k = f("intrinsics"), fp = (m["features"] as? [NSNumber])?.map { $0.floatValue } ?? []
  let transform = simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
  let intrinsics = simd_float3x3(SIMD3(k[0], k[1], k[2]), SIMD3(k[3], k[4], k[5]), SIMD3(k[6], k[7], k[8]))
  // Walking direction: recorded by the phone, or (older recordings) from the positions of the last second.
  let time = (m["time"] as! NSNumber).doubleValue
  var walk: SIMD3<Float>?
  if let wd = m["walkDirection"] as? [NSNumber] {
    walk = SIMD3(wd[0].floatValue, wd[1].floatValue, wd[2].floatValue)
  } else if m["walkDirection"] == nil {
    trail.append((time, SIMD3(t[12], 0, t[14])))
    trail.removeAll { time - $0.t > 1.2 }
    if let first = trail.first, time - first.t >= 0.6, simd_length(trail.last!.p - first.p) >= 0.15 {
      walk = simd_normalize(trail.last!.p - first.p)
    }
  }
  let camera = CameraSnapshot(transform: transform, intrinsics: intrinsics,
                              imageSize: CGSize(width: (m["imageWidth"] as! NSNumber).doubleValue,
                                                height: (m["imageHeight"] as! NSNumber).doubleValue),
                              walkDirection: walk)
  let w = (m["depthWidth"] as! NSNumber).intValue, h = (m["depthHeight"] as! NSNumber).intValue
  let raw = try Data(contentsOf: dir.appendingPathComponent("\(n).depth"))
  let values = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  let features = stride(from: 0, to: fp.count - 2, by: 3).map { SIMD3(fp[$0], fp[$0 + 1], fp[$0 + 2]) }
  let a = analyzer.analyze(depth: DepthMap(values: values, width: w, height: h), camera: camera,
                           floorY: (m["floorY"] as! NSNumber).floatValue, features: features,
                           now: (m["time"] as! NSNumber).doubleValue)
  sources[a.scaleSource, default: 0] += 1
  let zones = Zone.allCases.map { z -> String in
    guard let hit = a.zones[z.rawValue] else { return "\(z.key) -" }
    return String(format: "%@ %.2f%@%@", z.key, hit.distance, hit.low ? " low" : "", hit.stepUp ? " stepUp" : "")
  }.joined(separator: "  ")
  // Step 1.5: step down, before and after the check on the ARKit feature points
  let drop = a.dropSeen.map {
    String(format: "drop %.2f m, %.2f below, %.3f m2, floor before %.3f, jump %.2f, features floor %d below %d%@",
           $0.distance, $0.depth, $0.area, $0.floorBefore, $0.jump, a.dropFeatures.floor, a.dropFeatures.below,
           a.drop == nil ? " (vetoed)" : "")
  } ?? "drop -"
  let walls = (a.walls[0] ? "L" : "-") + (a.walls[1] ? "R" : "-")
  print("\(n) | \(a.scaleSource) \(a.fitInliers)/\(a.fitCandidates) | walls \(walls) walk \(walk == nil ? "-" : "y") | \(zones) | \(drop)")
}
print("scale source: \(sources)")
