# iphone-agent

An agent that runs **on the iPhone** and operates any app's UI: a durable agent loop
([PiDurableKit](https://github.com/finnvoor/PiDurableKit), pi-durable on JavaScriptCore), a cloud model
(DeepSeek's Anthropic-compatible API by default), and XCTest as the finger
([TouchSynthesis](https://github.com/willfaust/TouchSynthesis)-style self-runner). No Mac in the loop after setup.

Personal, sideloaded use only: it relies on XCTest private API and an unlicensed submodule.

```
App (SwiftUI chat) ── AgentCore ──────────────── PiDurableKit (JSCore, SQLite) ── model API
                       │ tools: view_screen, screenshot, tap, long_press, type_text, press_key, swipe,
                       │        back, dismiss_keyboard, answer_alert, press_home, find_app, launch_app,
                       │        open_url, wait, wait_for, run_steps
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
| `App/Agent`, `App/UI` | App model, settings/Keychain, chat, setup, settings, log screens; `Theme.swift` holds the design tokens |
| `Previews` | Simulator-only build of the UI with scripted data (`IPhoneAgentPreview` target) |
| `vendor/TouchSynthesis` | Submodule; we compile its Lockdown/DTX/TestManager/TouchSynthesizer/idevice/Util/Model code |
| `scripts/` | `install.sh` (build + install + pairing), `make-pairing.py` (export the Mac's pairing record) |

## Requirements

- iPhone on iOS 26 with Developer Mode on; Mac with Xcode 26, XcodeGen, Rust (`rustup target add aarch64-apple-ios`)
- Xcode signed in to the Apple Developer team in `Config/Base.xcconfig` (`KU8S35TEW8`)
- LocalDevVPN (App Store) on the phone
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

## Working on the UI

The real app links device-only XCTest and idevice code, so the UI also builds as `IPhoneAgentPreview`, a
simulator app backed by mock models (`Previews/Mocks.swift`) that plays a scripted run when you send a message:

```bash
xcodegen generate
xcodebuild -scheme IPhoneAgentPreview -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/IPhoneAgentPreview.app
xcrun simctl launch booted com.sorrycc.iphoneagent.preview -scenario working   # empty, setup, starting, working, done, failed, settings, log
```

The chat shows `Transcript` (AgentCore) rather than raw entries: tool calls are folded into one activity per request
and described in plain words ("Tapped “Search Maps”", resolved from the screen the model saw). The app icon is
rendered by `scripts/make-icon.swift`.

## Notes

- **Perception**: accessibility tree first (numbered elements, cheap, precise). The formatter flags screens with
  few elements (web views, maps, games) and the model then calls `screenshot`, scaled so pixels = tap points.
  SpringBoard's alerts are read alongside the foreground app. Element numbers stay stable within an app, so after an
  action the model gets only what changed; actions wait until two reads match instead of a fixed delay, and say when
  the screen did not change or another app came to the front.
- **Taps**: an element whose centre is under a bar, the floating search pill, the keyboard, or an alert is tapped
  where it is uncovered, or refused with what covers it (adapted from
  [iphone-use](https://github.com/leeguooooo/iphone-use), MIT, as is the app-name catalog behind `launch_app`).
- **Durability**: every turn and tool call is committed to SQLite before it runs. If iOS kills the app, reopening
  resumes; observation tools replay, actions come back to the model as `interrupted`.
- **Safety defaults**: 60 actions per request, Wallet/Health/Passwords blocked, tel/sms/facetime links blocked, the
  prompt forbids purchases, sends, and typing secrets unless explicitly asked. Configure in Settings.
- The pairing record grants full device access over the network. Keep it private.
