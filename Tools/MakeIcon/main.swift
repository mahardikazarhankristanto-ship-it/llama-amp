import AppKit

// Renders the example-loop pixel cover as a macOS app icon set.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let art = Covers.demo().cgImage()!
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                   (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    let r = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: r, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.addPath(path); ctx.clip()
    ctx.interpolationQuality = .none
    ctx.draw(art, in: r)
    ctx.resetClip()
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35)); ctx.setLineWidth(max(1, 6 * s)); ctx.strokePath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent("icon_\(name).png"))
}
