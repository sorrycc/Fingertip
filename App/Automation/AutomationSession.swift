import Combine
import Foundation
import Observation
import SwiftUI

/// Brings up on-device UI automation (adapted from TouchSynthesis's ContentView, moved to RemotePairing):
/// LocalDevVPN loopback → RPPairing tunnel to 10.7.0.1:49152 → RSD heartbeat → testmanagerd DTX via RSD proxies
/// → XCTest self-runner. iOS 26.4+ resets lockdownd (62078) connections over the loopback, hence RPPairing.
@Observable
@MainActor
final class AutomationSession {
    typealias Phase = AutomationPhase
    typealias StartStep = AutomationStartStep

    private(set) var phase = Phase.idle
    private(set) var pairingLoaded = false
    private(set) var heartbeatOK = false
    private(set) var keepAliveActive = false
    /// When the current start began, for the elapsed-time readout.
    private(set) var startedAt: Date?
    @ObservationIgnored let logger = ProtocolLogger()

    @ObservationIgnored private var pairingRecord: PairingRecord?
    private(set) var hasRemotePairing = false
    private(set) var hasLockdownPairing = false
    @ObservationIgnored private var tunnel: IdeviceTunnel?
    @ObservationIgnored private var testManager: TestManagerClient?
    @ObservationIgnored private var selfRunner: SelfRunner?
    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored private var logSink: AnyCancellable?
    @ObservationIgnored private var logWritten = 0

    static let deviceIP = "10.7.0.1"
    static let remotePairingPort: UInt16 = 49152

    /// The protocol log mirrored to Documents, so it can be pulled with `devicectl` after the console stream drops.
    static var logURL: URL { URL.documentsDirectory.appending(path: "automation.log") }

    var isReady: Bool { phase == .ready }

    /// Classic lockdown pairing record (HostCertificate…). Only its type is needed now: TestManagerClient takes a
    /// LockdownClient, which we never connect, so it falls through to the RSD path.
    static var pairingURL: URL { URL.documentsDirectory.appending(path: "pairing.plist") }
    /// RemotePairing file (public_key, private_key, identifier), made by `idevice-tools rppairing pair`.
    static var remotePairingURL: URL { URL.documentsDirectory.appending(path: "rp_pairing.plist") }

    init() {
        try? Data().write(to: Self.logURL)
        logSink = logger.$entries
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] entries in self?.mirrorLog(entries) }
        loadSavedPairing()
        // Ask early so the prompt doesn't interrupt the first Start.
        Task { _ = await LocalNetworkPermission.request(timeout: .seconds(10)) }
    }

    /// Appends new log lines to the mirror file instead of rewriting it.
    private func mirrorLog(_ entries: [LogEntry]) {
        if entries.count < logWritten {
            try? Data().write(to: Self.logURL)
            logWritten = 0
        }
        guard entries.count > logWritten,
              let handle = try? FileHandle(forWritingTo: Self.logURL)
        else { return }
        defer { try? handle.close() }
        let text = entries[logWritten...].map { $0.formatted + "\n" }.joined()
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        logWritten = entries.count
    }

    // MARK: Pairing

    func loadSavedPairing() {
        if let data = try? Data(contentsOf: Self.pairingURL) {
            do {
                pairingRecord = try PairingRecord(fromData: data)
                logger.log("Loaded lockdown pairing (HostID: \(pairingRecord!.hostID))", phase: "INIT", level: .success)
            } catch {
                logger.log("Saved lockdown pairing is invalid: \(error)", phase: "INIT", level: .error)
            }
        }
        hasRemotePairing = FileManager.default.fileExists(atPath: Self.remotePairingURL.path)
        logger.log(hasRemotePairing ? "Loaded RemotePairing file" : "No RemotePairing file — run scripts/install.sh or import rp_pairing.plist",
                   phase: "INIT", level: hasRemotePairing ? .success : .warning)
        hasLockdownPairing = pairingRecord != nil
        pairingLoaded = hasLockdownPairing && hasRemotePairing
    }

    /// Accepts either file; tells them apart by their keys. Returns a message for the user.
    @discardableResult
    func importPairing(from url: URL) -> (ok: Bool, message: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let outcome: (ok: Bool, message: String)
        do {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
            if plist["HostCertificate"] != nil {
                _ = try PairingRecord(fromData: data)
                try data.write(to: Self.pairingURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                outcome = (true, "Lockdown pairing imported")
            } else if plist["private_key"] != nil {
                try data.write(to: Self.remotePairingURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                outcome = (true, "RemotePairing file imported")
            } else {
                outcome = (false, "That file isn't a pairing file")
                logger.log("Not a pairing file (keys: \(plist.keys.sorted()))", phase: "IMPORT", level: .error)
            }
            loadSavedPairing()
        } catch {
            outcome = (false, "Import failed: \(error.localizedDescription)")
        }
        logger.log(outcome.message, phase: "IMPORT", level: outcome.ok ? .success : .error)
        return outcome
    }

    // MARK: Start / stop

    func start() async {
        guard let record = pairingRecord, hasRemotePairing else {
            phase = .failed("Pairing files missing — run scripts/install.sh with the phone plugged in")
            return
        }
        guard !isStarting, phase != .ready else { return }
        startedAt = .now

        // 0. Local Network permission; without it the loopback connection fails with EHOSTUNREACH.
        phase = .starting(.permission)
        let permission = await LocalNetworkPermission.request()
        logger.log("Local Network permission: \(permission)", phase: "P0", level: permission == .denied ? .error : .info)

        // 1. RPPairing tunnel + RSD heartbeat.
        phase = .starting(.tunnel)
        let tunnel = self.tunnel ?? IdeviceTunnel()
        let path = Self.remotePairingURL.path
        let tunnelError: String? = await Task.detached {
            tunnel.connect(withPairingFile: path, deviceIP: Self.deviceIP, port: Self.remotePairingPort)
        }.value
        if let tunnelError {
            let access = permission == .granted ? "" : " Check Settings → Privacy & Security → Local Network → Agent."
            return fail("Tunnel failed: \(tunnelError). Is LocalDevVPN connected?\(access)")
        }
        self.tunnel = tunnel
        heartbeatOK = true
        logger.log("RemotePairing tunnel + heartbeat up", phase: "P1", level: .success)
        BackgroundKeepAlive.shared.start()
        keepAliveActive = BackgroundKeepAlive.shared.isActive
        startHeartbeat()

        // 2. Self-runner: DTX to testmanagerd (RSD proxies), dlopen XCTest, enable automation (passcode prompt).
        phase = .starting(.selfRunner)
        do {
            let preload: String = await Task.detached { DeviceAutomation.preloadXCTest() }.value
            for line in preload.split(separator: "\n") {
                logger.log(String(line), phase: "DLOPEN", level: line.hasPrefix("OK") ? .success : .error)
            }
            // Never connected: its startService fails fast and TestManagerClient uses the tunnel's RSD proxies.
            let lockdown = LockdownClient(pairingRecord: record)
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
        startedAt = nil
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
        startedAt = nil
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
