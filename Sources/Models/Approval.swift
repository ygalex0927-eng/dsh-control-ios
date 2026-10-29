import Foundation

enum ApprovalKind: String, Codable, Sendable {
    /// 工具调用审批（approval/request）
    case approval
    /// agent 提问（user-questions/request）
    case question
}

/// 与 DSH 的 outcome 字符串保持一致：allowed-once / rejected / cancelled / unavailable。
enum ApprovalDecision: String, Codable, Sendable {
    case allowedOnce = "allowed-once"
    case rejected = "rejected"
    case cancelled = "cancelled"
    case unavailable = "unavailable"

    var label: String {
        switch self {
        case .allowedOnce: return "允许一次"
        case .rejected: return "拒绝"
        case .cancelled: return "已取消"
        case .unavailable: return "不可用"
        }
    }
}

struct ApprovalQuestionOption: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
}

struct ApprovalQuestion: Identifiable, Hashable, Sendable {
    var id: String
    var prompt: String
    var options: [ApprovalQuestionOption]
    var multi: Bool
    var allowCustom: Bool
}

struct ApprovalItem: Identifiable, Hashable, Sendable {
    /// `$events` 的 eventId，应答时原样回传。
    var id: String
    var kind: ApprovalKind
    var machineId: String
    var sessionId: String
    var agentId: String?
    var callId: String?
    var sessionTitle: String
    var toolName: String
    var reason: String
    var commandPreview: String?
    var questions: [ApprovalQuestion]
    var raw: JSONValue?
    var createdAt: Date
    var decision: ApprovalDecision?
    var isUnread: Bool

    var isResolved: Bool { decision != nil }

    init(
        id: String,
        kind: ApprovalKind,
        machineId: String,
        sessionId: String,
        agentId: String? = nil,
        callId: String? = nil,
        sessionTitle: String,
        toolName: String,
        reason: String,
        commandPreview: String? = nil,
        questions: [ApprovalQuestion] = [],
        raw: JSONValue? = nil,
        createdAt: Date = Date(),
        decision: ApprovalDecision? = nil,
        isUnread: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.machineId = machineId
        self.sessionId = sessionId
        self.agentId = agentId
        self.callId = callId
        self.sessionTitle = sessionTitle
        self.toolName = toolName
        self.reason = reason
        self.commandPreview = commandPreview
        self.questions = questions
        self.raw = raw
        self.createdAt = createdAt
        self.decision = decision
        self.isUnread = isUnread
    }
}
