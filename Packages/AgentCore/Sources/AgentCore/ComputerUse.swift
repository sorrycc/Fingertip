import CoreGraphics
import Foundation
import PiDurableKit

/// The last screen the model saw, so `tap(element: 3)` resolves to the frame it was shown.
public actor ScreenState {
    public private(set) var elements: [Int: CGRect] = [:]
    public private(set) var app = AppInfo()

    public init() {}

    func update(_ rendered: ScreenFormatter.Rendered, app: AppInfo) {
        elements = rendered.elements
        self.app = app
    }

    func frame(of element: Int) -> CGRect? { elements[element] }
}

/// Tunables for the computer-use tools.
public struct ComputerUseOptions: Sendable {
    /// Wait after an action before reading the screen again, for animations to settle.
    public var settleDelay: Duration
    /// Return the new screen after every action, saving the model a `view_screen` round trip.
    public var observeAfterActions: Bool
    /// Whether the model accepts images; without it the screenshot tool is not offered.
    public var allowScreenshots: Bool

    public init(settleDelay: Duration = .milliseconds(900), observeAfterActions: Bool = true, allowScreenshots: Bool = true) {
        self.settleDelay = settleDelay
        self.observeAfterActions = observeAfterActions
        self.allowScreenshots = allowScreenshots
    }
}

public enum ComputerUse {
    public static let extensionName = "computer-use"
    /// Tools that change the device; the safety policy counts and gates these.
    public static let actionTools: Set<String> = [
        "tap", "long_press", "type_text", "swipe", "press_home", "launch_app", "open_url",
    ]

    public static func makeExtension(
        driver: any DeviceDriver, state: ScreenState, policy: SafetyPolicy, options: ComputerUseOptions = .init()
    ) -> Extension {
        let tools = Tools(driver: driver, state: state, options: options)
        return Extension(extensionName) {
            PromptSection("computer-use", text: systemPrompt)
            PromptSection("device") { _ in
                let size = await driver.screenSize
                return "iPhone screen: \(Int(size.width))x\(Int(size.height)) points. Now: \(Date.now.formatted(date: .complete, time: .shortened))."
            }
            tools.viewScreen
            if options.allowScreenshots { tools.screenshot }
            tools.tap
            tools.longPress
            tools.typeText
            tools.swipe
            tools.pressHome
            tools.launchApp
            tools.openURL
            tools.wait
            policy.hook
        }
    }

    static let systemPrompt = """
        You operate the user's iPhone on their behalf. You see the screen through its accessibility tree \
        (`view_screen`) and act with taps, typing, and swipes. Every app's UI is your tool.

        How to work:
        - Start by calling `view_screen` unless an action result already showed the current screen.
        - Elements are numbered like `[7] Button "Search" @(215,640)`. Prefer `tap` with `element`; use x/y only for \
        things the tree does not number. Numbers change after every screen update—only use numbers from the latest screen.
        - To open an app use `launch_app` with its bundle id, or go home and use Spotlight (swipe down on the home \
        screen, type the app name). Common ids: com.apple.mobilesafari, com.apple.Maps, com.apple.MobileSMS, \
        com.apple.mobilemail, com.apple.mobilenotes, com.apple.reminders, com.apple.mobilecal, com.apple.Preferences, \
        com.apple.AppStore, com.apple.Music, com.apple.camera, com.apple.mobileslideshow.
        - To type, tap the field (or pass `element` to `type_text`), then type. End text with "\\n" to press return/search.
        - To scroll content down, swipe up. Dismiss sheets by swiping down or tapping Close/Cancel.
        - If the tree looks empty or unhelpful (web pages, maps, games, custom drawing), call `screenshot` and tap by x/y.
        - Act one step at a time and check the result. If something did not work twice, try a different approach.
        - Keep going until the task is done, then reply to the user with the answer in plain text. Do not ask the \
        user for confirmation of routine steps.

        Safety:
        - Never complete purchases, payments, bookings, transfers, or send messages/emails/posts unless the user \
        explicitly asked for exactly that. Stop before the final confirm button and report back instead.
        - Never type passwords, codes, or card numbers you were not given by the user in this conversation.
        - Do not change system settings, delete data, or sign out of accounts unless asked.
        - If a tool result says an action was blocked or the user stopped you, stop acting and summarize.
        """

