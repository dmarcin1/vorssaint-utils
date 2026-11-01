// SPDX-License-Identifier: GPL-3.0-or-later
// Uses Google libwebp, the same encoder used by RightSight's WebP coder.
import Accelerate
import CWebP
import CoreGraphics
import Foundation

enum WebPEncoder {
    static func write(_ image: CGImage, to url: URL, quality: Double) throws {
        let width = image.width, height = image.height, stride = image.width * 4
        guard width > 0, height > 0, width <= 16383, height <= 16383 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * height)
        defer { pixels.deallocate() }
        guard let context = CGContext(data: pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var source = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: stride)
        var destination = source
        guard vImageUnpremultiplyData_RGBA8888(&source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw CocoaError(.fileWriteUnknown)
        }
        var output: UnsafeMutablePointer<UInt8>?
        let count = WebPEncodeRGBA(pixels, Int32(width), Int32(height), Int32(stride), Float(min(1, max(0, quality)) * 100), &output)
        guard count > 0, let output else { throw CocoaError(.fileWriteUnknown) }
        defer { WebPFree(output) }
        try Data(bytes: output, count: count).write(to: url, options: .atomic)
    }
}
