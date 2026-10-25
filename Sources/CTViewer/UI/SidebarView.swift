import SwiftUI

struct SidebarView: View {
    @Environment(ViewerModel.self) private var model

    var body: some View {
        Group {
            if model.volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Study", systemImage: "square.stack.3d.down.right")
                } description: {
                    Text("Open a folder of DICOM images to see its series here.")
                } actions: {
                    Button("Open…") { model.presentOpenPanel() }
                }
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.studies) { group in
                        Section {
                            ForEach(group.volumes) { volume in
                                SeriesRow(volume: volume).tag(volume.id)
                            }
                        } header: {
                            StudyHeader(study: group.study)
                        }
                    }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let v = model.volumes.first {
                        PatientCard(patient: v.patient, studyDate: v.study.date)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if model.skippedFiles > 0 {
                    Label("\(model.skippedFiles) non-image file\(model.skippedFiles == 1 ? "" : "s") skipped",
                          systemImage: "doc.badge.ellipsis")
                }
                Label("Not for diagnostic use", systemImage: "exclamationmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct PatientCard: View {
    let patient: PatientInfo
    let studyDate: String?

    var body: some View {
        let name = DicomFormat.personName(patient.name) ?? patient.id ?? "Anonymous"
        let details = [DicomFormat.sex(patient.sex), DicomFormat.age(patient, studyDate: studyDate)].compactMap { $0 }
        HStack(spacing: 12) {
            Text(DicomFormat.initials(name))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    LinearGradient(colors: [Color(red: 0.28, green: 0.55, blue: 1.0), Color(red: 0.48, green: 0.33, blue: 0.95)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1)
                if let id = patient.id, id != name {
                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StudyHeader: View {
    let study: StudyInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(study.description ?? "Study")
            if let detail = [DicomFormat.date(study.date), study.institution].compactMap({ $0 }).first {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).textCase(nil)
            }
        }
    }
}

struct SeriesRow: View {
    let volume: Volume

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.black
                if let thumb = volume.thumbnail {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(volume.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(volume.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Badge(text: volume.modality)
                    if volume.supportsMPR { Badge(text: "3D") }
                    if let n = volume.seriesNumber {
                        Text(verbatim: "#\(n)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.secondary)
    }
}
