import AppKit
import SwiftUI
import simd

/// Maps between view points and (continuous) image pixel coordinates, honoring physical pixel spacing.
struct ViewGeometry {
    let imageRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    init(volume: Volume, plane: PlaneKind, viewSize: CGSize, transform: ViewTransform) {
        let (w, h) = volume.imageSize(plane)
        let s = volume.pixelSpacing(plane)
        let mmW = Double(w) * s.x, mmH = Double(h) * s.y
        let fit = min(viewSize.width / mmW, viewSize.height / mmH) * 0.96
        let scale = fit * transform.zoom
        let size = CGSize(width: mmW * scale, height: mmH * scale)
        let origin = CGPoint(x: (viewSize.width - size.width) / 2 + transform.pan.width,
                             y: (viewSize.height - size.height) / 2 + transform.pan.height)
        imageRect = CGRect(origin: origin, size: size)
        pixelWidth = w
        pixelHeight = h
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageRect.minX) / imageRect.width * CGFloat(pixelWidth),
                y: (p.y - imageRect.minY) / imageRect.height * CGFloat(pixelHeight))
    }

    func toView(_ q: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + q.x / CGFloat(pixelWidth) * imageRect.width,
                y: imageRect.minY + q.y / CGFloat(pixelHeight) * imageRect.height)
    }

    func contains(_ q: CGPoint) -> Bool {
        q.x >= 0 && q.y >= 0 && q.x < CGFloat(pixelWidth) && q.y < CGFloat(pixelHeight)
    }

    func clamp(_ q: CGPoint) -> CGPoint {
        CGPoint(x: min(max(q.x, 0), CGFloat(pixelWidth)), y: min(max(q.y, 0), CGFloat(pixelHeight)))
    }

    var zoomPercent: Int { Int((imageRect.width / CGFloat(pixelWidth) * 100).rounded()) }
}

struct ViewportView: View {
    @Environment(ViewerModel.self) private var model
    let volume: Volume
    let plane: PlaneKind
    var compact = false

    @State private var hoverPoint: CGPoint?
    @State private var isHovering = false
    @State private var lastDrag: CGPoint?
    @State private var dragAnchor: CGPoint?
    @State private var scrollAccumulator: CGFloat = 0

    private static let measureColor = Color(red: 1.0, green: 0.84, blue: 0.25)

