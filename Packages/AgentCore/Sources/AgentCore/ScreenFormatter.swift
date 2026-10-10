import CoreGraphics
import Foundation

/// Turns an accessibility tree into compact text the model can read, numbering every element it may act on.
///
/// ```
/// App: Ryanair (com.ryanair.cheapflights)  screen 430x932
/// [1] Button "Back" @(32,74)
/// NavigationBar "Search"
///   [2] SearchField "Destination" value="" placeholder="Where to?" @(215,140)
/// ```
public struct ScreenFormatter: Sendable {
    public struct Rendered: Sendable {
        public var text: String
        /// Element number → frame in screen points.
        public var elements: [Int: CGRect]
        /// How many elements were numbered; a near-empty tree usually means a canvas, game, or web content.
        public var elementCount: Int { elements.count }
        public var looksOpaque: Bool
    }

    public var screen: CGSize
    public var maxLines: Int
    public var maxTextLength: Int

    public init(screen: CGSize, maxLines: Int = 350, maxTextLength: Int = 120) {
        self.screen = screen
        self.maxLines = maxLines
        self.maxTextLength = maxTextLength
    }

    public func render(_ snapshot: ScreenSnapshot) -> Rendered {
        var lines: [String] = []
        var elements: [Int: CGRect] = [:]
        var truncated = false
        var opaqueArea: CGFloat = 0
        var keyboardVisible = false
        let screenRect = CGRect(origin: .zero, size: screen)

        func visit(_ node: UINode, depth: Int) {
            guard !truncated else { return }
            let visible = node.frame.intersection(screenRect)
            // Off-screen subtrees are noise; zero-size containers can still hold visible children.
            if node.frame.width > 0, node.frame.height > 0, visible.isNull || visible.width < 1 || visible.height < 1 {
                return
            }
            if node.type == ElementType.keyboard {
                keyboardVisible = true
                lines.append(indent(depth) + "Keyboard (visible; use type_text instead of tapping keys)")
                return
            }
            if node.type == ElementType.webView || node.type == ElementType.map {
                opaqueArea += visible.width * visible.height
            }
            let shown = shouldShow(node)
            var childDepth = depth
            if shown {
                if lines.count >= maxLines {
                    truncated = true
                    return
                }
                var line = indent(depth)
                if isActionable(node) {
                    let number = elements.count + 1
                    elements[number] = visible
                    line += "[\(number)] "
                }
                line += describe(node, visible: visible)
                lines.append(line)
                childDepth += 1
            }
            for child in node.children { visit(child, depth: childDepth) }
        }

        for child in snapshot.root.children { visit(child, depth: 0) }

        var header = "App: \(snapshot.app.display)  screen \(Int(screen.width))x\(Int(screen.height)) points"
        if keyboardVisible { header += "  keyboard: up" }
        var text = ([header] + lines).joined(separator: "\n")
        if truncated { text += "\n… (tree truncated at \(maxLines) lines; scroll or take a screenshot for more)" }
        let screenArea = max(screen.width * screen.height, 1)
        let looksOpaque = elements.count < 4 || opaqueArea / screenArea > 0.5
        if looksOpaque {
            text += "\nNote: few accessible elements here (web view, map, game, or custom drawing). Use `screenshot` to see the screen and tap by x/y."
        }
        return Rendered(text: text, elements: elements, looksOpaque: looksOpaque)
    }

    private func indent(_ depth: Int) -> String { String(repeating: "  ", count: min(depth, 12)) }

    private func isActionable(_ node: UINode) -> Bool {
        if ElementType.interactive.contains(node.type) { return true }
        // Labeled images and texts are often the only tappable thing in custom cells.
        if node.type == ElementType.staticText || node.type == ElementType.image || node.type == ElementType.other {
            return node.label != nil || node.identifier != nil
        }
        return false
    }

    private func shouldShow(_ node: UINode) -> Bool {
        if isActionable(node) { return true }
        if node.label != nil || node.value != nil { return true }
        switch node.type {
        case ElementType.alert, ElementType.navigationBar, ElementType.tabBar: return true
        default: return false
        }
    }

    private func describe(_ node: UINode, visible: CGRect) -> String {
        var parts = [node.typeName]
        let label = node.label ?? node.identifier
        if let label { parts.append(quote(label)) }
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

    private func quote(_ text: String) -> String {
        var flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        if flat.count > maxTextLength { flat = String(flat.prefix(maxTextLength)) + "…" }
        return "\"\(flat)\""
    }
}
