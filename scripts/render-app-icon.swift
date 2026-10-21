#!/usr/bin/env swift
// Renders the Mainline "Queue" app icon (docs/images/logo.svg) to every PNG the
// AppIcon asset catalog needs, plus docs/images/logo.png for the README.
// CoreGraphics only, so it runs on a stock Mac with no SVG tooling.
//
// Usage (from repo root): swift scripts/render-app-icon.swift
// Keep the geometry below in step with docs/images/logo.svg.

import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Draws the icon on a 1024×1024 canvas in SVG (y-down) coordinates.
func drawIcon(in ctx: CGContext) {
    // Squircle-ish tile: 824pt square inset 100pt, cubic corners.
    let tile = CGMutablePath()
    tile.move(to: CGPoint(x: 100, y: 286))
    tile.addCurve(to: CGPoint(x: 286, y: 100), control1: CGPoint(x: 100, y: 183), control2: CGPoint(x: 183, y: 100))
    tile.addLine(to: CGPoint(x: 738, y: 100))
    tile.addCurve(to: CGPoint(x: 924, y: 286), control1: CGPoint(x: 841, y: 100), control2: CGPoint(x: 924, y: 183))
    tile.addLine(to: CGPoint(x: 924, y: 738))
    tile.addCurve(to: CGPoint(x: 738, y: 924), control1: CGPoint(x: 924, y: 841), control2: CGPoint(x: 841, y: 924))
    tile.addLine(to: CGPoint(x: 286, y: 924))
    tile.addCurve(to: CGPoint(x: 100, y: 738), control1: CGPoint(x: 183, y: 924), control2: CGPoint(x: 100, y: 841))
    tile.closeSubpath()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x16181B), color(0x101214)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()

    // The main line.
    ctx.setStrokeColor(color(0x3A3D3F))
    ctx.setLineWidth(40)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512, y: 310))  // starts under the green stop so its cap never peeks out
    ctx.addLine(to: CGPoint(x: 512, y: 774))
    ctx.strokePath()

    // Three stops, shrinking by priority; the top one is ready. Opaque greys
    // (not white at reduced alpha) so the line never shows through a stop.
    let stops: [(y: CGFloat, r: CGFloat, fill: CGColor)] = [
        (310, 72, color(0x4FD18F)),
        (530, 52, color(0x9C9F9E)),
        (716, 40, color(0x55585A)),
    ]
    for stop in stops {
        ctx.setFillColor(stop.fill)
        ctx.fillEllipse(in: CGRect(x: 512 - stop.r, y: stop.y - stop.r, width: stop.r * 2, height: stop.r * 2))
    }
}

func writePNG(pixels: Int, to path: String) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    // Flip to y-down so the geometry matches the SVG.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(pixels)px)")
}

let iconset = "Mainline/Mainline/Assets.xcassets/AppIcon.appiconset"
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in outputs { try writePNG(pixels: px, to: "\(iconset)/\(name)") }
try writePNG(pixels: 512, to: "docs/images/logo.png")
