// Offline AppIcon exporter.
//
// Rasterises the shared `BrandMark` (the Vault glyph) into the full macOS AppIcon PNG set
// and writes the asset catalog's Contents.json. Run via Tools/render-appicon.sh, which
// compiles this together with DiskGallery/Views/Brand/BrandMark.swift so the Dock icon and
// the in-app mark stay byte-for-byte the same artwork.
//
//   swift Tools/RenderAppIcon.swift DiskGallery/Views/Brand/BrandMark.swift <appiconset-dir>

import SwiftUI
import AppKit

@MainActor
func renderPNG(side: Int, to url: URL) {
    let renderer = ImageRenderer(content: BrandMark(size: CGFloat(side)))
    renderer.scale = 1          // frame is in points; scale 1 ⇒ `side` pixels
    renderer.isOpaque = false   // transparent squircle corners (no alpha halo)
    guard let cg = renderer.cgImage else { fatalError("render failed at \(side)px") }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed at \(side)px")
    }
    try! data.write(to: url)
    print("  • \(url.lastPathComponent)  (\(cg.width)×\(cg.height))")
}

// (slot scale, point size, pixel file)
let entries: [(idiom: String, scale: String, size: String, px: Int)] = [
    ("mac", "1x", "16x16",   16),
    ("mac", "2x", "16x16",   32),
    ("mac", "1x", "32x32",   32),
    ("mac", "2x", "32x32",   64),
    ("mac", "1x", "128x128", 128),
    ("mac", "2x", "128x128", 256),
    ("mac", "1x", "256x256", 256),
    ("mac", "2x", "256x256", 512),
    ("mac", "1x", "512x512", 512),
    ("mac", "2x", "512x512", 1024),
]

let args = CommandLine.arguments
guard args.count >= 2 else {
    fatalError("usage: render-appicon <appiconset-dir>")
}
let outDir = args[1]
let dir = URL(fileURLWithPath: outDir, isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    print("Rendering AppIcon set → \(dir.path)")
    for px in Set(entries.map(\.px)).sorted() {
        renderPNG(side: px, to: dir.appendingPathComponent("appicon-\(px).png"))
    }
}

// Contents.json
let images = entries.map { e in
    """
        {
          "idiom" : "\(e.idiom)",
          "size" : "\(e.size)",
          "scale" : "\(e.scale)",
          "filename" : "appicon-\(e.px).png"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "diskgallery",
    "version" : 1
  }
}
"""
try! contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote Contents.json (\(entries.count) slots)")
