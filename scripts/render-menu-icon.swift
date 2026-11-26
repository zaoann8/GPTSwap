import AppKit
import Foundation

// Reuse the exact three GPT paths from the app icon. Only the ceramic plate,
// gradients and shadows are omitted for the monochrome menu-bar template.
final class IconPaths: NSObject, XMLParserDelegate {
    var paths: [[String: String]] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "path" { paths.append(attributes) }
    }
}

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let parser = XMLParser(contentsOf: project.appendingPathComponent("assets/AppIcon.svg"))!
let paths = IconPaths()
parser.delegate = paths
guard parser.parse(), paths.paths.count == 3 else { fatalError("Expected the three app-icon paths") }

func image(for path: [String: String], stroke: Bool = false) -> NSImage {
    let outline = stroke ? "stroke=\"black\" stroke-width=\"2.1\" stroke-linejoin=\"round\"" : ""
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="90 90 330 330">
      <path d="\(path["d"]!)" transform="\(path["transform"]!)" fill="black" \(outline)/>
    </svg>
    """
    guard let image = NSImage(data: Data(svg.utf8)) else { fatalError("Cannot render SVG path") }
    return image
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let bounds = NSRect(x: 0, y: 0, width: 256, height: 256)
image(for: paths.paths[0]).draw(in: bounds)
image(for: paths.paths[1], stroke: true).draw(in: bounds, from: .zero, operation: .destinationOut, fraction: 1)
image(for: paths.paths[2]).draw(in: bounds)
NSGraphicsContext.restoreGraphicsState()
let destination = project.appendingPathComponent("Sources/CodexAccountSwitcher/Resources/menu-icon-template.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print(destination.path)

if CommandLine.arguments.contains("--preview") {
    let preview = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: preview)!
    let cg = graphics.cgContext
    for (index, dark) in [false, true].enumerated() {
        let panel = CGRect(x: index * 128, y: 0, width: 128, height: 128)
        cg.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
        cg.fill(panel)
        cg.saveGState()
        cg.clip(to: panel.insetBy(dx: 8, dy: 8), mask: bitmap.cgImage!)
        cg.setFillColor((dark ? NSColor.white : NSColor.black).cgColor)
        cg.fill(panel)
        cg.restoreGState()
    }
    try preview.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: "/tmp/gptswap-menu-icon-preview.png")
    )
}