    struct Tools: Sendable {
        let driver: any DeviceDriver
        let state: ScreenState
        let options: ComputerUseOptions

        // MARK: Arguments

        struct ViewArgs: Decodable, Sendable { var screenshot: Bool? }
        struct TapArgs: Decodable, Sendable { var element: Int?; var x: Double?; var y: Double? }
        struct LongPressArgs: Decodable, Sendable { var element: Int?; var x: Double?; var y: Double?; var seconds: Double? }
        struct TypeArgs: Decodable, Sendable { var text: String; var element: Int? }
        struct SwipeArgs: Decodable, Sendable {
            var direction: String?
            var element: Int?
            var distance: Double?
            var from_x: Double?, from_y: Double?, to_x: Double?, to_y: Double?
        }
        struct LaunchArgs: Decodable, Sendable { var bundle_id: String }
        struct URLArgs: Decodable, Sendable { var url: String }
        struct WaitArgs: Decodable, Sendable { var seconds: Double? }

        static let target: KeyValuePairs<String, JSONSchema> = [
            "element": JSONSchema.integer("Element number from the latest screen").optional,
            "x": JSONSchema.number("Screen x in points, when no element number fits").optional,
            "y": JSONSchema.number("Screen y in points").optional,
        ]

        // MARK: Observation

        var viewScreen: Tool {
            Tool(
                "view_screen",
                description: "Read the current screen as a numbered accessibility tree. Set screenshot=true to also get an image.",
                parameters: .object(["screenshot": JSONSchema.boolean("Also attach a screenshot").optional]),
                replay: .safe
            ) { (args: ViewArgs, _) in
                var result = try await observe()
                if args.screenshot == true, options.allowScreenshots {
                    let jpeg = try await driver.screenshot()
                    result.content?.append(.image(ImageContent(data: jpeg, mimeType: "image/jpeg")))
                }
                return result
            }
        }

        var screenshot: Tool {
            Tool(
                "screenshot",
                description: "Take a screenshot. Image pixels equal screen points, so tap x/y can be read straight off it.",
                replay: .safe
            ) { _ in
                let jpeg = try await driver.screenshot()
                let size = await driver.screenSize
                return ToolResult.image(jpeg, mimeType: "image/jpeg", caption: "Screenshot \(Int(size.width))x\(Int(size.height)) points.")
            }
        }

        /// Reads the screen and remembers its element numbers.
        func observe() async throws -> ToolResult {
            let snapshot = try await driver.snapshot()
            let rendered = ScreenFormatter(screen: await driver.screenSize).render(snapshot)
            await state.update(rendered, app: snapshot.app)
            return .text(rendered.text, details: ["app": .string(snapshot.app.display), "elements": .number(Double(rendered.elementCount))])
        }

        /// Runs an action, then shows the resulting screen.
        func act(_ summary: String, _ body: () async throws -> Void) async throws -> ToolResult {
            try await body()
            guard options.observeAfterActions else { return .text("Done: \(summary)") }
            try await Task.sleep(for: options.settleDelay)
            do {
                let screen = try await observe()
                return .text("Done: \(summary)\n\n" + (screen.content?.compactMap(\.text).joined() ?? ""), details: screen.details)
            } catch {
                return .text("Done: \(summary)\n(Could not read the new screen: \(error.localizedDescription))")
            }
        }

