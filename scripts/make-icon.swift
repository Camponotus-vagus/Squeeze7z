// Regenerates the Squeeze7z app icon.
//
// The artwork is an Icon Composer document (Liquid Glass, macOS 26+): a solid background colour plus
// flat vector layers that the system renders with glass, specular highlights and shadows. This script is the
// source of the geometry; it writes
//
//   Resources/AppIcon.icon/icon.json + Assets/*.svg   the Icon Composer document
//   Resources/AppIcon.icns                            fallback rendered from the same document
//
// Usage: swift scripts/make-icon.swift [--render-only] [--previews <dir>]
//   --render-only     keep Resources/AppIcon.icon as it is (for example after editing it in
//                     Icon Composer) and only render AppIcon.icns again
//   --previews <dir>  also write PNG previews of every appearance and of the small sizes,
//                     plus a contact sheet (<dir>/sheet.png)
//
// Needs Icon Composer (bundled with Xcode 26 or later) for its ictool, and iconutil.

import CoreGraphics
import Foundation
import ImageIO

struct IconError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Geometry (1024 x 1024 canvas, origin top-left as in SVG)

/// The glyph is one archive drawn three times, each copy smaller than the one behind it and all
/// sharing the bottom-left corner: the original size as a faint pane, an intermediate one, and
/// the squeezed result as the only opaque shape. The bounding box is centred on the canvas.
let glyphLeft = 212.0
let glyphBottom = 812.0
/// Corner radius as a fraction of the side, so the three squares are scaled copies of each other.
let cornerRatio = 0.225

struct Pane {
    let name: String
    let side: Double
    /// Layer opacity; the front pane is opaque.
    let opacity: Double?
    let shadow: Double
    let translucency: Double?
}

/// Back to front, numbered as Icon Composer lists layers.
let panes = [
    Pane(name: "1-original", side: 600, opacity: 0.24, shadow: 0.2, translucency: 0.5),
    Pane(name: "2-smaller", side: 408, opacity: 0.5, shadow: 0.3, translucency: 0.4),
    Pane(name: "3-squeezed", side: 240, opacity: nil, shadow: 0.5, translucency: nil),
]

func fmt(_ value: Double) -> String {
    String(format: "%.1f", value)
}

func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\(body)</svg>\n"
}

/// Layer name -> SVG. Every layer is a plain white silhouette; the colours live in icon.json.
func makeLayers() -> [(name: String, svg: String)] {
    panes.map { pane in
        let radius = fmt(pane.side * cornerRatio)
        let rect = "<rect x=\"\(fmt(glyphLeft))\" y=\"\(fmt(glyphBottom - pane.side))\" width=\"\(fmt(pane.side))\" "
            + "height=\"\(fmt(pane.side))\" rx=\"\(radius)\" ry=\"\(radius)\" fill=\"#fff\"/>"
        return (pane.name, svg(rect))
    }
}

// MARK: - Icon Composer document

func solid(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
    ["solid": String(format: "display-p3:%.5f,%.5f,%.5f,1.00000", r, g, b)]
}

func fills(light: [String: Any], dark: [String: Any]) -> [[String: Any]] {
    [["value": light], ["appearance": "dark", "value": dark]]
}

func makeDocument() -> [String: Any] {
    // Default: white panes on a flat orange. Dark: the same panes in orange on near-black, as the
    // system icons do. The clear and tinted appearances are derived by the system from these.
    let paneFills = fills(light: solid(1, 1, 1), dark: solid(1.00, 0.60, 0.14))
    // Groups are listed front to back; one pane per group, so each gets its own glass and shadow.
    let groups: [[String: Any]] = panes.reversed().map { pane in
        var layer: [String: Any] = [
            "image-name": "\(pane.name).svg",
            "name": pane.name,
            "glass": true,
            "fill-specializations": paneFills,
        ]
        if let opacity = pane.opacity { layer["opacity"] = opacity }
        return [
            "name": pane.name,
            "layers": [layer],
            "shadow": ["kind": "neutral", "opacity": pane.shadow],
            "translucency": ["enabled": pane.translucency != nil, "value": pane.translucency ?? 0],
            "specular": true,
            "lighting": "individual",
        ]
    }
    return [
        "fill-specializations": fills(light: solid(1.00, 0.53, 0.02), dark: solid(0.11, 0.11, 0.12)),
        "groups": groups,
        "supported-platforms": ["squares": ["macOS"]],
    ]
}

func writeDocument(at url: URL) throws {
    let fileManager = FileManager.default
    let assets = url.appendingPathComponent("Assets", isDirectory: true)
    try? fileManager.removeItem(at: url)
    try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
    for (name, text) in makeLayers() {
        try Data(text.utf8).write(to: assets.appendingPathComponent("\(name).svg"))
    }
    let json = try JSONSerialization.data(withJSONObject: makeDocument(), options: [.prettyPrinted, .sortedKeys])
    try (json + Data("\n".utf8)).write(to: url.appendingPathComponent("icon.json"))
}

// MARK: - Rendering

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconError(description: "\(executable) failed (\(process.terminationStatus)): \(output)")
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The `ictool` that exports images lives inside Icon Composer (bundled with Xcode, or installed on
/// its own); the `ictool` on the Xcode tools path is a different program without `--export-image`.
func locateIctool() throws -> String {
    let relative = "Icon Composer.app/Contents/Executables/ictool"
    var candidates: [String] = []
    if let developer = try? run("/usr/bin/xcode-select", ["-p"]) {
        candidates.append(URL(fileURLWithPath: developer).deletingLastPathComponent()
            .appendingPathComponent("Applications/\(relative)").path)
    }
    candidates.append("/Applications/Xcode.app/Contents/Applications/\(relative)")
    candidates.append("/Applications/\(relative)")
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw IconError(description: "ictool not found: install Xcode 26 or later, or Icon Composer")
    }
    return path
}

