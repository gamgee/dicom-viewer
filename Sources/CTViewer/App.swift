import AppKit
import SwiftUI

@main
struct CTViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ViewerModel.shared

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("CT Viewer", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { model.enqueueOpen($0) }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands { ViewerCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ViewerModel.shared.detachMountedImages() }
    }
}

struct ViewerCommands: Commands {
    let model: ViewerModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .saveItem) {
            Button("Export Image as PNG…") { model.exportFocusedImage() }
                .keyboardShortcut("e")
                .disabled(model.selected == nil)
        }
        CommandMenu("Image") {
            Picker("Tool", selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
                ForEach(Tool.allCases) { Text("\($0.title)    \(String($0.key).uppercased())").tag($0) }
            }
            Divider()
            Button("Invert") { model.invert.toggle() }
                .keyboardShortcut("i")
            Button(model.showCrosshair ? "Hide Crosshair" : "Show Crosshair") { model.showCrosshair.toggle() }
                .keyboardShortcut("l")
            Button(model.isPlaying ? "Stop Cine" : "Play Cine") { model.togglePlay() }
                .keyboardShortcut("p")
            Button("Reset View") { model.resetView() }
                .keyboardShortcut("r")
            Divider()
            Button("Single View") { model.layout = .single }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Three Planes") { model.layout = .triple }
                .keyboardShortcut("2", modifiers: [.command, .option])
        }
    }
}
