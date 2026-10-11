import CoreGraphics
import Foundation
import PiDurableKit

extension ComputerUse {
    struct Tools: Sendable {
        let driver: any DeviceDriver
        let state: ScreenState
        let policy: SafetyPolicy
        let options: ComputerUseOptions

        // MARK: Arguments

        struct ViewArgs: Decodable, Sendable { var screenshot: Bool? }
        struct FindArgs: Decodable, Sendable { var name: String }
        struct StepsArgs: Decodable, Sendable { var steps: [ActionArgs] }

        /// Arguments of every action; each tool's schema offers its own subset, and `run_steps` steps use them all.
        struct ActionArgs: Decodable, Sendable {
            var action: String?
            var element: Int?
            var label: String?
            var kind: String?
            var x: Double?
            var y: Double?
            var seconds: Double?
            var text: String?
            var key: String?
            var count: Int?
            var direction: String?
            var distance: Double?
            var from_x: Double?, from_y: Double?, to_x: Double?, to_y: Double?
            var bundle_id: String?
            var app: String?
            var url: String?
            var button: String?
            var present: [String]?
            var absent: [String]?
            var timeout: Double?
        }

        static let stepActions = [
            "tap", "long_press", "type_text", "press_key", "swipe", "back", "dismiss_keyboard", "answer_alert",
            "press_home", "launch_app", "open_url", "wait", "wait_for",
        ]
        static let maxSteps = 12
        /// Long text is typed in pieces this long, so a failure part-way says how much went in.
        static let typingChunk = 200

        // MARK: Schemas

        static let element = JSONSchema.integer("Element number from the screen").optional
        static let label = JSONSchema.string("Exact label of an element on the current screen, instead of a number").optional
        static let kind = JSONSchema.string("With label: the element type (Button, Cell, …) when several share the label").optional
        static let x = JSONSchema.number("Screen x in points, when no element fits").optional
        static let y = JSONSchema.number("Screen y in points").optional
        static let keys = KeyboardKey.allCases.map(\.rawValue)

        static let condition: KeyValuePairs<String, JSONSchema> = [
            "present": JSONSchema.array(of: .string, description: "Texts that must all be on screen (substring of a label or value, any case)").optional,
            "absent": JSONSchema.array(of: .string, description: "Texts that must all be gone").optional,
            "app": JSONSchema.string("App that must be in front: name or bundle id").optional,
            "timeout": JSONSchema.number("Seconds, default 10", minimum: 0.5, maximum: 30).optional,
        ]

        static let step = JSONSchema.object([
            "action": .string("What to do", enum: stepActions),
            "element": element, "label": label, "kind": kind, "x": x, "y": y,
            "text": JSONSchema.string("type_text: text to type").optional,
            "key": JSONSchema.string("press_key: key", enum: keys).optional,
            "count": JSONSchema.integer("press_key: times to press, default 1").optional,
            "direction": JSONSchema.string("swipe: finger direction", enum: ["up", "down", "left", "right"]).optional,
            "distance": JSONSchema.number("swipe: fraction of the area, default 0.6").optional,
            "seconds": JSONSchema.number("long_press hold / wait duration").optional,
            "button": JSONSchema.string("answer_alert: button text").optional,
            "app": JSONSchema.string("launch_app: app name; wait_for: app that must be in front").optional,
            "bundle_id": JSONSchema.string("launch_app: bundle id").optional,
            "url": JSONSchema.string("open_url: URL").optional,
            "present": JSONSchema.array(of: .string, description: "wait_for: texts that must be on screen").optional,
            "absent": JSONSchema.array(of: .string, description: "wait_for: texts that must be gone").optional,
            "timeout": JSONSchema.number("wait_for: seconds, default 10").optional,
        ])

        // MARK: Observation tools

        var viewScreen: Tool {
            Tool(
                "view_screen",
                description: "Read the current screen as a numbered accessibility tree. Set screenshot=true to also get an image.",
                parameters: .object(["screenshot": JSONSchema.boolean("Also attach a screenshot").optional]),
                replay: .safe
            ) { (args: ViewArgs, _) in
                let screen = try await freshScreen()
                var result = ToolResult.text(screen.text, details: .object(screenDetails(screen)))
                if args.screenshot == true, options.allowScreenshots, await state.imagesAllowed {
                    let jpeg = try await driver.screenshot()
                    result.content?.append(.image(ImageContent(data: jpeg, mimeType: "image/jpeg")))
                }
                return result
            }
        }

