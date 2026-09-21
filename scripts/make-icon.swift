// Draws StowKit's app icon at every macOS size into the asset catalog.
// Usage: swift scripts/make-icon.swift StowKit/Assets.xcassets/AppIcon.appiconset
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func gradient(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, _ rect: CGRect) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}
func document(_ ctx: CGContext, _ rect: CGRect, fill: CGColor, lines: Bool) {
    let fold: CGFloat = 78
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + 22, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - 22, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 22), control: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + 22, y: rect.maxY))
    path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 22), control: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 22))
    path.addQuadCurve(to: CGPoint(x: rect.minX + 22, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x0B2A6B, 0.35))
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
    ctx.restoreGState()
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
    corner.addLine(to: CGPoint(x: rect.maxX - fold + 14, y: rect.maxY - fold))
    corner.addQuadCurve(to: CGPoint(x: rect.maxX - fold, y: rect.maxY - fold + 14), control: CGPoint(x: rect.maxX - fold, y: rect.maxY - fold))
    corner.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
    corner.closeSubpath()
    ctx.addPath(corner); ctx.setFillColor(color(0xC3D3EE)); ctx.fillPath()
    guard lines else { return }
    ctx.setFillColor(color(0x9FB6DC))
    ctx.addPath(rounded(CGRect(x: rect.minX + 46, y: rect.maxY - 120, width: 150, height: 26), 13)); ctx.fillPath()
    ctx.setFillColor(color(0xC9D7EE))
    for (i, width) in [230.0, 200, 228, 170].enumerated() {
        ctx.addPath(rounded(CGRect(x: rect.minX + 46, y: rect.maxY - 186 - CGFloat(i) * 52, width: width, height: 20), 10)); ctx.fillPath()
    }
}
func draw(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = rounded(body, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(tile); ctx.setFillColor(color(0x2F6FE8)); ctx.fillPath()
    ctx.restoreGState()
    gradient(ctx, tile, color(0x5AA2FF), color(0x1D47C9), body)
    // Tray back rim, then the documents standing in the tray, then its front.
    gradient(ctx, rounded(CGRect(x: 236, y: 330, width: 552, height: 120), 30), color(0x9DB7E8), color(0x7E9DD8), body)
    ctx.saveGState(); ctx.translateBy(x: 470, y: 560); ctx.rotate(by: 0.14)
    document(ctx, CGRect(x: -170, y: -250, width: 330, height: 440), fill: color(0xE3ECFA), lines: false)
    ctx.restoreGState()
    ctx.saveGState(); ctx.translateBy(x: 548, y: 560); ctx.rotate(by: -0.06)
    document(ctx, CGRect(x: -165, y: -260, width: 330, height: 470), fill: color(0xFFFFFF), lines: true)
    ctx.restoreGState()
    let front = rounded(CGRect(x: 210, y: 196, width: 604, height: 236), 44)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(0x0B2A6B, 0.4))
    ctx.addPath(front); ctx.setFillColor(color(0xF4F7FD)); ctx.fillPath()
    ctx.restoreGState()
    gradient(ctx, front, color(0xFFFFFF), color(0xDCE5F5), body)
    ctx.addPath(rounded(CGRect(x: 432, y: 300, width: 160, height: 40), 20)); ctx.setFillColor(color(0x2F5FC8, 0.28)); ctx.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale, name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(out.path)")
