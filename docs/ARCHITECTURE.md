# Architecture

```
App (SwiftUI chat) ── AgentCore ──────────────── PiDurableKit (JSCore, SQLite) ── model API
                       │ tools: view_screen, screenshot, tap, long_press, type_text, press_key, swipe,
                       │        back, dismiss_keyboard, answer_alert, press_home, find_app, launch_app,
                       │        open_url, wait, wait_for, run_steps, ask_user
                       │ SafetyPolicy hook: step budget, stop switch, blocked apps, ask-before
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
- The system prompt forbids purchases, sending messages, and typing secrets unless the user explicitly asks, and
  has the model confirm with `ask_user` before the final irreversible step
- No actions or apps require approval by default ("Ask Before" in Settings)

All of these can be changed in Settings.

## Chat transcript

The chat renders a `Transcript` (from AgentCore) rather than raw log entries. Tool calls are folded into one activity
per request and described in plain words (for example, "Tapped “Search Maps”"), resolved from the screen the model
saw.

## Run status and questions

While a run is going, the chat pins a status bar at the top. It shows the request, the current step, the app, the
action count against the budget, the elapsed time, and a Stop button. The same information appears in a Live
Activity on the Lock Screen and in the Dynamic Island. The Live Activity is drawn by the `FingertipWidgets`
extension, and its model and App Intents live in `Shared/`.

The agent waits for the user in two cases: the model calls `ask_user` (a question with up to four options and
an optional typed reply), or the safety policy reaches an action listed under "Ask Before". Both wait on
`UserPrompts` until the user answers or presses Stop. There is no timeout. The question appears in the status
bar, in the Live Activity (with option buttons), and, when Fingertip is in the background, as a notification
with option buttons and a reply field. If "Open Fingertip for questions" is on, the app also comes to the front
and then returns to the agent's app after the answer. `ask_user` replays safely, so if iOS kills the app while
it waits, the question is asked again on resume.