        var screenshot: Tool {
            Tool(
                ComputerUse.screenshotTool,
                description: "Take a screenshot. Image pixels equal screen points, so tap x/y can be read straight off it.",
                replay: .safe
            ) { _ in
                let jpeg = try await driver.screenshot()
                let size = await driver.screenSize
                return ToolResult.image(jpeg, mimeType: "image/jpeg", caption: "Screenshot \(Int(size.width))x\(Int(size.height)) points.")
            }
        }

        var findApp: Tool {
            Tool(
                "find_app",
                description: "Look up apps by name (any language, e.g. WeChat or 微信) and get their bundle ids.",
                parameters: .object(["name": JSONSchema.string("App name")]),
                replay: .safe
            ) { (args: FindArgs, _) in
                let installed = await driver.installedApps()
                let found = AppLookup.find(args.name, installed: installed)
                let note = installed.isEmpty ? "\n(The phone's app list is not available; catalog matches may not be installed.)" : ""
                guard !found.isEmpty else {
                    return ToolResult.text("No app matches “\(args.name)”. Open it from the home screen instead (swipe down for Spotlight and type its name).\(note)")
                }
                return ToolResult.text("Apps matching “\(args.name)”:\n" + found.prefix(10).map { "- \($0.display)" }.joined(separator: "\n") + note)
            }
        }

        var waitFor: Tool {
            Tool(
                "wait_for",
                description: "Wait until texts appear or disappear, or an app is in front, then show the screen. Use instead of fixed waits.",
                parameters: .object(Self.condition),
                replay: .safe
            ) { (args: ActionArgs, _) in
                let before = await state.screen
                let outcome = try await waitCondition(args)
                return await compose([outcome.summary], before: before, screen: outcome.screen, error: outcome.error, key: nil)
            }
        }

        // MARK: Action tools

        var tap: Tool {
            action("tap", "Tap an element by number or exact label, or a point by x/y.", [
                "element": Self.element, "label": Self.label, "kind": Self.kind, "x": Self.x, "y": Self.y,
            ])
        }

        var longPress: Tool {
            action("long_press", "Touch and hold an element or point (context menus, rearranging).", [
                "element": Self.element, "label": Self.label, "kind": Self.kind, "x": Self.x, "y": Self.y,
                "seconds": JSONSchema.number("Hold duration, default 1.0", minimum: 0.3, maximum: 5).optional,
            ])
        }

        var typeText: Tool {
            action("type_text", "Type text into the focused field. Pass element or label to tap a field first. End with \\n to press return.", [
                "text": JSONSchema.string("Text to type"),
                "element": JSONSchema.integer("Text field to tap first").optional,
                "label": JSONSchema.string("Exact label of the text field to tap first").optional,
                "kind": Self.kind,
            ])
        }

        var pressKey: Tool {
            action("press_key", "Press a keyboard key: return (submit, search, go), delete (backspace), tab, escape, space.", [
                "key": JSONSchema.string("Key", enum: Self.keys),
                "count": JSONSchema.integer("Times to press, default 1", minimum: 1, maximum: 50).optional,
            ])
        }

        var swipe: Tool {
            action("swipe", "Swipe the finger in a direction (up = scroll content down), within an element or the screen; or between two points.", [
                "direction": JSONSchema.string("Finger direction", enum: ["up", "down", "left", "right"]).optional,
                "element": JSONSchema.integer("Swipe inside this element (e.g. a list or carousel)").optional,
                "distance": JSONSchema.number("Fraction of the area to travel, default 0.6", minimum: 0.1, maximum: 0.95).optional,
                "from_x": JSONSchema.number().optional, "from_y": JSONSchema.number().optional,
                "to_x": JSONSchema.number().optional, "to_y": JSONSchema.number().optional,
            ])
        }

        var back: Tool {
            action("back", "Go back a screen: taps the navigation bar's back button, or swipes from the left edge.", [:])
        }

        var dismissKeyboard: Tool {
            action("dismiss_keyboard", "Hide the keyboard (taps its Done button, or swipes the content down).", [:])
        }

        var answerAlert: Tool {
            action("answer_alert", "Tap a button of the alert on screen (system permission prompts, confirmations).", [
                "button": JSONSchema.string("The button's text, e.g. Allow, Don’t Allow, OK"),
            ])
        }

        var pressHome: Tool {
            action("press_home", "Go to the home screen.", [:])
        }

        var launchApp: Tool {
            action("launch_app", "Open an installed app by name (e.g. WeChat, 微信, Settings) or bundle id.", [
                "app": JSONSchema.string("App name").optional,
                "bundle_id": JSONSchema.string("Bundle identifier, when known").optional,
            ])
        }

        var openURL: Tool {
            action("open_url", "Open a URL or deep link (https://…, maps://, tel: is not allowed).", [
                "url": JSONSchema.string("URL to open"),
            ])
        }

