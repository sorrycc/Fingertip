import SwiftUI
import UniformTypeIdentifiers

/// One-time setup and the start/stop switch for on-device UI automation.
struct SetupView: View {
    @EnvironmentObject private var automation: AutomationSession
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Connect LocalDevVPN", done: nil,
                         detail: "Install LocalDevVPN from the App Store and turn it on. It gives this app a loopback path to the phone's own lockdownd (10.7.0.1).")
                    step(2, "Developer Disk Image mounted", done: nil,
                         detail: "Plug into a Mac with Xcode once after each reboot (or use StikDebug) so XCTest frameworks are available.")
                    HStack {
                        step(3, "Pairing file", done: automation.pairingLoaded,
                             detail: "Create it on the Mac with scripts/make-pairing.sh, AirDrop the .mobiledevicepairing file here.")
                        Button(automation.pairingLoaded ? "Replace" : "Import") { importing = true }
                            .buttonStyle(.bordered)
                    }
                } header: {
                    Text("Before you start")
                }

                Section {
                    switch automation.phase {
                    case .ready:
                        Label("UI automation running", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Stop UI automation", role: .destructive) { automation.stop() }
                    case .starting(let step):
                        HStack { ProgressView(); Text(step).font(.footnote) }
                    case .idle, .failed:
                        if case .failed(let message) = automation.phase {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                        Button("Start UI automation") { Task { await automation.start() } }
                            .disabled(!automation.pairingLoaded)
                    }
                    HStack(spacing: 16) {
                        dot("Heartbeat", automation.heartbeatOK)
                        dot("Background", automation.keepAliveActive)
                        dot("Touch", automation.isReady)
                    }
                    .font(.caption)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Starting takes about a minute; iOS then asks for your passcode and shows an \"Automation Running\" overlay. Allow location \"Always\" so the agent keeps running while other apps are in front.")
                }

                Section("Log") {
                    DisclosureGroup("Protocol log (\(automation.logger.entries.count))", isExpanded: $showLog) {
                        LogList(logger: automation.logger)
                    }
                    Button("Copy log") { UIPasteboard.general.string = automation.logger.allText }
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .propertyList, .xml]) { result in
                if case .success(let url) = result { automation.importPairing(from: url) }
            }
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(number). \(title)").font(.subheadline.weight(.semibold))
                if let done {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
                }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dot(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(on ? .green : .gray.opacity(0.3)).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

private struct LogList: View {
    @ObservedObject var logger: ProtocolLogger

    var body: some View {
        ForEach(logger.entries.suffix(300)) { entry in
            Text(entry.formatted)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(entry.level.color)
        }
    }
}
