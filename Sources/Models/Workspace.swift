import Foundation

/// DSH 的工作区（电脑左侧栏的一栏）。`workspace/follow` 的 baseline/upsert 帧直接映射到这个结构。
struct Workspace: Identifiable, Hashable, Sendable {
    var id: String
    var path: String
    var title: String
    var sessionIds: [String]
    var updatedAt: Date

    static func decode(_ value: JSONValue) -> Workspace? {
        guard let id = value["workspaceId"]?.stringValue ?? value["id"]?.stringValue,
              let path = value["path"]?.stringValue
        else { return nil }
        let title = value["title"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent
        let sessionIds = value["sessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let updatedAt: Date = {
            if let millis = value["updatedAt"]?.intValue {
                return Date(timeIntervalSince1970: Double(millis) / 1000)
            }
            if let text = value["updatedAt"]?.stringValue {
                return ISO8601DateFormatter().date(from: text) ?? Date()
            }
            return Date()
        }()
        return Workspace(id: id, path: path, title: title, sessionIds: sessionIds, updatedAt: updatedAt)
    }

    /// 会话工作目录是否落在本工作区目录下（按路径段比较，不是字符串前缀）。
    func contains(cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !base.isEmpty else { return false }
        return cwd == base || cwd.hasPrefix(base + "/")
    }
}

/// `workspace/follow` 的下行帧（实测）：
/// `{type:"baseline", value:{items:[...], archivedSessionIds, pinnedSessionIds}}`
/// `{type:"upsert", value: workspace}` / `{type:"order", value:{workspaceIds:[...]}}`
enum WorkspaceFrame: Sendable {
    case baseline(workspaces: [Workspace], archived: [String], pinned: [String])
    case upsert(Workspace)
    case order([String])
    case unknown

    static func decode(_ value: JSONValue) -> WorkspaceFrame? {
        guard let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "baseline":
            let payload = value["value"]
            let items = payload?["items"]?.arrayValue ?? []
            return .baseline(
                workspaces: items.compactMap(Workspace.decode),
                archived: payload?["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                pinned: payload?["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        case "upsert":
            guard let workspace = Workspace.decode(value["value"] ?? .object([:])) else { return .unknown }
            return .upsert(workspace)
        case "order":
            return .order(value["value"]?["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        default:
            return .unknown
        }
    }
}