        var wait: Tool {
            Tool(
                "wait",
                description: "Wait a fixed time, then show the screen. Prefer wait_for.",
                parameters: .object(["seconds": JSONSchema.number("Default 2", minimum: 0.5, maximum: 15).optional]),
                replay: .safe
            ) { (args: ActionArgs, _) in
                let before = await state.screen
                let done = try await perform("wait", args)
                return await compose(["Done: \(done.summary)"], before: before, screen: try? await read(previous: before), error: nil, key: nil)
            }
        }

        var runSteps: Tool {
            Tool(
                "run_steps",
                description: """
                    Run up to \(Self.maxSteps) steps in one call, stopping at the first failure, then show the screen \
                    where it ended. Each step is {"action": …} plus that action's arguments, e.g. \
                    {"action":"tap","label":"Search"}, {"action":"type_text","text":"coffee\\n"}, \
                    {"action":"wait_for","present":["Results"]}. Put a wait_for after steps that change the screen.
                    """,
                parameters: .object(["steps": JSONSchema.array(of: Self.step, description: "Steps, in order")])
            ) { (args: StepsArgs, _) in
                try await batch(args.steps)
            }
        }

        func action(_ name: String, _ description: String, _ parameters: KeyValuePairs<String, JSONSchema>) -> Tool {
            Tool(name, description: description, parameters: .object(parameters)) { (args: ActionArgs, _) in
                try await runAction(name, args)
            }
        }

        /// One action, then its effect on the screen.
        func runAction(_ name: String, _ args: ActionArgs) async throws -> ToolResult {
            let before = await state.screen
            let done = try await perform(name, args)
            return await report(
                ["Done: \(done.summary)"], before: before, key: done.key, expectAlertGone: done.alert, details: done.details)
        }

        // MARK: Performing

        struct Performed {
            var summary: String
            /// Identifies the action for "changed nothing twice in a row" advice.
            var key: String?
            var details: JSONObject = [:]
            /// The alert this action answered, to check it went away.
            var alert: AlertInfo?
        }

        func perform(_ action: String, _ args: ActionArgs) async throws -> Performed {
            switch action {
            case "tap":
                let target = try await target(args)
                try await send { try await driver.tap(target.point) }
                return Performed(summary: "tapped \(target.name)\(target.noteSuffix)", key: "tap \(target.key)", details: target.details)

            case "long_press":
                let target = try await target(args)
                let seconds = min(max(args.seconds ?? 1.0, 0.3), 5)
                try await send { try await driver.longPress(target.point, duration: seconds) }
                return Performed(
                    summary: "long-pressed \(target.name)\(target.noteSuffix)", key: "long_press \(target.key)", details: target.details)

            case "type_text":
                return try await type(args)

            case "press_key":
                let name = (args.key ?? "").lowercased()
                let aliases = ["enter": "return", "search": "return", "go": "return", "send": "return", "backspace": "delete"]
                guard let key = KeyboardKey(rawValue: aliases[name] ?? name) else {
                    throw DriverError("key must be one of \(Self.keys.joined(separator: ", ")).")
                }
                let count = min(max(args.count ?? 1, 1), 50)
                try await send { for _ in 0..<count { try await driver.pressKey(key) } }
                return Performed(summary: "pressed \(key.rawValue)" + (count > 1 ? " ×\(count)" : ""), key: "press_key \(key.rawValue)")

            case "swipe":
                let (from, to) = try await swipePoints(args)
                try await send { try await driver.swipe(from: from, to: to, duration: 0.35) }
                return Performed(
                    summary: "swiped \(args.direction ?? "") (\(Int(from.x)),\(Int(from.y)))→(\(Int(to.x)),\(Int(to.y)))",
                    key: "swipe \(Int(from.x)),\(Int(from.y)),\(Int(to.x)),\(Int(to.y))")

            case "back":
                return try await goBack()

            case "dismiss_keyboard":
                return try await hideKeyboard()

            case "answer_alert":
                return try await answer(args)

            case "press_home":
                try await send { try await driver.pressHome() }
                return Performed(summary: "pressed home", key: "press_home")

            case "launch_app":
                return try await launch(args)

            case "open_url":
                guard let raw = args.url, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
                    throw DriverError("Not a valid URL: \(args.url ?? "(none)")")
                }
                guard !["tel", "telprompt", "sms", "facetime", "facetime-audio"].contains(scheme) else {
                    throw DriverError("\(scheme): links are blocked; ask the user to do this themselves.")
                }
                try await send { try await driver.openURL(url) }
                return Performed(summary: "opened \(url.absoluteString)", key: "open_url \(url.absoluteString)")

            case "wait":
                let seconds = min(max(args.seconds ?? 2, 0.5), 15)
                try await Task.sleep(for: .seconds(seconds))
                return Performed(summary: "waited \(Self.format(seconds))s")

            case "wait_for":
                let outcome = try await waitCondition(args)
                guard outcome.met else { throw DriverError(outcome.summary) }
                return Performed(summary: outcome.summary)

            default:
                throw DriverError("Unknown action “\(action)”. Use one of \(Self.stepActions.joined(separator: ", ")).")
            }
        }

