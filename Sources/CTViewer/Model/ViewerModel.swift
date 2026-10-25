import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case windowLevel, pan, zoom, measure, crosshair
    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowLevel: "Window / Level"
        case .pan: "Pan"
        case .zoom: "Zoom"
        case .measure: "Measure"
        case .crosshair: "Crosshair"
        }
    }

    var symbol: String {
        switch self {
        case .windowLevel: "circle.lefthalf.filled"
        case .pan: "hand.raised"
        case .zoom: "plus.magnifyingglass"
        case .measure: "ruler"
        case .crosshair: "scope"
        }
    }

    var key: Character {
        switch self {
        case .windowLevel: "w"
        case .pan: "p"
        case .zoom: "z"
        case .measure: "m"
        case .crosshair: "c"
        }
    }
}

struct WindowPreset: Identifiable, Hashable {
    let name: String
    let center: Double
    let width: Double
    var id: String { name }

    static let ct: [WindowPreset] = [
        WindowPreset(name: "Lung", center: -600, width: 1500),
        WindowPreset(name: "Mediastinum", center: 40, width: 400),
        WindowPreset(name: "Soft Tissue", center: 50, width: 350),
        WindowPreset(name: "Bone", center: 400, width: 1800),
        WindowPreset(name: "Liver", center: 60, width: 160),
        WindowPreset(name: "Brain", center: 40, width: 80),
    ]
}

enum Layout: String {
    case single, triple
}

struct ViewTransform: Equatable {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
}

struct Measurement: Identifiable {
    let id = UUID()
    let volumeID: UUID
    let plane: PlaneKind
    let slice: Int
    var start: CGPoint
    var end: CGPoint
}

struct StudyGroup: Identifiable {
    let id: String
    let study: StudyInfo
    let volumes: [Volume]
}

@MainActor
@Observable
final class ViewerModel {
    static let shared = ViewerModel()

    var volumes: [Volume] = []
    private(set) var selectedID: UUID?
    var loadingProgress: (done: Int, total: Int)?
    var errorMessage: String?
    var skippedFiles = 0

    var cursor = SIMD3<Int>(0, 0, 0)
    var windowCenter: Double = 40
    var windowWidth: Double = 400
    var invert = false
    var tool: Tool = .windowLevel
    var layout: Layout = .triple
    var singlePlane: PlaneKind = .native
    var focusedPlane: PlaneKind = .native
    var showCrosshair = true
    var showInspector = false
    var isPlaying = false
    var transforms: [PlaneKind: ViewTransform] = [:]
    var measurements: [Measurement] = []
    var draft: Measurement?

    @ObservationIgnored private var renderCache: [PlaneKind: (key: String, image: CGImage)] = [:]
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var mountedImages: [URL] = []
    @ObservationIgnored private var pendingURLs: [URL] = []

    var selected: Volume? { volumes.first { $0.id == selectedID } }

    var studies: [StudyGroup] {
        var order: [String] = []
        var groups: [String: [Volume]] = [:]
        for v in volumes {
            if groups[v.study.uid] == nil { order.append(v.study.uid) }
            groups[v.study.uid, default: []].append(v)
        }
        return order.map { StudyGroup(id: $0, study: groups[$0]![0].study, volumes: groups[$0]!) }
    }

    var effectiveLayout: Layout { selected?.supportsMPR == true ? layout : .single }
    var effectiveSinglePlane: PlaneKind { selected?.supportsMPR == true ? singlePlane : .native }

    var windowTitle: String {
        guard let v = selected else { return "CT Viewer" }
        return DicomFormat.personName(v.patient.name) ?? v.patient.id ?? "CT Viewer"
    }

    var windowSubtitle: String {
        guard let v = selected else { return "" }
        return [v.study.description, DicomFormat.date(v.study.date)].compactMap { $0 }.joined(separator: " · ")
    }

