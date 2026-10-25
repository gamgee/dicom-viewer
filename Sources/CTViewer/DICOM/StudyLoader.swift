import Foundation
import simd

/// One decoded DICOM image file, detached from its raw bytes.
struct LoadedSlice: @unchecked Sendable {
    let url: URL
    let seriesKey: String
    let seriesNumber: Int?
    let seriesDescription: String?
    let modality: String
    let patient: PatientInfo
    let study: StudyInfo
    let instanceNumber: Int?
    let position: SIMD3<Double>?
    let rowDir: SIMD3<Double>?
    let colDir: SIMD3<Double>?
    let spacingX: Double
    let spacingY: Double
    let thickness: Double?
    let spacingBetween: Double?
    let width: Int
    let height: Int
    let frames: Int
    let window: (center: Double, width: Double)?
    let monochrome1: Bool
    let values: [Float]?
    let rgba: [UInt8]?
    let tags: [TagRow]

    init(url: URL) throws {
        let ds = try DicomDataset(url: url)
        guard ds.contains(.pixelData) else { throw DicomError.noPixelData }
        let pixels = try PixelDecoder.decode(ds)

        self.url = url
        let seriesUID = ds.string(.seriesInstanceUID)
        seriesNumber = ds.int(.seriesNumber)
        seriesDescription = ds.string(.seriesDescription)
        seriesKey = seriesUID ?? "\(seriesNumber ?? 0)|\(seriesDescription ?? "")"
        modality = ds.string(.modality) ?? "OT"
        patient = PatientInfo(name: ds.string(.patientName), id: ds.string(.patientID),
                              birthDate: ds.string(.patientBirthDate), sex: ds.string(.patientSex),
                              age: ds.string(.patientAge))
        study = StudyInfo(uid: ds.string(.studyInstanceUID) ?? "unknown", description: ds.string(.studyDescription),
                          date: ds.string(.studyDate), institution: ds.string(.institutionName),
                          accession: ds.string(.accessionNumber))
        instanceNumber = ds.int(.instanceNumber)

        let pos = ds.numbers(.imagePosition)
        position = pos.count == 3 ? SIMD3(pos[0], pos[1], pos[2]) : nil
        let orient = ds.numbers(.imageOrientation)
        if orient.count == 6 {
            rowDir = simd_normalize(SIMD3(orient[0], orient[1], orient[2]))
            colDir = simd_normalize(SIMD3(orient[3], orient[4], orient[5]))
        } else {
            rowDir = nil
            colDir = nil
        }
        // Pixel Spacing is (row spacing, column spacing) = (vertical, horizontal).
        let ps = ds.numbers(.pixelSpacing).isEmpty ? ds.numbers(.imagerPixelSpacing) : ds.numbers(.pixelSpacing)
        spacingY = ps.count >= 1 && ps[0] > 0 ? ps[0] : 1
        spacingX = ps.count >= 2 && ps[1] > 0 ? ps[1] : spacingY
        thickness = ds.double(.sliceThickness)
        spacingBetween = ds.double(.spacingBetweenSlices)

        width = pixels.width
        height = pixels.height
        frames = pixels.frames
        if let c = ds.double(.windowCenter), let w = ds.double(.windowWidth) {
            window = (c, w)
        } else {
            window = nil
        }
        monochrome1 = pixels.monochrome1
        values = pixels.values
        rgba = pixels.rgba

        tags = ds.elements.values.sorted { $0.tag < $1.tag }.enumerated().map { i, e in
            TagRow(id: i, tag: e.tag.description, name: DicomDictionary.name(for: e.tag), vr: e.vr,
                   value: ds.displayValue(e))
        }
    }
}

enum StudyLoader {
    struct Result {
        var slices: [LoadedSlice]
        var skipped: Int
    }

    private static let ignoredNames: Set<String> = ["DICOMDIR", "LOCKFILE", "VERSION", "README", "AUTORUN.INF"]
    private static let ignoredExtensions: Set<String> = [
        "exe", "dll", "jar", "html", "htm", "js", "css", "txt", "pdf", "xml", "ini", "inf", "png", "jpg", "gif",
        "ico", "icns", "plist", "app", "sh", "bat", "cfg", "properties", "json", "zip", "class", "so", "dylib",
    ]

