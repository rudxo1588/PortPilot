// PortPilot's original vector icon. Uses only macOS frameworks.
// Regenerate: swift Resources/generate-icon.swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

let resourceURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconsetURL = resourceURL.appendingPathComponent("PortPilot.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
}

let oceanTop = color(0.095, 0.205, 0.345)
let oceanBottom = color(0.025, 0.073, 0.153)
let cableWhite = color(0.93, 0.97, 1.0)
let mint = color(0.24, 0.92, 0.79)
let socketInterior = color(0.035, 0.11, 0.195)

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// All geometry lives on a 1024-point canvas and is rasterized independently at
// each requested size. No source raster, brand assets, or icon fonts are used.
func drawIcon(in context: CGContext, pixels: Int) {
    context.saveGState()
    let rasterScale = CGFloat(pixels) / 1024
    context.scaleBy(x: rasterScale, y: rasterScale)
    context.setAllowsAntialiasing(true)

    let tileRect = CGRect(x: 56, y: 56, width: 912, height: 912)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 210, cornerHeight: 210, transform: nil)

    // A shallow, contained shadow preserves transparent macOS icon corners.
    if pixels >= 64 {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * rasterScale), blur: 24 * rasterScale,
                          color: color(0, 0.03, 0.08, 0.24))
        context.setFillColor(oceanBottom)
        context.addPath(tile)
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [oceanBottom, oceanTop] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 800, y: 56), end: CGPoint(x: 280, y: 968),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    if pixels >= 64 {
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0.16, 0.46, 0.58, 0.22), color(0.16, 0.46, 0.58, 0)] as CFArray,
                              locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 188, y: 852), startRadius: 0,
                                   endCenter: CGPoint(x: 188, y: 852), endRadius: 650, options: [])
    }
    context.restoreGState()

    if pixels >= 64 {
        context.setStrokeColor(color(0.75, 0.89, 1, 0.17))
        context.setLineWidth(3)
        context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), cornerWidth: 208, cornerHeight: 208, transform: nil))
        context.strokePath()
    }

    // One continuous routing cable, with two socket terminals. The broad route
    // gently suggests a P, but stays readable as a simple connection at 16px.
    let compact = pixels <= 32
    let route = CGMutablePath()
    route.move(to: CGPoint(x: 314, y: 286))
    route.addLine(to: CGPoint(x: 314, y: 648))
    route.addCurve(to: CGPoint(x: 445, y: 747), control1: CGPoint(x: 314, y: 714), control2: CGPoint(x: 365, y: 747))
    route.addLine(to: CGPoint(x: 568, y: 747))
    route.addCurve(to: CGPoint(x: 748, y: 582), control1: CGPoint(x: 685, y: 747), control2: CGPoint(x: 748, y: 689))
    route.addCurve(to: CGPoint(x: 575, y: 416), control1: CGPoint(x: 748, y: 480), control2: CGPoint(x: 684, y: 416))
    route.addLine(to: CGPoint(x: 510, y: 416))

    context.saveGState()
    if pixels >= 64 {
        context.setShadow(offset: CGSize(width: 0, height: -12 * rasterScale), blur: 16 * rasterScale,
                          color: color(0, 0.025, 0.065, 0.24))
    }
    context.setLineWidth(compact ? 116 : 100)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(cableWhite)
    context.addPath(route)
    context.strokePath()
    context.restoreGState()

    let terminals: [(CGPoint, CGColor)] = [
        (CGPoint(x: 314, y: 286), mint),
        (CGPoint(x: 510, y: 416), cableWhite)
    ]
    for (center, fill) in terminals {
        let radius: CGFloat = compact ? 78 : 76
        context.setFillColor(fill)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let hole: CGFloat = compact ? 27 : 31
        context.setFillColor(socketInterior)
        context.fillEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
    }
    context.restoreGState()
}

func image(pixels: Int) -> CGImage {
    let context = makeContext(width: pixels, height: pixels)
    drawIcon(in: context, pixels: pixels)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "PortPilotIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create PNG destination"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "PortPilotIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot save PNG"])
    }
}

let sizes = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in sizes { try writePNG(image(pixels: pixels), to: iconsetURL.appendingPathComponent(name)) }
try writePNG(image(pixels: 1024), to: resourceURL.appendingPathComponent("PortPilot-icon-1024.png"))

// A native PNG proof sheet with actual-size light and dark background samples.
let proof = makeContext(width: 1280, height: 800)
proof.setFillColor(color(0.95, 0.96, 0.97))
proof.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: proof, flipped: false)
func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, dark: Bool = false, bold: Bool = false) {
    let font = bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: dark ? NSColor(white: 0.84, alpha: 1) : NSColor(white: 0.26, alpha: 1)
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: x, y: y))
}
label("PortPilot", x: 42, y: 738, size: 28, bold: true)
label("Original vector icon · macOS", x: 42, y: 709, size: 15)
proof.draw(image(pixels: 512), in: CGRect(x: 18, y: 147, width: 512, height: 512))
label("1024 px source · shown at 512 px", x: 67, y: 111, size: 15)
let sampleSizes = [16, 32, 64, 128, 256]
for row in 0..<2 {
    let bottom: CGFloat = row == 0 ? 405 : 54
    let dark = row == 1
    proof.setFillColor(dark ? color(0.075, 0.09, 0.12) : color(1, 1, 1))
    let panel = CGPath(roundedRect: CGRect(x: 553, y: bottom, width: 695, height: 321), cornerWidth: 18, cornerHeight: 18, transform: nil)
    proof.addPath(panel)
    proof.fillPath()
    label(dark ? "Dark background · actual pixels" : "Light background · actual pixels", x: 577, y: bottom + 289, size: 14, dark: dark, bold: true)
    var cursor: CGFloat = 581
    for pixels in sampleSizes {
        let rect = CGRect(x: cursor, y: bottom + 40, width: CGFloat(pixels), height: CGFloat(pixels))
        proof.draw(image(pixels: pixels), in: rect)
        label("\(pixels)", x: cursor, y: bottom + 14, size: 12, dark: dark)
        cursor += CGFloat(pixels) + 31
    }
}
NSGraphicsContext.restoreGraphicsState()
try writePNG(proof.makeImage()!, to: resourceURL.appendingPathComponent("PortPilot-icon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", resourceURL.appendingPathComponent("PortPilot.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil could not assemble PortPilot.icns (exit \(iconutil.terminationStatus)). PNG resources are preserved.\n".utf8))
    exit(1)
}
print("Generated 10 iconset PNGs, 1024 PNG, proof sheet, and PortPilot.icns in \(resourceURL.path)")
