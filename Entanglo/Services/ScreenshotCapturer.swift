//
// filename: ScreenshotCapturer.swift
// path: Entanglo/Entanglo/Services/ScreenshotCapturer.swift
// purpose: Captures a PNG of the main display. On macOS 14+ uses
//          SCScreenshotManager (ScreenCaptureKit) because
//          CGDisplayCreateImage is deprecated and returns nil on
//          Sequoia even with the Screen Recording grant. Falls back
//          to CGDisplayCreateImage on older macOS.
//

import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

public enum ScreenshotCapturer {
    /// Captures the main display and returns PNG bytes. nil if Screen
    /// Recording permission isn't granted or the capture API fails.
    /// Async because SCScreenshotManager is async-only on macOS 14+.
    public static func captureMainDisplayPNG(compressionQuality: CGFloat = 0.85) async -> Data? {
        #if canImport(CoreGraphics) && canImport(AppKit) && canImport(ImageIO)
        if let cg = await captureCGImage() {
            let scaled = scaleDownIfNeeded(cg, maxLongSide: 2048) ?? cg
            return encodePNG(scaled)
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(CoreGraphics)
    private static func captureCGImage() async -> CGImage? {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return nil }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = Int(display.width)
                config.height = Int(display.height)
                config.showsCursor = false
                return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)
            } catch {
                // Fall through to legacy CG path so we still capture
                // (or fail explicitly with nil → "grant Screen Recording")
                // on macOS 13.
                return CGDisplayCreateImage(CGMainDisplayID())
            }
        }
        #endif
        return CGDisplayCreateImage(CGMainDisplayID())
    }
    #endif

    #if canImport(CoreGraphics) && canImport(ImageIO)
    private static func scaleDownIfNeeded(_ image: CGImage, maxLongSide: Int) -> CGImage? {
        let w = image.width, h = image.height
        let longSide = max(w, h)
        guard longSide > maxLongSide else { return image }
        let scale = CGFloat(maxLongSide) / CGFloat(longSide)
        let newW = Int(CGFloat(w) * scale)
        let newH = Int(CGFloat(h) * scale)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        let type: CFString
        if #available(macOS 11.0, *) {
            type = UTType.png.identifier as CFString
        } else {
            type = "public.png" as CFString
        }
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
    #endif
}
