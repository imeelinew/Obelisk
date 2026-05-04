#!/usr/bin/env swift
// Generates a macOS app icon (.icns) from the shared app icon PNG.
//
// Usage: swift scripts/make-icon.swift <output-dir> [source-png]
//        produces <output-dir>/AppIcon.icns

import AppKit

let renditions: [(pixels: Int, file: String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func defaultSourcePath() -> String {
    let scriptPath = CommandLine.arguments[0] as NSString
    let scriptDir = scriptPath.deletingLastPathComponent as NSString
    let rootDir = scriptDir.deletingLastPathComponent as NSString
    return rootDir.appendingPathComponent("Sources/UniBookmarkMenu/Resources/AppIcon.png")
}

func render(source: NSImage, size pixels: Int) -> Data? {
    let s = CGFloat(pixels)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let bounds = NSRect(x: 0, y: 0, width: s, height: s)

    NSColor.clear.setFill()
    bounds.fill()
    source.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output-dir> [source-png]\n".utf8))
    exit(2)
}

let outputDir = CommandLine.arguments[1]
let sourcePath = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : defaultSourcePath()
guard let sourceImage = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("failed to load source icon: \(sourcePath)\n".utf8))
    exit(1)
}
let iconset = (outputDir as NSString).appendingPathComponent("AppIcon.iconset")
let icns = (outputDir as NSString).appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(atPath: iconset)
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for rendition in renditions {
    guard let data = render(source: sourceImage, size: rendition.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(rendition.file)\n".utf8))
        exit(1)
    }
    let path = (iconset as NSString).appendingPathComponent(rendition.file)
    try? data.write(to: URL(fileURLWithPath: path))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", icns, iconset]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(atPath: iconset)
print(icns)
