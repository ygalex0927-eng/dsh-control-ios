import Foundation

enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waiting
    case failed

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .waiting: return "等你处理"
        case .failed: return "失败"
        }
    }
}

struct SessionSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var machineId: String
    var title: String
    /// 工作区名。空串表示「未分组」。
    var workspace: String
    var status: SessionStatus
    var modelName: String?
    var modelProvider: String?
    var modelEffort: String?
    var tokenUsage: TokenUsage?
    var sessionStats: SessionStats?
    var updatedAt: Date
    var pendingCount: Int
    var cwd: String?
    var isSubagent: Bool
    var parentSessionId: String?
    var lastSnippet: String?

    init(
        id: String = UUID().uuidString,
        machineId: String,
        title: String,
        workspace: String = "未分组",
        status: SessionStatus = .idle,
        modelName: String? = nil,
        modelProvider: String? = nil,
        modelEffort: String? = nil,
        tokenUsage: TokenUsage? = nil,
        sessionStats: SessionStats? = nil,
        updatedAt: Date = Date(),
        pendingCount: Int = 0,
        cwd: String? = nil,
        isSubagent: Bool = false,
        parentSessionId: String? = nil,
        lastSnippet: String? = nil
    ) {
        self.id = id
        self.machineId = machineId
        self.title = title
        self.workspace = workspace
        self.status = status
        self.modelName = modelName
        self.modelProvider = modelProvider
        self.modelEffort = modelEffort
        self.tokenUsage = tokenUsage
        self.sessionStats = sessionStats
        self.updatedAt = updatedAt
        self.pendingCount = pendingCount
        self.cwd = cwd
        self.isSubagent = isSubagent
        self.parentSessionId = parentSessionId
        self.lastSnippet = lastSnippet
    }
}
