import Foundation

enum AppTab: Hashable {
    case overview
    case sessions
    case settings
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
}

/// 左侧栏的一栏：工作区（或「置顶」「已归档」「未归类」）。数组顺序就是显示顺序。
struct SidebarGroup: Identifiable {
    enum Kind: Hashable {
        case pinned
        case workspace
        case unassigned
        case archived
    }

    var id: String
    var kind: Kind
    var title: String
    var workspacePath: String?
    var sessions: [SessionSummary]
}

/// 全局状态：机器、会话、待办、演示数据与路由。
///
/// M1 用 Mock 数据把全部界面跑通；`BridgeClient` 已按协议 v1 实现，
/// 真机联调时把 `isDemoMode` 关掉、补 Pairing / Keychain / 推送上报即可。
@MainActor
final class AppModel: ObservableObject {
    @Published var tab: AppTab = .overview
    @Published private(set) var isDemoMode: Bool
    @Published private(set) var machines: [Machine]
    @Published private(set) var runtimes: [String: MachineRuntime]
    @Published private(set) var sessions: [SessionSummary]
    @Published private(set) var approvals: [ApprovalItem]
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var archivedSessionIds: Set<String> = []
    @Published private(set) var pinnedSessionIds: Set<String> = []
    /// 按机器缓存模型目录（5 分钟内复用；打开选择器秒开）。
    @Published private(set) var modelCatalogs: [String: ModelCatalog] = [:]
    private var catalogFetchedAt: [String: Date] = [:]
    @Published private(set) var modelCatalogError: String?

    /// 当前实时机器（或第一台）的模型目录；picker/输入条直接读缓存。
    var modelCatalog: ModelCatalog {
        if let activeMachineId, let cached = modelCatalogs[activeMachineId] { return cached }
        if let first = machines.first, let cached = modelCatalogs[first.id] { return cached }
        return modelCatalogs.values.first ?? ModelCatalog()
    }
    func catalog(for machineId: String) -> ModelCatalog {
        modelCatalogs[machineId] ?? ModelCatalog()
    }

    func reloadModelCatalog(for machineId: String) async {
        guard let machine = machine(id: machineId) else { return }
        await loadModelCatalog(for: machine, force: true)
    }

    func activateMachine(_ machineId: String?) {
        guard !isDemoMode,
              let machine = machines.first(where: { $0.id == machineId }) ?? machines.first,
              activeMachineId != machine.id else { return }
        connectLive(machine: machine)
        prefetchModelCatalog(for: machine.id)
        Task { await loadSessions(for: machine) }
    }

    @Published private(set) var modelSelectionError: String?
    @Published private(set) var activeMachineId: String?
    @Published var showArchived = false

    @Published var filterMachineId: String?
    /// 调试/联调：`--open-session <sessionId>` 时自动打开会话详情。
    @Published var pendingOpenSessionID: String?
    @Published var searchText: String = ""
    @Published var toast: ToastMessage?

    let push: PushManager

    private var detailModels: [String: SessionDetailModel] = [:]
    private let store = MachineStore()
    private var toastTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var refreshDebounceTask: Task<Void, Never>?
    private var lastSessionRefresh = Date.distantPast
    private var workspaceOrder: [String] = []
    private var workspacesByMachine: [String: [Workspace]] = [:]
    private var orderByMachine: [String: [String]] = [:]
    private var archivedByMachine: [String: Set<String>] = [:]
    private var pinnedByMachine: [String: Set<String>] = [:]
    private var workspaceOwners: [String: String] = [:]

    init() {
        let forceMock = ProcessInfo.processInfo.arguments.contains("--mock")
        let forceLive = ProcessInfo.processInfo.arguments.contains("--live")
        let saved = MachineStore().load()
        let demo = !forceLive && (forceMock || saved.isEmpty)

        isDemoMode = demo
        push = PushManager()
        machines = demo ? MockData.machines() : saved
        runtimes = demo ? MachineStatusMerger.merge(MockData.observations()) : [:]
        sessions = demo ? MockData.sessions() : []
        approvals = demo ? MockData.approvals() : []
        Diagnostics.shared.start()
        if demo {
            workspaces = MockData.workspaces()
            workspaceOrder = workspaces.map(\.id)
            archivedSessionIds = ["session-docs"]
            pinnedSessionIds = ["session-strategy", "session-fold"]
        }
    }

    // MARK: - 聚合

    var stats: (online: Int, busy: Int, pending: Int) {
        MachineStatusMerger.aggregate(runtimes)
    }

    var pendingApprovals: [ApprovalItem] {
        approvals.filter { !$0.isResolved }
    }

