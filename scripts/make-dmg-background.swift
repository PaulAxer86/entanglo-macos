#!/usr/bin/env swift
//
// filename: make-dmg-background.swift
// purpose: Generate the DMG window background PNG using CoreGraphics + CoreText.
//          Output is written to the path passed as argv[1].
//          Window is 640x440; icons sit at Finder coords (180,240) and (460,240).
//          Background is drawn so the arrow/text line up with those positions.
//

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: make-dmg-background.swift <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments[1]

let W = 640, H = 440
let cs = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let ctx = CGContext(data: nil, width: W, height: H,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: bitmapInfo) else {
    fatalError("Cannot create CGContext")
}

// helper: y_top (Finder coords) → y_cg (CG coords from bottom)
func fy(_ yTop: CGFloat) -> CGFloat { CGFloat(H) - yTop }

// 1) Dark gradient base
let bgColors: [CGColor] = [
    CGColor(red: 0.039, green: 0.043, blue: 0.059, alpha: 1.0),
    CGColor(red: 0.058, green: 0.066, blue: 0.090, alpha: 1.0),
    CGColor(red: 0.075, green: 0.086, blue: 0.114, alpha: 1.0),
]
let gradient = CGGradient(colorsSpace: cs, colors: bgColors as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: CGFloat(H)),
                       end: CGPoint(x: CGFloat(W), y: 0),
                       options: [])

// 2) Ambient glow blobs
ctx.saveGState()
ctx.setBlendMode(.screen)
let glow1 = CGColor(red: 0.486, green: 0.361, blue: 1.0, alpha: 0.22)
ctx.setFillColor(glow1)
ctx.fillEllipse(in: CGRect(x: -120, y: CGFloat(H) - 220, width: 420, height: 420))
let glow2 = CGColor(red: 0.133, green: 0.827, blue: 0.933, alpha: 0.16)
ctx.setFillColor(glow2)
ctx.fillEllipse(in: CGRect(x: CGFloat(W) - 280, y: -160, width: 420, height: 420))
ctx.restoreGState()

// 3) Soft inner border highlight (top edge)
ctx.saveGState()
let topHighlight = CGGradient(colorsSpace: cs, colors: [
    CGColor(gray: 1.0, alpha: 0.08),
    CGColor(gray: 1.0, alpha: 0.0)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(topHighlight,
                       start: CGPoint(x: CGFloat(W)/2, y: CGFloat(H)),
                       end: CGPoint(x: CGFloat(W)/2, y: CGFloat(H) - 80),
                       options: [])
ctx.restoreGState()

// 4) Arrow from app spot → Applications spot.
//    Icon centers in Finder coords: (180, 240) and (460, 240).
//    Convert to CG y: fy(240) = 200.
let arrowY = fy(240)
let arrowStartX: CGFloat = 250  // leaves space after the app icon (icon ~96 wide)
let arrowEndX: CGFloat = 390    // leaves space before Applications icon
let accent = CGColor(red: 0.667, green: 0.545, blue: 1.0, alpha: 0.9)
let accentSoft = CGColor(red: 0.486, green: 0.361, blue: 1.0, alpha: 0.45)

// shadow line
ctx.setStrokeColor(accentSoft)
ctx.setLineWidth(6)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 4, y: arrowY))
ctx.strokePath()

// main line
ctx.setStrokeColor(accent)
ctx.setLineWidth(2.5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 4, y: arrowY))
ctx.strokePath()

// arrowhead
ctx.beginPath()
ctx.move(to: CGPoint(x: arrowEndX + 8, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 8, y: arrowY + 9))
ctx.addLine(to: CGPoint(x: arrowEndX - 8, y: arrowY - 9))
ctx.closePath()
ctx.setFillColor(accent)
ctx.fillPath()

// 5) Title text "Drag Entanglo into Applications"
func drawCenteredText(_ string: String, fontName: String, fontSize: CGFloat,
                      color: CGColor, atTopY yTop: CGFloat,
                      tracking: CGFloat = 0) {
    let font = NSFont(name: fontName, size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
        .kern: tracking,
    ]
    let attrString = NSAttributedString(string: string, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let x = (CGFloat(W) - bounds.width) / 2 - bounds.minX
    ctx.textPosition = CGPoint(x: x, y: fy(yTop) - bounds.height)
    CTLineDraw(line, ctx)
}

drawCenteredText("Welcome to Entanglo",
                 fontName: "SFProDisplay-Bold", fontSize: 22,
                 color: CGColor(gray: 1.0, alpha: 0.95),
                 atTopY: 60)

drawCenteredText("Drag the app into Applications to install",
                 fontName: "SFProText-Regular", fontSize: 13,
                 color: CGColor(gray: 1.0, alpha: 0.55),
                 atTopY: 95,
                 tracking: 0.2)

// 6) Footer (subtle wordmark / version-less brand)
drawCenteredText("entanglo.pages.dev",
                 fontName: "SFMono-Regular", fontSize: 10,
                 color: CGColor(gray: 1.0, alpha: 0.28),
                 atTopY: CGFloat(H) - 32,
                 tracking: 1.5)

// 7) Encode PNG
guard let image = ctx.makeImage() else { fatalError("Image render failed") }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.png.identifier as CFString,
                                                  1, nil) else {
    fatalError("Cannot create CGImageDestination at \(outPath)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG finalize failed") }

print("Generated DMG background: \(outPath) (\(W)x\(H))")