        /// Runs something that reaches the phone. A failure here may still have acted, and says so.
        func send(_ body: () async throws -> Void) async throws {
            do {
                try await body()
            } catch let error as CancellationError {
                throw error
            } catch {
                throw DriverError("\(error.localizedDescription) The action may still have reached the phone: look at the screen before retrying.")
            }
        }

        // MARK: Targets

        struct Target {
            var point: CGPoint
            var element: ScreenElement?
            var note: String?

            var name: String { element.map { "[\($0.number)] \($0.display)" } ?? "(\(Int(point.x)),\(Int(point.y)))" }
            var key: String { element.map { "#\($0.number)" } ?? "\(Int(point.x)),\(Int(point.y))" }
            var noteSuffix: String { note.map { " — \($0)" } ?? "" }
            var details: JSONObject { element?.label.map { ["target": .string($0)] } ?? [:] }
        }

        /// The point to touch for `element`, `label` (+ `kind`), or `x`/`y`. Elements covered by another control are
        /// tapped where they are uncovered, or refused.
        func target(_ args: ActionArgs, planned: Bool = true) async throws -> Target {
            if let number = args.element {
                guard let screen = await state.screen, let item = screen.items[number] else {
                    throw DriverError("No element [\(number)] on the latest screen. Call view_screen and use a current number.")
                }
                return try plan(item, in: screen, planned)
            }
            if let label = args.label {
                let screen = try await freshScreen()
                var type: Int?
                if let kind = args.kind {
                    guard let raw = ElementType.type(named: kind) else {
                        throw DriverError("Unknown kind “\(kind)”; use a type shown on the screen, like Button or Cell.")
                    }
                    type = raw
                }
                let matches = ScreenQuery.elements(labeled: label, type: type, in: screen)
                if matches.count == 1 { return try plan(matches[0], in: screen, planned) }
                if matches.isEmpty {
                    let similar = ScreenQuery.similar(to: label, in: screen)
                    let hint = similar.isEmpty
                        ? " Call view_screen to see what is there."
                        : " Did you mean: " + similar.map { "[\($0.number)] \($0.display)" }.joined(separator: ", ") + "?"
                    throw DriverError("No element labeled “\(label)”\(args.kind.map { " of kind \($0)" } ?? "") on the screen; nothing was sent.\(hint)")
                }
                throw DriverError(
                    "\(matches.count) elements are labeled “\(label)”: "
                        + matches.prefix(6).map { "[\($0.number)] \($0.display)" }.joined(separator: ", ")
                        + ". Nothing was sent; pass kind, or the element number.")
            }
            guard let x = args.x, let y = args.y else { throw DriverError("Pass element, label, or both x and y.") }
            let size = await driver.screenSize
            guard (0...size.width).contains(x), (0...size.height).contains(y) else {
                throw DriverError("(\(Int(x)),\(Int(y))) is outside the \(Int(size.width))x\(Int(size.height)) screen.")
            }
            return Target(point: CGPoint(x: x, y: y))
        }

        func plan(_ item: ScreenElement, in screen: Rendered, _ planned: Bool) throws -> Target {
            let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
            guard planned else { return Target(point: center, element: item) }
            switch TapPlanner.plan(item.number, in: screen) ?? .center(center) {
            case .center(let point):
                return Target(point: point, element: item)
            case .shifted(let point, let cover):
                return Target(point: point, element: item, note: "its centre is under \(cover), so its uncovered part was tapped")
            case .covered(let cover):
                throw DriverError(
                    "[\(item.number)] \(item.display) is covered by \(cover); nothing was sent. "
                        + "Close or scroll away what covers it first (answer an alert with answer_alert).")
            }
        }

