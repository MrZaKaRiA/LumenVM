import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = CGRect(x: 75, y: 75, width: 874, height: 874)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)
        NSGradient(starting: NSColor(red: 0.08, green: 0.20, blue: 0.25, alpha: 1), ending: NSColor(red: 0.025, green: 0.065, blue: 0.095, alpha: 1))!.draw(in: tile, angle: -70)
        NSColor(white: 1, alpha: 0.16).setStroke()
        tile.lineWidth = 3
        tile.stroke()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 38, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        func pane(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ start: NSColor, _ end: NSColor) {
            let path = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), xRadius: 45, yRadius: 45)
            NSGradient(starting: start, ending: end)!.draw(in: path, angle: -45)
        }
        pane(232, 253, 166, 518, NSColor(red: 0.73, green: 1, blue: 0.86, alpha: 1), NSColor(red: 0.25, green: 0.76, blue: 0.70, alpha: 1))
        pane(438, 253, 165, 354, NSColor(red: 0.39, green: 0.90, blue: 0.80, alpha: 1), NSColor(red: 0.13, green: 0.61, blue: 0.66, alpha: 1))
        pane(644, 253, 148, 208, NSColor(red: 0.29, green: 0.72, blue: 0.73, alpha: 1), NSColor(red: 0.15, green: 0.43, blue: 0.58, alpha: 1))
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
