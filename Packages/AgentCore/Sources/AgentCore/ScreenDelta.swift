import Foundation

/// What changed between two reads of the same app's screen, as text. Element numbers are stable across reads
/// (see `ScreenFormatter`), so unchanged elements keep the numbers the model already holds.
enum ScreenDelta {
    struct Changes: Equatable {
        var added: [String] = []
        var changed: [String] = []
        var removed: [String] = []

        var count: Int { added.count + changed.count + removed.count }
        var isEmpty: Bool { count == 0 }
    }

    static func changes(from old: Rendered, to new: Rendered) -> Changes {
        var changes = Changes()
        var oldNumbered: [Int: ScreenFormatter.Line] = [:]
        var oldPlain: [String: Int] = [:]
        for line in old.lines {
            if let number = line.number { oldNumbered[number] = line } else { oldPlain[line.text, default: 0] += 1 }
        }
        var seen = Set<Int>()
        for line in new.lines {
            if let number = line.number {
                seen.insert(number)
                if let before = oldNumbered[number] {
                    if before.text != line.text { changes.changed.append("~ [\(number)] \(line.text)") }
                } else {
                    changes.added.append("+ [\(number)] \(line.text)")
                }
            } else if let count = oldPlain[line.text], count > 0 {
                oldPlain[line.text] = count - 1
            } else {
                changes.added.append("+ \(line.text)")
            }
        }
        for line in old.lines {
            if let number = line.number, !seen.contains(number) { changes.removed.append("- [\(number)] \(line.text)") }
        }
        for line in old.lines where line.number == nil {
            if let count = oldPlain[line.text], count > 0 {
                oldPlain[line.text] = count - 1
                changes.removed.append("- \(line.text)")
            }
        }
        return changes
    }

    /// The changes as text, or nil when the full screen says it better: a different app, or most lines changed.
    static func text(from old: Rendered, to new: Rendered) -> String? {
        guard old.app.sameApp(as: new.app) else { return nil }
        let changes = changes(from: old, to: new)
        guard changes.count <= max(12, new.lines.count / 2) else { return nil }
        var lines = [new.header, "Changes since the last screen (other elements are unchanged and keep their numbers):"]
        lines += changes.added + changes.changed + changes.removed
        if changes.isEmpty { lines.append("(none)") }
        lines += new.notes
        return lines.joined(separator: "\n")
    }
}

/// Finding things on a rendered screen by text.
enum ScreenQuery {
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Numbered elements whose label or identifier is exactly `label` (ignoring case), optionally of one type.
    static func elements(labeled label: String, type: Int?, in screen: Rendered) -> [ScreenElement] {
        let wanted = normalized(label)
        return screen.items.values
            .filter { item in
                (type == nil || item.type == type)
                    && [item.label, item.identifier].contains { $0.map(normalized) == wanted }
            }
            .sorted { $0.number < $1.number }
    }

    /// Numbered elements whose label contains `label`, for "did you mean" suggestions.
    static func similar(to label: String, in screen: Rendered, limit: Int = 5) -> [ScreenElement] {
        let wanted = normalized(label)
        guard !wanted.isEmpty else { return [] }
        return screen.items.values
            .filter { item in
                guard let shown = item.label.map(normalized) else { return false }
                return shown.contains(wanted) || (wanted.count >= 3 && wanted.contains(shown))
            }
            .sorted { $0.number < $1.number }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether any visible node's label or value contains `text` (ignoring case).
    static func contains(_ text: String, in screen: Rendered) -> Bool {
        let wanted = normalized(text)
        guard !wanted.isEmpty else { return false }
        if let alert = screen.alert, normalized(alert.text).contains(wanted) { return true }
        return screen.nodes.contains { node in
            [node.label, node.value].contains { $0.map(normalized)?.contains(wanted) ?? false }
        }
    }

    /// Whether the foreground app is `app`, by bundle id or name (ignoring case).
    static func isApp(_ app: String, _ info: AppInfo) -> Bool {
        let wanted = normalized(app)
        return [info.bundleID, info.name].contains { $0.map(normalized) == wanted }
    }
}
