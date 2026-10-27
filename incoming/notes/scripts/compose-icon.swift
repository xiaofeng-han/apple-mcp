// Composes Resources/AppIcon.icon/Assets/artwork.png from the Apple Reminders MCP artwork, so the
// two apps look like a pair: the same robot and ruled lines, on a Notes page with a yellow header.
//
//   swift scripts/compose-icon.swift ../apple-reminders-mcp/Resources/AppIcon.icon/Assets/artwork.png \
//       Resources/AppIcon.icon/Assets/artwork.png && scripts/build-icon.sh
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let source = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func bitmap() -> [UInt8] { [UInt8](repeating: 0, count: size * size * 4) }
var original = bitmap()
CGContext(data: &original, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
// Row 0 is the top of the image in these buffers.
func pixel(_ b: [UInt8], _ x: Int, _ y: Int) -> (Double, Double, Double) {
    let i = (y * size + x) * 4
    return (Double(b[i]), Double(b[i + 1]), Double(b[i + 2]))
}
func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
}
let paper = (243.0, 247.0, 249.0), lineColor = (172.0, 177.0, 186.0)

var out = bitmap()
func put(_ x: Int, _ y: Int, _ c: (Double, Double, Double), _ alpha: Double = 1) {
    guard x >= 0, y >= 0, x < size, y < size else { return }
    let i = (y * size + x) * 4
    for (k, v) in [c.0, c.1, c.2].enumerated() { out[i + k] = UInt8(max(0, min(255, (v * alpha + Double(out[i + k]) * (1 - alpha)).rounded()))) }
    out[i + 3] = 255
}
for y in 0..<size { for x in 0..<size { put(x, y, paper) } }

// The yellow header, with a darker edge and a soft shadow onto the page.
let band = 250
for y in 0..<band {
    let t = Double(y) / Double(band)
    for x in 0..<size { put(x, y, (255, 216 - 22 * t, 84 - 44 * t)) }
}
for y in band..<(band + 3) { for x in 0..<size { put(x, y, (226, 172, 28)) } }
for y in (band + 3)..<(band + 24) {
    let a = 0.14 * (1 - Double(y - band - 3) / 21)
    for x in 0..<size { put(x, y, (120, 110, 80), a) }
}

// Ruled lines, built from the first line of the original (with its bevel): its left cap, its
// middle stretched, its right cap.
let lineTop = 225, lineBottom = 292, left = 372, right = 932, capWidth = 34
func drawLine(top: Int, from x0: Int, to x1: Int) {
    for dy in 0..<(lineBottom - lineTop) {
        for x in x0..<x1 {
            let sx: Int
            if x - x0 < capWidth { sx = left + (x - x0) } else if x1 - x <= capWidth { sx = right - (x1 - x) } else { sx = (left + right) / 2 }
            let c = pixel(original, sx, lineTop + dy)
            let alpha = min(1, distance(c, paper) / 12)
            put(x, top + dy, c, alpha)
        }
    }
}
// Line bodies start 6 rows into the sprite; the second sits where the original's second line is.
// Lines below the antenna stop short of the robot, which sits on plain paper as in the original.
for body in [349, 481] { drawLine(top: body - 6, from: 102, to: right) }
for body in [613, 745, 877] { drawLine(top: body - 6, from: 102, to: 302) }

// The robot: its silhouette (pixels clearly unlike the page) with the holes filled, so its
// highlights stay; outside it only a little shadow close by, never the light halo around it.
let x0 = 330, x1 = 952, y0 = 440, y1 = 948
let width = x1 - x0, height = y1 - y0
var core = [Bool](repeating: false, count: width * height)
for y in y0..<y1 { for x in x0..<x1 {
    let c = pixel(original, x, y)
    var strong = distance(c, paper) > 45
    // The original's second line (and its anti-aliased edge) runs behind the antenna; it is not
    // the robot, which is blue, cyan or dark.
    let spread = max(c.0, c.1, c.2) - min(c.0, c.1, c.2), light = (c.0 + c.1 + c.2) / 3
    if (470...546).contains(y), spread < 30, light > 120 { strong = false }
    core[(y - y0) * width + (x - x0)] = strong
} }
var outside = [Bool](repeating: false, count: width * height)
var stack: [(Int, Int)] = []
for x in 0..<width { stack += [(x, 0), (x, height - 1)] }
for y in 0..<height { stack += [(0, y), (width - 1, y)] }
while let (x, y) = stack.popLast() {
    guard x >= 0, y >= 0, x < width, y < height else { continue }
    let i = y * width + x
    if outside[i] || core[i] { continue }
    outside[i] = true
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}
func near(_ x: Int, _ y: Int, _ r: Int) -> Bool {
    for dy in -r...r { for dx in -r...r {
        let xx = x + dx, yy = y + dy
        if xx >= 0, yy >= 0, xx < width, yy < height, !outside[yy * width + xx] { return true }
    } }
    return false
}
for y in 0..<height { for x in 0..<width {
    let c = pixel(original, x + x0, y + y0)
    let i = y * width + x
    if !outside[i] {
        put(x + x0, y + y0, c)
    } else if near(x, y, 3) {
        // Anti-aliased edge: as much robot as it differs from the page.
        let alpha = min(1, max(0, (distance(c, paper) - 8) / 37))
        let spread = max(c.0, c.1, c.2) - min(c.0, c.1, c.2), light = (c.0 + c.1 + c.2) / 3
        if (470...546).contains(y + y0), spread < 30, light > 120 { continue }
        if alpha > 0 { put(x + x0, y + y0, c, alpha) }
    }
} }

let context = CGContext(data: &out, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output.path)")