        func point(element: Int?, x: Double?, y: Double?) async throws -> CGPoint {
            if let element {
                guard let frame = await state.frame(of: element) else {
                    throw DriverError("No element [\(element)] on the latest screen. Call view_screen and use a current number.")
                }
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            guard let x, let y else { throw DriverError("Pass element, or both x and y.") }
            let size = await driver.screenSize
            guard (0...size.width).contains(x), (0...size.height).contains(y) else {
                throw DriverError("(\(Int(x)),\(Int(y))) is outside the \(Int(size.width))x\(Int(size.height)) screen.")
            }
            return CGPoint(x: x, y: y)
        }

        // MARK: Actions

        var tap: Tool {
            Tool("tap", description: "Tap an element by number, or a point by x/y.", parameters: .object(Self.target)) {
                (args: TapArgs, _) in
                let p = try await point(element: args.element, x: args.x, y: args.y)
                return try await act("tapped \(args.element.map { "[\($0)]" } ?? "") at (\(Int(p.x)),\(Int(p.y)))") {
                    try await driver.tap(p)
                }
            }
        }

        var longPress: Tool {
            Tool(
                "long_press",
                description: "Touch and hold an element or point (context menus, rearranging).",
                parameters: .object([
                    "element": JSONSchema.integer("Element number").optional,
                    "x": JSONSchema.number().optional,
                    "y": JSONSchema.number().optional,
                    "seconds": JSONSchema.number("Hold duration, default 1.0", minimum: 0.3, maximum: 5).optional,
                ])
            ) { (args: LongPressArgs, _) in
                let p = try await point(element: args.element, x: args.x, y: args.y)
                return try await act("long-pressed (\(Int(p.x)),\(Int(p.y)))") {
                    try await driver.longPress(p, duration: args.seconds ?? 1.0)
                }
            }
        }

        var typeText: Tool {
            Tool(
                "type_text",
                description: "Type text into the focused field. Pass element to tap a field first. End with \\n to press return.",
                parameters: .object([
                    "text": JSONSchema.string("Text to type"),
                    "element": JSONSchema.integer("Text field to tap first").optional,
                ])
            ) { (args: TypeArgs, _) in
                if let element = args.element {
                    let p = try await point(element: element, x: nil, y: nil)
                    try await driver.tap(p)
                    try await Task.sleep(for: .milliseconds(600))
                }
                return try await act("typed \(args.text.debugDescription)") { try await driver.typeText(args.text) }
            }
        }

        var swipe: Tool {
            Tool(
                "swipe",
                description: "Swipe the finger in a direction (up = scroll content down), within an element or the screen; or between two points.",
                parameters: .object([
                    "direction": JSONSchema.string("Finger direction", enum: ["up", "down", "left", "right"]).optional,
                    "element": JSONSchema.integer("Swipe inside this element (e.g. a list or carousel)").optional,
                    "distance": JSONSchema.number("Fraction of the area to travel, default 0.6", minimum: 0.1, maximum: 0.95).optional,
                    "from_x": JSONSchema.number().optional, "from_y": JSONSchema.number().optional,
                    "to_x": JSONSchema.number().optional, "to_y": JSONSchema.number().optional,
                ])
            ) { (args: SwipeArgs, _) in
                let (from, to) = try await swipePoints(args)
                return try await act("swiped \(args.direction ?? "") (\(Int(from.x)),\(Int(from.y)))→(\(Int(to.x)),\(Int(to.y)))") {
                    try await driver.swipe(from: from, to: to, duration: 0.35)
                }
            }
        }

        func swipePoints(_ args: SwipeArgs) async throws -> (CGPoint, CGPoint) {
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

        var pressHome: Tool {
            Tool("press_home", description: "Go to the home screen.") { _ in
                try await act("pressed home") { try await driver.pressHome() }
            }
        }

        var launchApp: Tool {
            Tool(
                "launch_app",
                description: "Open an installed app by bundle id (e.g. com.apple.mobilesafari).",
                parameters: .object(["bundle_id": JSONSchema.string("Bundle identifier")])
            ) { (args: LaunchArgs, _) in
                try await act("launched \(args.bundle_id)") { try await driver.launchApp(bundleID: args.bundle_id) }
            }
        }

        var openURL: Tool {
            Tool(
                "open_url",
                description: "Open a URL or deep link (https://…, maps://, tel: is not allowed).",
                parameters: .object(["url": JSONSchema.string("URL to open")])
            ) { (args: URLArgs, _) in
                guard let url = URL(string: args.url), let scheme = url.scheme?.lowercased() else {
                    throw DriverError("Not a valid URL: \(args.url)")
                }
                guard !["tel", "telprompt", "sms", "facetime", "facetime-audio"].contains(scheme) else {
                    throw DriverError("\(scheme): links are blocked; ask the user to do this themselves.")
                }
                return try await act("opened \(url.absoluteString)") { try await driver.openURL(url) }
            }
        }

        var wait: Tool {
            Tool(
                "wait",
                description: "Wait for loading to finish, then show the screen.",
                parameters: .object(["seconds": JSONSchema.number("Default 2", minimum: 0.5, maximum: 15).optional]),
                replay: .safe
            ) { (args: WaitArgs, _) in
                try await Task.sleep(for: .seconds(min(max(args.seconds ?? 2, 0.5), 15)))
                return try await observe()
            }
        }
    }
}
