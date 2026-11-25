import AppKit
import Foundation

// 用法：swift Scripts/make-icon.swift [svg 路径] [iconset 输出目录]
// 生成 macOS 所需的全部图标尺寸，之后用 iconutil 打包成 .icns。

let svgPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.svg"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/AppIcon.iconset"

guard let image = NSImage(contentsOfFile: svgPath), image.size.width > 0 else {
    FileHandle.standardError.write("无法加载 SVG（或尺寸为 0）：\(svgPath)\n".data(using: .utf8)!)
    exit(1)
}

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for spec in specs {
    let px = spec.pixels
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px,
                                     pixelsHigh: px,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: URL(fileURLWithPath: outDir + "/" + spec.name))
    print("wrote \(spec.name) (\(px)×\(px))")
}
