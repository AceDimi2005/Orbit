// Reformat the existing Orbit artwork into Apple's tvOS asset catalog layout.
// Run from the repository root: swift Orbit-iOS/Tools/generate_tv_assets.swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("Orbit-iOS/OrbitTV/Assets.xcassets/AppIcon.brandassets")
let source = root.appendingPathComponent("Orbit-iOS/Orbit/Assets.xcassets/OrbitMark.imageset/OrbitMark.png")
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let mark = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { fatalError("Orbit artwork is missing") }
let info: [String: Any] = ["author": "xcode", "version": 1]
func json(_ object: [String: Any], at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}
func render(width: Int, height: Int, transparent: Bool = false, to url: URL, drawing: (CGContext) -> Void) {
    let alpha = transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    context.interpolationQuality = .high
    drawing(context)
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
}
/// Background colour sampled from a corner of the artwork itself, so the wide Top Shelf
/// canvas and the square source blend without a visible tile edge.
let backgroundColor: CGColor = {
    let width = 1, height = 1
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw the artwork scaled so that only its top-left corner region covers the single pixel.
    context.interpolationQuality = .none
    context.draw(mark, in: CGRect(x: 0, y: 0, width: mark.width / 24, height: mark.height / 24))
    return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
}()
func background(_ context: CGContext, width: Int, height: Int) {
    context.setFillColor(backgroundColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
}
// Blend the square source artwork into a wide canvas without a visible tile edge.
func drawMark(_ context: CGContext, in rect: CGRect) {
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.draw(mark, in: rect)
    context.setBlendMode(.destinationIn)
    let colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1),
                  CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors,
        locations: [0, 0.22, 0.78, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.midY),
        end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
    context.endTransparencyLayer()
    context.restoreGState()
}
func icon(name: String, size: (Int, Int), scales: [Int]) throws -> [String: Any] {
    let stack = catalog.appendingPathComponent(name + ".imagestack")
    let layerNames = ["Front", "Back"]
    try json(["info": info, "layers": layerNames.map { ["filename": $0 + ".imagestacklayer"] }], at: stack)
    for layer in layerNames {
        let layerURL = stack.appendingPathComponent(layer + ".imagestacklayer")
        try json(["info": info], at: layerURL)
        let setURL = layerURL.appendingPathComponent("Content.imageset")
        var images: [[String: Any]] = []
        for scale in scales {
            let width = size.0 * scale, height = size.1 * scale
            let filename = "\(layer.lowercased())@\(scale)x.png"
            try FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)
            render(width: width, height: height, transparent: layer == "Front", to: setURL.appendingPathComponent(filename)) { context in
                if layer == "Back" { background(context, width: width, height: height) }
                else {
                    let side = CGFloat(width) * 0.88
                    drawMark(context, in: CGRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))
                }
            }
            images.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
        }
        try json(["info": info, "images": images], at: setURL)
    }
    return ["filename": name + ".imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "\(size.0)x\(size.1)"]
}
func shelf(name: String, width: Int, role: String) throws -> [String: Any] {
    let set = catalog.appendingPathComponent(name + ".imageset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for scale in [1, 2] {
        let filename = "shelf@\(scale)x.png"
        render(width: width * scale, height: 720 * scale, to: set.appendingPathComponent(filename)) { context in
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            background(context, width: width, height: 720)
            let groupWidth: CGFloat = 1160
            let start = (CGFloat(width) - groupWidth) / 2
            drawMark(context, in: CGRect(x: start, y: 0, width: 720, height: 720))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let title = NSAttributedString(string: "ORBIT", attributes: [
                .font: NSFont.systemFont(ofSize: 118, weight: .bold),
                .foregroundColor: NSColor.white, .kern: 9
            ])
            title.draw(at: CGPoint(x: start + 680, y: 352))
            let subtitle = NSAttributedString(string: "Your PC. Within reach.", attributes: [
                .font: NSFont.systemFont(ofSize: 35, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.62, green: 0.75, blue: 0.86, alpha: 1)
            ])
            subtitle.draw(at: CGPoint(x: start + 687, y: 291))
            NSGraphicsContext.restoreGraphicsState()
        }
        images.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
    }
    try json(["info": info, "images": images], at: set)
    return ["filename": name + ".imageset", "idiom": "tv", "role": role, "size": "\(width)x720"]
}
let assets = try [
    icon(name: "App Icon - App Store", size: (1280, 768), scales: [1]),
    icon(name: "App Icon", size: (400, 240), scales: [1, 2]),
    shelf(name: "Top Shelf Image", width: 1920, role: "top-shelf-image"),
    shelf(name: "Top Shelf Image Wide", width: 2320, role: "top-shelf-image-wide")
]
try json(["info": info, "assets": assets], at: catalog)
print("Generated tvOS layered icons and opaque Top Shelf images from the existing Orbit artwork.")
