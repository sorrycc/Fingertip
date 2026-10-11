import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A scripted fake iPhone for exercising the agent loop off-device (macOS CLI, tests, SwiftUI previews).
///
/// It has a home screen and one app, "SkyFares", where the agent can search flights and read prices.
public actor SimulatedPhone: DeviceDriver {
    enum Screen: Equatable { case home, search, results }

    public nonisolated var screenSize: CGSize { CGSize(width: 430, height: 932) }
    public private(set) var log: [String] = []

    var screen = Screen.home
    var focusedField: String?
    var fields: [String: String] = ["from": "Dublin", "to": "", "date": ""]

    public init() {}

    public func snapshot() async throws -> ScreenSnapshot {
        switch screen {
        case .home:
            return ScreenSnapshot(app: AppInfo(bundleID: "com.apple.springboard", name: "Home Screen"), root: root([
                node(.icon, "Safari", 60, 120), node(.icon, "SkyFares", 160, 120), node(.icon, "Notes", 260, 120),
                node(.icon, "Settings", 360, 120),
            ]))
        case .search:
            return ScreenSnapshot(app: app, root: root([
                UINode(type: ElementType.navigationBar, label: "Find flights", frame: rect(215, 80, 430, 60)),
                field("from", "From", 215, 180), field("to", "To", 215, 250), field("date", "Date", 215, 320),
                node(.button, "Search flights", 215, 420),
                focusedField != nil ? UINode(type: ElementType.keyboard, frame: rect(215, 800, 430, 260)) : nil,
            ].compactMap { $0 }))
        case .results:
            let to = fields["to"] ?? ""
            let fares: [(String, Int)] = [("07:10 FR 662", 41), ("11:45 FR 668", 58), ("19:20 FR 672", 29), ("21:05 EI 162", 112)]
            return ScreenSnapshot(app: app, root: root([
                UINode(type: ElementType.navigationBar, label: "Dublin → \(to)", frame: rect(215, 80, 430, 60), children: [
                    node(.button, "Back", 40, 80),
                ]),
                UINode(type: ElementType.table, frame: rect(215, 500, 430, 760), children: fares.enumerated().map { i, fare in
                    UINode(type: ElementType.cell, label: "\(fare.0), €\(fare.1)", frame: rect(215, Double(180 + i * 90), 430, 80))
                }),
            ]))
        }
    }

    public func screenshot() async throws -> Data {
        let size = screenSize
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw DriverError("no context") }
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        for child in try await snapshot().root.children {
            // CoreGraphics is bottom-up; flip so the image matches screen points.
            var frame = child.frame
            frame.origin.y = size.height - frame.maxY
            context.fill(frame.insetBy(dx: 4, dy: 4))
        }
        guard let image = context.makeImage() else { throw DriverError("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DriverError("no encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    public func tap(_ point: CGPoint) async throws {
        log.append("tap \(Int(point.x)),\(Int(point.y))")
        let hit = try await snapshot().root.children.flatMap { [$0] + $0.children }.last { $0.frame.contains(point) }
        guard let hit else { focusedField = nil; return }
        switch (screen, hit.label ?? hit.identifier) {
        case (.home, "SkyFares"): screen = .search
        case (.search, "Search flights"):
            focusedField = nil
            if !(fields["to"] ?? "").isEmpty { screen = .results }
        case (.search, let label?) where ["From", "To", "Date"].contains(label): focusedField = label.lowercased()
        case (.results, "Back"): screen = .search
        default: break
        }
    }

    public func longPress(_ point: CGPoint, duration: TimeInterval) async throws { log.append("longPress") }

    public func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws {
        log.append("swipe \(Int(from.x)),\(Int(from.y))->\(Int(to.x)),\(Int(to.y))")
    }

    public func typeText(_ text: String) async throws {
        log.append("type \(text.debugDescription)")
        guard let field = focusedField else { throw DriverError("No text field is focused; tap one first.") }
        var value = fields[field] ?? ""
        for character in text {
            switch character {
            case "\n": focusedField = nil
            case "\u{7F}": if !value.isEmpty { value.removeLast() }
            default: value.append(character)
            }
        }
        fields[field] = value
    }

    public func pressHome() async throws {
        log.append("home")
        screen = .home
        focusedField = nil
    }

    public func launchApp(bundleID: String) async throws {
        log.append("launch \(bundleID)")
        guard bundleID == app.bundleID else { throw DriverError("\(bundleID) is not installed") }
        screen = .search
    }

    public func openURL(_ url: URL) async throws { log.append("open \(url)") }

    public func installedApps() async -> [InstalledApp] {
        [
            InstalledApp(bundleID: app.bundleID ?? "", name: app.name ?? ""),
            InstalledApp(bundleID: "com.apple.mobilesafari", name: "Safari"),
            InstalledApp(bundleID: "com.apple.mobilenotes", name: "Notes"),
            InstalledApp(bundleID: "com.apple.Preferences", name: "Settings"),
        ]
    }

    // MARK: Building blocks

    let app = AppInfo(bundleID: "com.example.skyfares", name: "SkyFares")

    enum Kind { case icon, button }

    func root(_ children: [UINode]) -> UINode {
        UINode(type: ElementType.application, frame: CGRect(origin: .zero, size: screenSize), children: [
            UINode(type: ElementType.window, frame: CGRect(origin: .zero, size: screenSize), children: children),
        ])
    }

    func node(_ kind: Kind, _ label: String, _ x: Double, _ y: Double) -> UINode {
        UINode(type: kind == .icon ? ElementType.icon : ElementType.button, label: label, frame: rect(x, y, 90, 60))
    }

    func field(_ key: String, _ label: String, _ x: Double, _ y: Double) -> UINode {
        UINode(
            type: ElementType.textField, label: label, value: (fields[key]).nonEmpty, placeholder: label,
            frame: rect(x, y, 380, 50), focused: focusedField == key)
    }

    func rect(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
