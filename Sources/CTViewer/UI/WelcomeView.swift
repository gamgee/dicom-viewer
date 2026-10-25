import SwiftUI

struct AppGlyph: View {
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.47, blue: 1.0), Color(red: 0.42, green: 0.22, blue: 0.86)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            Image(systemName: "lungs.fill")
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.25, green: 0.3, blue: 0.95).opacity(0.45), radius: 24, y: 10)
    }
}

struct WelcomeView: View {
    @Environment(ViewerModel.self) private var model
    var dropTargeted: Bool

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.24), Color(white: 0.06)],
                           center: .top, startRadius: 40, endRadius: 700)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                AppGlyph()
                VStack(spacing: 8) {
                    Text("CT Viewer")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Open a DICOM folder or disc copy to explore your scan\nin axial, coronal and sagittal planes.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open DICOM Folder…", systemImage: "folder")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o")

                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 22, weight: .light))
                    Text("or drop folders, DICOM files or an .iso here")
                        .font(.callout)
                }
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                .frame(width: 420, height: 110)
                .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .foregroundStyle(dropTargeted ? Color.accentColor : Color.white.opacity(0.18))
                )
                .animation(.easeOut(duration: 0.15), value: dropTargeted)

                HStack(spacing: 18) {
                    Feature(symbol: "square.split.2x1", text: "3-plane MPR")
                    Feature(symbol: "circle.lefthalf.filled", text: "Window presets")
                    Feature(symbol: "ruler", text: "Measurements")
                    Feature(symbol: "list.bullet.rectangle", text: "DICOM tags")
                }
                .padding(.top, 6)

                Text("For viewing only — not for diagnostic use.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
        }
    }
}

private struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct LoadingView: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 16) {
            AppGlyph(size: 64)
            Text(total == 0 ? "Scanning files…" : "Reading images…")
                .font(.headline)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 280)
            Text(total == 0 ? " " : "\(done) of \(total) files")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06))
    }
}
