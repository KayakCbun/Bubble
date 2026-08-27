import Foundation

enum BubbleNativeAction: String, CaseIterable {
    case showHelp = "show_help"
    case setupRuntime = "setup_runtime"
    case loginProvider = "login_provider"
    case logoutProvider = "logout_provider"
    case resumeSession = "resume_session"
    case showConversationTree = "show_conversation_tree"
    case reloadRuntime = "reload_runtime"
    case setModel = "set_model"
    case setThinking = "set_thinking"
    case openAgentsFile = "open_agents_file"
    case openApp = "open_app"
    case showMounts = "show_mounts"
    case attachClipboard = "attach_clipboard"
    case newSession = "new_session"
    case createSideSession = "create_side_session"
    case closeSession = "close_session"
    case copyLastResponse = "copy_last_response"
    case hideWindow = "hide_window"

    static var supported: [String] { allCases.map(\.rawValue) }
    static var toolActionList: String { supported.joined(separator: ", ") }

    private var slashName: String {
        switch self {
        case .showHelp: "help"
        case .setupRuntime: "setup"
        case .loginProvider: "login"
        case .logoutProvider: "logout"
        case .resumeSession: "resume"
        case .showConversationTree: "tree"
        case .reloadRuntime: "reload"
        case .setModel: "model"
        case .setThinking: "thinking"
        case .openAgentsFile: "agents"
        case .openApp: "open"
        case .showMounts: "mounts"
        case .attachClipboard: "clipboard"
        case .newSession: "new"
        case .createSideSession: "side"
        case .closeSession: "close"
        case .copyLastResponse: "copy"
        case .hideWindow: "quit"
        }
    }

    static func slashCommand(action: String, argument: String?) -> String? {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let action = Self(rawValue: normalized) else { return nil }
        let value = argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "/\(action.slashName)" : "/\(action.slashName) \(value)"
    }
}