    var body: some View {
        GeometryReader { geo in
            let geom = ViewGeometry(volume: volume, plane: plane, viewSize: geo.size,
                                    transform: model.transform(for: plane))
            let anatomy = volume.anatomy(plane)
            let image = model.image(for: plane)
            let crosshair = model.showCrosshair && model.effectiveLayout == .triple ? model.crosshair(in: plane) : nil
            let measurements = model.measurements(for: plane)
            let lengths = measurements.map { model.length(of: $0) ?? 0 }
            let focused = model.effectiveLayout == .triple && model.focusedPlane == plane

            ZStack {
                Color.black

                Canvas { ctx, _ in
                    if let image {
                        ctx.draw(Image(decorative: image, scale: 1).interpolation(.high), in: geom.imageRect)
                    }
                    if let crosshair {
                        drawCrosshair(ctx, geom: geom, crosshair: crosshair)
                    }
                    for (m, length) in zip(measurements, lengths) {
                        drawMeasurement(ctx, geom: geom, measurement: m, length: length)
                    }
                }

                InputCatcher(handler: makeHandler(geom: geom, size: geo.size), cursor: cursor,
                             takesFocus: plane == .native)

                overlays(geom: geom, anatomy: anatomy)
                    .allowsHitTesting(false)

                orientationLabels(size: geo.size)
                    .allowsHitTesting(false)

                sliceBar(anatomy: anatomy)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
            }
            .overlay {
                if focused {
                    Rectangle().strokeBorder(anatomy.color.opacity(0.55), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .onHover { isHovering = $0 }
        }
    }

    private var cursor: NSCursor {
        switch model.tool {
        case .pan: .openHand
        case .measure, .crosshair: .crosshair
        case .zoom, .windowLevel: .arrow
        }
    }

    // MARK: - Drawing

    private func drawCrosshair(_ ctx: GraphicsContext, geom: ViewGeometry,
                               crosshair c: (x: CGFloat, y: CGFloat, vertical: PlaneKind, horizontal: PlaneKind)) {
        let center = geom.toView(CGPoint(x: c.x, y: c.y))
        let r = geom.imageRect
        let gap: CGFloat = 14
        var vertical = Path()
        vertical.move(to: CGPoint(x: center.x, y: r.minY))
        vertical.addLine(to: CGPoint(x: center.x, y: center.y - gap))
        vertical.move(to: CGPoint(x: center.x, y: center.y + gap))
        vertical.addLine(to: CGPoint(x: center.x, y: r.maxY))
        var horizontal = Path()
        horizontal.move(to: CGPoint(x: r.minX, y: center.y))
        horizontal.addLine(to: CGPoint(x: center.x - gap, y: center.y))
        horizontal.move(to: CGPoint(x: center.x + gap, y: center.y))
        horizontal.addLine(to: CGPoint(x: r.maxX, y: center.y))
        ctx.stroke(vertical, with: .color(volume.anatomy(c.vertical).color.opacity(0.7)), lineWidth: 1)
        ctx.stroke(horizontal, with: .color(volume.anatomy(c.horizontal).color.opacity(0.7)), lineWidth: 1)
    }

    private func drawMeasurement(_ ctx: GraphicsContext, geom: ViewGeometry, measurement m: Measurement, length: Double) {
        let a = geom.toView(m.start), b = geom.toView(m.end)
        var line = Path()
        line.move(to: a)
        line.addLine(to: b)
        ctx.stroke(line, with: .color(.black.opacity(0.6)), lineWidth: 3.5)
        ctx.stroke(line, with: .color(Self.measureColor), lineWidth: 1.5)
        for p in [a, b] {
            let dot = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            ctx.fill(dot, with: .color(Self.measureColor))
            ctx.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
        let label = ctx.resolve(Text(String(format: "%.1f mm", length))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(.black))
        let size = label.measure(in: CGSize(width: 200, height: 40))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let box = CGRect(x: mid.x + 8, y: mid.y - size.height - 6, width: size.width + 12, height: size.height + 4)
        ctx.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(Self.measureColor))
        ctx.draw(label, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }

    // MARK: - Overlays

    @ViewBuilder
    private func overlays(geom: ViewGeometry, anatomy: Anatomy) -> some View {
        let index = model.sliceIndex(plane)
        let count = volume.sliceCount(plane)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    PlaneChip(anatomy: anatomy, reformatted: plane != .native)
                    if !compact {
                        Text(volume.title).font(.system(size: 12, weight: .semibold))
                        if let n = volume.seriesNumber { Text(verbatim: "Series \(n) · \(volume.modality)") }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Im \(index + 1) / \(count)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    Text(positionText(anatomy: anatomy))
                    if !compact, plane == .native, let t = volume.sliceThickness {
                        Text(String(format: "Thk %g mm", t))
                    }
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    if volume.rgba == nil {
                        Text("W \(Int(model.windowWidth.rounded()))  L \(Int(model.windowCenter.rounded()))")
                    }
                    Text("\(geom.zoomPercent)%").foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if let readout = probeText(geom: geom) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(readout.value).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text(readout.detail).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.bottom, isHovering && count > 1 ? 40 : 0)
            .animation(.easeOut(duration: 0.18), value: isHovering)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.88))
        .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 0.5)
        .padding(10)
    }

    private func positionText(anatomy: Anatomy) -> String {
        let p = volume.patientPoint(model.cursor)
        let value: Double
        switch anatomy {
        case .axial: value = p.z
        case .coronal: value = p.y
        case .sagittal: value = p.x
        }
        return String(format: "%@ %.1f mm", anatomy.axisLabel, value)
    }

    private func probeText(geom: ViewGeometry) -> (value: String, detail: String)? {
        guard let hoverPoint else { return nil }
        let q = geom.toImage(hoverPoint)
        guard geom.contains(q) else { return nil }
        let x = Int(q.x), y = Int(q.y)
        let voxel = volume.voxel(plane: plane, index: model.sliceIndex(plane), x: x, y: y)
        guard let v = volume.value(at: voxel) else { return nil }
        let unit = volume.isHounsfield ? " HU" : ""
        return (String(format: "%.0f%@", v, unit), "x \(x)  y \(y)")
    }

    private func orientationLabels(size: CGSize) -> some View {
        let axes = volume.axes(plane)
        return ZStack {
            label(-axes.right).position(x: 14, y: size.height / 2)
            label(axes.right).position(x: size.width - 14, y: size.height / 2)
            label(-axes.down).position(x: size.width / 2, y: 14)
        }
    }

    private func label(_ v: SIMD3<Double>) -> some View {
        Text(Self.orientationLetter(v))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .shadow(color: .black, radius: 1.5)
    }

    static func orientationLetter(_ v: SIMD3<Double>) -> String {
        let a = simd_abs(v)
        if a.x >= a.y, a.x >= a.z { return v.x > 0 ? "L" : "R" }
        if a.y >= a.z { return v.y > 0 ? "P" : "A" }
        return v.z > 0 ? "S" : "I"
    }

    @ViewBuilder
    private func sliceBar(anatomy: Anatomy) -> some View {
        let count = volume.sliceCount(plane)
        if count > 1 {
            HStack(spacing: 10) {
                Text("\(model.sliceIndex(plane) + 1)")
                    .frame(minWidth: 26, alignment: .trailing)
                Slider(value: Binding(get: { Double(model.sliceIndex(plane)) },
                                      set: { model.setSlice(plane, Int($0.rounded())) }),
                       in: 0...Double(count - 1))
                    .controlSize(.mini)
                    .tint(anatomy.color)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
            .frame(maxWidth: compact ? 260 : 380)
            .padding(.horizontal, 24)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .animation(.easeOut(duration: 0.18), value: isHovering)
        }
    }

    // MARK: - Input

    private func makeHandler(geom: ViewGeometry, size: CGSize) -> InputHandler {
        var h = InputHandler()
        h.mouseDown = { p, button, flags, clicks in
            model.focusedPlane = plane
            lastDrag = p
            dragAnchor = p
            if button == .left, clicks == 2 {
                model.toggleMaximize(plane)
                return
            }
            guard button == .left, !flags.contains(.option) else { return }
            let q = geom.toImage(p)
            switch model.tool {
            case .measure where geom.contains(q): model.beginMeasurement(plane: plane, at: q)
            case .crosshair: model.setCursor(plane: plane, imagePoint: q)
            default: break
            }
        }
        h.mouseDragged = { p, button, flags in
            let last = lastDrag ?? p
            let dx = p.x - last.x, dy = p.y - last.y
            lastDrag = p
            var action = model.tool
            if button == .right { action = .zoom }
            if button == .other || flags.contains(.option) { action = .pan }
            switch action {
            case .windowLevel: model.adjustWindow(dx: dx, dy: dy)
            case .pan: model.pan(plane, by: CGSize(width: dx, height: dy))
            case .zoom: zoom(by: exp(-dy * 0.01), anchor: dragAnchor ?? p, size: size)
            case .measure: model.updateMeasurement(to: geom.clamp(geom.toImage(p)))
            case .crosshair: model.setCursor(plane: plane, imagePoint: geom.toImage(p))
            }
            hoverPoint = p
        }
        h.mouseUp = { _, button in
            if button == .left, model.tool == .measure { model.commitMeasurement() }
            lastDrag = nil
            dragAnchor = nil
        }
        h.scroll = { dy, precise, flags, p in
            if flags.contains(.command) {
                zoom(by: exp(dy * (precise ? 0.01 : 0.1)), anchor: p, size: size)
                return
            }
            if precise {
                scrollAccumulator += dy
                let steps = Int(scrollAccumulator / 5)
                if steps != 0 {
                    model.step(plane, by: -steps)
                    scrollAccumulator -= CGFloat(steps) * 5
                }
            } else if dy != 0 {
                model.step(plane, by: dy > 0 ? -1 : 1)
            }
        }
        h.magnify = { m, p in zoom(by: 1 + m, anchor: p, size: size) }
        h.hover = { hoverPoint = $0 }
        h.key = { e in handleKey(e) }
        return h
    }

    private func zoom(by factor: CGFloat, anchor p: CGPoint, size: CGSize) {
        var t = model.transform(for: plane)
        let before = ViewGeometry(volume: volume, plane: plane, viewSize: size, transform: t).toImage(p)
        t.zoom = min(max(t.zoom * factor, 0.25), 24)
        let after = ViewGeometry(volume: volume, plane: plane, viewSize: size, transform: t).toView(before)
        t.pan.width += p.x - after.x
        t.pan.height += p.y - after.y
        model.setTransform(t, for: plane)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let target = model.focusedPlane
        guard !e.modifierFlags.contains(.command) else { return false }
        switch e.keyCode {
        case 126, 123: model.step(target, by: -1); return true
        case 125, 124: model.step(target, by: 1); return true
        case 116: model.step(target, by: -10); return true
        case 121: model.step(target, by: 10); return true
        case 115: model.setSlice(target, 0); return true
        case 119: model.setSlice(target, Int.max); return true
        case 49: model.togglePlay(); return true
        case 51, 117: model.clearMeasurements(on: target); return true
        case 53: model.draft = nil; return true
        default: break
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return false }
        if let tool = Tool.allCases.first(where: { $0.key == ch }) {
            model.tool = tool
            return true
        }
        if let digit = ch.wholeNumberValue, (1...WindowPreset.ct.count).contains(digit) {
            model.apply(WindowPreset.ct[digit - 1])
            return true
        }
        switch ch {
        case "i": model.invert.toggle()
        case "r": model.resetView()
        case "f": model.toggleMaximize(target)
        case "x": model.showCrosshair.toggle()
        default: return false
        }
        return true
    }
}

struct PlaneChip: View {
    let anatomy: Anatomy
    var reformatted = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(anatomy.color).frame(width: 7, height: 7)
            Text(anatomy.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.9)
            if reformatted {
                Text("MPR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(anatomy.color.opacity(0.45), lineWidth: 1))
        .shadow(color: .clear, radius: 0)
    }
}
