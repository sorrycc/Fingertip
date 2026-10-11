import CoreGraphics
import Foundation

/// Turns an accessibility tree into compact text the model can read, numbering every element it may act on.
///
/// ```
/// App: Ryanair (com.ryanair.cheapflights)  screen 430x932 points
/// [1] Button "Back" @(32,74)
/// NavigationBar "Search"
///   [2] SearchField "Destination" value="" placeholder="Where to?" @(215,140)
/// ```
///
/// Numbers are stable: rendered with the previous screen of the same app, an element that is still there keeps its
/// number, and new elements get numbers never used before in that app. So an action's result can list only what
/// changed, and the numbers the model already holds stay valid.
///
/// Decoration is left out: SF Symbol names, text repeating the label of the control it sits in, and plain text
/// already printed. An unlabeled cell is named by its texts, so the cell is the one thing to tap.
public struct ScreenFormatter: Sendable {
    public var screen: CGSize
    public var maxLines: Int
    public var maxTextLength: Int

    public init(screen: CGSize, maxLines: Int = 350, maxTextLength: Int = 120) {
        self.screen = screen
        self.maxLines = maxLines
        self.maxTextLength = maxTextLength
    }

    /// One printed line.
    public struct Line: Sendable, Equatable {
        public var number: Int?
        /// The line without its number or indentation.
        public var text: String
        var depth: Int

        public var rendered: String {
            String(repeating: "  ", count: min(depth, 12)) + (number.map { "[\($0)] " } ?? "") + text
        }
    }

    public struct Rendered: Sendable {
        public var app: AppInfo
        /// "App: …" plus, when present, the alert notice.
        public var header: String
        public var lines: [Line]
        /// Truncation and opaque-screen notes, printed after the lines.
        public var notes: [String]
        /// Element number → what was shown for it.
        public var items: [Int: ScreenElement]
        /// Every visible node in tree order, for geometry questions (what covers what, what the screen says).
        var nodes: [LayoutNode]
        public var alert: AlertInfo?
        public var keyboardFrame: CGRect?
        /// An activity indicator is spinning, so the screen is probably still loading.
        public var isLoading: Bool
        /// Few accessible elements: a web view, map, game, or custom drawing.
        public var looksOpaque: Bool
        /// The lines as printed; two reads with the same body show the same screen.
        public var body: String
        /// The next number a new element in this app gets.
        var nextNumber: Int

        public var text: String { ([header] + lines.map(\.rendered) + notes).joined(separator: "\n") }
        /// Element number → visible frame in screen points.
        public var elements: [Int: CGRect] { items.mapValues(\.frame) }
        public var elementCount: Int { items.count }
        /// Nothing usable to judge from: no elements at all.
        public var isSparse: Bool { items.isEmpty }

        /// Same screen as `other`: same app and the same printed lines.
        public func sameScreen(as other: Rendered) -> Bool { app.sameApp(as: other.app) && body == other.body }
    }

    // MARK: Rendering

    private struct Entry {
        var node: UINode
        var label: String?
        var visible: CGRect
        var depth: Int
        var actionable: Bool
        var layout: Int
        /// Printed instead of a description (the keyboard line).
        var special: String?
    }

