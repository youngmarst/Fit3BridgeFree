import AppIntents
import Fit3Kit

/// Which app icon/category the band should use for a Shortcuts-forwarded notification.
enum BandAppKind: String, AppEnum {
    case messages, mail, phone, other

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Band App"
    static var caseDisplayRepresentations: [BandAppKind: DisplayRepresentation] = [
        .messages: "Messages",
        .mail: "Mail",
        .phone: "Phone",
        .other: "Other",
    ]

    var forwardedApp: ForwardedApp {
        switch self {
        case .messages: return .messages
        case .mail: return .mail
        case .phone: return .phone
        case .other: return .other
        }
    }
}

/// Shortcuts action: "发送到手环". Used by personal automations such as
/// "收到信息时 → 发送到手环".
struct SendToBandIntent: AppIntent {
    static var title: LocalizedStringResource = "发送到 Galaxy Fit3"
    static var description = IntentDescription("在你的 Galaxy Fit3 手环上显示一条通知。")
    static var openAppWhenRun = false

    @Parameter(title: "标题")
    var title: String

    @Parameter(title: "内容", default: "")
    var message: String

    @Parameter(title: "应用", default: .messages)
    var app: BandAppKind

    static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$title) 和 \(\.$message) 以 \(\.$app) 发送到手环")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let notification = OutgoingNotification(app: app.forwardedApp,
                                                title: title.isEmpty ? app.forwardedApp.displayName : title,
                                                body: message)
        Logbook.shared.add("Shortcut: \(app.rawValue) – \(title)")
        let result = await BandManager.shared.deliver(notification)
        return .result(value: result)
    }
}

struct Fit3BridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToBandIntent(),
                    phrases: ["用 \(.applicationName) 发送到手环"],
                    shortTitle: "发送到手环",
                    systemImageName: "applewatch.radiowaves.left.and.right")
    }
}
