import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Decoded frames of one DICOM object. Grayscale data is stored rescaled (e.g. Hounsfield units),
/// color data as RGBA8.
struct DecodedPixels {
    let width: Int
    let height: Int
    let frames: Int
    var values: [Float]?
    var rgba: [UInt8]?
    let monochrome1: Bool
}

enum PixelDecoder {
    static func decode(_ ds: DicomDataset) throws -> DecodedPixels {
        guard let rows = ds.int(.rows), let cols = ds.int(.columns), rows > 0, cols > 0,
              let pixelElement = ds.elements[.pixelData] else { throw DicomError.noPixelData }
        let samples = ds.int(.samplesPerPixel) ?? 1
        let bitsAllocated = ds.int(.bitsAllocated) ?? 16
        let bitsStored = ds.int(.bitsStored) ?? bitsAllocated
        let signed = (ds.int(.pixelRepresentation) ?? 0) == 1
        let frames = max(1, ds.int(.numberOfFrames) ?? 1)
        let photometric = ds.string(.photometricInterpretation) ?? (samples == 3 ? "RGB" : "MONOCHROME2")
        let slope = Float(ds.double(.rescaleSlope) ?? 1)
        let intercept = Float(ds.double(.rescaleIntercept) ?? 0)
        let monochrome1 = photometric == "MONOCHROME1"

        var result: DecodedPixels
        if ds.isEncapsulated {
            result = try decodeEncapsulated(ds, width: cols, height: rows, samples: samples, frames: frames,
                                            monochrome1: monochrome1)
        } else if samples == 1 {
            let values = try unpackGray(ds, offset: pixelElement.offset, length: pixelElement.length,
                                        count: rows * cols * frames, bitsAllocated: bitsAllocated,
                                        bitsStored: bitsStored, signed: signed)
            result = DecodedPixels(width: cols, height: rows, frames: frames, values: values, monochrome1: monochrome1)
        } else if samples == 3, bitsAllocated == 8 {
            let planar = (ds.int(.planarConfiguration) ?? 0) == 1
            let rgba = unpackRGB(ds.bytes, offset: pixelElement.offset, length: pixelElement.length,
                                 pixelsPerFrame: rows * cols, frames: frames, planar: planar)
            result = DecodedPixels(width: cols, height: rows, frames: frames, rgba: rgba, monochrome1: false)
        } else {
            throw DicomError.unsupportedPixelFormat("\(samples) samples × \(bitsAllocated) bit")
        }

        if var values = result.values, slope != 1 || intercept != 0 {
            vDSP.multiply(slope, values, result: &values)
            vDSP.add(intercept, values, result: &values)
            result.values = values
        }
        return result
    }

    private static func unpackGray(_ ds: DicomDataset, offset: Int, length: Int, count: Int,
                                   bitsAllocated: Int, bitsStored: Int, signed: Bool) throws -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let bytesPerSample = bitsAllocated / 8
        guard [1, 2, 4].contains(bytesPerSample) else {
            throw DicomError.unsupportedPixelFormat("\(bitsAllocated) bits allocated")
        }
        let available = min(count, max(0, min(length, ds.bytes.count - offset)) / bytesPerSample)
        let little = ds.reader.littleEndian
        let shift = bitsAllocated - min(bitsStored, bitsAllocated)

        ds.bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let b = src.baseAddress! + offset
                switch bytesPerSample {
                case 1:
                    for i in 0..<available {
                        dst[i] = signed ? Float(Int8(bitPattern: b[i])) : Float(b[i])
                    }
                case 2:
                    for i in 0..<available {
                        let lo = UInt16(b[2 * i]), hi = UInt16(b[2 * i + 1])
                        let raw = little ? lo | hi << 8 : lo << 8 | hi
                        if signed {
                            dst[i] = Float(Int16(bitPattern: raw << UInt16(shift)) >> Int16(shift))
                        } else {
                            dst[i] = Float(raw & (0xFFFF >> UInt16(shift)))
                        }
                    }
                default:
                    for i in 0..<available {
                        let p = b + 4 * i
                        let raw = little
                            ? UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
                            : UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
                        dst[i] = signed ? Float(Int32(bitPattern: raw)) : Float(raw)
                    }
                }
            }
        }
        return out
    }

    private static func unpackRGB(_ bytes: [UInt8], offset: Int, length: Int, pixelsPerFrame: Int,
                                  frames: Int, planar: Bool) -> [UInt8] {
        let total = pixelsPerFrame * frames
        var out = [UInt8](repeating: 255, count: total * 4)
        let available = min(length, bytes.count - offset)
        for f in 0..<frames {
            let frameBase = offset + f * pixelsPerFrame * 3
            for i in 0..<pixelsPerFrame {
                let o = (f * pixelsPerFrame + i) * 4
                for c in 0..<3 {
                    let s = planar ? frameBase + c * pixelsPerFrame + i : frameBase + i * 3 + c
                    if s - offset < available { out[o + c] = bytes[s] }
                }
            }
        }
        return out
    }

    /// Compressed transfer syntaxes are decoded with ImageIO (JPEG baseline/extended, JPEG 2000).
    private static func decodeEncapsulated(_ ds: DicomDataset, width: Int, height: Int, samples: Int,
                                           frames: Int, monochrome1: Bool) throws -> DecodedPixels {
        let frameData: [Data]
        if ds.fragments.count == frames {
            frameData = ds.fragments.map { Data(ds.bytes[$0]) }
        } else if frames == 1 {
            frameData = [ds.fragments.reduce(into: Data()) { $0.append(contentsOf: ds.bytes[$1]) }]
        } else {
            throw DicomError.unsupportedTransferSyntax(ds.transferSyntax)
        }

        let n = width * height
        var values = samples == 1 ? [Float](repeating: 0, count: n * frames) : nil
        var rgba = samples == 1 ? nil : [UInt8](repeating: 0, count: n * frames * 4)

        for (f, data) in frameData.enumerated() {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == width, image.height == height else {
                throw DicomError.unsupportedTransferSyntax(ds.transferSyntax)
            }
            if samples == 1 {
                guard let raw = image.dataProvider?.data as Data? else { throw DicomError.noPixelData }
                let bpc = image.bitsPerComponent, bpp = image.bitsPerPixel, stride = image.bytesPerRow
                let little = image.bitmapInfo.contains(.byteOrder16Little)
                raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    for y in 0..<height {
                        for x in 0..<width {
                            let p = y * stride + x * (bpp / 8)
                            let v: Float
                            if bpc == 16 {
                                let a = UInt16(buf[p]), b = UInt16(buf[p + 1])
                                v = Float(little ? a | b << 8 : a << 8 | b)
                            } else {
                                v = Float(buf[p])
                            }
                            values![f * n + y * width + x] = v
                        }
                    }
                }
            } else {
                var frame = [UInt8](repeating: 0, count: n * 4)
                frame.withUnsafeMutableBytes { buf in
                    let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                rgba!.replaceSubrange((f * n * 4)..<((f + 1) * n * 4), with: frame)
            }
        }
        return DecodedPixels(width: width, height: height, frames: frames, values: values, rgba: rgba,
                             monochrome1: monochrome1)
    }
}
