import AgentCore
import Foundation
import PiDurableKit

// Runs the real agent loop against `SimulatedPhone`, so the model, tools, and safety hooks can be checked on a Mac.
//
//   DEEPSEEK_API_KEY=sk-… swift run AgentCLI "Find the cheapest flight from Dublin to London in SkyFares"
//
// Optional: AGENT_BASE_URL, AGENT_MODEL, AGENT_DB (sqlite path; default in-memory).

let env = ProcessInfo.processInfo.environment
guard let apiKey = env["DEEPSEEK_API_KEY"] ?? env["AGENT_API_KEY"] else {
    FileHandle.standardError.write("Set DEEPSEEK_API_KEY\n".data(using: .utf8)!)
    exit(2)
}
var config = AgentConfig()
if let base = env["AGENT_BASE_URL"].flatMap(URL.init(string:)) { config.baseURL = base }
if let model = env["AGENT_MODEL"] { config.modelID = model }
let task = CommandLine.arguments.dropFirst().joined(separator: " ").nonEmptyOr(
    "Open SkyFares and find the cheapest flight from Dublin to London. Tell me the flight and price.")

let phone = SimulatedPhone()
let storage: Storage = env["AGENT_DB"].map { .sqlite(at: URL(fileURLWithPath: $0)) } ?? .memory
let host = try await AgentHost.open(
    config: config, apiKey: apiKey, storage: storage, driver: phone,
    onReport: { print("[report] \($0)") })

print("▶ \(config.modelRef)  task: \(task)\n")
let submission = try await host.send(task)

// Print tool calls and results as entries are committed.
let printer = Task {
    var seen = Set<EntryID>()
    for try await view in host.conversation.views() {
        for entry in view.entries where !seen.contains(entry.id) {
            seen.insert(entry.id)
            switch entry.message {
            case .assistant(let message):
                for call in message.toolCalls { print("→ \(call.name) \(JSONValue.object(call.arguments).compact)") }
                if !message.text.isEmpty { print("\n💬 \(message.text)\n") }
                if let error = message.errorMessage { print("✖ \(error)") }
            case .toolResult(let result):
                let firstLine = result.text.split(separator: "\n").first.map(String.init) ?? ""
                print("  ← \(result.isError ? "ERROR " : "")\(firstLine.prefix(140))")
            default: break
            }
        }
    }
}

let settled = try await submission.wait()
try await Task.sleep(for: .milliseconds(300))
printer.cancel()
let usage = try await host.harness.usage()
print("status: \(settled.status)")
print("device log: \(await phone.log)")
print("usage: \(usage)")

extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension JSONValue {
    var compact: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
