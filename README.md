# iphone-agent

An agent that runs **on the iPhone** and operates any app's UI: a durable agent loop
([PiDurableKit](https://github.com/finnvoor/PiDurableKit), pi-durable on JavaScriptCore), a cloud model
(DeepSeek's Anthropic-compatible API by default), and XCTest as the finger
([TouchSynthesis](https://github.com/willfaust/TouchSynthesis)-style self-runner). No Mac in the loop after setup.

Personal, sideloaded use only: it relies on XCTest private API and an unlicensed submodule.

```
App (SwiftUI chat) ── AgentCore ──────────────── PiDurableKit (JSCore, SQLite) ── model API
                       │ tools: view_screen, screenshot, tap, type_text, swipe,
                       │        long_press, press_home, launch_app, open_url, wait
                       │ SafetyPolicy hook: step budget, stop switch, blocked apps
                       ▼
                 SelfRunnerDriver ── DeviceAutomation.m   XCAXClient_iOS accessibility snapshots, app launch
                                  └─ TouchSynthesizer.m   XCSynthesizedEventRecord touches/typing, screenshots
                 AutomationSession: LocalDevVPN loopback → lockdownd → idevice tunnel → testmanagerd DTX → XCTest
```

## Layout

| Path | What |
|---|---|
| `Packages/AgentCore` | Platform-neutral agent: model config, tools, screen formatter, safety, `SimulatedPhone`, `AgentCLI` |
| `App/Automation` | `AutomationSession` (setup flow), `SelfRunnerDriver`, `DeviceAutomation` (AX snapshot + launch, ObjC) |
| `App/Agent`, `App/UI` | App model, settings/Keychain, chat, setup, settings screens |
| `vendor/TouchSynthesis` | Submodule; we compile its Lockdown/DTX/TestManager/TouchSynthesizer/idevice/Util/Model code |
| `scripts/` | `install.sh` (build + install + pairing), `make-pairing.py` (export the Mac's pairing record) |

## Requirements

- iPhone on iOS 26 with Developer Mode on; Mac with Xcode 26, XcodeGen, Rust (`rustup target add aarch64-apple-ios`)
- Xcode signed in to the Apple Developer team in `Config/Base.xcconfig` (`KU8S35TEW8`)
- [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) on the phone
- Developer Disk Image mounted: connect to the Mac with Xcode once after each reboot (or use StikDebug)

## Setup

```bash
git clone --recursive … && cd iphone-agent
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig   # put AGENT_API_KEY in it (or paste it in the app)
scripts/install.sh            # builds idevice if needed, builds + installs the app, pushes the pairing record
```

On the phone:
1. Turn on LocalDevVPN.
2. Open **Agent** → hand icon (Setup) → **Start UI automation**. Wait about a minute, enter the passcode;
   the "Automation Running" overlay appears. Allow location **Always** (keeps the agent alive in the background).
3. Back in the chat, ask for something: *"Open Maps and find the nearest coffee shop that's open now."*

The agent works in other apps, then comes back to the chat with the answer. Tap ■ to stop; hold both volume
buttons to kill automation from anywhere.

## Developing off-device

The agent loop, tools, and safety hooks run on macOS against a scripted fake phone:

```bash
cd Packages/AgentCore
swift test
DEEPSEEK_API_KEY=sk-… swift run AgentCLI "Find the cheapest flight from Dublin to London in SkyFares"
# AGENT_MODEL, AGENT_BASE_URL, AGENT_DB=/tmp/agent.sqlite to test resume
```

## Notes

- **Perception**: accessibility tree first (numbered elements, cheap, precise). The formatter flags screens with
  few elements (web views, maps, games) and the model then calls `screenshot`, scaled so pixels = tap points.
- **Durability**: every turn and tool call is committed to SQLite before it runs. If iOS kills the app, reopening
  resumes; observation tools replay, actions come back to the model as `interrupted`.
- **Safety defaults**: 60 actions per request, Wallet/Health/Passwords blocked, tel/sms/facetime links blocked, the
  prompt forbids purchases, sends, and typing secrets unless explicitly asked. Configure in Settings.
- The pairing record grants full device access over the network. Keep it private.
