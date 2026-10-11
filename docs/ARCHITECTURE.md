# Architecture

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

The agent loop runs on [PiDurableKit](https://github.com/finnvoor/PiDurableKit) (pi-durable on JavaScriptCore).
Input is driven by XCTest through a [TouchSynthesis](https://github.com/willfaust/TouchSynthesis)-style self-runner,
which the app sets up itself over a loopback VPN, so no Mac is needed after setup.

## Perception

The agent reads the accessibility tree first. It is cheap and precise, and every element gets a number. The formatter
flags screens with few elements (web views, maps, games), and the model then calls `screenshot`, which is scaled so
one pixel equals one tap point. SpringBoard alerts are read along with the foreground app.

Element numbers stay stable within an app, so after an action the model sees only what changed. An action waits
until two consecutive reads match instead of sleeping for a fixed delay. It also reports when the screen did not
change or when another app came to the front.

## Taps

If an element's centre is covered by a bar, the floating search pill, the keyboard, or an alert, the tap lands on
an uncovered part of the element. If no part is uncovered, the tap is refused and the model is told what covers it.
This logic and the app-name catalog behind `launch_app` are adapted from
[iphone-use](https://github.com/leeguooooo/iphone-use) (MIT).

## Durability

Every turn and tool call is committed to SQLite before it runs. If iOS kills the app, reopening it resumes the run:
observation tools are replayed, and actions go back to the model marked `interrupted`.

## Safety defaults

- 60 actions per request
- Wallet, Health, and Passwords are blocked
- `tel:`, `sms:`, and `facetime:` links are blocked
- The system prompt forbids purchases, sending messages, and typing secrets unless the user explicitly asks

All of these can be changed in Settings.

## Chat transcript

The chat renders a `Transcript` (from AgentCore) rather than raw log entries. Tool calls are folded into one activity
per request and described in plain words (for example, "Tapped “Search Maps”"), resolved from the screen the model
saw.
