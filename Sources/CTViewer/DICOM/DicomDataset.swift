import Foundation

struct DicomTag: Hashable, Comparable, CustomStringConvertible, Sendable {
    let group: UInt16
    let element: UInt16

    init(_ group: UInt16, _ element: UInt16) {
        self.group = group
        self.element = element
    }

    static func < (a: DicomTag, b: DicomTag) -> Bool { (a.group, a.element) < (b.group, b.element) }
    var description: String { String(format: "(%04X,%04X)", group, element) }

    static let transferSyntaxUID = DicomTag(0x0002, 0x0010)
    static let specificCharacterSet = DicomTag(0x0008, 0x0005)
    static let sopClassUID = DicomTag(0x0008, 0x0016)
    static let studyDate = DicomTag(0x0008, 0x0020)
    static let accessionNumber = DicomTag(0x0008, 0x0050)
    static let modality = DicomTag(0x0008, 0x0060)
    static let manufacturer = DicomTag(0x0008, 0x0070)
    static let institutionName = DicomTag(0x0008, 0x0080)
    static let studyDescription = DicomTag(0x0008, 0x1030)
    static let seriesDescription = DicomTag(0x0008, 0x103E)
    static let patientName = DicomTag(0x0010, 0x0010)
    static let patientID = DicomTag(0x0010, 0x0020)
    static let patientBirthDate = DicomTag(0x0010, 0x0030)
    static let patientSex = DicomTag(0x0010, 0x0040)
    static let patientAge = DicomTag(0x0010, 0x1010)
    static let bodyPartExamined = DicomTag(0x0018, 0x0015)
    static let sliceThickness = DicomTag(0x0018, 0x0050)
    static let spacingBetweenSlices = DicomTag(0x0018, 0x0088)
    static let imagerPixelSpacing = DicomTag(0x0018, 0x1164)
    static let studyInstanceUID = DicomTag(0x0020, 0x000D)
    static let seriesInstanceUID = DicomTag(0x0020, 0x000E)
    static let seriesNumber = DicomTag(0x0020, 0x0011)
    static let instanceNumber = DicomTag(0x0020, 0x0013)
    static let imagePosition = DicomTag(0x0020, 0x0032)
    static let imageOrientation = DicomTag(0x0020, 0x0037)
    static let samplesPerPixel = DicomTag(0x0028, 0x0002)
    static let photometricInterpretation = DicomTag(0x0028, 0x0004)
    static let planarConfiguration = DicomTag(0x0028, 0x0006)
    static let numberOfFrames = DicomTag(0x0028, 0x0008)
    static let rows = DicomTag(0x0028, 0x0010)
    static let columns = DicomTag(0x0028, 0x0011)
    static let pixelSpacing = DicomTag(0x0028, 0x0030)
    static let bitsAllocated = DicomTag(0x0028, 0x0100)
    static let bitsStored = DicomTag(0x0028, 0x0101)
    static let pixelRepresentation = DicomTag(0x0028, 0x0103)
    static let windowCenter = DicomTag(0x0028, 0x1050)
    static let windowWidth = DicomTag(0x0028, 0x1051)
    static let rescaleIntercept = DicomTag(0x0028, 0x1052)
    static let rescaleSlope = DicomTag(0x0028, 0x1053)
    static let pixelData = DicomTag(0x7FE0, 0x0010)
}

struct DicomElement: Sendable {
    let tag: DicomTag
    let vr: String
    /// Offset of the value bytes in the file.
    let offset: Int
    let length: Int
    var itemCount = 0
}

enum DicomError: LocalizedError {
    case notDicom
    case unsupportedTransferSyntax(String)
    case noPixelData
    case unsupportedPixelFormat(String)

    var errorDescription: String? {
        switch self {
        case .notDicom: "Not a DICOM file"
        case .unsupportedTransferSyntax(let uid): "Unsupported transfer syntax \(uid)"
        case .noPixelData: "No image data"
        case .unsupportedPixelFormat(let detail): "Unsupported pixel format: \(detail)"
        }
    }
}

struct ByteReader {
    let bytes: [UInt8]
    let littleEndian: Bool

    func u16(_ p: Int) -> UInt16 {
        littleEndian
            ? UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8
            : UInt16(bytes[p]) << 8 | UInt16(bytes[p + 1])
    }

    func u32(_ p: Int) -> UInt32 {
        let b0 = UInt32(bytes[p]), b1 = UInt32(bytes[p + 1]), b2 = UInt32(bytes[p + 2]), b3 = UInt32(bytes[p + 3])
        return littleEndian ? b0 | b1 << 8 | b2 << 16 | b3 << 24 : b0 << 24 | b1 << 16 | b2 << 8 | b3
    }

    func u64(_ p: Int) -> UInt64 {
        let lo = UInt64(u32(p)), hi = UInt64(u32(p + 4))
        return littleEndian ? lo | hi << 32 : lo << 32 | hi
    }
}

