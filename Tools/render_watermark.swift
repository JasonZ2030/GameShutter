// Regenerates GameShutter/Assets.xcassets/GameShutterWatermark.imageset/GameShutterWatermark.png.
// Not part of the app target. Needs BarlowCondensed-ExtraBoldItalic.ttf and
// BarlowCondensed-MediumItalic.ttf (OFL, github.com/google/fonts ofl/barlowcondensed) in <font-dir>:
//   swift Tools/render_watermark.swift GameShutter/Assets.xcassets/GameShutterWatermark.imageset/GameShutterWatermark.png <font-dir>
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Renders the GameShutter watermark lockup (white mark + wordmark, soft shadow,
// transparent background) to a PNG. Geometry matches the design canvas's
// "As a video watermark" board, scaled by `k`.
let k: CGFloat = 4
let icon: CGFloat = 52 * k
let fontSize: CGFloat = 34 * k
let gap: CGFloat = 12 * k
let pad: CGFloat = 8 * k
let outPath = CommandLine.arguments[1]
let fontDir = CommandLine.arguments[2]

func loadFont(_ file: String) -> CTFont {
    let url = URL(fileURLWithPath: fontDir).appendingPathComponent(file) as CFURL
    let desc = (CTFontManagerCreateFontDescriptorsFromURL(url) as! [CTFontDescriptor])[0]
    return CTFontCreateWithFontDescriptor(desc, fontSize, nil)
}
let heavy = loadFont("BarlowCondensed-ExtraBoldItalic.ttf")
let medium = loadFont("BarlowCondensed-MediumItalic.ttf")

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let orange = CGColor(red: 1, green: 0x6A / 255.0, blue: 0x13 / 255.0, alpha: 1)
let ink = CGColor(red: 0x0E / 255.0, green: 0x11 / 255.0, blue: 0x16 / 255.0, alpha: 1)

let text = NSMutableAttributedString()
for (s, f) in [("GAME", heavy), ("SHUTTER", medium)] {
    text.append(NSAttributedString(string: s, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: f,
        kCTForegroundColorAttributeName as NSAttributedString.Key: white,
        kCTKernAttributeName as NSAttributedString.Key: 0.5 * k
    ]))
}
let line = CTLineCreateWithAttributedString(text)
let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

let width = Int(ceil(pad + icon + gap + textBounds.maxX + pad))
let height = Int(ceil(pad * 2 + icon))
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

ctx.setShadow(offset: CGSize(width: 0, height: -1 * k), blur: 3 * k,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

// Mark, drawn in the SVG's 100×100 top-left-origin space.
ctx.saveGState()
ctx.translateBy(x: pad, y: pad + icon)
ctx.scaleBy(x: icon / 100, y: -icon / 100)
let hex = CGMutablePath()
hex.addLines(between: [CGPoint(x: 50, y: 33), CGPoint(x: 64.72, y: 41.5), CGPoint(x: 64.72, y: 58.5),
                       CGPoint(x: 50, y: 67), CGPoint(x: 35.28, y: 58.5), CGPoint(x: 35.28, y: 41.5)])
hex.closeSubpath()
ctx.addPath(hex); ctx.setFillColor(orange); ctx.fillPath()

ctx.saveGState()
ctx.addPath(hex); ctx.clip()
let seams = CGMutablePath()
seams.move(to: CGPoint(x: 50, y: 30)); seams.addLine(to: CGPoint(x: 50, y: 70))
seams.move(to: CGPoint(x: 30, y: 50)); seams.addLine(to: CGPoint(x: 70, y: 50))
seams.move(to: CGPoint(x: 40, y: 36)); seams.addQuadCurve(to: CGPoint(x: 40, y: 64), control: CGPoint(x: 47, y: 50))
seams.move(to: CGPoint(x: 60, y: 36)); seams.addQuadCurve(to: CGPoint(x: 60, y: 64), control: CGPoint(x: 53, y: 50))
ctx.addPath(seams); ctx.setStrokeColor(ink); ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.strokePath()
ctx.restoreGState()

let blades: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (50, 33, 93.27, 57.98), (64.72, 41.5, 64.72, 91.46), (64.72, 58.5, 21.45, 83.48),
    (50, 67, 6.73, 42.02), (35.28, 58.5, 35.28, 8.54), (35.28, 41.5, 78.55, 16.52)]
let ring = CGMutablePath()
ring.addEllipse(in: CGRect(x: 6, y: 6, width: 88, height: 88))
for (x1, y1, x2, y2) in blades {
    ring.move(to: CGPoint(x: x1, y: y1)); ring.addLine(to: CGPoint(x: x2, y: y2))
}
ctx.addPath(ring); ctx.setStrokeColor(white); ctx.setLineWidth(5.5)
ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
ctx.restoreGState()

// Wordmark: cap height centered on the mark.
let capHeight = CTFontGetCapHeight(heavy)
ctx.textPosition = CGPoint(x: pad + icon + gap, y: pad + icon / 2 - capHeight / 2)
CTLineDraw(line, ctx)

ctx.endTransparencyLayer()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("\(width)x\(height)")
