// Renders the Knobby app icon (a volume knob) as a 1024x1024 PNG.
// Run via scripts/make-icon.sh, which packs it into AppIcon.icns.
import AppKit
import ImageIO

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift make-icon.swift <output.png>\n", stderr)
    exit(1)
}
let output = CommandLine.arguments[1]

let ctx = CGContext(
    data: nil, width: 1024, height: 1024,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha)
}

// Knob dial sweep: t = 0...1 maps to 225°...-45° (270° clockwise, like a
// physical volume knob). The indicator and blue level arc sit at `level`.
let level: CGFloat = 0.7
func dialAngle(_ t: CGFloat) -> CGFloat { (225 - 270 * t) * .pi / 180 }
let center = CGPoint(x: 512, y: 512)

// Rounded-square canvas with macOS Big Sur proportions (824pt content in a
// 1024 canvas) and a baked-in drop shadow, matching system app icons.
let canvas = CGPath(
    roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
    cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
              color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(canvas)
ctx.setFillColor(rgb(0x1c1c1e))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(canvas)
ctx.clip()
let background = CGGradient(
    colorsSpace: nil,
    colors: [rgb(0x3a3a3c), rgb(0x1c1c1e)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    background,
    start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Level arc around the knob: dim track with a blue fill up to `level`.
func strokeDial(from: CGFloat, to: CGFloat, radius: CGFloat, width: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.addArc(center: center, radius: radius,
               startAngle: dialAngle(from), endAngle: dialAngle(to), clockwise: true)
    ctx.strokePath()
}
strokeDial(from: 0, to: 1, radius: 330, width: 40, color: rgb(0xffffff, 0.14))
strokeDial(from: 0, to: level, radius: 330, width: 40, color: rgb(0x0a84ff))

// Knob body.
ctx.beginPath()
ctx.addArc(center: center, radius: 250, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.clip()
let knob = CGGradient(
    colorsSpace: nil,
    colors: [rgb(0x5a5a5e), rgb(0x2e2e30)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    knob,
    start: CGPoint(x: 512, y: 762), end: CGPoint(x: 512, y: 262), options: [])
ctx.restoreGState()

// Knob rim highlight.
ctx.setStrokeColor(rgb(0xffffff, 0.10))
ctx.setLineWidth(8)
ctx.beginPath()
ctx.addArc(center: center, radius: 246, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
ctx.strokePath()

// Indicator line at the current level.
let angle = dialAngle(level)
let direction = CGPoint(x: cos(angle), y: sin(angle))
ctx.setStrokeColor(rgb(0xffffff))
ctx.setLineWidth(36)
ctx.setLineCap(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: center.x + direction.x * 120, y: center.y + direction.y * 120))
ctx.addLine(to: CGPoint(x: center.x + direction.x * 205, y: center.y + direction.y * 205))
ctx.strokePath()

let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("failed to write \(output)\n", stderr)
    exit(1)
}
