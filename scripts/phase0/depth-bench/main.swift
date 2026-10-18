// Phase 0A (Mac): Depth Anything V2 Small (Core ML, Float16).
// Measures timing per compute unit (CPU only, CPU+GPU, CPU+Neural Engine, all)
// and saves the depth maps as grayscale PNGs (bright = near).
//
// Build and usage (from scripts/phase0):
//   swiftc -O depth-bench/main.swift -o depth-bench/depth-bench
//   ./depth-bench/depth-bench models/DepthAnythingV2SmallF16.mlpackage real-photos results/depth
import CoreML
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: depth-bench <model.mlpackage> <images folder> <output folder>") }
let packageURL = URL(fileURLWithPath: args[1])
let imagesURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

func loadCGImage(_ url: URL) -> CGImage {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("unreadable image: \(url.path)") }
  return img
}

func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
func p90(_ v: [Double]) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * 0.9))] }

/// Reads the output (Float16/Float32 image or MLMultiArray) as a Float array with its dimensions.
func depthValues(_ value: MLFeatureValue) -> (values: [Float], width: Int, height: Int) {
  if let pb = value.imageBufferValue {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let rowBytes = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!
    let format = CVPixelBufferGetPixelFormatType(pb)
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      let row = base.advanced(by: y * rowBytes)
      for x in 0..<w {
        switch format {
        case kCVPixelFormatType_OneComponent16Half:
          out[y * w + x] = Float(row.assumingMemoryBound(to: Float16.self)[x])
        case kCVPixelFormatType_OneComponent32Float:
          out[y * w + x] = row.assumingMemoryBound(to: Float.self)[x]
        case kCVPixelFormatType_OneComponent8:
          out[y * w + x] = Float(row.assumingMemoryBound(to: UInt8.self)[x])
        default:
          fail("unsupported output pixel format: \(format)")
        }
      }
    }
    return (out, w, h)
  }
  if let arr = value.multiArrayValue {
    let shape = arr.shape.map { $0.intValue }
    let h = shape[shape.count - 2], w = shape[shape.count - 1]
    var out = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { out[i] = arr[i].floatValue }
    return (out, w, h)
  }
  fail("unsupported output type")
}

func savePNG(_ d: (values: [Float], width: Int, height: Int), to url: URL) {
  let lo = d.values.min() ?? 0, hi = d.values.max() ?? 1
  let range = max(hi - lo, 1e-6)
  var bytes = d.values.map { UInt8(max(0, min(255, (($0 - lo) / range) * 255))) }
  let ctx = bytes.withUnsafeMutableBytes { buf in
    CGContext(data: buf.baseAddress, width: d.width, height: d.height, bitsPerComponent: 8,
              bytesPerRow: d.width, space: CGColorSpaceCreateDeviceGray(),
              bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  }
  let img = ctx.makeImage()!
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img, nil)
  CGImageDestinationFinalize(dest)
}

// Model compilation (once)
var t0 = DispatchTime.now().uptimeNanoseconds
let compiledURL = try MLModel.compileModel(at: packageURL)
print(String(format: "Model compilation: %.0f ms", ms(t0)))

let imageFiles = try FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)
  .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
let cgImages = imageFiles.map(loadCGImage)

let units: [(String, MLComputeUnits)] = [
  ("CPU only", .cpuOnly),
  ("CPU + GPU", .cpuAndGPU),
  ("CPU + Neural Engine", .cpuAndNeuralEngine),
  ("All (.all)", .all),
]

var report = ["# Phase 0A – Depth Anything V2 Small F16 (Core ML) on Mac", "",
              "| Compute unit | Load | Median | 90th percentile | fps (median) |",
              "|---|---|---|---|---|"]

for (name, cu) in units {
  let config = MLModelConfiguration()
  config.computeUnits = cu
  t0 = DispatchTime.now().uptimeNanoseconds
  let model = try MLModel(contentsOf: compiledURL, configuration: config)
  let loadMs = ms(t0)

  let inputName = model.modelDescription.inputDescriptionsByName.keys.first!
  let outputName = model.modelDescription.outputDescriptionsByName.keys.first!
  guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else {
    fail("the model input is not an image")
  }
  if cu == .cpuOnly {
    print("Input '\(inputName)': \(constraint.pixelsWide)x\(constraint.pixelsHigh); output '\(outputName)'")
  }

  let inputs: [MLDictionaryFeatureProvider] = try cgImages.map { cg in
    let fv = try MLFeatureValue(cgImage: cg, constraint: constraint,
                                options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
    return try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
  }

  // Warm-up, then 30 inferences cycling through all the images
  for i in 0..<3 { _ = try model.prediction(from: inputs[i % inputs.count]) }
  var times: [Double] = []
  for i in 0..<30 {
    t0 = DispatchTime.now().uptimeNanoseconds
    let out = try model.prediction(from: inputs[i % inputs.count])
    times.append(ms(t0))
    if cu == .all && i < inputs.count, let v = out.featureValue(for: outputName) {
      let name = imageFiles[i].deletingPathExtension().lastPathComponent
      savePNG(depthValues(v), to: outURL.appendingPathComponent("\(name)-depth.png"))
    }
  }
  let med = median(times)
  let line = String(format: "| %@ | %.0f ms | %.1f ms | %.1f ms | %.1f |", name, loadMs, med, p90(times), 1000 / med)
  print(line)
  report.append(line)
}

report.append("")
report.append("Note: Mac M4 measurements, indicative only. The Neural Engine/GPU choice must be made on the iPhone 13.")
try report.joined(separator: "\n").write(to: outURL.appendingPathComponent("timing.md"), atomically: true, encoding: .utf8)
print("Maps saved in \(outURL.path)")