    var runningSessions: [SessionSummary] {
        sessions.filter { $0.status == .running }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var waitingSessions: [SessionSummary] {
        sessions.filter { $0.status == .waiting }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var filteredSessions: [SessionSummary] {
        sessions
            .filter { filterMachineId == nil || $0.machineId == filterMachineId }
            .filter { session in
                guard !searchText.isEmpty else { return true }
                return session.title.localizedCaseInsensitiveContains(searchText)
                    || session.workspace.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 和电脑左侧栏一致的分组：置顶 → 工作区（按 order）→ 未归类 → 已归档（可选）。
    var sidebarGroups: [SidebarGroup] {
        let visible = filteredSessions
        var pinned: [SessionSummary] = []
        var archived: [SessionSummary] = []
        var normal: [SessionSummary] = []
        for session in visible {
            if archivedSessionIds.contains(session.id) {
                archived.append(session)
            } else if pinnedSessionIds.contains(session.id) {
                pinned.append(session)
            } else {
                normal.append(session)
            }
        }

        // pinnedSessionIds 的会话仍在各自工作区里，只是排到组内最前（和电脑左侧栏一致）。
        var groups: [SidebarGroup] = []

        let ordered = orderedWorkspaces()
        var assigned = Set<String>()
        for workspace in ordered {
            let owner = workspaceOwners[workspace.id]
            if let filterMachineId, let owner, owner != filterMachineId { continue }
            let belongs: (SessionSummary) -> Bool = {
                (owner == nil || $0.machineId == owner) && Self.belongsTo(workspace: workspace, session: $0)
            }
            let sessions = pinned.filter(belongs) + normal.filter(belongs)
            assigned.formUnion(sessions.map(\.id))
            groups.append(SidebarGroup(
                id: "workspace.\(workspace.id)",
                kind: .workspace,
                title: filterMachineId == nil && machines.count > 1 && owner != nil
                    ? "\(machineName(for: owner!)) · \(workspace.title)" : workspace.title,
                workspacePath: workspace.path,
                sessions: sortedSessions(sessions).map { titleAdjusted($0, fallback: workspace.title) }
            ))
        }

        let unassigned = sortedSessions(pinned.filter { !assigned.contains($0.id) && !archivedSessionIds.contains($0.id) }
            + normal.filter { !assigned.contains($0.id) })
        if !unassigned.isEmpty {
            groups.append(SidebarGroup(id: "section.unassigned", kind: .unassigned, title: "未归类", sessions: unassigned))
        }

        if showArchived, !archived.isEmpty {
            groups.append(SidebarGroup(id: "section.archived", kind: .archived, title: "已归档", sessions: sortedSessions(archived)))
        }
        return groups
    }

    /// 组内排序：pinned 优先，其次 updatedAt 倒序。
    private func sortedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { lhs, rhs in
            let leftPinned = pinnedSessionIds.contains(lhs.id)
            let rightPinned = pinnedSessionIds.contains(rhs.id)
            if leftPinned != rightPinned { return leftPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func orderedWorkspaces() -> [Workspace] {
        var seen = Set<String>()
        var ordered: [Workspace] = []
        for id in workspaceOrder {
            if let workspace = workspaces.first(where: { $0.id == id }), seen.insert(id).inserted {
                ordered.append(workspace)
            }
        }
        for workspace in workspaces where seen.insert(workspace.id).inserted {
            ordered.append(workspace)
        }
        return ordered
    }

    /// 归属规则：先看 workspace.sessionIds，再看会话 cwd 是否在工作区目录下。
    static func belongsTo(workspace: Workspace, session: SessionSummary) -> Bool {
        if workspace.sessionIds.contains(session.id) { return true }
        return workspace.contains(cwd: session.cwd)
    }

    private func titleAdjusted(_ session: SessionSummary, fallback: String) -> SessionSummary {
        guard session.title.isEmpty || session.title == "未命名会话" else { return session }
        var copy = session
        copy.title = fallback
        return copy
    }

    func runtime(for machineId: String) -> MachineRuntime {
        runtimes[machineId] ?? MachineRuntime()
    }

    func machine(id: String) -> Machine? {
        machines.first { $0.id == id }
    }

    func machineName(for machineId: String) -> String {
        machine(id: machineId)?.name ?? "未知机器"
    }

    func session(id: String) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    func sessions(for machineId: String) -> [SessionSummary] {
        sessions.filter { $0.machineId == machineId }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - 会话详情

    func detail(for session: SessionSummary) -> SessionDetailModel {
        if let existing = detailModels[session.id] { return existing }
        let machine = machine(id: session.machineId)
        let seeds = isDemoMode ? MockData.seedItems(for: session) : []
        let model = SessionDetailModel(session: session, isDemo: isDemoMode, machine: machine, seedItems: seeds)
        model.onBusyChanged = { [weak self] busy in
            self?.setBusy(busy, machineId: session.machineId)
        }
        if let title = currentModelTitle(for: session) {
            model.updateModel(title)
        }
        detailModels[session.id] = model
        prefetchModelCatalog(for: session.machineId)
        return model
    }

    private func setBusy(_ busy: Bool, machineId: String) {
        var runtime = runtimes[machineId] ?? MachineRuntime()
        runtime.state = busy ? .busy : .online
        runtime.updatedAt = Date()
        runtimes[machineId] = runtime
    }

    // MARK: - 实时联动（workspace/follow + /v1/events）

    /// 连接一台机器：常驻工作区流与事件流。同一时间只保持一台机器的实时连接。
    func connectLive(machine: Machine) {
        guard !isDemoMode, let url = machine.url else { return }
        stopStreams()
        activeMachineId = machine.id
        let key = bridgeKey(for: machine)

        workspaceTask = Task { [weak self] in
            let stream = await BridgeClient.shared.workspaceStream(host: url, key: key)
            do {
                for try await frame in stream {
                    guard !Task.isCancelled else { return }
                    self?.apply(workspaceFrame: frame, machineId: machine.id)
                }
            } catch {
                NSLog("[DSHControl] workspace stream failed: %@", String(describing: error))
            }
        }

        eventsTask = Task { [weak self] in
            let stream = await BridgeClient.shared.startEvents(host: url, key: key)
            do {
                for try await frame in stream {
                    guard !Task.isCancelled else { return }
                    await self?.handle(eventFrame: frame, machineId: machine.id)
                }
            } catch {
                // 事件通道断开：保留现有数据，下一次 bootstrap/重连再校准。
            }
        }
    }

    func stopStreams() {
        workspaceTask?.cancel()
        workspaceTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        refreshDebounceTask?.cancel()
        refreshDebounceTask = nil
        activeMachineId = nil
        // 旧事件流负责关闭自己的 socket，避免延迟 close 误关刚建立的新连接。
    }

    private func apply(workspaceFrame frame: WorkspaceFrame, machineId: String) {
        switch frame {
        case .baseline(let items, let archived, let pinned):
            workspacesByMachine[machineId] = items
            orderByMachine[machineId] = items.map(\.id)
            archivedByMachine[machineId] = Set(archived)
            pinnedByMachine[machineId] = Set(pinned)
        case .upsert(let workspace):
            var items = workspacesByMachine[machineId] ?? []
            if let index = items.firstIndex(where: { $0.id == workspace.id }) {
                items[index] = workspace
            } else {
                items.append(workspace)
            }
            workspacesByMachine[machineId] = items
            if !(orderByMachine[machineId] ?? []).contains(workspace.id) {
                orderByMachine[machineId, default: []].append(workspace.id)
            }
        case .order(let ids):
            orderByMachine[machineId] = ids
        case .unknown:
            return
        }
        workspaces = machines.flatMap { workspacesByMachine[$0.id] ?? [] }
        workspaceOrder = machines.flatMap { orderByMachine[$0.id] ?? [] }
        workspaceOwners = [:]
        for machine in machines {
            for workspace in workspacesByMachine[machine.id] ?? [] {
                workspaceOwners[workspace.id] = machine.id
            }
        }
        archivedSessionIds = archivedByMachine.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        pinnedSessionIds = pinnedByMachine.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    private func handle(eventFrame frame: BridgeEventFrame, machineId: String) async {
        switch frame {
        case .ready:
            // 新通道建立时校准一次；不随每个事件全量刷新。
            if Date().timeIntervalSince(lastSessionRefresh) > 2 {
                await refreshSessionsNow()
            }
        case .emit(let name, let args):
            // 电脑上新建/删除/改名/状态变化 → 防抖 500ms 刷新会话列表。
            if name.hasPrefix("api-session/") {
                updateSessionState(from: args)
                scheduleSessionRefresh()
            }
        case .request(let eventId, let name, let agentId, let request):
            var item = Self.makeApproval(
                eventId: eventId,
                eventName: name,
                agentId: agentId,
                machineId: machineId,
                request: request
            )
            if let session = session(id: item.sessionId) {
                item.sessionTitle = session.title
            } else {
                item.sessionTitle = item.sessionId.isEmpty ? "未知会话" : item.sessionId
            }
            if !approvals.contains(where: { $0.id == item.id }) {
                approvals.insert(item, at: 0)
                showToast(item.kind == .approval ? "有新的审批请求" : "agent 在等你回答")
            }
            scheduleSessionRefresh()
        case .cancel(let eventId):
            if approvals.contains(where: { $0.id == eventId }) {
                approvals.removeAll { $0.id == eventId }
                showToast("已在电脑上处理")
            }
        case .unknown:
            break
        }
    }

    private func scheduleSessionRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshSessionsNow()
        }
    }

    private func refreshSessionsNow() async {
        lastSessionRefresh = Date()
        for machine in machines {
            await loadSessions(for: machine)
        }
        refreshDetailModels()
    }

    /// 会话列表刷新后，把最新内容同步给已打开的详情页（不改变导航身份）。
    private func refreshDetailModels() {
        for (id, detail) in detailModels {
            guard let session = session(id: id) else { continue }
            detail.updateSession(session)
            if let title = currentModelTitle(for: session) {
                detail.updateModel(title)
            }
        }
    }

    /// `projections.values.modelSelection.next → lastUsed → catalog.default` 的展示名。
    func currentModelTitle(for session: SessionSummary) -> String? {
        catalog(for: session.machineId).displayTitle(
            provider: session.modelProvider,
            model: session.modelName,
            effort: session.modelEffort
        )
    }

    /// `api-session/status|activity` 的 args：尽量读出 sessionId 与 running，更新列表与已打开详情。
    private func updateSessionState(from args: [JSONValue]) {
        guard let payload = args.first ?? args.last else { return }
        let sessionId = payload["sessionId"]?.stringValue
            ?? payload["agentId"]?.stringValue
            ?? payload["id"]?.stringValue
        guard let sessionId else { return }
        let running = payload["running"]?.boolValue
            ?? payload["session"]?["running"]?.boolValue
        if let running {
            sessions = sessions.map { session in
                guard session.id == sessionId else { return session }
                var updated = session
                updated.status = running ? .running : .idle
                updated.updatedAt = Date()
                return updated
            }
            detailModels[sessionId]?.applyStatus(running ? .running : .idle)
        }
    }

    // MARK: - 待办（真实审批/提问）

    func answerApproval(_ approval: ApprovalItem, decision: ApprovalDecision) {
        guard !approval.isResolved else { return }
        send(answer: approval, outcome: ["kind": "result", "value": .string(decision.rawValue)], toast: "已\(decision.label)：\(approval.toolName)")
        detailModels[approval.sessionId]?.appendNotice("\(decision.label)：\(approval.toolName)", isError: decision == .rejected)
    }

    /// 提问应答：value 是答案数组 `[{id, selected:[...], custom?}]`。
    func answerQuestions(_ approval: ApprovalItem, answers: [JSONValue]) {
        guard !approval.isResolved else { return }
        send(answer: approval, outcome: ["kind": "result", "value": .array(answers)], toast: "已提交回答")
        detailModels[approval.sessionId]?.appendNotice("你已回答 agent 的提问")
    }

    /// 跳过提问：`{"kind":"next"}` 交给其他客户端处理。
    func skipApproval(_ approval: ApprovalItem) {
        guard !approval.isResolved else { return }
        send(answer: approval, outcome: ["kind": "next"], toast: "已跳过")
    }

    private func send(answer approval: ApprovalItem, outcome: JSONValue, toast: String) {
        approvals.removeAll { $0.id == approval.id }
        showToast(toast)
        Task { [weak self] in
            do {
                try await BridgeClient.shared.answerEvent(eventId: approval.id, outcome: outcome)
            } catch {
                self?.showToast("应答失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    /// `$events` 的 request 帧 → 收件箱条目。字段形状做宽容解析，取不到就展示原始 JSON。
    static func makeApproval(
        eventId: String,
        eventName: String,
        agentId: String?,
        machineId: String,
        request: JSONValue
    ) -> ApprovalItem {
        let kind: ApprovalKind = eventName.contains("question") ? .question : .approval
        let nested: JSONValue? = request["request"] ?? request["payload"] ?? request["data"]
        let arguments: JSONValue? = request["arguments"] ?? nested?["arguments"]

        let sessionId = string(from: [
            request["sessionId"],
            nested?["sessionId"],
            request["agentId"],
            agentId.map { .string($0) },
        ]) ?? ""
        let callId = string(from: [request["callId"], nested?["callId"]])

        let rawQuestions = request["questions"]?.arrayValue
            ?? nested?["questions"]?.arrayValue
            ?? request["userQuestions"]?.arrayValue
            ?? []
        let questions = parseQuestions(rawQuestions)

        let defaultTool = kind == .question ? "ask_user_question" : "tool"
        let toolName = string(from: [
            request["toolName"],
            request["tool"],
            request["name"],
            nested?["toolName"],
        ]) ?? defaultTool
        let command = string(from: [
            request["command"],
            arguments?["command"],
            arguments?["cmd"],
            request["input"]?["command"],
            request["params"]?["command"],
            nested?["command"],
        ])
        let reason = string(from: [
            request["reason"],
            request["description"],
            request["message"],
            request["summary"],
            nested?["reason"],
        ]) ?? questions.first?.prompt ?? request.rawText

        return ApprovalItem(
            id: eventId,
            kind: kind,
            machineId: machineId,
            sessionId: sessionId,
            agentId: agentId,
            callId: callId,
            sessionTitle: "",
            toolName: toolName,
            reason: reason,
            commandPreview: command,
            questions: questions,
            raw: request,
            createdAt: Date(),
            decision: nil,
            isUnread: true
        )
    }

    private static func string(from values: [JSONValue?]) -> String? {
        for value in values {
            if let text = value?.stringValue, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func parseQuestions(_ raw: [JSONValue]) -> [ApprovalQuestion] {
        var result: [ApprovalQuestion] = []
        for (index, item) in raw.enumerated() {
            let prompt = string(from: [item["question"], item["prompt"], item["text"], item["title"]]) ?? ""
            if prompt.isEmpty { continue }
            let questionId = item["id"]?.stringValue ?? "q\(index)"
            let multi = item["multi"]?.boolValue
                ?? item["multiple"]?.boolValue
                ?? item["multiSelect"]?.boolValue
                ?? false
            let allowCustom = item["allowCustom"]?.boolValue ?? item["custom"]?.boolValue ?? false
            let options = parseOptions(item["options"]?.arrayValue ?? [], questionId: questionId)
            result.append(ApprovalQuestion(
                id: questionId,
                prompt: prompt,
                options: options,
                multi: multi,
                allowCustom: allowCustom
            ))
        }
        return result
    }

    private static func parseOptions(_ raw: [JSONValue], questionId: String) -> [ApprovalQuestionOption] {
        var result: [ApprovalQuestionOption] = []
        for (index, option) in raw.enumerated() {
            if let label = option.stringValue, !label.isEmpty {
                result.append(ApprovalQuestionOption(id: "\(questionId)-\(index)", label: label))
                continue
            }
            guard let label = string(from: [option["label"], option["text"], option["value"]]) else { continue }
            let id = option["id"]?.stringValue ?? "\(questionId)-\(index)"
            result.append(ApprovalQuestionOption(id: id, label: label))
        }
        return result
    }

    // MARK: - 模型目录 / 切换

    func loadModelCatalog(for machine: Machine, force: Bool = false) async {
        guard let url = machine.url else { return }
        if !force,
           let fetchedAt = catalogFetchedAt[machine.id],
           Date().timeIntervalSince(fetchedAt) < 300,
           modelCatalogs[machine.id] != nil {
            return
        }
        do {
            let catalog = try await BridgeClient.shared.modelCatalog(host: url, key: bridgeKey(for: machine))
            modelCatalogs[machine.id] = catalog
            catalogFetchedAt[machine.id] = Date()
            modelCatalogError = nil
            refreshDetailModels()
        } catch let error as BridgeError {
            modelCatalogError = "\(error.code)：\(error.message)"
        } catch {
            modelCatalogError = error.localizedDescription
        }
    }

    /// 打开会话时后台预热 catalog（不阻塞 UI）。
    func prefetchModelCatalog(for machineId: String) {
        guard let machine = machine(id: machineId) else { return }
        if let fetchedAt = catalogFetchedAt[machineId],
           Date().timeIntervalSince(fetchedAt) < 300,
           modelCatalogs[machineId] != nil {
            return
        }
        Task { await loadModelCatalog(for: machine) }
    }

    /// 供模型选择器在缓存为空时手动刷新。
    func reloadModelCatalogForCurrentMachine() async {
        guard let machine = machines.first(where: { $0.id == activeMachineId }) ?? machines.first else { return }
        await loadModelCatalog(for: machine, force: true)
    }

    /// 乐观切换：立即更新会话/输入条/头部并返回，RPC 后台执行，失败回滚。
    func applyModelSelection(_ option: ModelOption, effort: String?, for session: SessionSummary) {
        let resolvedEffort = effort ?? option.defaultEffort
        let title = option.displayTitle(effort: resolvedEffort)
        let previous = sessions.first(where: { $0.id == session.id }) ?? session

        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var updated = sessions[index]
            updated.modelName = option.model
            updated.modelProvider = option.provider
            updated.modelEffort = resolvedEffort
            sessions[index] = updated
        }
        detailModels[session.id]?.updateModel(title)
        detailModels[session.id]?.setSwitchingModel(true)
        modelSelectionError = nil

        guard let machine = machine(id: session.machineId), let url = machine.url else {
            rollbackModelSelection(previous, sessionID: session.id, message: "未连接机器，切换已回滚")
            return
        }
        let key = bridgeKey(for: machine)
        Task { [weak self] in
            do {
                try await BridgeClient.shared.selectModel(
                    host: url,
                    key: key,
                    sessionId: session.id,
                    option: option,
                    effort: resolvedEffort
                )
                self?.detailModels[session.id]?.setSwitchingModel(false)
                self?.showToast("已切换模型：\(title)")
            } catch let error as BridgeError {
                self?.rollbackModelSelection(previous, sessionID: session.id, message: "\(error.code)：\(error.message)")
            } catch {
                self?.rollbackModelSelection(previous, sessionID: session.id, message: error.localizedDescription)
            }
        }
    }

    private func rollbackModelSelection(_ previous: SessionSummary, sessionID: String, message: String) {
        modelSelectionError = message
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = previous
        }
        detailModels[sessionID]?.updateModel(currentModelTitle(for: previous) ?? previous.modelName ?? "默认模型")
        detailModels[sessionID]?.setSwitchingModel(false)
        showToast("切换模型失败：\(message)", isError: true)
    }

    func selectModel(_ option: ModelOption, effort: String?, for session: SessionSummary) async -> Bool {
        guard let machine = machine(id: session.machineId), let url = machine.url else { return false }
        let resolvedEffort = effort ?? option.defaultEffort
        modelSelectionError = nil
        detailModels[session.id]?.setSwitchingModel(true)
        defer { detailModels[session.id]?.setSwitchingModel(false) }
        do {
            try await BridgeClient.shared.selectModel(
                host: url,
                key: bridgeKey(for: machine),
                sessionId: session.id,
                option: option,
                effort: resolvedEffort
            )
            let title = option.displayTitle(effort: resolvedEffort)
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                var updated = sessions[index]
                updated.modelName = option.model
                updated.modelProvider = option.provider
                updated.modelEffort = resolvedEffort
                if updated != sessions[index] { sessions[index] = updated }
            }
            detailModels[session.id]?.updateModel(title)
            showToast("已切换模型：\(title)")
            return true
        } catch let error as BridgeError {
            modelSelectionError = "\(error.code)：\(error.message)"
            showToast("切换模型失败：\(error.code)", isError: true)
            return false
        } catch {
            modelSelectionError = error.localizedDescription
            showToast("切换模型失败：\(error.localizedDescription)", isError: true)
            return false
        }
    }

    // MARK: - 机器

    /// 只删手机本地记录（用户一个人用，没有设备授权/吊销体系）。
    func removeMachine(_ machine: Machine) {
        machines.removeAll { $0.id == machine.id }
        sessions.removeAll { $0.machineId == machine.id }
        approvals.removeAll { $0.machineId == machine.id }
        runtimes.removeValue(forKey: machine.id)
        detailModels = detailModels.filter { $0.value.session.machineId != machine.id }
        BridgeKeyStore.shared.remove(for: machine.id)
        store.save(machines)
        workspacesByMachine.removeValue(forKey: machine.id)
        orderByMachine.removeValue(forKey: machine.id)
        archivedByMachine.removeValue(forKey: machine.id)
        pinnedByMachine.removeValue(forKey: machine.id)
        workspaces.removeAll { workspaceOwners[$0.id] == machine.id }
        workspaceOwners = workspaceOwners.filter { $0.value != machine.id }
        if activeMachineId == machine.id { stopStreams() }
        if filterMachineId == machine.id { filterMachineId = nil }
        showToast("已移除 \(machine.name)")
    }

    /// 添加机器：`/v1/hello` 成功即视为已连接，不需要配对码。
    func addMachine(rawLink: String) async -> String {
        guard let link = MachineLink.parse(rawLink) ?? MachineLink.parseAddress(rawLink) else {
            return "地址格式不正确。示例：http://127.0.0.1:8787 或 dshcontrol://add?host=https%3A%2F%2Fmac.tailnet.ts.net"
        }
        return await addMachine(url: link.host, key: link.key)
    }

    func addMachine(url: URL, key: String?) async -> String {
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = (trimmedKey?.isEmpty == true) ? nil : trimmedKey

        if isDemoMode {
            let machine = Machine(
                id: "demo-added-\(UUID().uuidString.prefix(4))",
                name: "新机器 · \(url.host ?? url.absoluteString)",
                host: url.absoluteString,
                kind: .unknown,
                bridgeVersion: "0.1.0-dev",
                dshVersion: "0.2.1-rc.3",
                isDemo: true
            )
            machines.append(machine)
            runtimes[machine.id] = MachineRuntime(state: .online, pendingCount: 0, sessionCount: 0, updatedAt: Date())
            showToast("演示：已添加 \(machine.name)")
            return "演示模式：地址解析成功（\(url.absoluteString)）。切到真机模式会立即请求 /v1/hello。"
        }

        do {
            let hello = try await BridgeClient.shared.hello(host: url)
            var machine = hello.makeMachine(host: url.absoluteString)
            machine.bridgeVersion = hello.bridge?.version
            machine.dshVersion = hello.dsh?.version
            machine.protocolVersion = hello.protocolVersion
            machines.removeAll { $0.host == machine.host }
            machines.insert(machine, at: 0)
            if let effectiveKey {
                BridgeKeyStore.shared.set(effectiveKey, for: machine.id)
            } else {
                BridgeKeyStore.shared.remove(for: machine.id)
            }
            store.save(machines)
            runtimes[machine.id] = MachineRuntime(state: .online, pendingCount: 0, sessionCount: 0, updatedAt: Date())
            filterMachineId = machine.id
            isDemoMode = false
            await loadSessions(for: machine)
            await loadModelCatalog(for: machine)
            connectLive(machine: machine)
            tab = .sessions
            showToast("已连接 \(machine.name)")
            let keyNote = effectiveKey == nil ? "零鉴权" : "带访问密钥"
            return "已连接 \(machine.name)（\(keyNote)），加载到 \(sessions.count) 个会话。"
        } catch {
            return "连接失败：\(error.localizedDescription)"
        }
    }

    /// 每台机器可选的访问密钥；桥默认零鉴权时为空。
    private func bridgeKey(for machine: Machine) -> String? {
        BridgeKeyStore.shared.key(for: machine.id)
    }

    func refreshLive() async {
        guard !isDemoMode else {
            showToast("演示模式使用本地数据")
            return
        }
        await bootstrap()
    }

    private func loadSessions(for machine: Machine) async {
        guard let url = machine.url else { return }
        do {
            let value = try await BridgeClient.shared.rpc(
                host: url,
                key: bridgeKey(for: machine),
                endpoint: "session/list",
                args: ["_request": [:]]
            )
            let mapped = Self.mapSessions(value, machineId: machine.id)
            patchSessions(with: mapped, machineId: machine.id)
            var runtime = runtimes[machine.id] ?? MachineRuntime()
            runtime.sessionCount = mapped.count
            runtime.updatedAt = Date()
            runtimes[machine.id] = runtime
        } catch {
            showToast("会话列表加载失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// 按 sessionId 原地 patch：只有值真的变了才写回数组，避免整页重排。
    private func patchSessions(with mapped: [SessionSummary], machineId: String) {
        var updated = sessions
        var changed = false
        for incoming in mapped {
            if let index = updated.firstIndex(where: { $0.id == incoming.id }) {
                guard updated[index] != incoming else { continue }
                updated[index] = incoming
                changed = true
            } else {
                updated.append(incoming)
                changed = true
            }
        }
        let validIDs = Set(mapped.map(\.id))
        let beforeCount = updated.count
        updated.removeAll { $0.machineId == machineId && !validIDs.contains($0.id) }
        if updated.count != beforeCount { changed = true }
        if changed { sessions = updated }
    }

    /// 真实形状（0.2.1-rc.3 实测）：
    /// `{ items: [ { sessionId, updatedAt(ms), running, cwd, projections: { values: { title, modelSelection, turnOutline, inbox } } } ] }`
    static func mapSessions(_ value: JSONValue, machineId: String) -> [SessionSummary] {
        let list = value["items"]?.arrayValue
            ?? value.arrayValue
            ?? value["sessions"]?.arrayValue
            ?? []
        return list.enumerated().compactMap { index, item in
            guard let id = item["sessionId"]?.stringValue ?? item["id"]?.stringValue else { return nil }
            let cwd = item["cwd"]?.stringValue
            let projections = item["projections"]?["values"]
            let cwdTitle = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let explicitTitle = projections?["title"]?.stringValue ?? item["title"]?.stringValue ?? ""
            let title = explicitTitle.isEmpty ? cwdTitle : explicitTitle
            let modelSelection = projections?["modelSelection"]
            let chosen = modelSelection?["next"] ?? modelSelection?["lastUsed"]
            let model = chosen?["model"]?.stringValue ?? item["model"]?.stringValue
            let modelProvider = chosen?["provider"]?.stringValue
            let modelEffort = chosen?["reasoningEffort"]?.stringValue
            let tokenUsage = TokenUsage.decode(projections?["tokenUsage"])
            let sessionStats = SessionStats.decode(projections?["sessionStats"])
            let running = item["running"]?.boolValue ?? false
            let updatedAt: Date = {
                if let millis = item["updatedAt"]?.intValue {
                    return Date(timeIntervalSince1970: Double(millis) / 1000)
                }
                return Date()
            }()
            let snippet = projections?["turnOutline"]?.arrayValue?.last?["prompt"]?.stringValue
            let workspace = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未归类"
            _ = index
            var pending = 0
            if let inbox = projections?["inbox"] {
                pending = (inbox["next-turn"]?.arrayValue?.count ?? 0) + (inbox["next-step"]?.arrayValue?.count ?? 0)
            }
            return SessionSummary(
                id: id,
                machineId: machineId,
                title: title,
                workspace: workspace,
                status: running ? .running : .idle,
                modelName: model,
                modelProvider: modelProvider,
                modelEffort: modelEffort,
                tokenUsage: tokenUsage,
                sessionStats: sessionStats,
                updatedAt: updatedAt,
                pendingCount: pending,
                cwd: cwd,
                lastSnippet: snippet
            )
        }
    }

    // MARK: - 模式

    func switchToDemoMode() {
        stopStreams()
        isDemoMode = true
        resetDemo()
        showToast("已切到演示模式")
    }

    func switchToLiveMode() {
        isDemoMode = false
        detailModels = [:]
        machines = store.load()
        runtimes = [:]
        sessions = []
        approvals = []
        filterMachineId = nil
        showToast(machines.isEmpty ? "真机模式：还没有添加机器，点「添加机器」粘贴地址" : "已切到真机模式")
        Task { await bootstrap() }
    }

    /// 真机模式启动时：health + session/list 刷新所有已添加机器。
    func bootstrap() async {
        guard !isDemoMode else { return }
        if let filterMachineId, !machines.contains(where: { $0.id == filterMachineId }) {
            self.filterMachineId = nil
        }
        for machine in machines {
            guard let url = machine.url else { continue }
            do {
                let health = try await BridgeClient.shared.health(host: url, key: bridgeKey(for: machine))
                runtimes[machine.id] = MachineRuntime(
                    state: health.ok ? (health.pendingCount > 0 ? .busy : .online) : .offline,
                    pendingCount: health.pendingCount,
                    sessionCount: runtimes[machine.id]?.sessionCount ?? 0,
                    updatedAt: Date()
                )
                await loadSessions(for: machine)
            } catch {
                runtimes[machine.id] = MachineRuntime(state: .offline, pendingCount: 0, sessionCount: 0, updatedAt: Date())
            }
        }
        if let machine = machines.first(where: { $0.id == filterMachineId })
            ?? machines.first(where: { $0.id == activeMachineId }) ?? machines.first {
            await loadModelCatalog(for: machine)
            connectLive(machine: machine)
        }
    }

    /// 联调快捷入口：`--bridge http://127.0.0.1:8787 [--key <访问密钥>]`，启动后自动添加并跳到会话列表。
    func handleLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let bridge = value(after: "--bridge") else { return }
        let key = value(after: "--key")
        let openSession = value(after: "--open-session")
        isDemoMode = false
        let encodedHost = bridge.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bridge
        var link = "dshcontrol://add?host=\(encodedHost)"
        if let key, !key.isEmpty, let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            link += "&key=\(encodedKey)"
        }
        let message = await addMachine(rawLink: link)
        showToast(message, isError: message.hasPrefix("连接失败"))
        if let openSession, sessions.contains(where: { $0.id == openSession }) {
            tab = .sessions
            pendingOpenSessionID = openSession
        }

        // 演示/截图用：--tab overview|sessions|inbox|settings（放在连接之后，覆盖自动跳转）
        if let rawTab = value(after: "--tab") {
            switch rawTab {
            case "overview": tab = .overview
            case "sessions": tab = .sessions
            case "inbox": tab = .sessions
            case "settings": tab = .settings
            default: break
            }
        }
    }

    // MARK: - 新建会话

    func createSession(title: String, workspace: String, machineId: String) {
        let trimmedTitle = title.isEmpty ? "未命名会话" : title
        let trimmedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isDemoMode,
           let machine = machine(id: machineId),
           let url = machine.url,
           let cwd = sessions.first(where: { $0.workspace == trimmedWorkspace })?.cwd {
            Task { [weak self] in
                do {
                    _ = try await BridgeClient.shared.rpc(
                        host: url,
                        key: self?.bridgeKey(for: machine),
                        endpoint: "session/create",
                        args: ["request": ["cwd": .string(cwd)]]
                    )
                    await self?.loadSessions(for: machine)
                    self?.showToast("已创建「\(trimmedTitle)」")
                } catch {
                    self?.showToast("创建失败：\(error.localizedDescription)", isError: true)
                }
            }
            return
        }

        let session = SessionSummary(
            id: "local-\(UUID().uuidString)",
            machineId: machineId,
            title: trimmedTitle,
            workspace: trimmedWorkspace.isEmpty ? "未分组" : trimmedWorkspace,
            status: .idle,
            modelName: "DeepSeek-V4.1",
            updatedAt: Date(),
            pendingCount: 0,
            lastSnippet: "新建会话，还没有消息"
        )
        sessions.insert(session, at: 0)
        var runtime = runtimes[machineId] ?? MachineRuntime()
        runtime.sessionCount += 1
        runtime.updatedAt = Date()
        runtimes[machineId] = runtime
        showToast("已新建「\(trimmedTitle)」")
    }

    // MARK: - 演示

    func resetDemo() {
        workspacesByMachine = [:]
        orderByMachine = [:]
        archivedByMachine = [:]
        pinnedByMachine = [:]
        workspaceOwners = [:]
        detailModels = [:]
        machines = MockData.machines()
        runtimes = MachineStatusMerger.merge(MockData.observations())
        sessions = MockData.sessions()
        approvals = MockData.approvals()
        workspaces = MockData.workspaces()
        workspaceOrder = workspaces.map(\.id)
        archivedSessionIds = ["session-docs"]
        pinnedSessionIds = ["session-strategy", "session-fold"]
        modelCatalogs = [:]
        catalogFetchedAt = [:]
        modelCatalogError = nil
        showArchived = false
        filterMachineId = nil
        showToast("演示数据已重置")
    }

    // MARK: - Toast

    func showToast(_ text: String, isError: Bool = false) {
        let toast = ToastMessage(text: text, isError: isError)
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
