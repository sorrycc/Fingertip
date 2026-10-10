import AgentCore
import UIKit

/// `DeviceDriver` on the real iPhone: XCTest touch synthesis (TouchSynthesis) plus XCTest accessibility snapshots.
/// Only usable while `AutomationSession` reports `.ready`.
final class SelfRunnerDriver: DeviceDriver, @unchecked Sendable {
    let size: CGSize
    private let queue = DispatchQueue(label: "agent.automation", qos: .userInitiated)

    @MainActor init() {
        size = UIScreen.main.bounds.size
    }

    var screenSize: CGSize { size }

    // MARK: Observation

    func snapshot() async throws -> ScreenSnapshot {
        let dictionary: [String: Any] = try await onQueue {
            var error: NSString?
            guard let result = DeviceAutomation.snapshotForegroundApp(withMaxDepth: 60, error: &error) as? [String: Any] else {
                throw DriverError("Accessibility snapshot failed: \(error as String? ?? "unknown error")")
            }
            return result
        }
        guard let rootDictionary = dictionary["root"] as? [String: Any], let root = UINode(dictionary: rootDictionary) else {
            throw DriverError("Accessibility snapshot had no root element")
        }
        let app = dictionary["app"] as? [String: Any] ?? [:]
        let info = AppInfo(
            bundleID: app["bundleID"] as? String, name: app["name"] as? String, pid: (app["pid"] as? NSNumber)?.int32Value)
        return ScreenSnapshot(app: info, root: root)
    }

    func screenshot() async throws -> Data {
        let (jpeg, error): (Data?, String?) = await withCheckedContinuation { continuation in
            TouchSynthesizer.takeScreenshot(withQuality: 0.7) { data, error in
                continuation.resume(returning: (data, error))
            }
        }
        guard let jpeg, let image = UIImage(data: jpeg) else { throw DriverError("Screenshot failed: \(error ?? "no data")") }
        // Scale device pixels down to points so image coordinates equal tap coordinates (and cost fewer tokens).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.6) else { throw DriverError("Could not encode screenshot") }
        return data
    }

    // MARK: Actions

    func tap(_ point: CGPoint) async throws {
        try await synthesize { TouchSynthesizer.tap(at: point, completion: $0) }
    }

    func longPress(_ point: CGPoint, duration: TimeInterval) async throws {
        try await synthesize { TouchSynthesizer.longPress(at: point, duration: duration, completion: $0) }
    }

    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws {
        try await synthesize { TouchSynthesizer.swipe(from: from, to: to, duration: duration, completion: $0) }
    }

    func typeText(_ text: String) async throws {
        try await synthesize { TouchSynthesizer.typeText(text, typingSpeed: 30, completion: $0) }
    }

    func pressHome() async throws {
        try await synthesize { TouchSynthesizer.pressButton(1, completion: $0) }
    }

    func launchApp(bundleID: String) async throws {
        try await onQueue {
            var path: NSString?
            if let error = DeviceAutomation.launchApp(withBundleID: bundleID, path: &path) { throw DriverError(error) }
        }
    }

    func openURL(_ url: URL) async throws {
        try await onQueue {
            var path: NSString?
            if let error = DeviceAutomation.open(url, path: &path) { throw DriverError(error) }
        }
    }

    // MARK: Helpers

    private func synthesize(_ start: @escaping (@escaping (String?) -> Void) -> Void) async throws {
        let error: String? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { start { continuation.resume(returning: $0) } }
        }
        if let error { throw DriverError(error) }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