    public func render(_ snapshot: ScreenSnapshot, previous: Rendered? = nil) -> Rendered {
        let screenRect = CGRect(origin: .zero, size: screen)
        var entries: [Entry] = []
        var nodes: [LayoutNode] = []
        var printed = Set<String>()
        var truncated = false
        var opaqueArea: CGFloat = 0
        var keyboardFrame: CGRect?
        var keyboardHints: CGRect?
        var loading = false
        var alert: AlertInfo?
        var walkingSystemAlert = false

        func walk(_ node: UINode, depth: Int, display: Int, inAlert: Bool, owner: String?) {
            guard !truncated else { return }
            let visible = node.frame.intersection(screenRect)
            // Off-screen subtrees are noise; zero-size containers can still hold visible children.
            if node.frame.width > 0, node.frame.height > 0, visible.isNull || visible.width < 1 || visible.height < 1 {
                return
            }
            let box = visible.isNull ? .zero : visible
            let inAlert = inAlert || node.type == ElementType.alert
            let index = nodes.count
            nodes.append(LayoutNode(
                type: node.type, label: node.label ?? node.identifier, value: node.value, frame: box, depth: depth,
                subtreeEnd: index + 1, inAlert: inAlert))
            defer { nodes[index].subtreeEnd = nodes.count }

            if node.type == ElementType.keyboard {
                keyboardFrame = box
                entries.append(Entry(
                    node: node, visible: box, depth: display, actionable: false, layout: index,
                    special: "Keyboard (visible; use type_text and press_key instead of tapping keys)"))
                return
            }
            // Some apps (Shortcuts' action search) host the keyboard in a plain input view with no Keyboard element.
            if Self.keyboardHintIDs.contains(node.identifier ?? ""), box.width > 0 {
                keyboardHints = keyboardHints.map { $0.union(box) } ?? box
            }
            if node.type == ElementType.webView || node.type == ElementType.map { opaqueArea += box.width * box.height }
            if node.type == ElementType.activityIndicator, box.width > 0 { loading = true }
            if node.type == ElementType.alert, alert == nil { alert = alertInfo(node, system: walkingSystemAlert) }

            let label = displayLabel(node)
            let interactive = ElementType.interactive.contains(node.type)
            var actionable = isActionable(node, label: label)
            var shown = actionable || label != nil || node.value != nil || Self.structural.contains(node.type)
            // Text or an icon repeating what the control it sits in already says.
            if !interactive, let label, let owner, owner.localizedCaseInsensitiveContains(label) {
                shown = false
                actionable = false
            }
            // Text already printed (a page title under its navigation bar).
            if shown, !interactive, node.value == nil, let label, printed.contains(label) {
                shown = false
                actionable = false
            }
            if shown {
                if entries.count >= maxLines {
                    truncated = true
                    return
                }
                entries.append(Entry(node: node, label: label, visible: box, depth: display, actionable: actionable, layout: index))
                if let label { printed.insert(label) }
            }
            let childOwner = actionable ? (label ?? owner) : owner
            for child in node.children {
                walk(child, depth: depth + 1, display: shown ? display + 1 : display, inAlert: inAlert, owner: childOwner)
            }
        }

        if let systemAlert = snapshot.alert {
            walkingSystemAlert = true
            walk(systemAlert, depth: 0, display: 0, inAlert: true, owner: nil)
            walkingSystemAlert = false
        }
        for child in snapshot.root.children { walk(child, depth: 1, display: 0, inAlert: false, owner: nil) }
        if keyboardFrame == nil { keyboardFrame = keyboardHints }

        // Numbers: keep the previous screen's number for the same element, else a fresh one.
        let reuse = previous.flatMap { $0.app.sameApp(as: snapshot.app) ? $0 : nil }
        var previousNumbers: [String: Int] = [:]
        for item in reuse.map({ Array($0.items.values) }) ?? [] { previousNumbers[item.key] = item.number }
        var next = reuse?.nextNumber ?? 1
        var occurrences: [String: Int] = [:]
        var keys: [Int: String] = [:]
        var numbers: [Int: Int] = [:]
        var used = Set<Int>()
        for (i, entry) in entries.enumerated() where entry.actionable {
            let base = "\(entry.node.type)|\(entry.label ?? "")|\(entry.node.identifier ?? "")|\(entry.node.placeholder ?? "")"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let key = "\(base)#\(occurrence)"
            keys[i] = key
            if let number = previousNumbers[key], !used.contains(number) {
                numbers[i] = number
                used.insert(number)
            }
        }
        for i in entries.indices where entries[i].actionable && numbers[i] == nil {
            while used.contains(next) { next += 1 }
            numbers[i] = next
            used.insert(next)
            next += 1
        }

        // Labels shared by several controls get their identifier printed, to tell them apart.
        var labelCounts: [String: Int] = [:]
        for entry in entries where entry.actionable {
            if let label = entry.label?.lowercased() { labelCounts[label, default: 0] += 1 }
        }

        var lines: [Line] = []
        var items: [Int: ScreenElement] = [:]
        for (i, entry) in entries.enumerated() {
            if let special = entry.special {
                lines.append(Line(number: nil, text: special, depth: entry.depth))
                continue
            }
            let shared = entry.label.map { labelCounts[$0.lowercased(), default: 0] > 1 } ?? false
            let text = describe(entry.node, label: entry.label, visible: entry.visible, showID: shared)
            let number = numbers[i]
            lines.append(Line(number: number, text: text, depth: entry.depth))
            if let number {
                let node = entry.node
                items[number] = ScreenElement(
                    number: number, type: node.type, label: entry.label, identifier: node.identifier, value: node.value,
                    frame: entry.visible, enabled: node.enabled, focused: node.focused, node: entry.layout,
                    key: keys[i] ?? "")
            }
        }

        var header = "App: \(snapshot.app.display)  screen \(Int(screen.width))x\(Int(screen.height)) points"
        if keyboardFrame != nil { header += "  keyboard: up" }
        if let alert {
            header += "\n" + (alert.isSystem ? "System alert" : "Alert") + " on screen: \(alert.summary). "
                + "Answer it with answer_alert before doing anything else."
        }
        var notes: [String] = []
        if truncated { notes.append("… (tree truncated at \(maxLines) lines; scroll or take a screenshot for more)") }
        let screenArea = max(screen.width * screen.height, 1)
        let looksOpaque = items.count < 4 || opaqueArea / screenArea > 0.5
        if looksOpaque {
            notes.append("Note: few accessible elements here (web view, map, game, or custom drawing). Use `screenshot` to see the screen and tap by x/y.")
        }
        return Rendered(
            app: snapshot.app, header: header, lines: lines, notes: notes, items: items, nodes: nodes, alert: alert,
            keyboardFrame: keyboardFrame, isLoading: loading, looksOpaque: looksOpaque,
            body: lines.map(\.rendered).joined(separator: "\n"), nextNumber: next)
    }

