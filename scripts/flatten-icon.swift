// Turns an icon drawn as a rounded white square on a transparent canvas into the full-bleed,
// opaque 1024px artwork macOS wants (it masks the square to its own shape itself; an icon that is
// transparent around its own shape is shown shrunk inside a grey tile).
//
//   swift scripts/flatten-icon.swift <source.png> Resources/<App>/AppIcon.icon/Assets/artwork.png [trim]
//
// It finds the square, crops the largest centred square inside it, minus `trim` source pixels
// (default 14) so the drawn rim stays out of sight, and fills what is left of the drawn corners
// with the square's own colour. Then run scripts/build-icon.sh notes|reminders.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]),
      let bitmap = source.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
    fputs("usage: swift flatten-icon.swift <source.png> <artwork.png> [trim]\n", stderr)
    exit(2)
}
let trim = CGFloat(args.count > 3 ? Double(args[3]) ?? 14 : 14)
let width = bitmap.pixelsWide, height = bitmap.pixelsHigh

// Rows and columns through the plain part of the square, clear of its corners.
func opaque(_ x: Int, _ y: Int) -> Bool { (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 }
let row = height * 2 / 5, column = width / 3
guard let left = (0..<width).first(where: { opaque($0, row) }),
      let right = (0..<width).reversed().first(where: { opaque($0, row) }),
      let top = (0..<height).first(where: { opaque(column, $0) }),
      let bottom = (0..<height).reversed().first(where: { opaque(column, $0) }) else {
    fputs("no opaque square found\n", stderr)
    exit(1)
}
let fill = bitmap.colorAt(x: (left + right) / 2, y: top + 60)!.usingColorSpace(.deviceRGB)!.withAlphaComponent(1)
let side = CGFloat(min(right - left + 1, bottom - top + 1)) - 2 * trim
let crop = NSRect(x: CGFloat(left + right + 1) / 2 - side / 2, y: CGFloat(top + bottom + 1) / 2 - side / 2,
                  width: side, height: side)   // from the top-left, like the pixel loops above

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current!.imageInterpolation = .high
fill.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let scale = 1024 / side
source.draw(in: NSRect(x: -crop.minX * scale, y: -(CGFloat(height) - crop.maxY) * scale,
                       width: CGFloat(width) * scale, height: CGFloat(height) * scale))
NSGraphicsContext.restoreGraphicsState()
// The source's "opaque" pixels are often a little short of full alpha; macOS wants none.
for y in 0..<1024 {
    for x in 0..<1024 where out.colorAt(x: x, y: y)!.alphaComponent < 1 {
        out.setColor(out.colorAt(x: x, y: y)!.withAlphaComponent(1), atX: x, y: y)
    }
}
try out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
let c = fill.usingColorSpace(.sRGB)!
print(String(format: "square %d...%d x %d...%d; wrote %@; fill srgb:%.5f,%.5f,%.5f,1.00000 (icon.json)",
             left, right, top, bottom, args[2], c.redComponent, c.greenComponent, c.blueComponent))
