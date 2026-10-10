import SwiftUI
import UniformTypeIdentifiers

/// One-time setup and the start/stop switch for on-device UI automation.
struct SetupView: View {
    @Environment(AutomationSession.self) private var automation
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importMessage: (ok: Bool, message: String)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusHero { importing = true }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if automation.phase != .idle {
                    Section("Health") {
                        HealthRow(title: "Device tunnel", detail: "LocalDevVPN loopback heartbeat",
                                  systemImage: "point.3.connected.trianglepath.dotted", on: automation.heartbeatOK)
                        HealthRow(title: "Background", detail: "Keeps running while other apps are open",
                                  systemImage: "location.fill", on: automation.keepAliveActive)
                        HealthRow(title: "Touch input", detail: "XCTest taps and typing",
                                  systemImage: "hand.tap.fill", on: automation.isReady)
                    }
                }

                Section {
                    RequirementRow(
                        number: 1, title: "LocalDevVPN is on",
                        detail: "Install LocalDevVPN from the App Store and turn it on. It gives this app a loopback path to the phone's own developer services.")
                    RequirementRow(
                        number: 2, title: "Developer Disk Image mounted",
                        detail: "Connect to a Mac with Xcode once after each reboot (or use StikDebug).")
                    RequirementRow(
                        number: 3, title: "Pairing files", done: automation.pairingLoaded,
                        detail: pairingDetail) {
                        Button(automation.pairingLoaded ? "Replace" : "Import") { importing = true }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                    if let importMessage {
                        Label(importMessage.message, systemImage: importMessage.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(importMessage.ok ? .green : .red)
                    }
                } header: {
                    Text("Before you start")
                } footer: {
                    Text("scripts/install.sh builds the app and copies both pairing files onto the phone. You can also AirDrop them here and import.")
                }

                Section {
                    NavigationLink {
                        LogView(logger: automation.logger)
                    } label: {
                        Label("Protocol log", systemImage: "doc.text.magnifyingglass")
                    }
                    ShareLink(item: AutomationSession.logURL) {
                        Label("Share log file", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .propertyList, .xml]) { result in
                if case .success(let url) = result {
                    withAnimation { importMessage = automation.importPairing(from: url) }
                }
            }
            .animation(.snappy, value: automation.phase)
        }
    }

    private var pairingDetail: String {
        switch (automation.hasLockdownPairing, automation.hasRemotePairing) {
        case (true, true): "Lockdown and RemotePairing files are installed."
        case (true, false): "Missing rp_pairing.plist (RemotePairing). Import it, or rerun scripts/install.sh."
        case (false, true): "Missing pairing.plist (lockdown). Import it, or rerun scripts/install.sh."
        case (false, false): "Run scripts/install.sh with the phone plugged in, or import the files made on your Mac."
        }
    }
}

/// The big status block: what's happening, progress while starting, and the main button.
private struct StatusHero: View {
    @Environment(AutomationSession.self) private var automation
    let importPairing: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(automation.phase.tint.opacity(0.14))
                    .frame(width: 84, height: 84)
                Circle()
                    .strokeBorder(automation.phase.tint.opacity(0.25), lineWidth: 1)
                    .frame(width: 104, height: 104)
                Image(systemName: automation.phase.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(automation.phase.tint)
                    .symbolEffect(.pulse, isActive: automation.phase.isStarting)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text(headline).font(.title3.weight(.bold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            if case .starting(let current) = automation.phase {
                StartProgress(current: current, startedAt: automation.startedAt)
            }

            button
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var button: some View {
        switch automation.phase {
        case .ready:
            Button(role: .destructive) { automation.stop() } label: {
                Text("Stop Automation").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        case .starting:
            EmptyView()
        case .idle where !automation.pairingLoaded, .failed where !automation.pairingLoaded:
            Button(action: importPairing) {
                Label("Import Pairing Files", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        case .idle, .failed:
            Button { Task { await automation.start() } } label: {
                Label(automation.phase == .idle ? "Start Automation" : "Try Again", systemImage: "play.fill")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private var headline: String {
        switch automation.phase {
        case .idle: "Automation is off"
        case .starting: "Starting…"
        case .ready: "Ready to work"
        case .failed: "Couldn't start"
        }
    }

    private var message: String {
        switch automation.phase {
        case .idle:
            automation.pairingLoaded
                ? "Starting takes about a minute. iOS then asks for your passcode and shows an “Automation Running” overlay."
                : "Finish the steps below first."
        case .starting:
            "Keep this screen open. Allow location “Always” when asked so the agent keeps running in the background."
        case .ready:
            "The agent can tap, type, and swipe in any app. Hold both volume buttons to stop it from anywhere."
        case .failed(let message):
            message
        }
    }
}

private struct StartProgress: View {
    let current: AutomationSession.StartStep
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AutomationSession.StartStep.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    Group {
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 20)
                    Text(step.title)
                        .font(.subheadline)
                        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("Elapsed \(Duration.seconds(context.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 30)
            }
        }
        .padding(14)
        .background(Theme.cardFill, in: Theme.card)
    }
}

private struct HealthRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let on: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: on ? .green : .gray)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(on ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RequirementRow<Accessory: View>: View {
    let number: Int
    let title: String
    var done: Bool?
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done == true ? Color.green : Color.accentColor.opacity(0.15))
                if done == true {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.vertical, 2)
    }
}

extension RequirementRow where Accessory == EmptyView {
    init(number: Int, title: String, done: Bool? = nil, detail: String) {
        self.init(number: number, title: title, done: done, detail: detail) { EmptyView() }
    }
}
