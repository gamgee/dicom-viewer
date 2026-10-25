import Foundation

/// Human-friendly formatting of DICOM value representations.
enum DicomFormat {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func parseDate(_ da: String?) -> Date? {
        guard let da, da.count >= 8 else { return nil }
        return parser.date(from: String(da.prefix(8)))
    }

    static func date(_ da: String?) -> String? {
        guard let da else { return nil }
        return parseDate(da).map { display.string(from: $0) } ?? da
    }

    /// "DOE^JANE^M" → "Jane M Doe"; all-caps names are title-cased.
    static func personName(_ pn: String?) -> String? {
        guard let pn, !pn.isEmpty else { return nil }
        let parts = pn.split(separator: "^", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let family = parts.first ?? ""
        let given = parts.dropFirst().prefix(2).filter { !$0.isEmpty }
        var name = (given + [family]).filter { !$0.isEmpty }.joined(separator: " ")
        if name == name.uppercased(), name.contains(where: \.isLetter), !name.contains(where: \.isNumber) {
            name = name.capitalized
        }
        return name.isEmpty ? nil : name
    }

    static func initials(_ name: String?) -> String {
        guard let name else { return "?" }
        let letters = name.split(separator: " ").compactMap(\.first).filter(\.isLetter)
        let s = String(letters.prefix(1) + letters.suffix(letters.count > 1 ? 1 : 0)).uppercased()
        return s.isEmpty ? "#" : s
    }

    static func age(_ patient: PatientInfo, studyDate: String?) -> String? {
        if let a = patient.age, let n = Int(a.prefix(3)) {
            switch a.last {
            case "Y": return "\(n) y"
            case "M": return "\(n) mo"
            case "W": return "\(n) wk"
            case "D": return "\(n) d"
            default: break
            }
        }
        guard let birth = parseDate(patient.birthDate) else { return nil }
        let ref = parseDate(studyDate) ?? Date()
        return Calendar.current.dateComponents([.year], from: birth, to: ref).year.map { "\($0) y" }
    }

    static func sex(_ s: String?) -> String? {
        switch s?.uppercased() {
        case "F": "Female"
        case "M": "Male"
        case "O": "Other"
        default: nil
        }
    }
}
