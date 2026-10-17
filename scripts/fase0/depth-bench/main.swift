// Fase 0A (Mac): Depth Anything V2 Small (Core ML, Float16).
// Misura i tempi per unità di calcolo (solo CPU, CPU+GPU, CPU+Neural Engine, tutte)
// e salva le mappe di profondità come PNG in scala di grigi (chiaro = vicino).
//
// Compilazione e uso (dalla cartella scripts/fase0):
//   swiftc -O depth-bench/main.swift -o depth-bench/depth-bench
//   ./depth-bench/depth-bench modelli/DepthAnythingV2SmallF16.mlpackage immagini-reali risultati/profondita
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
guard args.count == 4 else { fail("uso: depth-bench <modello.mlpackage> <cartella immagini> <cartella output>") }
let packageURL = URL(fileURLWithPath: args[1])
let imagesURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

func loadCGImage(_ url: URL) -> CGImage {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("immagine non leggibile: \(url.path)") }
  return img
}

func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
func p90(_ v: [Double]) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * 0.9))] }

/// Legge l'output (immagine Float16/Float32 o MLMultiArray) come array di Float con dimensioni.
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
          fail("formato pixel di output non gestito: \(format)")
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
  fail("tipo di output non gestito")
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

// Compilazione del modello (una volta)
var t0 = DispatchTime.now().uptimeNanoseconds
let compiledURL = try MLModel.compileModel(at: packageURL)
print(String(format: "Compilazione modello: %.0f ms", ms(t0)))

let imageFiles = try FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)
  .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
let cgImages = imageFiles.map(loadCGImage)

let units: [(String, MLComputeUnits)] = [
  ("Solo CPU", .cpuOnly),
  ("CPU + GPU", .cpuAndGPU),
  ("CPU + Neural Engine", .cpuAndNeuralEngine),
  ("Tutte (.all)", .all),
]

var report = ["# Fase 0A – Depth Anything V2 Small F16 (Core ML) su Mac", "",
              "| Unità di calcolo | Caricamento | Mediana | 90° percentile | fps (mediana) |",
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
    fail("l'input non è un'immagine")
  }
  if cu == .cpuOnly {
    print("Input '\(inputName)': \(constraint.pixelsWide)x\(constraint.pixelsHigh); output '\(outputName)'")
  }

  let inputs: [MLDictionaryFeatureProvider] = try cgImages.map { cg in
    let fv = try MLFeatureValue(cgImage: cg, constraint: constraint,
                                options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
    return try MLDictionaryFeatureProvider(dictionary: [inputName: fv])
  }

  // Riscaldamento, poi 30 inferenze ripetute su tutte le immagini a rotazione
  for i in 0..<3 { _ = try model.prediction(from: inputs[i % inputs.count]) }
  var times: [Double] = []
  for i in 0..<30 {
    t0 = DispatchTime.now().uptimeNanoseconds
    let out = try model.prediction(from: inputs[i % inputs.count])
    times.append(ms(t0))
    if cu == .all && i < inputs.count, let v = out.featureValue(for: outputName) {
      let name = imageFiles[i].deletingPathExtension().lastPathComponent
      savePNG(depthValues(v), to: outURL.appendingPathComponent("\(name)-profondita.png"))
    }
  }
  let med = median(times)
  let line = String(format: "| %@ | %.0f ms | %.1f ms | %.1f ms | %.1f |", name, loadMs, med, p90(times), 1000 / med)
  print(line)
  report.append(line)
}

report.append("")
report.append("Nota: misure su Mac M4, indicative. La scelta Neural Engine/GPU va fatta sull'iPhone 13.")
try report.joined(separator: "\n").write(to: outURL.appendingPathComponent("tempi.md"), atomically: true, encoding: .utf8)
print("Mappe salvate in \(outURL.path)")
