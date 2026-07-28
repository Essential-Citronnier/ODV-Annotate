// AnnotationMaskImage.swift
// OpenDicomViewer
//
// Rasterizes a decoded plugin mask into a tinted CGImage cropped to its
// bounding box.
//
// SwiftUI re-evaluates an annotation's body on every pan, zoom, and window
// change, so rasterizing per draw would allocate a full-slice buffer many times
// a second during interaction. The results are cached by mask content instead.
// Licensed under the MIT License. See LICENSE for details.

import CoreGraphics
import Foundation

enum AnnotationMaskImage {

    /// Bounded LRU of rendered masks. A handful of masks are visible at once;
    /// the cap exists so a long prompting session cannot grow without limit.
    private static let cacheLimit = 16
    private static var cache: [Int: CGImage] = [:]
    private static var order: [Int] = []
    private static let lock = NSLock()

    /// Tint applied to foreground pixels, matching the mint stroke the
    /// annotation layer draws around the mask.
    private static let tint: (r: UInt8, g: UInt8, b: UInt8) = (0x3D, 0xDC, 0xB4)

    /// Rasterize the foreground of `mask` into an image cropped to its tight
    /// bounding box, or nil when the mask is empty or malformed.
    static func cgImage(mask: [Bool], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }

        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        // Hashing the run boundaries rather than every pixel keeps the lookup
        // cheap for full-slice masks while still distinguishing shapes.
        var previous = false
        for (index, value) in mask.enumerated() where value != previous {
            hasher.combine(index)
            previous = value
        }
        let key = hasher.finalize()

        lock.lock()
        if let cached = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let image = rasterize(mask: mask, width: width, height: height) else {
            return nil
        }

        lock.lock()
        cache[key] = image
        order.append(key)
        while order.count > cacheLimit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
        lock.unlock()

        return image
    }

    private static func rasterize(mask: [Bool], width: Int, height: Int) -> CGImage? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        var pixels = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)

        for y in 0..<cropHeight {
            let sourceRow = (y + minY) * width + minX
            let destinationRow = y * cropWidth * 4
            for x in 0..<cropWidth where mask[sourceRow + x] {
                let offset = destinationRow + x * 4
                pixels[offset] = tint.r
                pixels[offset + 1] = tint.g
                pixels[offset + 2] = tint.b
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: cropWidth,
                       height: cropHeight,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: cropWidth * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