/// A parsed DICOM Part 10 file (or raw dataset). Only top-level elements are indexed;
/// sequences are walked so their extent is known but their contents are not kept.
struct DicomDataset {
    static let implicitLittle = "1.2.840.10008.1.2"
    static let explicitLittle = "1.2.840.10008.1.2.1"
    static let explicitBig = "1.2.840.10008.1.2.2"
    static let deflated = "1.2.840.10008.1.2.1.99"

    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]

    let bytes: [UInt8]
    private(set) var elements: [DicomTag: DicomElement] = [:]
    private(set) var transferSyntax = implicitLittle
    private(set) var fragments: [Range<Int>] = []
    private(set) var reader: ByteReader
    private(set) var textEncoding: String.Encoding = .isoLatin1

    var isEncapsulated: Bool { !fragments.isEmpty }

    init(url: URL) throws {
        try self.init(bytes: [UInt8](try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        reader = ByteReader(bytes: bytes, littleEndian: true)
        var pos = 0

        if bytes.count >= 132, bytes[128] == 0x44, bytes[129] == 0x49, bytes[130] == 0x43, bytes[131] == 0x4D {
            pos = 132
            var meta: [DicomTag: DicomElement] = [:]
            var unused: [Range<Int>] = []
            pos = Self.parse(reader, from: pos, to: bytes.count, explicit: true, store: &meta,
                             fragments: &unused, inItem: false, stopAfterGroup2: true)
            elements = meta
            if let ts = string(.transferSyntaxUID) { transferSyntax = ts }
        } else {
            // Raw dataset without preamble: sniff the first element.
            guard bytes.count > 8 else { throw DicomError.notDicom }
            let group = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            guard [0x0002, 0x0008, 0x0010, 0x0018, 0x0020, 0x0028].contains(group) else { throw DicomError.notDicom }
            let isUpper = { (b: UInt8) in (0x41...0x5A).contains(b) }
            if isUpper(bytes[4]), isUpper(bytes[5]) { transferSyntax = Self.explicitLittle }
        }

        switch transferSyntax {
        case Self.deflated:
            throw DicomError.unsupportedTransferSyntax(transferSyntax)
        case Self.explicitBig:
            reader = ByteReader(bytes: bytes, littleEndian: false)
        default:
            break
        }
        let explicit = transferSyntax != Self.implicitLittle

        var dataset = elements
        var frags: [Range<Int>] = []
        _ = Self.parse(reader, from: pos, to: bytes.count, explicit: explicit, store: &dataset,
                       fragments: &frags, inItem: false, stopAfterGroup2: false)
        elements = dataset
        fragments = frags
        if let charset = string(.specificCharacterSet), charset.contains("ISO_IR 192") {
            textEncoding = .utf8
        }
    }

    /// Walks elements in `start..<end`. Nested items are parsed with `store` disabled.
    private static func parse(_ r: ByteReader, from start: Int, to end: Int, explicit: Bool,
                              store: inout [DicomTag: DicomElement], fragments: inout [Range<Int>],
                              inItem: Bool, stopAfterGroup2: Bool, keep: Bool = true) -> Int {
        var p = start
        while p + 8 <= end {
            // The file meta group is always explicit little endian.
            let metaReader = ByteReader(bytes: r.bytes, littleEndian: true)
            let group = stopAfterGroup2 ? metaReader.u16(p) : r.u16(p)
            if stopAfterGroup2, group != 0x0002 { return p }
            let rr = stopAfterGroup2 ? metaReader : r
            let tag = DicomTag(group, rr.u16(p + 2))

            if group == 0xFFFE {
                let len = rr.u32(p + 4)
                p += 8
                if tag.element == 0xE00D || tag.element == 0xE0DD { return p }
                if len != 0xFFFF_FFFF { p += Int(len) }
                continue
            }

            let vr: String
            let length: UInt32
            let headerLength: Int
            if explicit || stopAfterGroup2 {
                let c0 = r.bytes[p + 4], c1 = r.bytes[p + 5]
                guard (0x41...0x5A).contains(c0), (0x41...0x5A).contains(c1) else { return end }
                vr = String(decoding: [c0, c1], as: UTF8.self)
                if longVRs.contains(vr) {
                    guard p + 12 <= end else { return end }
                    length = rr.u32(p + 8)
                    headerLength = 12
                } else {
                    length = UInt32(rr.u16(p + 6))
                    headerLength = 8
                }
            } else {
                vr = DicomDictionary.vr(for: tag) ?? "UN"
                length = rr.u32(p + 4)
                headerLength = 8
            }
            let valueStart = p + headerLength
            var element: DicomElement

            if length == 0xFFFF_FFFF {
                if tag == .pixelData {
                    var q = valueStart
                    var first = true
                    let le = ByteReader(bytes: r.bytes, littleEndian: true)
                    while q + 8 <= end {
                        let g = le.u16(q), e = le.u16(q + 2), l = Int(le.u32(q + 4))
                        q += 8
                        if g == 0xFFFE, e == 0xE0DD { break }
                        guard g == 0xFFFE, e == 0xE000, q + l <= end else { break }
                        if first { first = false } else if keep { fragments.append(q..<(q + l)) }
                        q += l
                    }
                    element = DicomElement(tag: tag, vr: "OB", offset: valueStart, length: q - valueStart)
                    p = q
                } else {
                    // Sequence (or UN) of undefined length.
                    let nestedExplicit = vr == "UN" ? false : explicit
                    let (q, count) = walkItems(r, from: valueStart, to: end, explicit: nestedExplicit, defined: false)
                    element = DicomElement(tag: tag, vr: vr == "UN" ? "SQ" : vr, offset: valueStart,
                                           length: q - valueStart, itemCount: count)
                    p = q
                }
            } else {
                var len = Int(length)
                if valueStart + len > end {
                    // Truncated file: keep whatever pixel data exists, stop otherwise.
                    guard tag == .pixelData else { return end }
                    len = end - valueStart
                }
                element = DicomElement(tag: tag, vr: vr, offset: valueStart, length: len)
                if vr == "SQ" {
                    element.itemCount = walkItems(r, from: valueStart, to: valueStart + len,
                                                  explicit: explicit, defined: true).1
                }
                p = valueStart + len
            }
            if keep, !inItem { store[tag] = element }
        }
        return p
    }

    private static func walkItems(_ r: ByteReader, from start: Int, to end: Int, explicit: Bool,
                                  defined: Bool) -> (Int, Int) {
        var q = start
        var count = 0
        var scratch: [DicomTag: DicomElement] = [:]
        var noFragments: [Range<Int>] = []
        while q + 8 <= end {
            let g = r.u16(q), e = r.u16(q + 2), l = r.u32(q + 4)
            q += 8
            if g == 0xFFFE, e == 0xE0DD { break }
            guard g == 0xFFFE, e == 0xE000 else { return (end, count) }
            count += 1
            if l == 0xFFFF_FFFF {
                q = parse(r, from: q, to: end, explicit: explicit, store: &scratch, fragments: &noFragments,
                          inItem: true, stopAfterGroup2: false, keep: false)
            } else {
                q += Int(l)
            }
        }
        return (min(q, end), count)
    }

    // MARK: - Value access

    func contains(_ tag: DicomTag) -> Bool { elements[tag] != nil }

    func string(_ tag: DicomTag) -> String? {
        guard let e = elements[tag], e.length > 0, e.offset + e.length <= bytes.count else { return nil }
        let slice = bytes[e.offset..<(e.offset + e.length)]
        let s = String(bytes: slice, encoding: textEncoding) ?? String(decoding: slice, as: UTF8.self)
        let trimmed = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    func strings(_ tag: DicomTag) -> [String] {
        guard let s = string(tag) else { return [] }
        return s.split(separator: "\\", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func numbers(_ tag: DicomTag) -> [Double] {
        guard let e = elements[tag], e.offset + e.length <= bytes.count else { return [] }
        let end = e.offset + e.length
        switch e.vr {
        case "US": return stride(from: e.offset, to: end - 1, by: 2).map { Double(reader.u16($0)) }
        case "SS": return stride(from: e.offset, to: end - 1, by: 2).map { Double(Int16(bitPattern: reader.u16($0))) }
        case "UL": return stride(from: e.offset, to: end - 3, by: 4).map { Double(reader.u32($0)) }
        case "SL": return stride(from: e.offset, to: end - 3, by: 4).map { Double(Int32(bitPattern: reader.u32($0))) }
        case "FL": return stride(from: e.offset, to: end - 3, by: 4).map { Double(Float(bitPattern: reader.u32($0))) }
        case "FD": return stride(from: e.offset, to: end - 7, by: 8).map { Double(bitPattern: reader.u64($0)) }
        default: return strings(tag).compactMap { Double($0) }
        }
    }

    func double(_ tag: DicomTag) -> Double? { numbers(tag).first }
    func int(_ tag: DicomTag) -> Int? { numbers(tag).first.map { Int($0) } }

    func displayValue(_ e: DicomElement) -> String {
        if e.tag == .pixelData {
            return isEncapsulated
                ? "Compressed pixel data · \(fragments.count) fragment(s)"
                : "Pixel data · \(e.length.formatted()) bytes"
        }
        switch e.vr {
        case "SQ":
            return "Sequence · \(e.itemCount) item\(e.itemCount == 1 ? "" : "s")"
        case "US", "SS", "UL", "SL", "FL", "FD":
            let values = numbers(e.tag)
            let shown = values.prefix(12).map { $0.rounded() == $0 ? String(Int($0)) : String(format: "%g", $0) }
            return shown.joined(separator: " \\ ") + (values.count > 12 ? " …" : "")
        case "OB", "OW", "OF", "OD", "OL", "OV":
            return "\(e.length.formatted()) bytes binary"
        case "UN":
            let slice = bytes[e.offset..<min(e.offset + e.length, bytes.count)]
            if !slice.isEmpty, slice.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0 }) {
                return string(e.tag) ?? ""
            }
            return "\(e.length.formatted()) bytes binary"
        default:
            let s = string(e.tag) ?? ""
            return s.count > 200 ? String(s.prefix(200)) + "…" : s
        }
    }
}
