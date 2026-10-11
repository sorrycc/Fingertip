import Foundation
import Network

/// Triggers (and reports) iOS's Local Network permission. Without it, connecting to the LocalDevVPN loopback
/// (10.7.0.1) fails with EHOSTUNREACH and iOS never shows a prompt, because plain TCP does not trigger one;
/// a Bonjour browse does.
@MainActor
enum LocalNetworkPermission {
    enum Status { case granted, denied, unknown }

    /// Browses for our own advertised service; finding it means access is allowed. Shows the prompt on first use.
    static func request(timeout: Duration = .seconds(30)) async -> Status {
        let service = "_fingertip._tcp"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        guard let listener = try? NWListener(using: parameters) else { return .unknown }
        listener.service = NWListener.Service(name: UUID().uuidString, type: service)
        listener.newConnectionHandler = { $0.cancel() }
        let browser = NWBrowser(for: .bonjour(type: service, domain: nil), using: parameters)

        return await withCheckedContinuation { continuation in
            var finished = false
            var sawDenial = false
            func finish(_ status: Status) {
                guard !finished else { return }
                finished = true
                browser.cancel()
                listener.cancel()
                continuation.resume(returning: status)
            }
            browser.stateUpdateHandler = { state in
                // kDNSServiceErr_PolicyDenied also shows while the prompt is up, so keep waiting for a result.
                if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 { sawDenial = true }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { Task { @MainActor in finish(.granted) } }
            }
            listener.start(queue: .main)
            browser.start(queue: .main)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(sawDenial ? .denied : .unknown)
            }
        }
    }
}
