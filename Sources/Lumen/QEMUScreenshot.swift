import AppKit
import Foundation

enum QEMUScreenshot {
    /// QEMU's default screendump is a binary P6 image with RGB samples.
    static func png(fromPPM data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var index = 0
        func isWhitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        func token() -> String? {
            while index < bytes.count {
                if isWhitespace(bytes[index]) { index += 1; continue }
                if bytes[index] == 35 {
                    while index < bytes.count, bytes[index] != 10 { index += 1 }
                    continue
                }
                break
            }
            let start = index
            while index < bytes.count, !isWhitespace(bytes[index]) { index += 1 }
            return start < index ? String(bytes: bytes[start..<index], encoding: .ascii) : nil
        }
        guard token() == "P6", let widthText = token(), let width = Int(widthText),
              let heightText = token(), let height = Int(heightText), token() == "255",
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 64_000_000, index < bytes.count, isWhitespace(bytes[index]) else {
            throw ScreenshotError.invalidPPM
        }
        let delimiter = bytes[index]
        index += 1
        if delimiter == 13, index < bytes.count, bytes[index] == 10 { index += 1 }
        let count = width * height * 3
        guard bytes.count - index == count,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: width * 3, bitsPerPixel: 24),
              let target = bitmap.bitmapData else { throw ScreenshotError.invalidPPM }
        bytes.withUnsafeBytes { pointer in
            target.update(from: pointer.baseAddress!.advanced(by: index).assumingMemoryBound(to: UInt8.self), count: count)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ScreenshotError.invalidPPM }
        return png
    }

    private enum ScreenshotError: LocalizedError {
        case invalidPPM
        var errorDescription: String? { "The QEMU framebuffer capture could not be decoded." }
    }
}
