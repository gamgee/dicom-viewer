import CoreGraphics
import Foundation
import SwiftUI
import simd

struct PatientInfo: Hashable, Sendable {
    var name: String?
    var id: String?
    var birthDate: String?
    var sex: String?
    var age: String?
}

struct StudyInfo: Hashable, Sendable {
    var uid: String
    var description: String?
    var date: String?
    var institution: String?
    var accession: String?
}

struct TagRow: Identifiable, Hashable, Sendable {
    let id: Int
    let tag: String
    let name: String
    let vr: String
    let value: String
}

/// The three planes a volume can be shown in. `native` is the acquisition plane;
/// the other two are reformats through a fixed row (j) or column (i).
enum PlaneKind: Int, CaseIterable, Identifiable, Sendable {
    case native, fixedRow, fixedCol
    var id: Int { rawValue }
}

enum Anatomy {
    case axial, coronal, sagittal

    var title: String {
        switch self {
        case .axial: "Axial"
        case .coronal: "Coronal"
        case .sagittal: "Sagittal"
        }
    }

    var color: Color {
        switch self {
        case .axial: Color(red: 0.98, green: 0.36, blue: 0.40)
        case .coronal: Color(red: 0.35, green: 0.86, blue: 0.52)
        case .sagittal: Color(red: 0.99, green: 0.80, blue: 0.30)
        }
    }

    /// Patient axis this plane is perpendicular to (LPS).
    var axisLabel: String {
        switch self {
        case .axial: "Z"
        case .coronal: "Y"
        case .sagittal: "X"
        }
    }
}

struct PlaneImage {
    let width: Int
    let height: Int
    var values: [Float]
    var rgba: [UInt8]?
}

/// A stack of equally sized, parallel slices assembled into a contiguous voxel grid.
final class Volume: Identifiable, @unchecked Sendable {
    let id = UUID()
    let seriesNumber: Int?
    let seriesDescription: String?
    let modality: String
    let patient: PatientInfo
    let study: StudyInfo

    let nx: Int
    let ny: Int
    let nz: Int
    /// Horizontal (along rows), vertical (along columns) and slice spacing in mm.
    let spacing: SIMD3<Double>
    let rowDir: SIMD3<Double>
    let colDir: SIMD3<Double>
    let normal: SIMD3<Double>
    let origin: SIMD3<Double>
    /// Position of each slice along `normal`, in mm.
    let slicePositions: [Double]
    let sliceThickness: Double?

    let values: [Float]
    let rgba: [UInt8]?
    let defaultWindow: (center: Double, width: Double)
    let monochrome1: Bool
    let isHounsfield: Bool
    let sliceTags: [[TagRow]]
    let sliceFiles: [URL]
    var thumbnail: CGImage?

    init(slices: [LoadedSlice], positions: [Double], sliceSpacing: Double, frames: Int = 1) {
        let first = slices[0]
        seriesNumber = first.seriesNumber
        seriesDescription = first.seriesDescription
        modality = first.modality
        patient = first.patient
        study = first.study
        nx = first.width
        ny = first.height
        nz = frames > 1 ? frames : slices.count
        spacing = SIMD3(first.spacingX, first.spacingY, sliceSpacing)
        rowDir = first.rowDir ?? SIMD3(1, 0, 0)
        colDir = first.colDir ?? SIMD3(0, 1, 0)
        normal = simd_normalize(simd_cross(rowDir, colDir))
        origin = first.position ?? .zero
        slicePositions = positions
        sliceThickness = first.thickness
        monochrome1 = first.monochrome1
        isHounsfield = first.modality == "CT"

        if first.rgba != nil {
            values = []
            rgba = slices.flatMap { $0.rgba ?? [] }
        } else {
            var all = [Float]()
            all.reserveCapacity(nx * ny * nz)
            for s in slices { all.append(contentsOf: s.values ?? []) }
            values = all
            rgba = nil
        }

        let middle = slices[slices.count / 2]
        if let w = middle.window, w.width > 1 {
            defaultWindow = w
        } else if first.modality == "CT" {
            defaultWindow = (40, 400)
        } else if !values.isEmpty {
            let sliceSize = nx * ny
            let start = (nz / 2) * sliceSize
            let mid = values[start..<min(values.count, start + sliceSize)]
            let lo = Double(mid.min() ?? 0), hi = Double(mid.max() ?? 1)
            defaultWindow = ((lo + hi) / 2, max(1, hi - lo))
        } else {
            defaultWindow = (128, 256)
        }

        if frames > 1 {
            sliceTags = Array(repeating: first.tags, count: nz)
            sliceFiles = Array(repeating: first.url, count: nz)
        } else {
            sliceTags = slices.map(\.tags)
            sliceFiles = slices.map(\.url)
        }
    }

    var title: String {
        if let d = seriesDescription, !d.isEmpty { return d }
        return seriesNumber.map { "Series \($0)" } ?? "Series"
    }

