#!/usr/bin/env swift
// Generates a macOS app icon (.icns) using the SF Symbol `bookmark.fill`
// rendered in white over a soft yellow gradient with a rounded-square mask.
//
// Usage: swift scripts/make-icon.swift <output-dir>
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

func render(size pixels: Int) -> Data? {
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

    // Tahoe (macOS 26) applies a uniform squircle mask to all app icons —
    // Dock, Finder, Spotlight, Launchpad. If our PNG has its own rounded
    // corners with transparent pixels outside, Spotlight's mask reveals the
    // transparency as a visible "halo" around the badge. So we render full
    // bleed and let the system shape it.

    // Soft warm yellow gradient — top is paler, bottom is a touch more saturated.
    let top = NSColor(red: 1.00, green: 0.96, blue: 0.78, alpha: 1)
    let bottom = NSColor(red: 1.00, green: 0.82, blue: 0.36, alpha: 1)
    let gradient = NSGradient(starting: top, ending: bottom)!
    gradient.draw(in: bounds, angle: -90)

    // Centered white bookmark glyph.
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: s * 0.50, weight: .semibold)
    guard
        let symbolBase = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil),
        let symbol = symbolBase.withSymbolConfiguration(symbolConfig)
    else {
        return rep.representation(using: .png, properties: [:])
    }

    // Tint the symbol white via source-atop fill.
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }

    let symbolSize = symbol.size
    let drawRect = NSRect(
        x: (s - symbolSize.width) / 2,
        // Optical center: nudge up slightly so the bookmark "tail" doesn't
        // make the glyph feel bottom-heavy.
        y: (s - symbolSize.height) / 2 + s * 0.01,
        width: symbolSize.width,
        height: symbolSize.height
    )
    tinted.draw(in: drawRect)

    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output-dir>\n".utf8))
    exit(2)
}

let outputDir = CommandLine.arguments[1]
let iconset = (outputDir as NSString).appendingPathComponent("AppIcon.iconset")
let icns = (outputDir as NSString).appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(atPath: iconset)
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for rendition in renditions {
    guard let data = render(size: rendition.pixels) else {
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
