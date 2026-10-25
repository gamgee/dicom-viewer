import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SliceRenderer {
    /// Applies a window/level to a plane and returns an 8-bit image.
    static func render(_ image: PlaneImage, center: Double, width: Double, invert: Bool) -> CGImage? {
        let n = image.width * image.height
        guard n > 0 else { return nil }
        if let rgba = image.rgba {
            return makeImage(rgba, width: image.width, height: image.height, rgba: true)
        }
        let w = max(width, 1)
        let lower = Float(center - w / 2)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        vDSP.add(-lower, image.values, result: &a)
        vDSP.multiply(Float(255 / w), a, result: &b)
        vDSP.clip(b, to: 0...255, result: &a)
        if invert {
            vDSP.multiply(-1, a, result: &b)
            vDSP.add(255, b, result: &a)
        }
        var bytes = [UInt8](repeating: 0, count: n)
        vDSP.convertElements(of: a, to: &bytes, rounding: .towardNearestInteger)
        return makeImage(bytes, width: image.width, height: image.height, rgba: false)
    }

    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int, rgba: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let space = rgba ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
        let info = rgba ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: rgba ? 32 : 8,
                       bytesPerRow: width * (rgba ? 4 : 1), space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
