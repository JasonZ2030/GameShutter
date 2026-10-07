// Regenerates every PNG in GameShutter/Assets.xcassets/AppIcon.appiconset and
// rewrites its Contents.json. Not part of the app target.
//   swift Tools/render_app_icon.swift GameShutter/Assets.xcassets/AppIcon.appiconset
//
// The GameShutter mark (shutter blades around a basketball, same geometry as
// render_watermark.swift) in white on Ink, opaque. Small sizes drop the seams
// and thicken the strokes so the mark stays legible.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let orange = CGColor(red: 1, green: 0x6A / 255.0, blue: 0x13 / 255.0, alpha: 1)
let ink = CGColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)

// (idiom, size in points, scale)
let entries: [(String, String, Int)] = [
    ("iphone", "20x20", 2), ("iphone", "20x20", 3),
    ("iphone", "29x29", 2), ("iphone", "29x29", 3),
    ("iphone", "40x40", 2), ("iphone", "40x40", 3),
    ("iphone", "60x60", 2), ("iphone", "60x60", 3),
    ("ipad", "20x20", 1), ("ipad", "20x20", 2),
    ("ipad", "29x29", 1), ("ipad", "29x29", 2),
    ("ipad", "40x40", 1), ("ipad", "40x40", 2),
    ("ipad", "76x76", 1), ("ipad", "76x76", 2),
    ("ipad", "83.5x83.5", 2),
    ("ios-marketing", "1024x1024", 1)
]

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let s = CGFloat(px)
    ctx.setFillColor(ink)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Mark spans 76% of the icon, centered, in the SVG's 100×100 top-left space.
    let markSize = s * 0.76
    ctx.translateBy(x: (s - markSize) / 2, y: (s + markSize) / 2)
    ctx.scaleBy(x: markSize / 100, y: -markSize / 100)

    let strokeWidth: CGFloat
    let drawSeams: Bool
    switch px {
    case 120...: strokeWidth = 5; drawSeams = true
    case 48..<120: strokeWidth = 7; drawSeams = true
    default: strokeWidth = 9; drawSeams = false
    }
    let ringInset = 6 + (strokeWidth - 5.5) / 2

    let hex = CGMutablePath()
    hex.addLines(between: [CGPoint(x: 50, y: 33), CGPoint(x: 64.72, y: 41.5), CGPoint(x: 64.72, y: 58.5),
                           CGPoint(x: 50, y: 67), CGPoint(x: 35.28, y: 58.5), CGPoint(x: 35.28, y: 41.5)])
    hex.closeSubpath()
    ctx.addPath(hex); ctx.setFillColor(orange); ctx.fillPath()

    if drawSeams {
        ctx.saveGState()
        ctx.addPath(hex); ctx.clip()
        let seams = CGMutablePath()
        seams.move(to: CGPoint(x: 50, y: 30)); seams.addLine(to: CGPoint(x: 50, y: 70))
        seams.move(to: CGPoint(x: 30, y: 50)); seams.addLine(to: CGPoint(x: 70, y: 50))
        seams.move(to: CGPoint(x: 40, y: 36)); seams.addQuadCurve(to: CGPoint(x: 40, y: 64), control: CGPoint(x: 47, y: 50))
        seams.move(to: CGPoint(x: 60, y: 36)); seams.addQuadCurve(to: CGPoint(x: 60, y: 64), control: CGPoint(x: 53, y: 50))
        ctx.addPath(seams); ctx.setStrokeColor(ink)
        ctx.setLineWidth(px >= 120 ? 2 : 2.6); ctx.setLineCap(.round); ctx.strokePath()
        ctx.restoreGState()
    }

    let blades: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (50, 33, 93.27, 57.98), (64.72, 41.5, 64.72, 91.46), (64.72, 58.5, 21.45, 83.48),
        (50, 67, 6.73, 42.02), (35.28, 58.5, 35.28, 8.54), (35.28, 41.5, 78.55, 16.52)]
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: ringInset, y: ringInset, width: 100 - 2 * ringInset, height: 100 - 2 * ringInset))
    for (x1, y1, x2, y2) in blades {
        ring.move(to: CGPoint(x: x1, y: y1)); ring.addLine(to: CGPoint(x: x2, y: y2))
    }
    // Keep blade tips inside the (possibly inset) ring.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: ringInset, y: ringInset, width: 100 - 2 * ringInset, height: 100 - 2 * ringInset))
    ctx.clip()
    ctx.addPath(ring); ctx.setStrokeColor(white); ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: ringInset, y: ringInset, width: 100 - 2 * ringInset, height: 100 - 2 * ringInset))
    ctx.setStrokeColor(white); ctx.setLineWidth(strokeWidth); ctx.strokePath()

    return ctx.makeImage()!
}

var images: [[String: String]] = []
var rendered: Set<Int> = []
for (idiom, size, scale) in entries {
    let points = Double(size.split(separator: "x")[0])!
    let px = Int((points * Double(scale)).rounded())
    let filename = "Icon-\(px).png"
    if !rendered.contains(px) {
        let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(filename) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(px: px), nil)
        CGImageDestinationFinalize(dest)
        rendered.insert(px)
    }
    images.append(["filename": filename, "idiom": idiom, "scale": "\(scale)x", "size": size])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("rendered \(rendered.sorted())")
