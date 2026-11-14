#!/usr/bin/env swift
import Foundation
import AppKit

// MARK: - Mathematical Apple Continuous Squircle Path
// Inset = 100 px, Body = 824 x 824 px, Canvas = 1024 x 1024 px.
// Nominal radius = 185.43 px (~22.5% of body width).
// Uses 3-segment cubic Bezier spline with transition length L = 1.528665 * R (~283.45 px).

func appleSquirclePath(rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let w = rect.width
    let h = rect.height
    let r = radius
    let p = min(r, min(w, h) / (2 * 1.528665))
    let l = 1.528665 * p
    let minX = rect.minX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY

    // Bottom straight edge
    path.move(to: CGPoint(x: minX + l, y: minY))
    path.addLine(to: CGPoint(x: maxX - l, y: minY))

    // Bottom-right corner (curving up to maxX)
    path.addCurve(
        to: CGPoint(x: maxX - 0.505001 * p, y: minY + 0.141595 * p),
        control1: CGPoint(x: maxX - 1.233693 * p, y: minY),
        control2: CGPoint(x: maxX - 0.741477 * p, y: minY + 0.038484 * p)
    )
    path.addCurve(
        to: CGPoint(x: maxX - 0.038484 * p, y: minY + 0.741477 * p),
        control1: CGPoint(x: maxX - 0.268525 * p, y: minY + 0.244706 * p),
        control2: CGPoint(x: maxX - 0.141595 * p, y: minY + 0.505001 * p)
    )
    path.addCurve(
        to: CGPoint(x: maxX, y: minY + l),
        control1: CGPoint(x: maxX, y: minY + 1.233693 * p),
        control2: CGPoint(x: maxX, y: minY + l)
    )

    // Right straight edge
    path.addLine(to: CGPoint(x: maxX, y: maxY - l))

    // Top-right corner (curving left to maxY)
    path.addCurve(
        to: CGPoint(x: maxX - 0.141595 * p, y: maxY - 0.505001 * p),
        control1: CGPoint(x: maxX, y: maxY - 1.233693 * p),
        control2: CGPoint(x: maxX - 0.038484 * p, y: maxY - 0.741477 * p)
    )
    path.addCurve(
        to: CGPoint(x: maxX - 0.741477 * p, y: maxY - 0.038484 * p),
        control1: CGPoint(x: maxX - 0.244706 * p, y: maxY - 0.268525 * p),
        control2: CGPoint(x: maxX - 0.505001 * p, y: maxY - 0.141595 * p)
    )
    path.addCurve(
        to: CGPoint(x: maxX - l, y: maxY),
        control1: CGPoint(x: maxX - 1.233693 * p, y: maxY),
        control2: CGPoint(x: maxX - l, y: maxY)
    )

    // Top straight edge
    path.addLine(to: CGPoint(x: minX + l, y: maxY))

    // Top-left corner (curving down to minX)
    path.addCurve(
        to: CGPoint(x: minX + 0.505001 * p, y: maxY - 0.141595 * p),
        control1: CGPoint(x: minX + 1.233693 * p, y: maxY),
        control2: CGPoint(x: minX + 0.741477 * p, y: maxY - 0.038484 * p)
    )
    path.addCurve(
        to: CGPoint(x: minX + 0.038484 * p, y: maxY - 0.741477 * p),
        control1: CGPoint(x: minX + 0.268525 * p, y: maxY - 0.244706 * p),
        control2: CGPoint(x: minX + 0.141595 * p, y: maxY - 0.505001 * p)
    )
    path.addCurve(
        to: CGPoint(x: minX, y: maxY - l),
        control1: CGPoint(x: minX, y: maxY - 1.233693 * p),
        control2: CGPoint(x: minX, y: maxY - l)
    )

    // Left straight edge
    path.addLine(to: CGPoint(x: minX, y: minY + l))

    // Bottom-left corner (curving right to minY)
    path.addCurve(
        to: CGPoint(x: minX + 0.141595 * p, y: minY + 0.505001 * p),
        control1: CGPoint(x: minX, y: minY + 1.233693 * p),
        control2: CGPoint(x: minX + 0.038484 * p, y: minY + 0.741477 * p)
    )
    path.addCurve(
        to: CGPoint(x: minX + 0.741477 * p, y: minY + 0.038484 * p),
        control1: CGPoint(x: minX + 0.244706 * p, y: minY + 0.268525 * p),
        control2: CGPoint(x: minX + 0.505001 * p, y: minY + 0.141595 * p)
    )
    path.addCurve(
        to: CGPoint(x: minX + l, y: minY),
        control1: CGPoint(x: minX + 1.233693 * p, y: minY),
        control2: CGPoint(x: minX + l, y: minY)
    )

    path.closeSubpath()
    return path
}