    var subtitle: String {
        var parts = [nz == 1 ? "1 image" : "\(nz) images"]
        if nz > 1, let t = sliceThickness { parts.append(String(format: "%g mm", t)) }
        parts.append("\(nx)×\(ny)")
        return parts.joined(separator: " · ")
    }

    var supportsMPR: Bool { nz >= 8 }

    // MARK: - Plane geometry

    /// Patient-space direction in which the slice index k increases.
    var sliceDirection: SIMD3<Double> {
        guard let first = slicePositions.first, let last = slicePositions.last, last < first else { return normal }
        return -normal
    }

    /// Reformats show the slice axis vertically; flip it so that head/anterior ends up on top.
    var flipSliceAxis: Bool {
        let d = sliceDirection
        let n = simd_abs(d)
        if n.z >= n.x, n.z >= n.y { return d.z > 0 }
        if n.y >= n.x { return d.y < 0 }
        return d.x < 0
    }

    func sliceForRow(_ row: Int) -> Int { flipSliceAxis ? nz - 1 - row : row }
    func rowForSlice(_ k: Int) -> Int { flipSliceAxis ? nz - 1 - k : k }

    func imageSize(_ plane: PlaneKind) -> (width: Int, height: Int) {
        switch plane {
        case .native: (nx, ny)
        case .fixedRow: (nx, nz)
        case .fixedCol: (ny, nz)
        }
    }

    func pixelSpacing(_ plane: PlaneKind) -> (x: Double, y: Double) {
        switch plane {
        case .native: (spacing.x, spacing.y)
        case .fixedRow: (spacing.x, spacing.z)
        case .fixedCol: (spacing.y, spacing.z)
        }
    }

    func sliceCount(_ plane: PlaneKind) -> Int {
        switch plane {
        case .native: nz
        case .fixedRow: ny
        case .fixedCol: nx
        }
    }

    /// Screen-right and screen-down directions in patient space.
    func axes(_ plane: PlaneKind) -> (right: SIMD3<Double>, down: SIMD3<Double>) {
        let down = flipSliceAxis ? -sliceDirection : sliceDirection
        switch plane {
        case .native: return (rowDir, colDir)
        case .fixedRow: return (rowDir, down)
        case .fixedCol: return (colDir, down)
        }
    }

    func anatomy(_ plane: PlaneKind) -> Anatomy {
        let n: SIMD3<Double>
        switch plane {
        case .native: n = normal
        case .fixedRow: n = colDir
        case .fixedCol: n = rowDir
        }
        let a = simd_abs(n)
        if a.z >= a.x, a.z >= a.y { return .axial }
        return a.y >= a.x ? .coronal : .sagittal
    }

    /// Patient-space position (mm) of a voxel.
    func patientPoint(_ v: SIMD3<Int>) -> SIMD3<Double> {
        let along = slicePositions.isEmpty ? 0 : slicePositions[v.z] - slicePositions[0]
        return origin + Double(v.x) * spacing.x * rowDir + Double(v.y) * spacing.y * colDir + along * normal
    }

    func planeImage(_ plane: PlaneKind, index: Int) -> PlaneImage {
        let (w, h) = imageSize(plane)
        if let rgba {
            return PlaneImage(width: w, height: h, values: [], rgba: gather(rgba, channels: 4, plane: plane, index: index, zero: 0))
        }
        return PlaneImage(width: w, height: h, values: gather(values, channels: 1, plane: plane, index: index, zero: 0))
    }

    private func gather<T>(_ src: [T], channels c: Int, plane: PlaneKind, index: Int, zero: T) -> [T] {
        let (w, h) = imageSize(plane)
        let sliceSize = nx * ny
        if plane == .native {
            let start = index * sliceSize * c
            return Array(src[start..<(start + sliceSize * c)])
        }
        var out = [T](repeating: zero, count: w * h * c)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for r in 0..<h {
                    let k = sliceForRow(r)
                    if plane == .fixedRow {
                        let sb = (k * sliceSize + index * nx) * c
                        let db = r * w * c
                        for n in 0..<(nx * c) { o[db + n] = s[sb + n] }
                    } else {
                        for j in 0..<ny {
                            let sb = (k * sliceSize + j * nx + index) * c
                            let db = (r * w + j) * c
                            for ch in 0..<c { o[db + ch] = s[sb + ch] }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Converts an in-plane pixel to a voxel coordinate.
    func voxel(plane: PlaneKind, index: Int, x: Int, y: Int) -> SIMD3<Int> {
        switch plane {
        case .native: SIMD3(x, y, index)
        case .fixedRow: SIMD3(x, index, sliceForRow(y))
        case .fixedCol: SIMD3(index, x, sliceForRow(y))
        }
    }

    func value(at v: SIMD3<Int>) -> Float? {
        guard rgba == nil, (0..<nx).contains(v.x), (0..<ny).contains(v.y), (0..<nz).contains(v.z) else { return nil }
        return values[v.z * nx * ny + v.y * nx + v.x]
    }
}