    /// Shown even without a label: they give the screen its structure.
    private static let structural: Set<Int> = [ElementType.alert, ElementType.navigationBar, ElementType.tabBar]

    /// The label to show: SF Symbol names dropped from non-controls, an unlabeled cell named by its texts, else a
    /// meaningful identifier.
    private func displayLabel(_ node: UINode) -> String? {
        var label = node.label
        if let current = label, !ElementType.interactive.contains(node.type), Self.isSymbolName(current) { label = nil }
        if label == nil, node.type == ElementType.cell {
            let texts = node.descendantTexts(limit: 3)
            if !texts.isEmpty { label = texts.joined(separator: " · ") }
        }
        if label == nil, let identifier = node.identifier, !Self.isGeneratedID(identifier) { label = identifier }
        return label
    }

    private func isActionable(_ node: UINode, label: String?) -> Bool {
        if ElementType.interactive.contains(node.type) { return true }
        // Labeled images and texts are often the only tappable thing in custom cells.
        if node.type == ElementType.staticText || node.type == ElementType.image || node.type == ElementType.other {
            return label != nil
        }
        return false
    }

    private func describe(_ node: UINode, label: String?, visible: CGRect, showID: Bool) -> String {
        var parts = [node.typeName]
        if let label { parts.append(quote(label)) }
        if showID, let identifier = node.identifier, identifier != label, !Self.isGeneratedID(identifier) {
            parts.append("id=\(quote(identifier))")
        }
        if let value = node.value, value != label { parts.append("value=\(quote(value))") }
        if ElementType.textInput.contains(node.type) {
            if node.value == nil { parts.append("value=\"\"") }
            if let placeholder = node.placeholder, placeholder != label { parts.append("placeholder=\(quote(placeholder))") }
        }
        if !node.enabled { parts.append("disabled") }
        if node.selected { parts.append("selected") }
        if node.focused { parts.append("focused") }
        parts.append("@(\(Int(visible.midX)),\(Int(visible.midY)))")
        return parts.joined(separator: " ")
    }