    var activePreset: WindowPreset? {
        WindowPreset.ct.first { abs($0.center - windowCenter) < 0.5 && abs($0.width - windowWidth) < 0.5 }
    }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open DICOM Images"
        panel.message = "Choose a folder (e.g. a copied CD), DICOM files or a disc image."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await open(urls) }
    }

    /// Finder delivers multi-selections as separate open events; collect them briefly and load once.
    func enqueueOpen(_ url: URL) {
        guard url.isFileURL else { return }
        pendingURLs.append(url)
        guard pendingURLs.count == 1 else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            let urls = pendingURLs
            pendingURLs = []
            await open(urls)
        }
    }

    func open(_ urls: [URL]) async {
        guard !urls.isEmpty, loadingProgress == nil else { return }
        stopPlaying()
        loadingProgress = (0, 0)
        defer { loadingProgress = nil }

        var roots: [URL] = []
        for url in urls {
            if ["iso", "cdr", "dmg"].contains(url.pathExtension.lowercased()) {
                if let mount = await mountDiskImage(url) {
                    roots.append(mount)
                } else {
                    errorMessage = "“\(url.lastPathComponent)” could not be mounted. If it is a raw CD dump (.bin-style 2352-byte sectors) or damaged, copy the disc contents into a folder instead."
                    return
                }
            } else {
                roots.append(url)
            }
        }

        let files = await Task.detached { StudyLoader.collectFiles(roots) }.value
        guard !files.isEmpty else {
            errorMessage = "No files found in the selection."
            return
        }
        loadingProgress = (0, files.count)
        let result = await StudyLoader.load(files) { done in
            Task { @MainActor in ViewerModel.shared.loadingProgress?.done = done }
        }
        let built = await Task.detached { StudyLoader.makeVolumes(result.slices) }.value
        guard !built.isEmpty else {
            errorMessage = "No readable DICOM images were found (\(result.skipped) file(s) skipped)."
            return
        }
        volumes = built
        skippedFiles = result.skipped
        measurements = []
        let best = built.max { a, b in
            (a.supportsMPR ? 1 : 0, a.nz) < (b.supportsMPR ? 1 : 0, b.nz)
        }
        select(best?.id)
    }

    private func mountDiskImage(_ url: URL) async -> URL? {
        await Task.detached { () -> URL? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["attach", "-readonly", "-nobrowse", "-noverify", "-plist", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]],
                  let mount = entities.compactMap({ $0["mount-point"] as? String }).first
            else { return nil }
            return URL(fileURLWithPath: mount)
        }.value.map { mount in
            mountedImages.append(mount)
            return mount
        }
    }

    func detachMountedImages() {
        for mount in mountedImages {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["detach", "-quiet", mount.path]
            try? p.run()
            p.waitUntilExit()
        }
        mountedImages = []
    }

    // MARK: - Selection & view state

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        stopPlaying()
        selectedID = id
        renderCache = [:]
        draft = nil
        guard let v = selected else { return }
        cursor = SIMD3(v.nx / 2, v.ny / 2, v.nz / 2)
        windowCenter = v.defaultWindow.center
        windowWidth = v.defaultWindow.width
        invert = v.monochrome1
        transforms = [:]
        focusedPlane = .native
        if !v.supportsMPR { singlePlane = .native }
    }

    func sliceIndex(_ plane: PlaneKind) -> Int {
        switch plane {
        case .native: cursor.z
        case .fixedRow: cursor.y
        case .fixedCol: cursor.x
        }
    }

    func setSlice(_ plane: PlaneKind, _ index: Int) {
        guard let v = selected else { return }
        let i = min(max(index, 0), v.sliceCount(plane) - 1)
        switch plane {
        case .native: cursor.z = i
        case .fixedRow: cursor.y = i
        case .fixedCol: cursor.x = i
        }
    }

    func step(_ plane: PlaneKind, by delta: Int) {
        setSlice(plane, sliceIndex(plane) + delta)
    }

    func transform(for plane: PlaneKind) -> ViewTransform { transforms[plane] ?? ViewTransform() }
    func setTransform(_ t: ViewTransform, for plane: PlaneKind) { transforms[plane] = t }

    func pan(_ plane: PlaneKind, by delta: CGSize) {
        var t = transform(for: plane)
        t.pan.width += delta.width
        t.pan.height += delta.height
        transforms[plane] = t
    }

    func adjustWindow(dx: CGFloat, dy: CGFloat) {
        let k = max(1, windowWidth / 250)
        windowWidth = max(1, windowWidth + Double(dx) * k)
        windowCenter += Double(dy) * k
    }

    func apply(_ preset: WindowPreset) {
        windowCenter = preset.center
        windowWidth = preset.width
    }

    func resetWindow() {
        guard let v = selected else { return }
        windowCenter = v.defaultWindow.center
        windowWidth = v.defaultWindow.width
    }

    func resetView() {
        transforms = [:]
        resetWindow()
        invert = selected?.monochrome1 ?? false
    }

    func toggleMaximize(_ plane: PlaneKind) {
        guard selected?.supportsMPR == true else { return }
        if layout == .triple {
            singlePlane = plane
            layout = .single
        } else {
            layout = .triple
        }
        focusedPlane = plane
    }

    func setCursor(plane: PlaneKind, imagePoint p: CGPoint) {
        guard let v = selected else { return }
        let (w, h) = v.imageSize(plane)
        let x = min(max(Int(p.x.rounded(.down)), 0), w - 1)
        let y = min(max(Int(p.y.rounded(.down)), 0), h - 1)
        cursor = v.voxel(plane: plane, index: sliceIndex(plane), x: x, y: y)
    }

    /// Crosshair line positions in a plane's image coordinates (pixel centers).
    func crosshair(in plane: PlaneKind) -> (x: CGFloat, y: CGFloat, vertical: PlaneKind, horizontal: PlaneKind)? {
        guard let v = selected else { return nil }
        switch plane {
        case .native:
            return (CGFloat(cursor.x) + 0.5, CGFloat(cursor.y) + 0.5, .fixedCol, .fixedRow)
        case .fixedRow:
            return (CGFloat(cursor.x) + 0.5, CGFloat(v.rowForSlice(cursor.z)) + 0.5, .fixedCol, .native)
        case .fixedCol:
            return (CGFloat(cursor.y) + 0.5, CGFloat(v.rowForSlice(cursor.z)) + 0.5, .fixedRow, .native)
        }
    }

    func image(for plane: PlaneKind) -> CGImage? {
        guard let v = selected else { return nil }
        let index = sliceIndex(plane)
        let key = "\(v.id)|\(index)|\(windowCenter)|\(windowWidth)|\(invert)"
        if let cached = renderCache[plane], cached.key == key { return cached.image }
        guard let image = SliceRenderer.render(v.planeImage(plane, index: index), center: windowCenter,
                                               width: windowWidth, invert: invert) else { return nil }
        renderCache[plane] = (key, image)
        return image
    }

    // MARK: - Measurements

    func beginMeasurement(plane: PlaneKind, at p: CGPoint) {
        guard let v = selected else { return }
        draft = Measurement(volumeID: v.id, plane: plane, slice: sliceIndex(plane), start: p, end: p)
    }

    func updateMeasurement(to p: CGPoint) { draft?.end = p }

    func commitMeasurement() {
        if let d = draft, hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 1.5 {
            measurements.append(d)
        }
        draft = nil
    }

    func measurements(for plane: PlaneKind) -> [Measurement] {
        guard let v = selected else { return [] }
        let index = sliceIndex(plane)
        var list = measurements.filter { $0.volumeID == v.id && $0.plane == plane && $0.slice == index }
        if let d = draft, d.plane == plane, d.slice == index { list.append(d) }
        return list
    }

    func clearMeasurements(on plane: PlaneKind) {
        guard let v = selected else { return }
        let index = sliceIndex(plane)
        measurements.removeAll { $0.volumeID == v.id && $0.plane == plane && $0.slice == index }
    }

    func length(of m: Measurement) -> Double? {
        guard let v = volumes.first(where: { $0.id == m.volumeID }) else { return nil }
        let s = v.pixelSpacing(m.plane)
        return hypot(Double(m.end.x - m.start.x) * s.x, Double(m.end.y - m.start.y) * s.y)
    }

    // MARK: - Cine

    func togglePlay() {
        isPlaying ? stopPlaying() : startPlaying()
    }

    private func startPlaying() {
        guard let v = selected, v.sliceCount(focusedPlane) > 1 else { return }
        isPlaying = true
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                guard let self, let v = self.selected else { return }
                let plane = self.focusedPlane
                self.setSlice(plane, (self.sliceIndex(plane) + 1) % v.sliceCount(plane))
            }
        }
    }

    func stopPlaying() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    // MARK: - Export

    func exportFocusedImage() {
        guard let v = selected else { return }
        let plane = effectiveLayout == .single ? effectiveSinglePlane : focusedPlane
        guard let image = image(for: plane) else { return }
        let s = v.pixelSpacing(plane)
        let minSpacing = min(s.x, s.y)
        let w = Int((Double(image.width) * s.x / minSpacing).rounded())
        let h = Int((Double(image.height) * s.y / minSpacing).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let output = ctx.makeImage() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(v.title) \(v.anatomy(plane).title) \(sliceIndex(plane) + 1).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SliceRenderer.writePNG(output, to: url)
    }
}