    static func collectFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                files.append(url)
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isPackageKey]
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in e {
                let values = try? f.resourceValues(forKeys: Set(keys))
                if values?.isPackage == true { e.skipDescendants(); continue }
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 256 else { continue }
                if ignoredNames.contains(f.lastPathComponent.uppercased()) { continue }
                if ignoredExtensions.contains(f.pathExtension.lowercased()) { continue }
                files.append(f)
            }
        }
        return files
    }

    static func load(_ files: [URL], progress: @escaping @Sendable (Int) -> Void) async -> Result {
        await withTaskGroup(of: LoadedSlice?.self) { group in
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            var next = 0
            while next < min(width, files.count) {
                let url = files[next]
                group.addTask { try? LoadedSlice(url: url) }
                next += 1
            }
            var result = Result(slices: [], skipped: 0)
            var done = 0
            while let slice = await group.next() {
                done += 1
                if done % 4 == 0 || done == files.count { progress(done) }
                if let slice { result.slices.append(slice) } else { result.skipped += 1 }
                if next < files.count {
                    let url = files[next]
                    group.addTask { try? LoadedSlice(url: url) }
                    next += 1
                }
            }
            return result
        }
    }

    /// Groups slices into series, splits series into geometrically consistent stacks and sorts them.
    static func makeVolumes(_ slices: [LoadedSlice]) -> [Volume] {
        var volumes: [Volume] = []
        let bySeries = Dictionary(grouping: slices, by: \.seriesKey)
        for (_, series) in bySeries {
            var stacks: [String: [LoadedSlice]] = [:]
            for s in series {
                if s.frames > 1 {
                    volumes.append(makeMultiframe(s))
                    continue
                }
                let o = [s.rowDir, s.colDir].compactMap { $0 }
                    .map { v in "\(Int((v.x * 50).rounded())),\(Int((v.y * 50).rounded())),\(Int((v.z * 50).rounded()))" }
                    .joined(separator: ";")
                let key = "\(s.width)x\(s.height)|\(s.rgba != nil)|\(o)"
                stacks[key, default: []].append(s)
            }
            for (_, stack) in stacks {
                volumes.append(makeStack(stack))
            }
        }
        for v in volumes {
            v.thumbnail = SliceRenderer.render(v.planeImage(.native, index: v.nz / 2),
                                               center: v.defaultWindow.center, width: v.defaultWindow.width,
                                               invert: v.monochrome1)
        }
        return volumes.sorted {
            ($0.study.date ?? "", $0.seriesNumber ?? Int.max, $0.title) < ($1.study.date ?? "", $1.seriesNumber ?? Int.max, $1.title)
        }
    }

    private static func makeStack(_ stack: [LoadedSlice]) -> Volume {
        let first = stack[0]
        let sorted: [LoadedSlice]
        let positions: [Double]
        if let r = first.rowDir, let c = first.colDir, stack.allSatisfy({ $0.position != nil }) {
            let n = simd_normalize(simd_cross(r, c))
            // Radiological order: head → feet, anterior → posterior, right → left.
            let a = simd_abs(n)
            let descending = a.z >= a.x && a.z >= a.y ? n.z > 0 : (a.y >= a.x ? n.y < 0 : n.x < 0)
            let pairs = stack.map { (slice: $0, d: simd_dot($0.position!, n)) }
                .sorted { descending ? $0.d > $1.d : $0.d < $1.d }
            sorted = pairs.map(\.slice)
            positions = pairs.map(\.d)
        } else {
            sorted = stack.sorted { ($0.instanceNumber ?? 0) < ($1.instanceNumber ?? 0) }
            let step = first.spacingBetween ?? first.thickness ?? 1
            positions = sorted.indices.map { Double($0) * step }
        }
        let gaps = zip(positions.dropFirst(), positions).map { abs($0 - $1) }.filter { $0 > 1e-3 }.sorted()
        let spacing = gaps.isEmpty ? (first.spacingBetween ?? first.thickness ?? 1) : gaps[gaps.count / 2]
        return Volume(slices: sorted, positions: positions, sliceSpacing: spacing)
    }

    private static func makeMultiframe(_ s: LoadedSlice) -> Volume {
        let step = s.spacingBetween ?? s.thickness ?? 1
        return Volume(slices: [s], positions: (0..<s.frames).map { Double($0) * step }, sliceSpacing: step,
                      frames: s.frames)
    }
}