func drawLinearGradient(in ctx: CGContext, path: CGPath, startColor: NSColor, endColor: NSColor, startPoint: CGPoint, endPoint: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [startColor.cgColor, endColor.cgColor] as CFArray
    let locations: [CGFloat] = [0.0, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        ctx.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
}

// MARK: - Renderer for Cascading Twin Cards

func renderAppIcon(size: Int) -> NSImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 4 * size,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    renderIcon(size: size, in: ctx)

    let cgImage = ctx.makeImage()!
    return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
}

func renderIcon(size: Int, in ctx: CGContext) {
    let scale = CGFloat(size) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    func aligned(_ rect: CGRect) -> CGRect {
        let minX = aligned(rect.minX)
        let maxX = aligned(rect.maxX)
        let minY = aligned(rect.minY)
        let maxY = aligned(rect.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    let dropsDetail = size < 64

    // Body: EXACTLY 824x824 at [100, 100], continuous squircle, NO BAKED SHADOW
    let squircleRect = aligned(CGRect(x: 100, y: 100, width: 824, height: 824))
    let squircle = appleSquirclePath(rect: squircleRect, radius: aligned(185.43))

    // Squircle background gradient
    let topColor = NSColor(red: 38/255.0, green: 38/255.0, blue: 42/255.0, alpha: 1.0)
    let bottomColor = NSColor(red: 18/255.0, green: 18/255.0, blue: 20/255.0, alpha: 1.0)
    drawLinearGradient(in: ctx, path: squircle, startColor: topColor, endColor: bottomColor, startPoint: CGPoint(x: 512, y: 924), endPoint: CGPoint(x: 512, y: 100))

    // Subtle inner rim stroke
    if !dropsDetail {
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setLineWidth(size >= 128 ? 1.5 : 1.0 / scale)
        ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.12).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Artwork: Optically centered twin cascading cards
    // Centered horizontally: cards are 410px wide. Left card starts at 257, right card ends at 767.
    // Margin left = 257 - 100 = 157. Margin right = 924 - 767 = 157. Perfectly symmetric.
    // Centered vertically: front card y: 227..717. Back card y: 307..797.
    // Margin bottom = 227 - 100 = 127. Margin top = 924 - 797 = 127. Perfectly symmetric.

    // Back Card (Unclipped History): warm amber parchment shifted up-left
    let bRect = aligned(CGRect(x: 257, y: 307, width: 410, height: 490))
    let bPath = CGPath(roundedRect: bRect, cornerWidth: aligned(28), cornerHeight: aligned(28), transform: nil)
    drawLinearGradient(in: ctx, path: bPath,
                       startColor: NSColor(red: 254/255.0, green: 243/255.0, blue: 199/255.0, alpha: 1.0),
                       endColor: NSColor(red: 253/255.0, green: 230/255.0, blue: 138/255.0, alpha: 1.0),
                       startPoint: CGPoint(x: bRect.midX, y: bRect.maxY), endPoint: CGPoint(x: bRect.midX, y: bRect.minY))

    // Front Card (Active Clip): pure white shifted down-right
    let fRect = aligned(CGRect(x: 357, y: 227, width: 410, height: 490))
    let fPath = CGPath(roundedRect: fRect, cornerWidth: aligned(28), cornerHeight: aligned(28), transform: nil)
    ctx.saveGState()
    if !dropsDetail {
        ctx.setShadow(offset: CGSize(width: -6, height: -8), blur: 16, color: CGColor(gray: 0, alpha: 0.28))
    }
    drawLinearGradient(in: ctx, path: fPath,
                       startColor: NSColor(white: 1.0, alpha: 1.0),
                       endColor: NSColor(red: 254/255.0, green: 252/255.0, blue: 247/255.0, alpha: 1.0),
                       startPoint: CGPoint(x: fRect.midX, y: fRect.maxY), endPoint: CGPoint(x: fRect.midX, y: fRect.minY))
    ctx.restoreGState()

    // Bold warm amber bar on front card
    let badgeRect = aligned(CGRect(x: fRect.minX + 44, y: fRect.maxY - 110, width: 240, height: 38))
    let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: aligned(10), cornerHeight: aligned(10), transform: nil)
    drawLinearGradient(in: ctx, path: badgePath,
                       startColor: NSColor(red: 217/255.0, green: 119/255.0, blue: 6/255.0, alpha: 1.0),
                       endColor: NSColor(red: 180/255.0, green: 83/255.0, blue: 9/255.0, alpha: 1.0),
                       startPoint: CGPoint(x: badgeRect.minX, y: badgeRect.midY), endPoint: CGPoint(x: badgeRect.maxX, y: badgeRect.midY))

    if size >= 256 {
        let s1Rect = aligned(CGRect(x: fRect.minX + 44, y: fRect.maxY - 190, width: 190, height: 22))
        ctx.addPath(CGPath(roundedRect: s1Rect, cornerWidth: aligned(6), cornerHeight: aligned(6), transform: nil))
        ctx.setFillColor(NSColor(red: 243/255.0, green: 244/255.0, blue: 246/255.0, alpha: 1.0).cgColor)
        ctx.fillPath()
    }

    // Brass Clip: Clamped ONLY to front card at top
    let clipW: CGFloat = 190
    let clipH: CGFloat = 62
    let clipRect = aligned(CGRect(x: fRect.midX - clipW / 2, y: fRect.maxY - 34, width: clipW, height: clipH))
    let clipPath = CGPath(roundedRect: clipRect, cornerWidth: aligned(14), cornerHeight: aligned(14), transform: nil)

    if !dropsDetail {
        let archPath = CGMutablePath()
        archPath.move(to: CGPoint(x: clipRect.minX + 32, y: clipRect.midY))
        archPath.addCurve(to: CGPoint(x: clipRect.maxX - 32, y: clipRect.midY),
                          control1: CGPoint(x: clipRect.minX + 32, y: clipRect.maxY + 48),
                          control2: CGPoint(x: clipRect.maxX - 32, y: clipRect.maxY + 48))
        ctx.saveGState()
        ctx.addPath(archPath)
        ctx.setLineWidth(14)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor(red: 251/255.0, green: 191/255.0, blue: 36/255.0, alpha: 1.0).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: CGColor(gray: 0, alpha: 0.30))
    drawLinearGradient(in: ctx, path: clipPath,
                       startColor: NSColor(red: 251/255.0, green: 191/255.0, blue: 36/255.0, alpha: 1.0),
                       endColor: NSColor(red: 217/255.0, green: 119/255.0, blue: 6/255.0, alpha: 1.0),
                       startPoint: CGPoint(x: clipRect.midX, y: clipRect.maxY), endPoint: CGPoint(x: clipRect.midX, y: clipRect.minY))
    ctx.restoreGState()

    if !dropsDetail {
        let apRect = aligned(CGRect(x: clipRect.midX - 35, y: clipRect.midY - 11, width: 70, height: 22))
        ctx.addPath(CGPath(roundedRect: apRect, cornerWidth: aligned(8), cornerHeight: aligned(8), transform: nil))
        ctx.setFillColor(NSColor(red: 69/255.0, green: 26/255.0, blue: 3/255.0, alpha: 1.0).cgColor)
        ctx.fillPath()
    }
}

// MARK: - Utilities

func savePNG(image: NSImage, url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ImageExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG"])
    }
    try png.write(to: url)
}

func buildAppIcon(outputICNS: URL) throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let iconsetEntries: [(String, Int)] = [
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

    for (filename, size) in iconsetEntries {
        let img = renderAppIcon(size: size)
        let fileURL = tempDir.appendingPathComponent(filename)
        try savePNG(image: img, url: fileURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", tempDir.path, "-o", outputICNS.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "IconUtil", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed with code \(process.terminationStatus)"])
    }
}

// Command line entry point
let args = CommandLine.arguments
let targetPath = args.count > 1 ? args[1] : "resources/AppIcon.icns"
let targetURL = URL(fileURLWithPath: targetPath)

print("Generating AppIcon (Cascading Twin Cards) -> \(targetURL.path)...")
do {
    try buildAppIcon(outputICNS: targetURL)
    print("Successfully built \(targetURL.lastPathComponent)")
} catch {
    print("Error generating icon: \(error)")
    exit(1)
}
