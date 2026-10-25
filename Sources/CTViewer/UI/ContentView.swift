import SwiftUI

struct ContentView: View {
    @Environment(ViewerModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            Group {
                if let progress = model.loadingProgress {
                    LoadingView(done: progress.done, total: progress.total)
                } else if let volume = model.selected {
                    ViewerArea(volume: volume)
                        .id(volume.id)
                } else {
                    WelcomeView(dropTargeted: dropTargeted)
                }
            }
            .toolbar { ViewerToolbar(model: model) }
        }
        .inspector(isPresented: $model.showInspector) {
            TagInspectorView()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 640)
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.open(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert("Couldn’t Open Images", isPresented: Binding(get: { model.errorMessage != nil },
                                                           set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ViewerArea: View {
    @Environment(ViewerModel.self) private var model
    let volume: Volume

    var body: some View {
        GeometryReader { geo in
            Group {
                switch model.effectiveLayout {
                case .single:
                    ViewportView(volume: volume, plane: model.effectiveSinglePlane)
                case .triple:
                    HStack(spacing: 2) {
                        ViewportView(volume: volume, plane: .native)
                        VStack(spacing: 2) {
                            ViewportView(volume: volume, plane: .fixedRow, compact: true)
                            ViewportView(volume: volume, plane: .fixedCol, compact: true)
                        }
                        .frame(width: max(220, geo.size.width * 0.36))
                    }
                }
            }
        }
        .background(Color(white: 0.13))
    }
}

struct ViewerToolbar: ToolbarContent {
    @Bindable var model: ViewerModel

    var body: some ToolbarContent {
        let hasImage = model.selected != nil

        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $model.tool) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol)
                        .help("\(tool.title) (\(String(tool.key).uppercased()))")
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(!hasImage)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Presets") {
                    ForEach(Array(WindowPreset.ct.enumerated()), id: \.element) { i, preset in
                        Button {
                            model.apply(preset)
                        } label: {
                            Text("\(preset.name)   W \(Int(preset.width)) / L \(Int(preset.center))   ·  \(i + 1)")
                        }
                    }
                }
                Divider()
                Button("Image Default") { model.resetWindow() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    Text(model.activePreset?.name ?? "Window")
                }
            }
            .help("Window presets")
            .disabled(!hasImage || model.selected?.rgba != nil)

            Picker("Layout", selection: $model.layout) {
                Label("Single", systemImage: "rectangle").tag(Layout.single)
                Label("Three Planes", systemImage: "rectangle.split.2x1").tag(Layout.triple)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Layout (double-click a view to maximize)")
            .disabled(model.selected?.supportsMPR != true)

            Button { model.invert.toggle() } label: {
                Label("Invert", systemImage: model.invert ? "circle.righthalf.filled.inverse" : "circle.righthalf.filled")
            }
            .help("Invert (I)")
            .disabled(!hasImage)

            Button { model.togglePlay() } label: {
                Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Cine playback (Space)")
            .disabled(!hasImage)

            Button { model.resetView() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset zoom, pan and window (R)")
            .disabled(!hasImage)

            Button { model.showInspector.toggle() } label: {
                Label("Attributes", systemImage: "info.circle")
            }
            .help("Show DICOM attributes")
            .disabled(!hasImage)
        }
    }
}