/// Renders the document as macOS shows it, at `points` x `points` and the given scale.
func render(_ document: URL, to output: URL, ictool: String, rendition: String, points: Int, scale: Int) throws {
    try? FileManager.default.removeItem(at: output)
    try run(ictool, [
        document.path, "--export-image", "--output-file", output.path, "--platform", "macOS",
        "--rendition", rendition, "--width", "\(points)", "--height", "\(points)", "--scale", "\(scale)",
    ])
    guard FileManager.default.fileExists(atPath: output.path) else {
        throw IconError(description: "ictool wrote nothing for \(rendition) \(points)pt@\(scale)x")
    }
}

func renderIcns(from document: URL, to icns: URL, ictool: String) throws {
    let fileManager = FileManager.default
    let work = fileManager.temporaryDirectory.appendingPathComponent("squeeze7z-icon-\(UUID().uuidString)")
    let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: work) }

    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try render(document, to: iconset.appendingPathComponent(name), ictool: ictool,
                       rendition: "Default", points: points, scale: scale)
        }
    }
    try? fileManager.removeItem(at: icns)
    try run("/usr/bin/iconutil", ["-c", "icns", "-o", icns.path, iconset.path])
}

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconError(description: "Cannot read \(url.path)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw IconError(description: "Cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError(description: "Cannot write \(url.path)")
    }
}

/// Writes one PNG per appearance and small size, and a contact sheet that puts them side by side
/// on light and dark backdrops (small sizes also magnified, to judge them pixel by pixel).
func renderPreviews(from document: URL, to directory: URL, ictool: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tile = 320
    let renditions = ["Default", "ClearLight", "TintedLight", "Dark", "ClearDark", "TintedDark"]
    var tiles: [CGImage] = []
    for rendition in renditions {
        let url = directory.appendingPathComponent("\(rendition)-512.png")
        try render(document, to: url, ictool: ictool, rendition: rendition, points: 512, scale: 1)
        tiles.append(try loadImage(url))
    }
    var small: [(points: Int, image: CGImage)] = []
    for points in [16, 32, 64, 128] {
        let url = directory.appendingPathComponent("Default-\(points)@2x.png")
        try render(document, to: url, ictool: ictool, rendition: "Default", points: points, scale: 2)
        small.append((points, try loadImage(url)))
        let single = directory.appendingPathComponent("Default-\(points).png")
        try render(document, to: single, ictool: ictool, rendition: "Default", points: points, scale: 1)
    }

    let pad = 20
    let width = 3 * tile + 4 * pad
    let stripHeight = 288
    let height = 2 * tile + 4 * pad + stripHeight
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError(description: "Cannot create the contact sheet")
    }
    let light = CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    let dark = CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.52, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    for (index, image) in tiles.enumerated() {
        let column = index % 3, row = index / 3
        // CoreGraphics has the origin at the bottom-left: row 0 is drawn at the top.
        let rect = CGRect(x: pad + column * (tile + pad), y: height - pad - (row + 1) * tile - row * pad,
                          width: tile, height: tile)
        ctx.setFillColor(row == 0 ? light : dark)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
    }
    let strip = CGRect(x: pad, y: pad, width: width - 2 * pad, height: stripHeight)
    ctx.setFillColor(light)
    ctx.fill(strip)
    ctx.interpolationQuality = .none
    var x = strip.minX + 16
    // Actual pixels of the @2x renders, then 16 pt and 32 pt magnified with nearest neighbour.
    let magnified = small.prefix(2).enumerated().map { (image: $0.element.image, zoom: $0.offset == 0 ? 6 : 3) }
    for entry in small.map({ (image: $0.image, zoom: 1) }) + magnified {
        let side = CGFloat(entry.image.width * entry.zoom)
        ctx.draw(entry.image, in: CGRect(x: x, y: strip.midY - side / 2, width: side, height: side))
        x += side + 14
    }
    guard let sheet = ctx.makeImage() else { throw IconError(description: "Cannot render the contact sheet") }
    try writePNG(sheet, to: directory.appendingPathComponent("sheet.png"))
}

// MARK: - Main

var renderOnly = false
var previews: URL?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--render-only":
        renderOnly = true
    case "--previews" where !arguments.isEmpty:
        previews = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    default:
        FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift [--render-only] [--previews <dir>]\n".utf8))
        exit(2)
    }
}

do {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let document = root.appendingPathComponent("Resources/AppIcon.icon", isDirectory: true)
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")
    let ictool = try locateIctool()

    if !renderOnly {
        try writeDocument(at: document)
        print("Wrote \(document.path)")
    }
    guard FileManager.default.fileExists(atPath: document.appendingPathComponent("icon.json").path) else {
        throw IconError(description: "Missing \(document.path)")
    }
    try renderIcns(from: document, to: icns, ictool: ictool)
    print("Wrote \(icns.path)")
    if let previews {
        try renderPreviews(from: document, to: previews, ictool: ictool)
        print("Wrote previews to \(previews.path)")
    }
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
