import CoreGraphics
import Foundation

/// Where to touch an element so the touch reaches it.
///
/// A tap at an element's centre goes to whatever is drawn on top there. iOS 26's floating glass bars and search
/// pill, a pinned navigation bar, or the keyboard can sit over a row's centre; the tap then scrolls the list or
/// opens something else. This checks the screen's other controls (adapted from iphone-use's `clear_tap_point`,
/// MIT): with the centre covered it taps the tallest uncovered band of the element, and with all of it covered it
/// refuses, naming the cover. Frames come from the accessibility tree, which has no z-order, so bars and the
/// keyboard are taken to be on top of content, and a small control on top of a much bigger sibling.
public enum TapPlan: Equatable, Sendable {
    case center(CGPoint)
    /// The centre is covered; this point inside the element is not.
    case shifted(CGPoint, coveredBy: String)
    /// Nothing of the element can be reached.
    case covered(by: String)
}

enum TapPlanner {
    /// Kinds that take a touch, or bars pinned over content.
    static let occluders: Set<Int> = [
        ElementType.button, ElementType.link, ElementType.cell, ElementType.switchControl, ElementType.textField,
        ElementType.secureTextField, ElementType.searchField, ElementType.textView, ElementType.slider,
        ElementType.navigationBar, ElementType.tabBar, ElementType.toolbar, ElementType.keyboard,
    ]
    /// Taller than this is a container that happens to be typed as a bar.
    static let maxBarHeight: CGFloat = 200
    /// How far floating glass (search pill, bars, keyboard) eats touches outside its frame.
    static let floatingMargin: CGFloat = 14
    /// Content that scrolls under bars (controls usually live inside the bar instead).
    static let contentTypes: Set<Int> = [
        ElementType.cell, ElementType.staticText, ElementType.image, ElementType.other, ElementType.link,
        ElementType.textView,
    ]
    /// Narrowest uncovered band worth tapping.
    static let minimumBand: CGFloat = 8

    static func plan(_ number: Int, in screen: Rendered) -> TapPlan? {
        guard let item = screen.items[number], screen.nodes.indices.contains(item.node) else { return nil }
        return plan(node: item.node, nodes: screen.nodes)
    }

    static func plan(node index: Int, nodes: [LayoutNode]) -> TapPlan {
        let target = nodes[index]
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        // Content behind an alert does not take touches.
        if !target.inAlert, let alert = nodes.first(where: { $0.type == ElementType.alert }) {
            return .covered(by: alert.display)
        }

        struct Cover {
            var top: CGFloat
            var bottom: CGFloat
            var node: LayoutNode
        }
        var covers: [Cover] = []
        for (j, row) in nodes.enumerated() {
            let descendant = j > index && j < target.subtreeEnd
            let ancestor = j < index && row.subtreeEnd > index
            // A row wrapping the whole target is a container around it, except a floating bar over content.
            let wrapper = wraps(row.frame, target.frame) && !(isFloating(row) && contentTypes.contains(target.type))
            guard j != index, !descendant, !ancestor, occluders.contains(row.type), row.frame.width > 0,
                  row.frame.height > 0, !wrapper, canCover(index, j, nodes)
            else { continue }
            let margin = isFloating(row) ? floatingMargin : 0
            let grown = row.frame.insetBy(dx: -margin, dy: -margin)
            guard grown.minX <= center.x, center.x <= grown.maxX else { continue }
            covers.append(Cover(top: grown.minY, bottom: grown.maxY, node: row))
        }
        guard let cover = covers.first(where: { $0.top <= center.y && center.y <= $0.bottom }) else {
            return .center(center)
        }
        // Uncovered vertical bands of the target along its centre column.
        var free = [(target.frame.minY, target.frame.maxY)]
        for cover in covers {
            free = free.flatMap { a, b -> [(CGFloat, CGFloat)] in
                var parts: [(CGFloat, CGFloat)] = []
                if cover.top > a { parts.append((a, min(cover.top, b))) }
                if cover.bottom < b { parts.append((max(cover.bottom, a), b)) }
                return parts.filter { $0.1 - $0.0 > 0 }
            }
        }
        guard let best = free.filter({ $0.1 - $0.0 >= minimumBand }).max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) else {
            return .covered(by: cover.node.display)
        }
        return .shifted(CGPoint(x: center.x, y: (best.0 + best.1) / 2), coveredBy: cover.node.display)
    }

    /// Floating glass over scrolling content, which reaches past its frame.
    static func isFloating(_ node: LayoutNode) -> Bool {
        node.type == ElementType.searchField || node.type == ElementType.keyboard
            || (ElementType.bars.contains(node.type) && node.frame.height <= maxBarHeight)
    }

    /// `outer` holds all of `inner`: a full-row wrapper, not a cover.
    static func wraps(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.minX <= inner.minX + 0.5 && outer.minY <= inner.minY + 0.5
            && outer.maxX >= inner.maxX - 0.5 && outer.maxY >= inner.maxY - 0.5
    }

    static func parent(of index: Int, _ nodes: [LayoutNode]) -> Int? {
        let depth = nodes[index].depth
        return nodes[..<index].lastIndex { $0.depth < depth }
    }

    /// The target sits inside a bar, so only the keyboard or another bar is drawn over it.
    static func isBarItem(_ index: Int, _ nodes: [LayoutNode]) -> Bool {
        nodes[..<index].indices.contains { j in
            ElementType.bars.contains(nodes[j].type) && nodes[j].frame.height <= maxBarHeight && nodes[j].subtreeEnd > index
        }
    }

    static func canCover(_ index: Int, _ j: Int, _ nodes: [LayoutNode]) -> Bool {
        let target = nodes[index], row = nodes[j]
        let sameParent = parent(of: index, nodes) != nil && parent(of: index, nodes) == parent(of: j, nodes)
        // Two links in one run of text: a wrapped link's frame spans both lines.
        if target.type == ElementType.link, row.type == ElementType.link, sameParent { return false }
        // A much bigger sibling (a bar-wide title button) is drawn under the small control at its edge.
        let area = { (rect: CGRect) in rect.width * rect.height }
        if !isFloating(row), sameParent, area(row.frame) > 2 * area(target.frame) { return false }
        // Floating glass is drawn over content, never under it.
        if isFloating(target), !isFloating(row) { return false }
        if isBarItem(index, nodes) {
            return row.type == ElementType.keyboard || (ElementType.bars.contains(row.type) && row.frame.height <= maxBarHeight)
        }
        return true
    }
}
