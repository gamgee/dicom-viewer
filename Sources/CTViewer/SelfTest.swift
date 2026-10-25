import Foundation

/// `CTViewer --selftest <dicom-folder> <output-folder>` loads a folder headlessly,
/// prints a summary and renders the middle slice of every plane to PNG.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let input = URL(fileURLWithPath: args[i + 1])
        let output = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let start = Date()
            let files = StudyLoader.collectFiles([input])
            let result = await StudyLoader.load(files) { _ in }
            let volumes = StudyLoader.makeVolumes(result.slices)
            print("files \(files.count), images \(result.slices.count), skipped \(result.skipped), "
                + String(format: "%.2fs", Date().timeIntervalSince(start)))
            for (n, v) in volumes.enumerated() {
                print("[\(n)] \(v.title) | \(v.modality) | \(v.nx)x\(v.ny)x\(v.nz) | spacing "
                    + String(format: "%.3f %.3f %.3f", v.spacing.x, v.spacing.y, v.spacing.z)
                    + " | window \(v.defaultWindow) | MPR \(v.supportsMPR)")
                for plane in PlaneKind.allCases where plane == .native || v.supportsMPR {
                    let index = v.sliceCount(plane) / 2
                    let center = v.voxel(plane: plane, index: index, x: v.imageSize(plane).width / 2,
                                         y: v.imageSize(plane).height / 2)
                    print("    \(v.anatomy(plane).title): \(v.imageSize(plane)) center value \(v.value(at: center) ?? .nan)")
                    if let image = SliceRenderer.render(v.planeImage(plane, index: index), center: -600, width: 1500,
                                                        invert: false) {
                        SliceRenderer.writePNG(image, to: output.appendingPathComponent("\(n)_\(v.anatomy(plane).title).png"))
                    }
                }
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