    private func alertInfo(_ node: UINode, system: Bool) -> AlertInfo {
        var texts: [String] = []
        var buttons: [String] = []
        func collect(_ node: UINode) {
            if node.type == ElementType.button, let label = node.label ?? node.identifier {
                buttons.append(label)
                return
            }
            if node.type == ElementType.staticText, let label = node.label { texts.append(label) }
            node.children.forEach(collect)
        }
        collect(node)
        if texts.isEmpty, let label = node.label { texts.append(label) }
        return AlertInfo(text: texts.joined(separator: " — "), buttons: buttons, isSystem: system)
    }

    private func quote(_ text: String) -> String {
        var flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        if flat.count > maxTextLength { flat = String(flat.prefix(maxTextLength)) + "…" }
        return "\"\(flat)\""
    }

    /// An SF Symbol name such as `chevron.forward`: decoration, not content.
    static func isSymbolName(_ label: String) -> Bool {
        label.contains(".") && label.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." }
    }

    /// Identifiers of a keyboard's own parts: its input view and its dictation key.
    static let keyboardHintIDs: Set<String> = ["inputView", "dictation"]

    /// Auto-generated identifiers (UUIDs, long dotted paths) name nothing the model can use.
    static func isGeneratedID(_ identifier: String) -> Bool {
        if identifier.count > 48 { return true }
        let hexRun = identifier.split { !$0.isHexDigit }.contains { $0.count >= 8 }
        return hexRun && identifier.filter { $0 == "-" }.count >= 4
    }
}

public typealias Rendered = ScreenFormatter.Rendered

/// A numbered element as it was shown.
public struct ScreenElement: Sendable, Equatable {
    public var number: Int
    public var type: Int
    /// The label shown: the element's label, its cell texts, or its identifier.
    public var label: String?
    public var identifier: String?
    public var value: String?
    /// Visible part of the element, in screen points.
    public var frame: CGRect
    public var enabled: Bool
    public var focused: Bool
    /// Index into `Rendered.nodes`.
    var node: Int
    /// What identifies it across reads, for stable numbering.
    var key: String

    public var typeName: String { ElementType.name(type) }
    public var isSecure: Bool { type == ElementType.secureTextField }
    public var isTextInput: Bool { ElementType.textInput.contains(type) }

    /// `Button "Search"`, for messages.
    public var display: String { label.map { "\(typeName) “\($0)”" } ?? typeName }
}

/// A visible node, in tree order, with the range of its subtree.
struct LayoutNode: Sendable, Equatable {
    var type: Int
    var label: String?
    var value: String?
    var frame: CGRect
    var depth: Int
    /// One past the index of its last descendant.
    var subtreeEnd: Int
    /// Part of an alert.
    var inAlert: Bool

    var display: String { label.map { "\(ElementType.name(type)) “\($0)”" } ?? ElementType.name(type) }
}

/// An alert on screen.
public struct AlertInfo: Sendable, Equatable {
    public var text: String
    public var buttons: [String]
    /// Owned by another process (SpringBoard) rather than the foreground app.
    public var isSystem: Bool

    public var summary: String {
        let clipped = text.count > 160 ? String(text.prefix(160)) + "…" : text
        let shown = text.isEmpty ? "(no text)" : "“\(clipped)”"
        return shown + (buttons.isEmpty ? "" : ", buttons: " + buttons.map { "“\($0)”" }.joined(separator: ", "))
    }
}

extension UINode {
    /// Labels of descendant static texts, in order, skipping SF Symbol names.
    func descendantTexts(limit: Int) -> [String] {
        var texts: [String] = []
        func visit(_ node: UINode) {
            guard texts.count < limit else { return }
            if node.type == ElementType.staticText, let label = node.label, !ScreenFormatter.isSymbolName(label) {
                texts.append(label)
            }
            node.children.forEach(visit)
        }
        children.forEach(visit)
        return texts
    }
}

extension AppInfo {
    /// Same app, ignoring the pid.
    public func sameApp(as other: AppInfo) -> Bool {
        (bundleID ?? name) == (other.bundleID ?? other.name)
    }
}
