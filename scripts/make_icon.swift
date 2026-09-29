// Draws VoiceFlow's icons from the logo, Resources/Logo.png (a black waveform on white):
// - Resources/AppIcon.icns: the logo on a white rounded square (Dock, Finder, the window's sidebar).
// - Resources/MenuBarIcon.png and MenuBarIcon@2x.png: a solid silhouette of the logo for the menu bar. It is a
//   template image, so macOS colours it to match the menu bar; VoiceFlow turns it red while recording.
// Run from the project folder: swift scripts/make_icon.swift
import AppKit

// MARK: - Read the logo as "ink" (0 = white paper, 1 = black)

let logo = NSImage(contentsOf: URL(fileURLWithPath: "Resources/Logo.png"))!
    .cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = logo.width, h = logo.height
let grayContext = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
grayContext.draw(logo, in: CGRect(x: 0, y: 0, width: w, height: h))
let gray = grayContext.data!.bindMemory(to: UInt8.self, capacity: w * h)
// The paper is 99.7–100 % white; anything lighter than 99 % counts as paper.
let ink = (0..<(w * h)).map { max(0, min(1, (0.99 - Double(gray[$0]) / 255) / 0.99)) }

// The waveform's bounding box, plus a margin for the soft edges and the thickening below.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w where ink[y * w + x] > 0.15 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
minX = max(0, minX - 12); maxX = min(w - 1, maxX + 12); minY = max(0, minY - 12); maxY = min(h - 1, maxY + 12)
let cropW = maxX - minX + 1, cropH = maxY - minY + 1

/// A black image whose opacity is `alpha` (one value per pixel of the cropped logo).
func blackImage(_ alpha: [Double]) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: cropW * cropH * 4)
    for i in 0..<(cropW * cropH) { pixels[i * 4 + 3] = UInt8((alpha[i] * 255).rounded()) }
    let context = CGContext(data: &pixels, width: cropW, height: cropH, bitsPerComponent: 8, bytesPerRow: cropW * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

// With its shading, for the app icon.
var shadedAlpha = [Double](repeating: 0, count: cropW * cropH)
for y in 0..<cropH { for x in 0..<cropW { shadedAlpha[y * cropW + x] = ink[(y + minY) * w + x + minX] } }

// Solid, for the menu bar: every column is filled from the ribbon's top edge to its bottom edge, so the light
// highlights inside the curves don't turn into holes, and the ribbon is thickened by `grow` pixels all round
// (about 0.25 pt at menu-bar size) so it stays readable at 18 points tall. The edges are soft once scaled down.
let grow = 8
let edges: [(top: Int, bottom: Int)?] = (0..<cropW).map { x in
    let column = (0..<cropH).map { ink[($0 + minY) * w + x + minX] }
    guard let top = column.firstIndex(where: { $0 > 0.3 }), let bottom = column.lastIndex(where: { $0 > 0.3 }) else { return nil }
    return (top, bottom)
}
var solidAlpha = [Double](repeating: 0, count: cropW * cropH)
for x in 0..<cropW {
    for dx in -grow...grow {
        guard x + dx >= 0, x + dx < cropW, let edge = edges[x + dx] else { continue }
        let reach = Int(Double(grow * grow - dx * dx).squareRoot())
        for y in max(0, edge.top - reach)...min(cropH - 1, edge.bottom + reach) { solidAlpha[y * cropW + x] = 1 }
    }
}
let shaded = blackImage(shadedAlpha), solid = blackImage(solidAlpha)
let aspect = CGFloat(cropH) / CGFloat(cropW)

func png(pixelsWide: Int, pixelsHigh: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    draw(context.cgContext, CGFloat(pixelsWide))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - App icon

func appIcon(_ px: Int) -> Data {
    png(pixelsWide: px, pixelsHigh: px) { cg, s in
        let inset = s * 0.1  // Apple's icon grid leaves a margin around the rounded square
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let square = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.025,
                     color: NSColor.black.withAlphaComponent(0.3).cgColor)
        NSColor.white.setFill()
        square.fill()
        cg.restoreGState()
        NSGradient(starting: .white, ending: NSColor(white: 0.93, alpha: 1))!.draw(in: square, angle: -90)
        let width = rect.width * 0.78, height = width * aspect
        cg.draw(shaded, in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
    }
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! appIcon(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! appIcon(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

// MARK: - Menu-bar icon (32 × 18 points; the logo is 30 points wide)

for scale in [1, 2] {
    let data = png(pixelsWide: 32 * scale, pixelsHigh: 18 * scale) { cg, s in
        let width = s * 30 / 32, height = width * aspect
        cg.draw(solid, in: CGRect(x: (s - width) / 2, y: (CGFloat(18 * scale) - height) / 2, width: width, height: height))
    }
    try! data.write(to: URL(fileURLWithPath: "Resources/MenuBarIcon\(scale == 2 ? "@2x" : "").png"))
}
print("Wrote Resources/AppIcon.icns and Resources/MenuBarIcon.png (+ @2x)")
