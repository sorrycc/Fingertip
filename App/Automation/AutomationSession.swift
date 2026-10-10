import Foundation
import SwiftUI

/// Brings up on-device UI automation (adapted from TouchSynthesis's ContentView):
/// lockdown over the LocalDevVPN loopback → idevice heartbeat → testmanagerd DTX → XCTest self-runner.
@MainActor
final class AutomationSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting(String)
        case ready
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var pairingLoaded = false
    @Published private(set) var heartbeatOK = false
    @Published private(set) var keepAliveActive = false
    let logger = ProtocolLogger()

    private var pairingRecord: PairingRecord?
    private var tunnel: IdeviceTunnel?
    private var testManager: TestManagerClient?
    private var selfRunner: SelfRunner?
    private var heartbeatTimer: Timer?

    var isReady: Bool { phase == .ready }

    static var pairingURL: URL {
        URL.documentsDirectory.appending(path: "pairing.plist")
    }

    init() {
        loadSavedPairing()
        // Ask early so the prompt doesn't interrupt the first Start.
        Task { _ = await LocalNetworkPermission.request(timeout: .seconds(10)) }
    }

    // MARK: Pairing

    func loadSavedPairing() {
        guard let data = try? Data(contentsOf: Self.pairingURL) else {
            logger.log("No pairing file yet — import one in Setup", phase: "INIT", level: .warning)
            return
        }
        do {
            pairingRecord = try PairingRecord(fromData: data)
            pairingLoaded = true
            logger.log("Loaded pairing (HostID: \(pairingRecord!.hostID))", phase: "INIT", level: .success)
        } catch {
            logger.log("Saved pairing is invalid: \(error)", phase: "INIT", level: .error)
        }
    }

    func importPairing(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let record = try PairingRecord(fromData: data)
            try data.write(to: Self.pairingURL, options: .completeFileProtectionUntilFirstUserAuthentication)
            pairingRecord = record
            pairingLoaded = true
            logger.log("Pairing imported (HostID: \(record.hostID))", phase: "IMPORT", level: .success)
        } catch {
            logger.log("Import failed: \(error.localizedDescription)", phase: "IMPORT", level: .error)
        }
    }

    // MARK: Start / stop

    func start() async {
        guard let record = pairingRecord else {
            phase = .failed("Import a pairing file first")
            return
        }
        guard !isStarting, phase != .ready else { return }

        // 0. Local Network permission; without it the loopback connection fails with EHOSTUNREACH.
        phase = .starting("Checking Local Network permission…")
        let permission = await LocalNetworkPermission.request()
        logger.log("Local Network permission: \(permission)", phase: "P0", level: permission == .denied ? .error : .info)

        // 1. Lockdown handshake, proving the VPN loopback and pairing record work.
        phase = .starting("Connecting to lockdownd via VPN…")
        do {
            let client = LockdownClient(pairingRecord: record)
            try client.connect()
            _ = try client.queryType()
            _ = try client.startSession()
            client.disconnect()
            logger.log("Lockdown handshake OK", phase: "P1", level: .success)
        } catch {
            let hint = (error as? LockdownError)?.recoverySuggestion.map { " — \($0)" } ?? ""
            let access = permission == .granted ? "" : " Also check Settings → Privacy & Security → Local Network → Agent is on."
            return fail("Lockdown failed: \(error.localizedDescription)\(hint). Is LocalDevVPN connected?\(access)")
        }

        // 2. Heartbeat and tunnel.
        phase = .starting("Starting heartbeat & tunnel…")
        let tunnel = self.tunnel ?? IdeviceTunnel()
        let path = Self.pairingURL.path
        let tunnelError: String? = await Task.detached {
            tunnel.connect(withPairingFile: path, deviceIP: "10.7.0.1", port: 62078)
        }.value
        if let tunnelError {
            return fail("Tunnel failed: \(tunnelError). Is the Developer Disk Image mounted?")
        }
        self.tunnel = tunnel
        heartbeatOK = true
        BackgroundKeepAlive.shared.start()
        keepAliveActive = BackgroundKeepAlive.shared.isActive
        startHeartbeat()

        // 3. Self-runner: DTX to testmanagerd, dlopen XCTest, enable automation (passcode prompt).
        phase = .starting("Starting XCTest self-runner (≈60s, then enter passcode)…")
        do {
            let lockdown = LockdownClient(pairingRecord: record)
            try lockdown.connect()
            _ = try lockdown.queryType()
            _ = try lockdown.startSession()
            let testManager = TestManagerClient(lockdown: lockdown, tunnel: tunnel, logger: logger)
            let runner = SelfRunner(lockdown: lockdown, testManager: testManager, tunnel: tunnel, logger: logger)
            self.testManager = testManager
            selfRunner = runner
            try await runner.start()
        } catch {
            return fail("Self-runner failed: \(error.localizedDescription)")
        }

        let diagnostics: String = await Task.detached { DeviceAutomation.diagnostics() }.value
        for line in diagnostics.split(separator: "\n") {
            logger.log(String(line), phase: "AX", level: .debug)
        }
        phase = .ready
        logger.log("UI automation ready", phase: "READY", level: .success)
    }

    func stop() {
        testManager?.disconnect()
        testManager = nil
        selfRunner = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        tunnel?.disconnect()
        tunnel = nil
        heartbeatOK = false
        BackgroundKeepAlive.shared.stop()
        keepAliveActive = false
        phase = .idle
        logger.log("Stopped. Hold both volume buttons if the automation overlay lingers.", phase: "STOP", level: .success)
    }

    private var isStarting: Bool {
        if case .starting = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        logger.log(message, phase: "START", level: .error)
        stop()
        phase = .failed(message)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let tunnel = self.tunnel else { return }
                let ok = await Task.detached { tunnel.pingTunnel() }.value
                self.heartbeatOK = ok
                if !ok { self.logger.log("Heartbeat: device unreachable", phase: "HB", level: .warning) }
            }
        }
    }
}
