// Runs the app's LightAnalyzer and LightWarning (MVP step 1.4) on diagnostic recordings from the iPhone, so that the
// thresholds can be checked on real camera images: passages found, warnings that would be spoken, false ones.
// The phone samples the camera's luma and chroma planes; here the recorded JPEG (640 wide) is decoded and turned back
// to Y, Cb, Cr (BT.601 full range, as in both the JPEG and the ARKit camera image) on the same grid.
// Usage (from mobile/): scripts/guide/light-replay/run.sh scripts/guide/logs/rec-<date> [more recordings…]
import CoreGraphics
import Foundation
import ImageIO
import simd

/// Stand-in for the module's camera snapshot (that file needs ARKit).
struct CameraSnapshot {
  let transform: simd_float4x4
  let intrinsics: simd_float3x3
  let imageSize: CGSize
  var walkDirection: SIMD3<Float>? = nil
}

func lumaGrid(_ url: URL) -> LumaGrid? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
  let w = img.width, h = img.height
  var pixels = [UInt8](repeating: 0, count: w * h * 4)
  let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
    guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard ok else { return nil }
  let gw = LightTuning.gridWidth, gh = LightTuning.gridHeight
  var values = [UInt8](repeating: 0, count: gw * gh), chroma = values
  for j in 0..<gh {
    let y = min(h - 1, Int((Float(j) + 0.5) * Float(h) / Float(gh)))
    for i in 0..<gw {
      let x = min(w - 1, Int((Float(i) + 0.5) * Float(w) / Float(gw)))
      let o = (y * w + x) * 4
      let r = Float(pixels[o]), g = Float(pixels[o + 1]), b = Float(pixels[o + 2])
      let cb = -0.168736 * r - 0.331264 * g + 0.5 * b, cr = 0.5 * r - 0.418688 * g - 0.081312 * b
      values[j * gw + i] = UInt8(min(255, max(0, (0.299 * r + 0.587 * g + 0.114 * b).rounded())))
      chroma[j * gw + i] = UInt8(min(255, (cb * cb + cr * cr).squareRoot().rounded()))
    }
  }
  return LumaGrid(values: values, chroma: chroma, width: gw, height: gh)
}

/// ARKit light per second from the guide's log (recordings made before the light was stored with each frame):
/// (seconds since local midnight, light).
func lightTimeline(_ rec: URL) -> [(t: Double, light: Float)] {
  let csv = rec.deletingLastPathComponent()
    .appendingPathComponent(rec.lastPathComponent.replacingOccurrences(of: "rec-", with: "guide-") + ".csv")
  guard let text = try? String(contentsOf: csv, encoding: .utf8) else { return [] }
  return text.split(separator: "\n").compactMap { line -> (Double, Float)? in
    guard line.contains(",stat,"), let r = line.range(of: "light ") else { return nil }
    let hms = line.prefix(12).split(separator: ":").compactMap { Double($0) }
    guard hms.count == 3, let v = Float(line[r.upperBound...].prefix { $0.isNumber || $0 == "." }) else { return nil }
    return (hms[0] * 3600 + hms[1] * 60 + hms[2], v)
  }
}

func secondsOfDay(_ epoch: Double) -> Double {
  let d = Date(timeIntervalSince1970: epoch)
  return d.timeIntervalSince(Calendar.current.startOfDay(for: d))
}

let verbose = ProcessInfo.processInfo.environment["VERBOSE"] == "1"
/// Light assumed when neither the frame nor the log has it: the logs of step 1.1 have none, and those rooms were lit
/// (about 1000 in the logs of step 1.2).
let defaultAmbient: Float = 1000
let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"; return f }()
var totals = (frames: 0, dark: 0, bright: 0, warnings: 0)
for path in CommandLine.arguments.dropFirst() {
  let dir = URL(fileURLWithPath: path)
  let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
  print("== \(dir.lastPathComponent): \(names.count) frames")
  let warning = LightWarning()
  let timeline = lightTimeline(dir)
  for n in names {
    let m = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("\(n).json"))) as! [String: Any]
    let f = { (k: String) in (m[k] as! [NSNumber]).map { $0.floatValue } }
    let t = f("transform"), k = f("intrinsics")
    let transform = simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                  SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
    let intrinsics = simd_float3x3(SIMD3(k[0], k[1], k[2]), SIMD3(k[3], k[4], k[5]), SIMD3(k[6], k[7], k[8]))
    var walk: SIMD3<Float>?
    if let wd = m["walkDirection"] as? [NSNumber] { walk = SIMD3(wd[0].floatValue, wd[1].floatValue, wd[2].floatValue) }
    let camera = CameraSnapshot(transform: transform, intrinsics: intrinsics,
                                imageSize: CGSize(width: (m["imageWidth"] as! NSNumber).doubleValue,
                                                  height: (m["imageHeight"] as! NSNumber).doubleValue),
                                walkDirection: walk)
    let height = (m["cameraHeight"] as? NSNumber)?.floatValue
      ?? (m["floorY"] as? NSNumber).map { t[13] - $0.floatValue } ?? LightTuning.defaultCameraHeight
    guard let grid = lumaGrid(dir.appendingPathComponent("\(n).jpg")) else { continue }
    let time = (m["time"] as! NSNumber).doubleValue
    // ARKit light: stored with the frame (since step 1.4), else the log's line of that second.
    let stored = ((m["light"] as? [String: Any])?["ambient"] as? NSNumber)?.floatValue ?? (m["arLight"] as? NSNumber)?.floatValue
    let day = secondsOfDay(time)
    let logged = timeline.min { abs($0.t - day) < abs($1.t - day) }.flatMap { abs($0.t - day) <= 1.5 ? $0.light : nil }
    let ambient = stored.flatMap { $0 >= 0 ? $0 : nil } ?? logged ?? defaultAmbient
    let a = LightAnalyzer.analyze(grid, camera: camera, cameraHeight: height, ambient: ambient)
    let spoken = warning.update(a, now: time)
    totals.frames += 1
    if a.kind == .dark { totals.dark += 1 }
    if a.kind == .bright { totals.bright += 1 }
    if spoken != nil { totals.warnings += 1 }
    guard verbose || a.kind != nil || spoken != nil else { continue }
    let found = a.kind.map { String(format: "%@ from %.2f m (light %.0f)", $0.rawValue, a.front, a.passage) } ?? "-"
    print(String(format: "%@ %@ | ARKit %.0f, h %.2f, feet %.0f, far view dark %.0f%% bright %.0f%% | %@%@", n,
                 clock.string(from: Date(timeIntervalSince1970: time)), ambient, height, a.feet, 100 * a.darkShare,
                 100 * a.brightShare, found, spoken.map { " → SPEAK \"\($0.message)\"" } ?? ""))
  }
}
print("total: \(totals.frames) frames, dark passage in \(totals.dark), bright in \(totals.bright), warnings spoken \(totals.warnings)")
