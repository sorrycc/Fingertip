import AgentCore
import Foundation
import PiDurableKit

// Runs the real agent loop against `SimulatedPhone`, so the model, tools, and safety hooks can be checked on a Mac.
//
//   DEEPSEEK_API_KEY=sk-… swift run AgentCLI "Find the cheapest flight from Dublin to London in SkyFares"
//
// Optional: AGENT_BASE_URL and AGENT_MODEL for another Anthropic-compatible endpoint (for example
// https://zenmux.ai/api/anthropic and anthropic/claude-sonnet-5.5, with the key in AGENT_API_KEY),
// AGENT_DB (sqlite path; default in-memory).
//
// When the agent asks (`ask_user`, or an action listed under AGENT_CONFIRM_TOOLS, comma-separated), type the
// reply, or an option's number.

let env = ProcessInfo.processInfo.environment
guard let apiKey = env["DEEPSEEK_API_KEY"] ?? env["AGENT_API_KEY"] else {
    FileHandle.standardError.write("Set DEEPSEEK_API_KEY\n".data(using: .utf8)!)
    exit(2)
}
var provider = ModelProvider.deepSeek(apiKey: apiKey)
if let base = env["AGENT_BASE_URL"].flatMap(URL.init(string:)) {
    provider.id = "fingertip-custom"
    provider.name = base.host() ?? "Custom"
    provider.baseURL = base
}
if let model = env["AGENT_MODEL"] { provider.modelIDs = [model] }
let modelID = provider.modelIDs[0]
let task = CommandLine.arguments.dropFirst().joined(separator: " ").nonEmptyOr(
    "Open SkyFares and find the cheapest flight from Dublin to London. Tell me the flight and price.")

let phone = SimulatedPhone()
let storage: Storage = env["AGENT_DB"].map { .sqlite(at: URL(fileURLWithPath: $0)) } ?? .memory
let confirmTools = (env["AGENT_CONFIRM_TOOLS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
let host = try await AgentHost.open(
    providers: [provider], model: modelID, of: provider, storage: storage, driver: phone,
    safety: SafetyPolicy.Configuration(confirmTools: confirmTools),
    onReport: { print("[report] \($0)") })

// Answers the agent's questions from stdin; end of input cancels them.
let asker = Task.detached {
    for await prompt in host.prompts.updates() {
        guard let prompt else { continue }
        print("\n❓ \(prompt.question)")
        for (i, option) in prompt.options.enumerated() { print("   \(i + 1). \(option)") }
        print("> ", terminator: "")
        fflush(stdout)
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces) else {
            host.prompts.cancelAll()
            continue
        }
        let picked = Int(line).flatMap { prompt.options.indices.contains($0 - 1) ? prompt.options[$0 - 1] : nil }
        host.answer(prompt.id, picked ?? line)
    }
}

print("▶ \(provider.ref(modelID))  task: \(task)\n")
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
asker.cancel()
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
