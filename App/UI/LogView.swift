import SwiftUI

/// The automation protocol log: searchable, filterable, newest at the bottom.
struct LogView: View {
    @ObservedObject var logger: ProtocolLogger
    @State private var query = ""
    @State private var problemsOnly = false

    private var entries: [LogEntry] {
        logger.entries.filter { entry in
            (!problemsOnly || entry.level == .error || entry.level == .warning)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query)
                    || entry.phase.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let entries = entries
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    LogRow(entry: entry)
                    Divider().opacity(0.5)
                }
            }
            .padding(.horizontal, 12)
        }
        .defaultScrollAnchor(.bottom)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No log entries" : "No matches",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(query.isEmpty ? "Start automation to see the protocol log." : "Try a different search."))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search log")
        .navigationTitle("Protocol Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis") {
                    Toggle("Warnings & errors only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                    Button("Copy all", systemImage: "doc.on.doc") { UIPasteboard.general.string = logger.allText }
                    ShareLink("Share log file", item: AutomationSession.logURL)
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Self.time.string(from: entry.timestamp))
                    .foregroundStyle(.tertiary)
                Text(entry.phase)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 4))
                    .foregroundStyle(tint)
            }
            .font(.caption2.monospaced())
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    private var tint: Color {
        switch entry.level {
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .debug: .gray
        case .info: .accentColor
        }
    }
}
