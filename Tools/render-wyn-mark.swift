#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Rasterize the Wyn mark (serif W on the website’s dark rounded block) into
// AppIcon PNGs, WynLogo, and website/public/favicon.svg.
//
// Run from the repo root:
//   swift Tools/render-wyn-mark.swift

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let bgHex = 0x241016
let inkHex = 0xF4ECE4
let viewBox: CGFloat = 512
let cornerRatio: CGFloat = 4.0 / 32.0
let fontName = "IowanOldStyle-Bold"

func srgb(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func fmt(_ n: CGFloat) -> String {
    String(format: "%.3f", n).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

func glyphPath(fontName: String, emSize: CGFloat = 1000) -> CGPath {
    guard let font = NSFont(name: fontName, size: emSize) else {
        fatalError("missing font \(fontName)")
    }
    var unichar: UniChar = 0x0057
    var glyph = CGGlyph()
    CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
    guard glyph != 0, let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
        fatalError("no W glyph in \(fontName)")
    }
    return path
}

func placedW(canvas: CGFloat, padding: CGFloat) -> CGPath {
    let raw = glyphPath(fontName: fontName)
    let bb = raw.boundingBoxOfPath
    let scale = (canvas - padding * 2) / max(bb.width, bb.height)
    var t = CGAffineTransform.identity
        .translatedBy(x: canvas / 2, y: canvas / 2)
        .scaledBy(x: scale, y: -scale)
        .translatedBy(x: -bb.midX, y: -bb.midY)
    guard let path = raw.copy(using: &t) else { fatalError("W transform") }
    return path
}

func svgPath(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        let p = e.points
        switch e.type {
        case .moveToPoint:
            d += "M\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addLineToPoint:
            d += "L\(fmt(p[0].x)) \(fmt(p[0].y))"
        case .addQuadCurveToPoint:
            d += "Q\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y))"
        case .addCurveToPoint:
            d += "C\(fmt(p[0].x)) \(fmt(p[0].y)) \(fmt(p[1].x)) \(fmt(p[1].y)) \(fmt(p[2].x)) \(fmt(p[2].y))"
        case .closeSubpath:
            d += "Z"
        @unknown default:
            break
        }
    }
    return d
}

func renderPNG(size: Int, rounded: Bool) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.setShouldSmoothFonts(true)
    ctx.interpolationQuality = .high

    let canvas = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    ctx.setFillColor(srgb(bgHex))
    if rounded {
        ctx.clear(rect)
        let r = canvas * cornerRatio
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    } else {
        ctx.fill(rect)
    }

    let padding = canvas * (size <= 32 ? 0.12 : 0.15)
    ctx.setFillColor(srgb(inkHex))
    ctx.addPath(placedW(canvas: canvas, padding: padding))
    ctx.fillPath()
    guard let image = ctx.makeImage() else { fatalError("makeImage \(size)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyPNGCompressionFilter: 0] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("write \(url.path)") }
}

func writeSVG(to url: URL) {
    let radius = viewBox * cornerRatio
    let d = svgPath(placedW(canvas: viewBox, padding: viewBox * 0.15))
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(fmt(viewBox)) \(fmt(viewBox))" role="img" aria-label="Wyn">
      <rect width="\(fmt(viewBox))" height="\(fmt(viewBox))" rx="\(fmt(radius))" fill="#241016"/>
      <path fill="#f4ece4" d="\(d)"/>
    </svg>

    """
    try! svg.write(to: url, atomically: true, encoding: .utf8)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDir = repo.appendingPathComponent("WynApp/Assets.xcassets/AppIcon.appiconset")
let logoDir = repo.appendingPathComponent("WynApp/Assets.xcassets/WynLogo.imageset")
let siteDir = repo.appendingPathComponent("website/public")

struct Icon {
    let name: String
    let pixels: Int
}

let icons: [Icon] = [
    .init(name: "icon_16x16.png", pixels: 16),
    .init(name: "icon_16x16@2x.png", pixels: 32),
    .init(name: "icon_32x32.png", pixels: 32),
    .init(name: "icon_32x32@2x.png", pixels: 64),
    .init(name: "icon_128x128.png", pixels: 128),
    .init(name: "icon_128x128@2x.png", pixels: 256),
    .init(name: "icon_256x256.png", pixels: 256),
    .init(name: "icon_256x256@2x.png", pixels: 512),
    .init(name: "icon_512x512.png", pixels: 512),
    .init(name: "icon_512x512@2x.png", pixels: 1024),
]

for icon in icons {
    writePNG(renderPNG(size: icon.pixels, rounded: false), to: iconDir.appendingPathComponent(icon.name))
}

writeSVG(to: logoDir.appendingPathComponent("wyn-logo.svg"))
writeSVG(to: siteDir.appendingPathComponent("favicon.svg"))

print("wrote Wyn mark → AppIcon, WynLogo, website/public/favicon.svg")
