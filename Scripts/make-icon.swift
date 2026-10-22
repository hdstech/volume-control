// Renders the app icon: three glowing mixer faders on an indigo tile.
// Usage: swift Scripts/make-icon.swift <output.png>   (1024×1024)
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
guard let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("Couldn't create context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

// macOS icon grid: an 824-pt tile centered on the 1024 canvas, leaving room for the drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Tile shadow.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.35))
context.addPath(tilePath)
context.setFillColor(color(0x15103A))
context.fillPath()
context.restoreGState()

// Tile background: deep indigo diagonal gradient with a soft violet glow near the top.
context.saveGState()
context.addPath(tilePath)
context.clip()
context.drawLinearGradient(
    gradient([color(0x4B3BF0), color(0x2A1C8F), color(0x0D0A2B)], [0, 0.45, 1]),
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)
context.drawRadialGradient(
    gradient([color(0xB59CFF, 0.45), color(0xB59CFF, 0)], [0, 1]),
    startCenter: CGPoint(x: 420, y: 860), startRadius: 0,
    endCenter: CGPoint(x: 420, y: 860), endRadius: 520,
    options: []
)
// Glassy top sheen.
context.drawLinearGradient(
    gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)], [0, 1]),
    start: CGPoint(x: 0, y: tile.maxY),
    end: CGPoint(x: 0, y: tile.midY + 60),
    options: []
)
context.restoreGState()

// Faders.
struct Fader {
    let x: CGFloat
    let level: CGFloat
    let top: UInt32
    let bottom: UInt32
}

let trackBottom: CGFloat = 270
let trackTop: CGFloat = 754
let trackWidth: CGFloat = 34
let knobRadius: CGFloat = 54

let faders = [
    Fader(x: 352, level: 0.42, top: 0x5CF0FF, bottom: 0x2D7BFF),
    Fader(x: 512, level: 0.80, top: 0xFF7AE0, bottom: 0xA14BFF),
    Fader(x: 672, level: 0.60, top: 0xB6FF6E, bottom: 0x21C99A),
]

for fader in faders {
    let track = CGRect(x: fader.x - trackWidth / 2, y: trackBottom, width: trackWidth, height: trackTop - trackBottom)
    let trackPath = CGPath(roundedRect: track, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil)

    // Empty track.
    context.addPath(trackPath)
    context.setFillColor(color(0xFFFFFF, 0.12))
    context.fillPath()

    let knobY = trackBottom + (trackTop - trackBottom) * fader.level

    // Lit portion below the knob, with a colored glow.
    let lit = CGRect(x: track.minX, y: trackBottom, width: trackWidth, height: knobY - trackBottom)
    let litPath = CGPath(roundedRect: lit, cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2, transform: nil)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 36, color: color(fader.top, 0.85))
    context.addPath(litPath)
    context.setFillColor(color(fader.bottom))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(litPath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(fader.top), color(fader.bottom)], [0, 1]),
        start: CGPoint(x: 0, y: knobY),
        end: CGPoint(x: 0, y: trackBottom),
        options: []
    )
    context.restoreGState()

    // Knob: bright disc with a soft shadow, a subtle vertical shade, and a colored center dot.
    let knob = CGRect(x: fader.x - knobRadius, y: knobY - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    context.addEllipse(in: knob)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addEllipse(in: knob)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0xFFFFFF), color(0xDCD8F5)], [0, 1]),
        start: CGPoint(x: 0, y: knob.maxY),
        end: CGPoint(x: 0, y: knob.minY),
        options: []
    )
    context.restoreGState()

    let dot: CGFloat = 15
    context.addEllipse(in: CGRect(x: fader.x - dot, y: knobY - dot, width: dot * 2, height: dot * 2))
    context.setFillColor(color(fader.bottom))
    context.fillPath()
}

// Fine inner border so the tile reads on light and dark backgrounds.
context.saveGState()
context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183, cornerHeight: 183, transform: nil))
context.setStrokeColor(color(0xFFFFFF, 0.14))
context.setLineWidth(3)
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("Couldn't render") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Couldn't encode") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
