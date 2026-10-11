import CoreGraphics
import Foundation

/// The agent's hands and eyes on a device. `SelfRunnerDriver` implements it on iPhone; `SimulatedPhone` on macOS.
public protocol DeviceDriver: Sendable {
    /// Screen size in points; taps, swipes, and accessibility frames all use this coordinate space.
    var screenSize: CGSize { get async }
    func snapshot() async throws -> ScreenSnapshot
    /// A JPEG of the screen, scaled to `screenSize` so image pixels equal tap points.
    func screenshot() async throws -> Data
    func tap(_ point: CGPoint) async throws
    func longPress(_ point: CGPoint, duration: TimeInterval) async throws
    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws
    /// Types into the focused field. `\n` presses return.
    func typeText(_ text: String) async throws
    func pressHome() async throws
    func launchApp(bundleID: String) async throws
    func openURL(_ url: URL) async throws
    /// Presses a key on the keyboard. Defaults to typing the key's character.
    func pressKey(_ key: KeyboardKey) async throws
    /// Apps installed on the device, for finding apps by name. Empty when the driver cannot list them.
    func installedApps() async -> [InstalledApp]
}

extension DeviceDriver {
    public func pressKey(_ key: KeyboardKey) async throws { try await typeText(key.character) }
    public func installedApps() async -> [InstalledApp] { [] }
}

/// Keys the agent can press.
public enum KeyboardKey: String, Sendable, CaseIterable {
    case `return`, delete, tab, escape, space

    /// The character XCTest types for the key (`XCUIKeyboardKey` raw values).
    public var character: String {
        switch self {
        case .return: "\n"
        case .delete: "\u{7F}"
        case .tab: "\t"
        case .escape: "\u{1B}"
        case .space: " "
        }
    }
}

public struct DriverError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
