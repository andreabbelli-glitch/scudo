// Renders the app icon: a white shield with a check mark on a teal gradient.
// Usage: swift Tools/make-icon.swift <output.png> [size]
// The PNG is opaque (no alpha channel), as App Store Connect requires.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift make-icon.swift <output.png> [size]")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let size = arguments.count >= 3 ? Int(arguments[2]) ?? 1024 : 1024
let scale = CGFloat(size) / 1024

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("cannot create context") }

// Work in a 1024-point, top-left-origin coordinate space.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: scale, y: -scale)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Background gradient.
let background = CGGradient(colorsSpace: colorSpace, colors: [color(0x0A5C63), color(0x0E8A6B), color(0x2BC48A)] as CFArray, locations: [0, 0.55, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])

// Soft light in the top-left corner.
let glow = CGGradient(colorsSpace: colorSpace, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 230, y: 160), startRadius: 0, endCenter: CGPoint(x: 230, y: 160), endRadius: 700, options: [])

// Shield.
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 178))
shield.addCurve(to: CGPoint(x: 778, y: 262), control1: CGPoint(x: 600, y: 238), control2: CGPoint(x: 690, y: 262))
shield.addLine(to: CGPoint(x: 778, y: 500))
shield.addCurve(to: CGPoint(x: 512, y: 866), control1: CGPoint(x: 778, y: 690), control2: CGPoint(x: 660, y: 800))
shield.addCurve(to: CGPoint(x: 246, y: 500), control1: CGPoint(x: 364, y: 800), control2: CGPoint(x: 246, y: 690))
shield.addLine(to: CGPoint(x: 246, y: 262))
shield.addCurve(to: CGPoint(x: 512, y: 178), control1: CGPoint(x: 334, y: 262), control2: CGPoint(x: 424, y: 238))
shield.closeSubpath()

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x03292B, 0.35))
context.addPath(shield)
context.setFillColor(color(0xFFFFFF))
context.fillPath()
context.restoreGState()

// Subtle shading on the right half of the shield.
context.saveGState()
context.addPath(shield)
context.clip()
context.setFillColor(color(0x0A5C63, 0.07))
context.fill(CGRect(x: 512, y: 0, width: 512, height: 1024))
context.restoreGState()

// Check mark, painted with the background gradient.
let check = CGMutablePath()
check.move(to: CGPoint(x: 392, y: 520))
check.addLine(to: CGPoint(x: 478, y: 606))
check.addLine(to: CGPoint(x: 640, y: 424))
context.saveGState()
context.addPath(check.copy(strokingWithWidth: 70, lineCap: .round, lineJoin: .round, miterLimit: 10))
context.clip()
context.drawLinearGradient(background, start: CGPoint(x: 300, y: 300), end: CGPoint(x: 760, y: 760), options: [])
context.restoreGState()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot create image") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(output.path)") }
print("Wrote \(output.path) (\(size)×\(size))")
