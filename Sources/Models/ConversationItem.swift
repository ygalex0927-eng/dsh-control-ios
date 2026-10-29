import Foundation

enum MessageRole: String, Hashable, Sendable {
    case user
    case assistant
    case system
}

enum ToolKind: String, Hashable, Sendable {
    case terminal
    case diff
    case search
    case read
    case fetch
    case question
    case generic

    var label: String {
        switch self {
        case .terminal: return "命令"
        case .diff: return "改动"
        case .search: return "搜索"
        case .read: return "读取"
        case .fetch: return "网络"
        case .question: return "提问"
        case .generic: return "工具"
        }
    }

    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .diff: return "plus.forwardslash.minus"
        case .search: return "magnifyingglass"
        case .read: return "doc.text"
        case .fetch: return "globe"
        case .question: return "questionmark.bubble"
        case .generic: return "wrench.and.screwdriver"
        }
    }
}

struct ToolFileDiff: Identifiable, Hashable, Sendable {
    enum LineKind: Hashable, Sendable {
        case added
        case removed
    }

    struct Line: Identifiable, Hashable, Sendable {
        var id: String
        var kind: LineKind
        var text: String
    }

    var path: String
    var lines: [Line]

    var id: String { path }
}

struct ToolCard: Identifiable, Hashable, Sendable {
    var id: String
    var callId: String
    var name: String
    var kind: ToolKind
    var title: String
    var subtitle: String?
    var command: String?
    var output: String?
    var exitCode: Int?
    var files: [ToolFileDiff]
    var isRunning: Bool
    var isFailed: Bool
    var rawArguments: String?

    init(
        id: String,
        callId: String,
        name: String,
        kind: ToolKind,
        title: String,
        subtitle: String? = nil,
        command: String? = nil,
        output: String? = nil,
        exitCode: Int? = nil,
        files: [ToolFileDiff] = [],
        isRunning: Bool = true,
        isFailed: Bool = false,
        rawArguments: String? = nil
    ) {
        self.id = id
        self.callId = callId
        self.name = name
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.files = files
        self.isRunning = isRunning
        self.isFailed = isFailed
        self.rawArguments = rawArguments
    }
}

struct PlanItem: Identifiable, Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    var id: String
    var text: String
    var status: Status

    var isCompleted: Bool { status == .completed }
}

struct PlanCard: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var items: [PlanItem]

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(items.filter(\.isCompleted).count) / Double(items.count)
    }
}

struct SubagentCard: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var status: String
    var detail: String?
}

/// 会话转录里的一项。折叠器只产出这几种；视图负责画。
enum ConversationItem: Identifiable, Hashable, Sendable {
    case message(id: String, role: MessageRole, text: String, reasoning: String?, complete: Bool, at: Date)
    case tool(ToolCard)
    case plan(PlanCard)
    case image(id: String, caption: String)
    case subagent(SubagentCard)
    case notice(id: String, text: String, isError: Bool)

    var id: String {
        switch self {
        case .message(let id, _, _, _, _, _): return id
        case .tool(let card): return card.id
        case .plan(let plan): return plan.id
        case .image(let id, _): return id
        case .subagent(let card): return card.id
        case .notice(let id, _, _): return id
        }
    }
}
