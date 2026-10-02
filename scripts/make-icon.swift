// Draws the app icon (a citrus-slice wheel on a warm squircle) and writes an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Annular sector with rounded corners (same construction as the in-app wheel).
func segment(center c: CGPoint, inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat, gap: CGFloat, corner: CGFloat) -> CGPath {
    func p(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)) }
    let ri = inner + corner, ro = outer - corner, d = gap / 2 + corner
    let path = CGMutablePath()
    let o0 = start + asin(d / ro), o1 = end - asin(d / ro)
    let i0 = start + asin(d / ri), i1 = end - asin(d / ri)
    path.move(to: p(ro, o0))
    for k in 1...60 { path.addLine(to: p(ro, o0 + (o1 - o0) * CGFloat(k) / 60)) }
    path.addLine(to: p(ri, i1))
    for k in 1...60 { path.addLine(to: p(ri, i1 - (i1 - i0) * CGFloat(k) / 60)) }
    path.closeSubpath()
    return path.union(path.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Body with a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0xFF8A3A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0xFFC84F), color(0xFF8A36), color(0xF2552A)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 180, y: 924), end: CGPoint(x: 860, y: 100), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: [])
    ctx.restoreGState()

    // The wheel.
    let c = CGPoint(x: 512, y: 494)
    let r: CGFloat = 300
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x8A2A00, 0.35))
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(color(0xFFD9AE, 0.55))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: c.x - r + 6, y: c.y - r + 6, width: 2 * r - 12, height: 2 * r - 12))
    ctx.setStrokeColor(color(0xFFFFFF, 0.7))
    ctx.setLineWidth(12)
    ctx.strokePath()

    let count = 6
    for i in 0..<count {
        let mid = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(count)
        let path = segment(center: c, inner: 118, outer: 272, start: mid - .pi / CGFloat(count),
                           end: mid + .pi / CGFloat(count), gap: 22, corner: 24)
        ctx.addPath(path)
        ctx.setFillColor(i == 0 ? color(0xF04E1C) : color(0xFFF0E2))
        ctx.fillPath()
    }
    // Centre well.
    ctx.addEllipse(in: CGRect(x: c.x - 98, y: c.y - 98, width: 196, height: 196))
    ctx.setFillColor(color(0xE8742E))
    ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: c.x - 98, y: c.y - 98, width: 196, height: 196))
    ctx.setStrokeColor(color(0xFFE2BF, 0.9))
    ctx.setLineWidth(10)
    ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68))
    ctx.setFillColor(color(0xFFD2A0))
    ctx.fillPath()

    // Leaf.
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: 650, y: 770))
    leaf.addCurve(to: CGPoint(x: 850, y: 860), control1: CGPoint(x: 690, y: 880), control2: CGPoint(x: 790, y: 900))
    leaf.addCurve(to: CGPoint(x: 650, y: 770), control1: CGPoint(x: 820, y: 770), control2: CGPoint(x: 730, y: 730))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x1F4D1F, 0.35))
    ctx.addPath(leaf)
    ctx.setFillColor(color(0x46A84B))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.move(to: CGPoint(x: 662, y: 774))
    ctx.addQuadCurve(to: CGPoint(x: 838, y: 852), control: CGPoint(x: 760, y: 830))
    ctx.setStrokeColor(color(0xBFE8B5, 0.9))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    ctx.strokePath()
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: pixels))
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("Wrote \(out.path)")
