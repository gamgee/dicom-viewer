import SwiftUI

struct TagInspectorView: View {
    @Environment(ViewerModel.self) private var model
    @State private var search = ""

    var body: some View {
        let volume = model.selected
        let index = model.cursor.z
        let tags = volume.map { $0.sliceTags[min(index, $0.sliceTags.count - 1)] } ?? []
        let rows = search.isEmpty ? tags : tags.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search)
                || $0.tag.localizedCaseInsensitiveContains(search)
        }

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DICOM Attributes").font(.headline)
                if let volume {
                    Text("\(volume.sliceFiles[min(index, volume.sliceFiles.count - 1)].lastPathComponent) · image \(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 12)

            Table(rows) {
                TableColumn("Tag") { row in
                    Text(row.tag).font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 84, ideal: 88, max: 96)
                TableColumn("Name") { row in
                    Text(row.name).lineLimit(1).help(row.name)
                }
                .width(min: 90, ideal: 150)
                TableColumn("Value") { row in
                    Text(row.value).lineLimit(1).textSelection(.enabled).help(row.value)
                }
            }
            .font(.system(size: 11.5))
        }
    }
}
