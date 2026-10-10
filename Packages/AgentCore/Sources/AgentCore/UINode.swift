import CoreGraphics
import Foundation

/// One node of an accessibility snapshot, platform-neutral so the formatter and tools can run on macOS too.
public struct UINode: Codable, Sendable, Hashable {
    /// `XCUIElementType` raw value.
    public var type: Int
    public var label: String?
    public var identifier: String?
    public var value: String?
    public var placeholder: String?
    public var frame: CGRect
    public var enabled: Bool
    public var selected: Bool
    public var focused: Bool
    public var children: [UINode]

    public init(
        type: Int, label: String? = nil, identifier: String? = nil, value: String? = nil, placeholder: String? = nil,
        frame: CGRect, enabled: Bool = true, selected: Bool = false, focused: Bool = false, children: [UINode] = []
    ) {
        self.type = type
        self.label = label
        self.identifier = identifier
        self.value = value
        self.placeholder = placeholder
        self.frame = frame
        self.enabled = enabled
        self.selected = selected
        self.focused = focused
        self.children = children
    }

    public var typeName: String { ElementType.name(type) }

    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

    /// Builds a tree from the dictionary shape `AXSnapshotter` produces on device.
    public init?(dictionary: [String: Any]) {
        guard let type = dictionary["type"] as? Int else { return nil }
        let frame = dictionary["frame"] as? [Double] ?? [0, 0, 0, 0]
        self.init(
            type: type,
            label: (dictionary["label"] as? String).nonEmpty,
            identifier: (dictionary["identifier"] as? String).nonEmpty,
            value: (dictionary["value"] as? String).nonEmpty,
            placeholder: (dictionary["placeholder"] as? String).nonEmpty,
            frame: frame.count == 4 ? CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) : .zero,
            enabled: dictionary["enabled"] as? Bool ?? true,
            selected: dictionary["selected"] as? Bool ?? false,
            focused: dictionary["focused"] as? Bool ?? false,
            children: (dictionary["children"] as? [[String: Any]] ?? []).compactMap(UINode.init(dictionary:))
        )
    }
}

/// The app in the foreground when a snapshot was taken.
public struct AppInfo: Codable, Sendable, Hashable {
    public var bundleID: String?
    public var name: String?
    public var pid: Int32?

    public init(bundleID: String? = nil, name: String? = nil, pid: Int32? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }

    public var display: String {
        switch (name, bundleID) {
        case let (name?, id?): "\(name) (\(id))"
        case let (nil, id?): id
        case let (name?, nil): name
        default: "unknown app"
        }
    }
}

public struct ScreenSnapshot: Sendable {
    public var app: AppInfo
    public var root: UINode

    public init(app: AppInfo, root: UINode) {
        self.app = app
        self.root = root
    }
}

/// `XCUIElementType` names (XCUIAutomation/XCUIElementTypes.h).
public enum ElementType {
    static let names: [String] = [
        "Any", "Other", "Application", "Group", "Window", "Sheet", "Drawer", "Alert", "Dialog", "Button",
        "RadioButton", "RadioGroup", "CheckBox", "DisclosureTriangle", "PopUpButton", "ComboBox", "MenuButton",
        "ToolbarButton", "Popover", "Keyboard", "Key", "NavigationBar", "TabBar", "TabGroup", "Toolbar", "StatusBar",
        "Table", "TableRow", "TableColumn", "Outline", "OutlineRow", "Browser", "CollectionView", "Slider",
        "PageIndicator", "ProgressIndicator", "ActivityIndicator", "SegmentedControl", "Picker", "PickerWheel",
        "Switch", "Toggle", "Link", "Image", "Icon", "SearchField", "ScrollView", "ScrollBar", "StaticText",
        "TextField", "SecureTextField", "DatePicker", "TextView", "Menu", "MenuItem", "MenuBar", "MenuBarItem", "Map",
        "WebView", "IncrementArrow", "DecrementArrow", "Timeline", "RatingIndicator", "ValueIndicator", "SplitGroup",
        "Splitter", "RelevanceIndicator", "ColorWell", "HelpTag", "Matte", "DockItem", "Ruler", "RulerMarker", "Grid",
        "LevelIndicator", "Cell", "LayoutArea", "LayoutItem", "Handle", "Stepper", "Tab", "TouchBar", "StatusItem",
    ]

    public static func name(_ raw: Int) -> String { names.indices.contains(raw) ? names[raw] : "Type\(raw)" }

    public static let other = 1, application = 2, window = 4, alert = 7, button = 9, keyboard = 19, key = 20
    public static let navigationBar = 21, tabBar = 22, statusBar = 25, table = 26, collectionView = 32
    public static let image = 43, icon = 44, searchField = 45, scrollView = 46, staticText = 48
    public static let textField = 49, secureTextField = 50, textView = 52, map = 57, webView = 58, cell = 75

    /// Types a user can act on directly; these always get an element number.
    static let interactive: Set<Int> = [
        9, 10, 12, 13, 14, 15, 16, 17, 20, 33, 37, 38, 39, 40, 41, 42, 44, 45, 49, 50, 51, 52, 54, 59, 60, 75, 79, 80,
    ]
    /// Text-input types; their value matters and they accept `type_text`.
    static let textInput: Set<Int> = [45, 49, 50, 52]
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