        func swipePoints(_ args: ActionArgs) async throws -> (CGPoint, CGPoint) {
            if let fx = args.from_x, let fy = args.from_y, let tx = args.to_x, let ty = args.to_y {
                return (CGPoint(x: fx, y: fy), CGPoint(x: tx, y: ty))
            }
            guard let direction = args.direction else { throw DriverError("Pass direction, or from_x/from_y/to_x/to_y.") }
            let size = await driver.screenSize
            var area = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.1, dy: size.height * 0.15)
            if let element = args.element {
                guard let frame = await state.frame(of: element) else { throw DriverError("No element [\(element)] on the latest screen.") }
                area = frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
            }
            let d = min(max(args.distance ?? 0.6, 0.1), 0.95)
            let c = CGPoint(x: area.midX, y: area.midY)
            let dx = area.width * d / 2, dy = area.height * d / 2
            switch direction {
            case "up": return (CGPoint(x: c.x, y: c.y + dy), CGPoint(x: c.x, y: c.y - dy))
            case "down": return (CGPoint(x: c.x, y: c.y - dy), CGPoint(x: c.x, y: c.y + dy))
            case "left": return (CGPoint(x: c.x + dx, y: c.y), CGPoint(x: c.x - dx, y: c.y))
            case "right": return (CGPoint(x: c.x - dx, y: c.y), CGPoint(x: c.x + dx, y: c.y))
            default: throw DriverError("direction must be up, down, left, or right")
            }
        }

        // MARK: Actions with more to them

        func type(_ args: ActionArgs) async throws -> Performed {
            guard let text = args.text, !text.isEmpty else { throw DriverError("Pass the text to type.") }
            var secure = false
            var into = ""
            if args.element != nil || args.label != nil {
                let target = try await target(args)
                secure = target.element?.isSecure ?? false
                try await send { try await driver.tap(target.point) }
                try await Task.sleep(for: .milliseconds(600))
                into = " into \(target.name)"
            } else if options.observeAfterActions, let screen = await state.screen {
                let focused = screen.items.values.filter { $0.focused && $0.isTextInput }
                if screen.keyboardFrame == nil, focused.isEmpty {
                    throw DriverError(
                        "No keyboard is up and no field is focused, so the text would go nowhere; nothing was typed. "
                            + "Tap the text field first, or pass element or label.")
                }
                secure = focused.contains(where: \.isSecure)
            }
            var typed = 0
            for chunk in TextChunks.split(text, size: Self.typingChunk) {
                do {
                    try await driver.typeText(chunk)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    if typed == 0 {
                        throw DriverError("\(error.localizedDescription) The action may still have reached the phone: look at the field before retrying.")
                    }
                    let rest = secure ? "" : " Not yet typed: \(String(text.dropFirst(typed)).debugDescription)."
                    throw DriverError(
                        "Typing stopped after \(typed) of \(text.count) characters (\(error.localizedDescription)); the next part may be "
                            + "partly typed. Read the field, then type only what is missing, never the whole text again.\(rest)")
                }
                typed += chunk.count
            }
            let summary = secure
                ? "typed \(text.count) characters into a secure field\(into)"
                : "typed \(Self.quoted(text))\(into)"
            var details: JSONObject = [:]
            if secure { details["secure"] = .bool(true) }
            return Performed(summary: summary, key: "type_text", details: details)
        }

        func goBack() async throws -> Performed {
            let screen = try await freshScreen()
            let width = await driver.screenSize.width
            // The leading button of a navigation bar.
            let candidates = screen.items.values.filter { item in
                item.type == ElementType.button && item.frame.minX < width * 0.25
                    && screen.nodes[..<item.node].indices.contains { j in
                        screen.nodes[j].type == ElementType.navigationBar && screen.nodes[j].subtreeEnd > item.node
                    }
            }
            if let button = candidates.min(by: { $0.frame.minX < $1.frame.minX }) {
                let target = try plan(button, in: screen, true)
                try await send { try await driver.tap(target.point) }
                return Performed(summary: "tapped the back button \(target.name)", key: "back")
            }
            let size = await driver.screenSize
            let y = size.height * 0.45
            try await send { try await driver.swipe(from: CGPoint(x: 1, y: y), to: CGPoint(x: size.width * 0.75, y: y), duration: 0.3) }
            return Performed(summary: "swiped from the left edge to go back (no back button found)", key: "back")
        }

        static let keyboardDoneLabels: Set<String> = ["done", "完成", "hide keyboard", "隐藏键盘", "dismiss keyboard", "收起键盘"]

        func hideKeyboard() async throws -> Performed {
            let screen = try await freshScreen()
            guard let keyboard = screen.keyboardFrame else {
                return Performed(summary: "the keyboard was not up; nothing to do")
            }
            let done = screen.items.values
                .filter { $0.type == ElementType.button && Self.keyboardDoneLabels.contains(ScreenQuery.normalized($0.label ?? "")) }
                .min { abs($0.frame.maxY - keyboard.minY) < abs($1.frame.maxY - keyboard.minY) }
            if let done {
                let target = try plan(done, in: screen, true)
                try await send { try await driver.tap(target.point) }
                return Performed(summary: "tapped \(target.name) to hide the keyboard", key: "dismiss_keyboard")
            }
            let size = await driver.screenSize
            let start = CGPoint(x: size.width / 2, y: max(keyboard.minY - 80, size.height * 0.2))
            let end = CGPoint(x: size.width / 2, y: min(keyboard.minY + 200, size.height - 10))
            try await send { try await driver.swipe(from: start, to: end, duration: 0.3) }
            return Performed(
                summary: "swiped the content down to hide the keyboard (no Done button found; if it is still up, tap the field's "
                    + "Return key or an empty area)",
                key: "dismiss_keyboard")
        }

        func answer(_ args: ActionArgs) async throws -> Performed {
            guard let wanted = args.button?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else {
                throw DriverError("Pass the button's text.")
            }
            let screen = try await freshScreen()
            guard let alert = screen.alert else { throw DriverError("No alert is on screen; nothing was sent.") }
            let buttons = screen.items.values
                .filter { $0.type == ElementType.button && screen.nodes[$0.node].inAlert }
                .sorted { $0.number < $1.number }
            let key = ScreenQuery.normalized(wanted)
            var matches = buttons.filter { ScreenQuery.normalized($0.label ?? "") == key }
            if matches.isEmpty { matches = buttons.filter { ScreenQuery.normalized($0.label ?? "").contains(key) } }
            guard matches.count == 1, let button = matches.first else {
                let names = buttons.compactMap(\.label).map { "“\($0)”" }.joined(separator: ", ")
                throw DriverError(
                    (matches.isEmpty ? "The alert has no button “\(wanted)”" : "Several alert buttons match “\(wanted)”")
                        + "; nothing was sent. Its buttons: \(names.isEmpty ? "(none readable)" : names).")
            }
            try await send { try await driver.tap(CGPoint(x: button.frame.midX, y: button.frame.midY)) }
            return Performed(
                summary: "answered the alert with \(button.display)", key: "answer_alert \(key)",
                details: button.label.map { ["target": .string($0)] } ?? [:], alert: alert)
        }

        func launch(_ args: ActionArgs) async throws -> Performed {
            var bundleID = args.bundle_id?.trimmingCharacters(in: .whitespaces)
            var name: String?
            if bundleID?.isEmpty ?? true, let app = args.app {
                let installed = await driver.installedApps()
                // A blocked app is refused by name, installed or not.
                for candidate in [AppLookup.Candidate(bundleID: app, name: app, installed: nil, exact: true)]
                    + AppLookup.find(app, installed: installed).filter(\.exact) {
                    if case .block(let message) = policy.launchVerdict(bundleID: candidate.bundleID, name: candidate.name) {
                        throw DriverError(message)
                    }
                }
                guard let found = AppLookup.resolve(app, installed: installed) else {
                    let candidates = AppLookup.find(app, installed: installed)
                    if candidates.isEmpty {
                        throw DriverError(
                            "No app named “\(app)” is known; nothing was launched. Try find_app with another spelling, or open it "
                                + "from the home screen (swipe down for Spotlight and type its name).")
                    }
                    throw DriverError(
                        "“\(app)” could mean: " + candidates.prefix(6).map(\.display).joined(separator: "; ")
                            + ". Nothing was launched; call launch_app with the bundle_id you mean.")
                }
                bundleID = found.bundleID
                name = found.name
            }
            guard let bundleID, !bundleID.isEmpty else { throw DriverError("Pass app (its name) or bundle_id.") }
            if case .block(let message) = policy.launchVerdict(bundleID: bundleID, name: name) { throw DriverError(message) }
            try await send { try await driver.launchApp(bundleID: bundleID) }
            return Performed(
                summary: "launched \(name.map { "\($0) (\(bundleID))" } ?? bundleID)", key: "launch_app \(bundleID)",
                details: ["bundle_id": .string(bundleID)])
        }

        // MARK: Waiting for conditions

        struct ConditionOutcome {
            var met: Bool
            var summary: String
            var screen: Rendered?
            var error: String?
        }

        func waitCondition(_ args: ActionArgs) async throws -> ConditionOutcome {
            let present = (args.present ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let absent = (args.absent ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let app = (args.app?.trimmingCharacters(in: .whitespaces)).nonEmpty
            guard !present.isEmpty || !absent.isEmpty || app != nil else {
                throw DriverError("Pass present, absent, or app to wait for.")
            }
            let timeout = min(max(args.timeout ?? 10, 0.5), 30)
            let goals: [String] = (app.map { ["\($0) in front"] } ?? [])
                + present.map { "“\($0)” on screen" } + absent.map { "“\($0)” gone" }
            let wanted = goals.joined(separator: ", ")
            let clock = ContinuousClock()
            let start = clock.now
            var screen: Rendered?
            var readError: String?

            func unmet(_ screen: Rendered) -> [String] {
                var reasons: [String] = []
                if let app, !ScreenQuery.isApp(app, screen.app) { reasons.append("\(screen.app.display) is in front, not \(app)") }
                let missing = present.filter { !ScreenQuery.contains($0, in: screen) }
                if !missing.isEmpty { reasons.append("not on screen: " + missing.map { "“\($0)”" }.joined(separator: ", ")) }
                if !absent.isEmpty, screen.isSparse {
                    reasons.append("the screen has no readable elements, so “gone” cannot be proven")
                } else {
                    let still = absent.filter { ScreenQuery.contains($0, in: screen) }
                    if !still.isEmpty { reasons.append("still on screen: " + still.map { "“\($0)”" }.joined(separator: ", ")) }
                }
                return reasons
            }

            var reasons: [String] = []
            while true {
                do {
                    let base: Rendered?
                    if let screen { base = screen } else { base = await state.screen }
                    let next = try await read(previous: base)
                    screen = next
                    reasons = unmet(next)
                    if reasons.isEmpty {
                        await state.update(next)
                        return ConditionOutcome(
                            met: true, summary: "Condition met after \(Self.format(clock.now - start))s: \(wanted).", screen: next)
                    }
                } catch {
                    readError = error.localizedDescription
                }
                if clock.now - start >= .seconds(timeout) { break }
                try await Task.sleep(for: .milliseconds(400))
            }
            if let screen { await state.update(screen) }
            let why = reasons.isEmpty ? "the screen could not be read" : reasons.joined(separator: "; ")
            return ConditionOutcome(
                met: false, summary: "Timed out after \(Self.format(timeout))s: \(why).", screen: screen, error: readError)
        }

        // MARK: Batches

        func batch(_ steps: [ActionArgs]) async throws -> ToolResult {
            guard !steps.isEmpty else { throw DriverError("Pass at least one step.") }
            guard steps.count <= Self.maxSteps else { throw DriverError("At most \(Self.maxSteps) steps per call.") }
            for (i, step) in steps.enumerated() {
                guard let action = step.action, Self.stepActions.contains(action) else {
                    throw DriverError("Step \(i + 1): action must be one of \(Self.stepActions.joined(separator: ", ")). Nothing was run.")
                }
            }
            let before = await state.screen
            var lines: [String] = []
            var failure: String?
            var unsettled = false
            for (i, step) in steps.enumerated() {
                let action = step.action ?? ""
                let waits = action == "wait" || action == "wait_for"
                // Let the previous step's effect land before resolving this one.
                if unsettled, !waits, let screen = await settle(from: await state.screen).screen {
                    await state.update(screen)
                }
                if ComputerUse.actionTools.contains(action) {
                    let arguments: JSONObject = step.bundle_id.map { ["bundle_id": .string($0)] } ?? [:]
                    if case .block(let message) = policy.checkLaunch(action, arguments: arguments) {
                        failure = "Step \(i + 1) (\(action)) was blocked: \(message)"
                        break
                    }
                    if case .block(let message) = policy.check(tool: action, app: await state.app) {
                        failure = "Step \(i + 1) (\(action)) was blocked: \(message)"
                        break
                    }
                }
                do {
                    let done = try await perform(action, step)
                    lines.append("\(i + 1). \(done.summary)")
                    unsettled = !waits
                } catch let error as CancellationError {
                    throw error
                } catch {
                    failure = "Step \(i + 1) (\(action)) failed: \(error.localizedDescription)"
                    break
                }
            }
            var headline = (failure == nil ? "Ran all \(steps.count) steps:" : "Ran \(lines.count) of \(steps.count) steps:")
            if !lines.isEmpty { headline += "\n" + lines.joined(separator: "\n") }
            var parts = [headline]
            if let failure { parts.append(failure + " Later steps were not run.") }
            if unsettled { return await report(parts, before: before, key: nil) }
            return await compose(parts, before: before, screen: await state.screen, error: nil, key: nil)
        }

        // MARK: Reading and reporting

        func read(previous: Rendered?) async throws -> Rendered {
            let snapshot = try await driver.snapshot()
            // Numbers keep growing within an app; start over before they get unwieldy.
            let base = previous.flatMap { $0.nextNumber > 999 ? nil : $0 }
            return ScreenFormatter(screen: await driver.screenSize).render(snapshot, previous: base)
        }

        /// Reads the screen now and makes it the one element numbers refer to.
        func freshScreen() async throws -> Rendered {
            let screen = try await read(previous: await state.screen)
            await state.update(screen)
            return screen
        }

        struct Settled {
            var screen: Rendered?
            var note: String?
            var error: String?
        }

        /// Reads until two reads in a row show the same screen (and nothing is spinning), or the budget runs out.
        func settle(from previous: Rendered?) async -> Settled {
            let clock = ContinuousClock()
            let start = clock.now
            try? await Task.sleep(for: options.settle.minimumWait)
            var last: Rendered?
            var readError: String?
            while !Task.isCancelled {
                do {
                    let next = try await read(previous: last ?? previous)
                    // Two equal empty trees prove nothing, but waiting longer will not either.
                    if let last, next.sameScreen(as: last), next.isSparse || !next.isLoading {
                        return Settled(screen: next)
                    }
                    last = next
                } catch {
                    readError = error.localizedDescription
                }
                let elapsed = clock.now - start
                if elapsed >= options.settle.budget {
                    let note = last.map {
                        $0.isLoading
                            ? "Still loading after \(Self.format(elapsed))s; use wait_for for what you expect."
                            : "The screen was still changing after \(Self.format(elapsed))s; read it again if it looks mid-animation."
                    }
                    return Settled(screen: last, note: note, error: readError)
                }
                try? await Task.sleep(for: options.settle.interval)
            }
            return Settled(screen: last, error: readError ?? "cancelled")
        }

        /// Settles, then reports the action's effect.
        func report(
            _ headline: [String], before: Rendered?, key: String?, expectAlertGone: AlertInfo? = nil, details: JSONObject = [:]
        ) async -> ToolResult {
            guard options.observeAfterActions else { return .text(headline.joined(separator: "\n"), details: .object(details)) }
            let settled = await settle(from: before)
            return await compose(
                headline + [settled.note].compactMap { $0 }, before: before, screen: settled.screen, error: settled.error,
                key: key, expectAlertGone: expectAlertGone, details: details)
        }

        /// The effect of an action on the screen: a different app, no change, the changes, or the whole screen.
        func compose(
            _ headline: [String], before: Rendered?, screen: Rendered?, error: String?, key: String?,
            expectAlertGone: AlertInfo? = nil, details: JSONObject = [:]
        ) async -> ToolResult {
            var parts = headline
            var details = details
            guard let screen else {
                parts.append("(Could not read the new screen: \(error ?? "unknown error"))")
                return .text(parts.joined(separator: "\n\n"), details: .object(details))
            }
            await state.update(screen)
            details.merge(screenDetails(screen)) { _, new in new }
            if let expectAlertGone, screen.alert == expectAlertGone {
                parts.append("The alert is still showing; the tap may not have registered. Try once more, or tell the user.")
            }
            guard let before else {
                parts.append(screen.text)
                return .text(parts.joined(separator: "\n\n"), details: .object(details))
            }
            let changed = !screen.sameScreen(as: before)
            var repeats = 0
            if let key { repeats = await state.noteEffect(key: key, on: before.body, changed: changed) }

            if !before.app.sameApp(as: screen.app) {
                parts.append("Foreground app changed: \(before.app.display) → \(screen.app.display).")
                parts.append(screen.text)
            } else if !changed {
                if key == nil {
                    parts.append("The screen did not change.")
                } else if repeats >= 2 {
                    parts.append(
                        "The screen did not change. This action has now done nothing \(repeats) times in a row on this screen: "
                            + "do not repeat it. Re-read the screen, then try another element, scroll, or wait_for.")
                } else {
                    parts.append("The screen did not change. If you expected a change, the action hit nothing useful: choose another target.")
                }
                parts.append(screen.header)
            } else if options.deltaObservations, let delta = ScreenDelta.text(from: before, to: screen) {
                parts.append(delta)
            } else {
                parts.append(screen.text)
            }
            return .text(parts.joined(separator: "\n\n"), details: .object(details))
        }

        func screenDetails(_ screen: Rendered) -> JSONObject {
            ["app": .string(screen.app.display), "elements": .number(Double(screen.elementCount))]
        }

        // MARK: Formatting

        static func format(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return format(Double(seconds) + Double(attoseconds) / 1e18)
        }

        static func format(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

        static func quoted(_ text: String) -> String {
            text.count > 80 ? String(text.prefix(80)).debugDescription + "… (\(text.count) characters)" : text.debugDescription
        }
    }
}

/// Splits text into pieces of at most `size` characters. Swift characters are grapheme clusters, so an emoji,
/// flag, or letter with combining marks is never split.
enum TextChunks {
    static func split(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var chunks: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return chunks
    }
}
