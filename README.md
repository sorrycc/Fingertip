<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128" alt="Fingertip icon">
</p>

# Fingertip

An AI agent that runs on the iPhone and operates other apps through their UI. You ask in a chat, and it reads the
screen, taps, types, and switches apps until the task is done. After the one-time setup, no Mac is involved.

> [!WARNING]
> This project uses private XCTest APIs and must be sideloaded. It is intended for personal use and cannot be
> distributed through the App Store.

## How it works

```
Chat UI ── AgentCore (agent loop, tools, safety) ── model API
              │
              ▼
        SelfRunnerDriver ── XCTest (accessibility snapshots, synthesized touches)
```

- **Agent loop**: a durable loop on [PiDurableKit](https://github.com/finnvoor/PiDurableKit), with state stored in
  SQLite. If iOS kills the app, the run resumes when you reopen it.
- **Model**: any Anthropic-compatible API. DeepSeek and ZenMux (Claude models) are built in, and you can add more
  providers in Settings. Switch models from the chat toolbar; the switch applies from the next step.
- **Device control**: an on-device XCTest runner based on [TouchSynthesis](https://github.com/willfaust/TouchSynthesis).
- **Safety**: an action budget per request, a stop button, blocked apps and URL schemes, and actions or apps that
  need your approval. All are configurable.
- **While it works**: a status bar in the chat and a Live Activity show what the agent is doing. When it asks a
  question (for example before sending a message), you can answer from the chat, the Live Activity, or a
  notification.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## Requirements

- iPhone on iOS 26 with Developer Mode enabled
- LocalDevVPN (from the App Store) installed on the iPhone
- Mac with Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Rust
- An Apple Developer team for code signing

## Quick start

```bash
git clone --recursive <repo-url> && cd fingertip
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
# Edit Config/Secrets.xcconfig: set DEVELOPMENT_TEAM and AGENT_API_KEY (DeepSeek) and/or ZENMUX_API_KEY
scripts/install.sh   # builds idevice, builds and installs the app, pushes the pairing record
```

The Developer Disk Image must be mounted. Connect the iPhone to Xcode once after each reboot.

Then, on the iPhone:

1. Turn on LocalDevVPN.
2. Open **Fingertip**, tap the hand icon, and choose **Start UI automation**. Enter your passcode when prompted.
   When setup finishes (about a minute), the "Automation Running" overlay appears.
3. Allow location access **Always**. This keeps the agent running in the background.
4. Send a request, for example: "Open Maps and find the nearest coffee shop that's open now."

To stop a run, tap the stop button. To end automation from any app, hold both volume buttons.

## Development

The agent loop, tools, and safety policy are in a platform-neutral Swift package. You can test them on macOS
against a simulated phone:

```bash
cd Packages/AgentCore
swift test
DEEPSEEK_API_KEY=sk-... swift run AgentCLI "Find the cheapest flight from Dublin to London in SkyFares"
```

`AGENT_MODEL` and `AGENT_BASE_URL` override the model. Set `AGENT_DB` to a file path to test resuming a run. When the
agent asks a question, type the reply or an option's number. `AGENT_CONFIRM_TOOLS=open_url,tap` makes those
actions wait for approval.

To work on the UI in the Simulator, run `xcodegen generate` and build the `FingertipPreview` scheme. This build
uses mock data from `Previews/Mocks.swift`. Launch it with `-scenario <name>` to open a specific state: `empty`,
`setup`, `starting`, `working`, `confirm`, `done`, `failed`, `settings`, or `log`.

## Project layout

| Path | Contents |
|---|---|
| `Packages/AgentCore` | Agent loop, tools, screen formatter, safety policy, simulated phone, `AgentCLI` |
| `App/Automation` | Automation setup, XCTest driver, accessibility snapshots |
| `App/Agent`, `App/UI` | App state, settings and Keychain, SwiftUI screens |
| `Shared`, `Widgets` | Live Activity model and App Intents, and the widget extension that draws it |
| `Previews` | Simulator-only UI build with mock data |
| `vendor/TouchSynthesis`, `vendor/idevice` | Git submodules for device communication and touch synthesis |
| `scripts` | Install, pairing, idevice build, log retrieval, icon generation |

## Security

`scripts/install.sh` copies the Mac's pairing record to the iPhone. This record grants full device access over the
network. Do not share it, and do not commit it to source control.

## Acknowledgements

- [PiDurableKit](https://github.com/finnvoor/PiDurableKit): durable agent runtime
- [TouchSynthesis](https://github.com/willfaust/TouchSynthesis): XCTest self-runner and touch synthesis
- [idevice](https://github.com/jkcoxson/idevice): lockdown and device tunneling
- [iphone-use](https://github.com/leeguooooo/iphone-use) (MIT): tap-occlusion handling and the app-name catalog

## License

[MIT](LICENSE) © chencheng

TouchSynthesis has no license. Review its terms before redistributing builds.
