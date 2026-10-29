import Foundation

/// 最近一次内容变化的类型：视图据此决定是否自动滚动（思考增长不滚）。
enum FoldChangeKind: Sendable {
    case structural
    case textStream
    case reasoningStream
}

/// 把 append-only 事件日志折叠成转录。
///
/// 不变量：
/// - 同一 `seq` 只折一次（重复到达静默丢弃）→ 断线重连、翻页重叠都不会双渲染；
/// - 未知事件类型静默忽略，不渲染占位符；
/// - `turn/start` / `turn/end` 维护 running；turn 结束会把未完成的气泡和工具卡收尾。
struct SessionFold: Sendable {
    private(set) var items: [ConversationItem] = []
    private(set) var seen: Set<Int> = []
    private(set) var isRunning: Bool = false
    private(set) var appliedCount: Int = 0
    /// 转录窗口里最早的事件 seq；`> 0` 说明快照被截断，可以往前翻页。
    private(set) var oldestSeq: Int?
    /// 每次内容变化 +1。流式 chunk 是同一个 item 变长（id 不变），视图靠它跟随。
    private(set) var revision: Int = 0
    /// 每条 assistant 消息的 usage（key = 转录条目 id）。
    private(set) var messageUsage: [String: TokenUsage] = [:]
    /// 每条 assistant 消息的思考时长（秒）；只有能从流式帧算出来时才存在，算不出就不编。
    private(set) var messageThinkingSeconds: [String: Double] = [:]
    /// 最近一次 fold 变化的类型（结构 / 正文流 / 思考流）。
    private(set) var lastChangeKind: FoldChangeKind = .structural
    private var streamKey: String?
    private var reasoningStartedAt: Date?
    private var firstTextAt: Date?
    /// 流式增量缓冲：chunk 路径只 append（O(1)），flush 时 join 一次再物化 item。
    private var streamTextBuffer: [String] = []
    private var streamReasoningBuffer: [String] = []
    private var streamDirty = false

    private var indexByID: [String: Int] = [:]
    private var toolIndex: [String: String] = [:]
    private var streamTurn: Int = 0
    private var streamStep: Int = 0

    init() {}

    init(items: [ConversationItem]) {
        self.items = items
        rebuildIndex()
    }

    // MARK: - 事件入口

    mutating func replace(with events: [FoldEvent]) {
        items = []
        seen = []
        oldestSeq = nil
        isRunning = false
        messageUsage = [:]
        messageThinkingSeconds = [:]
        streamKey = nil
        streamTextBuffer = []
        streamReasoningBuffer = []
        streamDirty = false
        reasoningStartedAt = nil
        firstTextAt = nil
        indexByID = [:]
        toolIndex = [:]
        for event in events { _ = apply(event) }
        revision &+= 1
    }

    @discardableResult
    mutating func apply(_ event: FoldEvent) -> Bool {
        guard !seen.contains(event.seq) else { return false }
        seen.insert(event.seq)
        lastChangeKind = .structural
        flushStreamingIfNeeded()
        if oldestSeq == nil || event.seq < (oldestSeq ?? Int.max) {
            oldestSeq = event.seq
        }

        switch event.type {
        case "user/message":
            applyUserMessage(event)
        case "assistant/chunk", "assistant-stream/chunk", "assistant/delta":
            applyAssistantChunk(event)
        case "assistant/message":
            applyAssistantMessage(event)
        case "assistant/attempt":
            applyAssistantAttempt(event)
        case "tool/call":
            applyToolCall(event)
        case "tool/result":
            applyToolResult(event)
        case "turn/start":
            isRunning = true
        case "turn/end":
            isRunning = false
            finishOpenItems()
            appendTurnEndNotice(event)
        case "todo/write", "todo/update":
            applyTodos(event)
        case "notice", "system/notice":
            let text = event.data["text"]?.stringValue ?? event.data["message"]?.stringValue ?? ""
            if !text.isEmpty { appendNotice(text, isError: event.data["level"]?.stringValue == "error", id: "notice-\(event.seq)") }
        default:
            // 0.2 的事件词汇是开放的（插件会加类型）：未知类型必须静默。
            break
        }

        appliedCount += 1
        revision &+= 1
        return true
    }

    /// 把流式缓冲 join 一次并物化到 item（渲染 flush 时调用）。
    @discardableResult
    mutating func flushStreaming() -> Bool {
        guard streamDirty else { return false }
        streamDirty = false
        let key = streamKey ?? "a\(streamTurn).\(streamStep)"
        var text = ""
        var reasoning = ""
        if let index = indexByID[key], case .message(_, _, let previousText, let previousReasoning, _, _) = items[index] {
            text = previousText
            reasoning = previousReasoning ?? ""
        }
        lastChangeKind = streamTextBuffer.isEmpty ? .reasoningStream : .textStream
        text += streamTextBuffer.joined()
        reasoning += streamReasoningBuffer.joined()
        streamTextBuffer = []
        streamReasoningBuffer = []
        // 保留 chunk 标记：纯思考更新不驱动自动滚动。
        upsert(.message(
            id: key,
            role: .assistant,
            text: text,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            complete: false,
            at: Date()
        ))
        return true
    }

    /// 事件路径需要顺序时，静默把缓冲落盘。
    private mutating func flushStreamingIfNeeded() {
        guard streamDirty else { return }
        _ = flushStreaming()
    }

    /// DSH 0.2 不再持久化 chunk：模型的输出以 `assistant-stream` 帧到达。
    /// 落盘的只有之后的 `assistant/message`（或失败时的 `assistant/attempt`）。
    @discardableResult
    mutating func applyAssistantStream(_ value: JSONValue) -> Bool {
        guard let frame = value["frame"], let kind = frame["type"]?.stringValue else { return false }
        switch kind {
        case "start":
            streamTurn = frame["turn"]?.intValue ?? 0
            streamStep = frame["step"]?.intValue ?? 0
            streamKey = "a\(streamTurn).\(streamStep)"
            reasoningStartedAt = nil
            firstTextAt = nil
            return true
        case "chunk":
            let incomingTurn = frame["turn"]?.intValue ?? streamTurn
            let incomingStep = frame["step"]?.intValue ?? streamStep
            if incomingTurn != streamTurn || incomingStep != streamStep {
                flushStreamingIfNeeded()
                streamTurn = incomingTurn
                streamStep = incomingStep
                streamKey = "a\(streamTurn).\(streamStep)"
                reasoningStartedAt = nil
                firstTextAt = nil
            }
            let chunk = frame["chunk"]
            let rawText = chunk?["text"]?.stringValue ?? chunk?["delta"]?.stringValue ?? ""
            let isReasoning = chunk?["type"]?.stringValue == "reasoning-delta"
            let delta = isReasoning ? "" : rawText
            let reasoning = chunk?["reasoning"]?.stringValue ?? (isReasoning ? rawText : "")
            guard !delta.isEmpty || !reasoning.isEmpty else { return false }
            let key = "a\(streamTurn).\(streamStep)"
            let chunkTime: Date = {
                if let millis = frame["time"]?.intValue {
                    return Date(timeIntervalSince1970: Double(millis) / 1000)
                }
                return Date()
            }()
            lastChangeKind = delta.isEmpty ? .reasoningStream : .textStream
            if !reasoning.isEmpty, reasoningStartedAt == nil {
                reasoningStartedAt = chunkTime
            }
            if !delta.isEmpty, firstTextAt == nil {
                firstTextAt = chunkTime
            }
            if let reasoningStartedAt, let marker = firstTextAt {
                messageThinkingSeconds[key] = marker.timeIntervalSince(reasoningStartedAt)
            } else if let reasoningStartedAt {
                // 还在思考、正文没开始：实时递增，供顶部「深度求索中 · Xs」显示。
                messageThinkingSeconds[key] = Date().timeIntervalSince(reasoningStartedAt)
            }
            // O(1)：只 append 到独立缓冲，标记 dirty；80ms flush 时才 join + 物化一次。
            if !delta.isEmpty {
                streamTextBuffer.append(delta)
                streamDirty = true
            }
            if !reasoning.isEmpty {
                streamReasoningBuffer.append(reasoning)
                streamDirty = true
            }
            return true
        case "end":
            flushStreamingIfNeeded()
            let key = streamKey ?? "a\(streamTurn).\(streamStep)"
            let outcome = frame["outcome"]?["kind"]?.stringValue ?? ""
            if let reasoningStartedAt {
                let end = firstTextAt ?? Date()
                messageThinkingSeconds[key] = end.timeIntervalSince(reasoningStartedAt)
            }
            streamKey = nil
            reasoningStartedAt = nil
            firstTextAt = nil
            if outcome == "abandoned" {
                removeItem(id: key)
                messageUsage[key] = nil
                messageThinkingSeconds[key] = nil
                return true
            }
            if let index = indexByID[key], case .message(let id, let role, let text, let reasoning, false, let at) = items[index] {
                items[index] = .message(id: id, role: role, text: text, reasoning: reasoning, complete: true, at: at)
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - 逐事件规则

    private mutating func applyUserMessage(_ event: FoldEvent) {
        // DSH 会往日志里写 runtime-context / time-context / tool 结果等注入消息：
        // 它们是真实的模型输入，但不是人说的话，手机端不渲染。
        let sourceKind = event.data["source"]?["kind"]?.stringValue
        guard sourceKind == nil || sourceKind == "user" else { return }

        let serverID = event.data["id"]?.stringValue ?? "u\(event.seq)"
        let text = Self.text(from: event.data["content"]) ?? event.data["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return }

        // 发送时乐观条目 id 是 `pending-<requestId>`，落盘事件的 rpcId 就是同一个 requestId。
        let rpcId = event.data["source"]?["rpcId"]?.stringValue
            ?? event.data["rpcId"]?.stringValue
            ?? event.data["requestId"]?.stringValue

        if let rpcId, let index = indexByID["pending-\(rpcId)"] {
            replaceUserItem(at: index, oldID: "pending-\(rpcId)", serverID: serverID, text: text, at: event.time)
            return
        }

        // 真实落盘的 user/message 没有 requestId，所以主要靠「pending- + 同文本 + 30 秒内」兜底。
        if let index = pendingUserIndex(matching: text, at: event.time) {
            replaceUserItem(at: index, oldID: items[index].id, serverID: serverID, text: text, at: event.time)
            return
        }

        // 再兜一层：连续两条 role=user、文本相同、时间差 < 5 秒 → 只留一条。
        if let index = lastDuplicateUserIndex(matching: text, at: event.time) {
            replaceUserItem(at: index, oldID: items[index].id, serverID: serverID, text: text, at: event.time)
            return
        }

        upsert(.message(id: serverID, role: .user, text: text, reasoning: nil, complete: true, at: event.time))
    }

    /// 同 role + 同文本（trim 后）+ 最近 30 秒内、且仍是 `pending-` 的乐观用户消息。
    private func pendingUserIndex(matching text: String, at time: Date) -> Int? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in items.indices.reversed() {
            guard case .message(let id, let role, let itemText, _, _, let at) = items[index] else { continue }
            guard role == .user, id.hasPrefix("pending-") else { continue }
            guard itemText.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { continue }
            guard abs(at.timeIntervalSince(time)) <= 30 else { continue }
            return index
        }
        return nil
    }

    /// 连续两条用户消息、文本相同、时间差 < 5 秒：只保留一条（防止发送侧重复 append）。
    private func lastDuplicateUserIndex(matching text: String, at time: Date) -> Int? {
        guard case .message(_, .user, let lastText, _, _, let lastAt)? = items.last else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lastText.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { return nil }
        guard abs(lastAt.timeIntervalSince(time)) < 5 else { return nil }
        return items.count - 1
    }

    /// 原地替换乐观条目：保留位置与顺序，只把 id 换成服务端 id（索引表同步）。
    private mutating func replaceUserItem(at index: Int, oldID: String, serverID: String, text: String, at time: Date) {
        items[index] = .message(id: serverID, role: .user, text: text, reasoning: nil, complete: true, at: time)
        indexByID.removeValue(forKey: oldID)
        indexByID[serverID] = index
    }

    private mutating func applyAssistantChunk(_ event: FoldEvent) {
        let turn = event.data["turn"]?.intValue ?? 0
        let step = event.data["step"]?.intValue ?? 0
        let key = "a\(turn).\(step)"
        let delta = Self.text(from: event.data["text"])
            ?? Self.text(from: event.data["chunk"]?["text"])
            ?? event.data["delta"]?.stringValue
            ?? ""
        let reasoningDelta = event.data["reasoning"]?.stringValue ?? ""

        var text = ""
        var reasoning = ""
        if let index = indexByID[key], case .message(_, _, let existingText, let existingReasoning, _, _) = items[index] {
            text = existingText
            reasoning = existingReasoning ?? ""
        }
        text += delta
        reasoning += reasoningDelta
        guard !text.isEmpty || !reasoning.isEmpty else { return }

        upsert(.message(
            id: key,
            role: .assistant,
            text: text,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            complete: false,
            at: event.time
        ))
    }

    private mutating func applyAssistantMessage(_ event: FoldEvent) {
        let turn = event.data["turn"]?.intValue ?? 0
        let step = event.data["step"]?.intValue ?? 0
        let key = "a\(turn).\(step)"
        let message = event.data["message"]
        let content = message?["content"] ?? event.data["content"]
        let text = Self.text(from: content) ?? event.data["text"]?.stringValue ?? ""
        // 持久事件里的 reasoning 是 content 块数组中的 type=reasoning；重开历史必须还能显示思考块。
        let reasoning = Self.reasoning(from: content)
            ?? Self.text(from: message?["reasoning"] ?? event.data["reasoning"])

        if let usage = TokenUsage.decode(event.data["usage"] ?? message?["usage"]) {
            messageUsage[key] = usage
        }

        if text.isEmpty && (reasoning ?? "").isEmpty {
            // 只调工具的一步：不留空气泡。
            removeItem(id: key)
            return
        }
        upsert(.message(id: key, role: .assistant, text: text, reasoning: reasoning, complete: true, at: event.time))
    }

    private mutating func applyAssistantAttempt(_ event: FoldEvent) {
        let turn = event.data["turn"]?["turn"]?.intValue ?? event.data["turn"]?.intValue ?? 0
        let step = event.data["turn"]?["step"]?.intValue ?? event.data["step"]?.intValue ?? 0
        removeItem(id: "a\(turn).\(step)")
    }

    private mutating func applyToolCall(_ event: FoldEvent) {
        guard let callId = event.data["callId"]?.stringValue ?? event.data["call_id"]?.stringValue else { return }
        let name = event.data["name"]?.stringValue ?? "tool"
        let arguments = event.data["arguments"] ?? event.data["args"] ?? .object([:])
        let card = ToolPresentation.makeCard(callId: callId, name: name, arguments: arguments)
        toolIndex[callId] = card.id
        upsert(.tool(card))
    }

    private mutating func applyToolResult(_ event: FoldEvent) {
        let message = event.data["message"]
        guard let callId = message?["source"]?["callId"]?.stringValue
            ?? message?["toolCallId"]?.stringValue
            ?? event.data["callId"]?.stringValue
        else { return }

        // 孤儿结果（调用在更早一页上）丢弃，不造无上下文的卡片。
        guard let itemID = toolIndex[callId], let index = indexByID[itemID], case .tool(var card) = items[index] else {
            return
        }

        let resultText = Self.text(from: message?["content"]) ?? Self.text(from: event.data["result"]) ?? ""
        let failed = event.data["error"]?.stringValue != nil
            || event.data["isError"]?.boolValue == true
            || message?["isError"]?.boolValue == true
        card.output = resultText
        card.isRunning = false
        card.isFailed = failed
        card.exitCode = ToolPresentation.exitCode(in: resultText)
        items[index] = .tool(card)
    }

    private mutating func applyTodos(_ event: FoldEvent) {
        let rawTodos = event.data["todos"]?.arrayValue ?? event.data["items"]?.arrayValue ?? []
        let parsed: [PlanItem] = rawTodos.enumerated().compactMap { offset, value in
            let text = value["content"]?.stringValue ?? value["text"]?.stringValue ?? ""
            guard !text.isEmpty else { return nil }
            let status = PlanItem.Status(rawValue: value["status"]?.stringValue ?? "") ?? .pending
            return PlanItem(id: "todo-\(offset)", text: text, status: status)
        }
        guard !parsed.isEmpty else { return }
        upsert(.plan(PlanCard(id: "plan", title: "计划", items: parsed)))
    }

    private mutating func appendTurnEndNotice(_ event: FoldEvent) {
        let reason = event.data["reason"]
        let kind = reason?["kind"]?.stringValue ?? ""
        guard !kind.isEmpty, kind != "success", kind != "completed" else { return }
        let detail = reason?["error"]?["message"]?.stringValue
            ?? reason?["message"]?.stringValue
            ?? reason?["reason"]?["message"]?.stringValue
        guard let detail, !detail.isEmpty else { return }
        appendNotice(detail, isError: true, id: "notice-\(event.seq)")
    }

    private mutating func finishOpenItems() {
        for (index, item) in items.enumerated() {
            switch item {
            case .message(let id, let role, let text, let reasoning, false, let at):
                items[index] = .message(id: id, role: role, text: text, reasoning: reasoning, complete: true, at: at)
            case .tool(var card) where card.isRunning:
                card.isRunning = false
                items[index] = .tool(card)
            default:
                break
            }
        }
    }

    /// 往前翻页：把更早的事件折进一个临时折叠器，再把新的条目 prepend 到最前面。
    /// 已见过的 seq 丢弃（与快照重叠的部分安全去重），条目按原日志顺序保持。
    @discardableResult
    mutating func prepend(_ events: [FoldEvent]) -> Int {
        let ordered = events.sorted { $0.seq < $1.seq }
        guard !ordered.isEmpty else { return 0 }

        var temporary = SessionFold()
        var applied = 0
        for event in ordered where !seen.contains(event.seq) {
            if temporary.apply(event) { applied += 1 }
        }
        guard applied > 0 else { return 0 }

        let existing = Set(items.map(\.id))
        let newItems = temporary.items.filter { !existing.contains($0.id) }
        if !newItems.isEmpty {
            items.insert(contentsOf: newItems, at: 0)
        }
        seen.formUnion(temporary.seen)
        appliedCount += applied
        for (key, usage) in temporary.messageUsage where messageUsage[key] == nil {
            messageUsage[key] = usage
        }
        for (key, seconds) in temporary.messageThinkingSeconds where messageThinkingSeconds[key] == nil {
            messageThinkingSeconds[key] = seconds
        }
        if let minSeq = ordered.map(\.seq).filter({ seen.contains($0) }).min() {
            oldestSeq = min(oldestSeq ?? minSeq, minSeq)
        }
        rebuildIndex()
        revision &+= 1
        return applied
    }

    // MARK: - 本地改写（乐观发送 / mock 演示）

    mutating func appendUser(_ text: String, id: String = "u-\(UUID().uuidString)", at: Date = Date()) {
        upsert(.message(id: id, role: .user, text: text, reasoning: nil, complete: true, at: at))
        lastChangeKind = .structural
        revision &+= 1
    }

    mutating func appendAssistantDelta(_ delta: String, turn: Int = 9, step: Int = 1, at: Date = Date()) {
        let key = "a\(turn).\(step)"
        var text = ""
        var reasoning = ""
        if let index = indexByID[key], case .message(_, _, let existingText, let existingReasoning, _, _) = items[index] {
            text = existingText
            reasoning = existingReasoning ?? ""
        }
        text += delta
        upsert(.message(id: key, role: .assistant, text: text, reasoning: reasoning.isEmpty ? nil : reasoning, complete: false, at: at))
        revision &+= 1
    }

    mutating func finalizeAssistant(_ text: String, reasoning: String? = nil, turn: Int = 9, step: Int = 1, at: Date = Date()) {
        upsert(.message(id: "a\(turn).\(step)", role: .assistant, text: text, reasoning: reasoning, complete: true, at: at))
        revision &+= 1
    }

    mutating func appendTool(_ card: ToolCard) {
        toolIndex[card.callId] = card.id
        upsert(.tool(card))
        revision &+= 1
    }

    mutating func updateTool(callId: String, output: String?, failed: Bool = false, exitCode: Int? = nil) {
        guard let itemID = toolIndex[callId], let index = indexByID[itemID], case .tool(var card) = items[index] else { return }
        if let output { card.output = output }
        card.isRunning = false
        card.isFailed = failed
        card.exitCode = exitCode
        items[index] = .tool(card)
        revision &+= 1
    }

    mutating func appendNotice(_ text: String, isError: Bool = false, id: String = "notice-\(UUID().uuidString)") {
        upsert(.notice(id: id, text: text, isError: isError))
        revision &+= 1
    }

    mutating func appendImage(_ caption: String, id: String = "img-\(UUID().uuidString)") {
        upsert(.image(id: id, caption: caption))
        revision &+= 1
    }

    mutating func appendSubagent(_ card: SubagentCard) {
        upsert(.subagent(card))
        revision &+= 1
    }

    mutating func upsertPlan(_ plan: PlanCard) {
        upsert(.plan(plan))
        revision &+= 1
    }

    // MARK: - 索引

    private mutating func upsert(_ item: ConversationItem) {
        if let index = indexByID[item.id], index < items.count {
            items[index] = item
        } else {
            items.append(item)
            indexByID[item.id] = items.count - 1
        }
    }

    private mutating func removeItem(id: String) {
        guard let index = indexByID[id], index < items.count else { return }
        items.remove(at: index)
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        indexByID = [:]
        for (index, item) in items.enumerated() {
            indexByID[item.id] = index
        }
        // 工具卡索引跟着重建
        toolIndex = [:]
        for item in items {
            if case .tool(let card) = item { toolIndex[card.callId] = card.id }
        }
    }

    // MARK: - 解析工具函数

    func usage(for itemID: String) -> TokenUsage? { messageUsage[itemID] }

    func thinkingSeconds(for itemID: String) -> Double? { messageThinkingSeconds[itemID] }

    /// 从 `data.message.content` 块数组里取 type == "reasoning" 的文本。
    static func reasoning(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let blocks = value.arrayValue {
            let joined = blocks.compactMap { block -> String? in
                guard block["type"]?.stringValue == "reasoning" else { return nil }
                return block["text"]?.stringValue
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let blocks = value["content"]?.arrayValue {
            return reasoning(from: .array(blocks))
        }
        return nil
    }

    static func text(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            return text.isEmpty ? nil : text
        case .array(let blocks):
            let joined = blocks.compactMap { block -> String? in
                if let text = block.stringValue { return text }
                if block["type"]?.stringValue == "text" { return block["text"]?.stringValue }
                return nil
            }.joined()
            return joined.isEmpty ? nil : joined
        case .object(let object):
            if let text = object["text"]?.stringValue { return text.isEmpty ? nil : text }
            if let text = object["content"]?.stringValue { return text.isEmpty ? nil : text }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - 工具卡呈现规则

enum ToolPresentation {
    static func makeCard(callId: String, name: String, arguments: JSONValue) -> ToolCard {
        let args: JSONValue = {
            if let text = arguments.stringValue, let parsed = JSONValue.parse(text) { return parsed }
            return arguments
        }()
        let raw = arguments.stringValue ?? args.rawText

        switch name {
        case "bash", "shell", "run":
            let command = args["command"]?.stringValue ?? args["cmd"]?.stringValue ?? ""
            let cwd = args["workdir"]?.stringValue ?? args["cwd"]?.stringValue ?? args["directory"]?.stringValue
            return ToolCard(
                id: "tool-\(callId)",
                callId: callId,
                name: name,
                kind: .terminal,
                title: firstLine(command),
                subtitle: cwd,
                command: command,
                rawArguments: raw
            )

        case "edit", "write", "apply_patch":
            let path = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? "未命名文件"
            let oldText = args["old_string"]?.stringValue ?? ""
            let newText = args["new_string"]?.stringValue ?? args["content"]?.stringValue ?? ""
            let diff = ToolFileDiff(path: path, lines: diffLines(old: oldText, new: newText))
            return ToolCard(
                id: "tool-\(callId)",
                callId: callId,
                name: name,
                kind: .diff,
                title: path,
                files: [diff],
                rawArguments: raw
            )

        case "grep", "glob", "search":
            let pattern = args["pattern"]?.stringValue ?? args["query"]?.stringValue ?? ""
            return ToolCard(id: "tool-\(callId)", callId: callId, name: name, kind: .search, title: pattern, rawArguments: raw)

        case "read", "read_image", "view":
            let path = args["file_path"]?.stringValue ?? args["path"]?.stringValue ?? ""
            return ToolCard(id: "tool-\(callId)", callId: callId, name: name, kind: .read, title: path, rawArguments: raw)

        case "web_fetch":
            let url = args["url"]?.stringValue ?? ""
            return ToolCard(id: "tool-\(callId)", callId: callId, name: name, kind: .fetch, title: url, rawArguments: raw)

        case "web_search":
            let queries = args["queries"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return ToolCard(
                id: "tool-\(callId)",
                callId: callId,
                name: name,
                kind: .fetch,
                title: queries.first ?? "搜索",
                subtitle: queries.count > 1 ? queries.dropFirst().joined(separator: " · ") : nil,
                rawArguments: raw
            )

        case "ask_user_question":
            let question = args["questions"]?.arrayValue?.first?["question"]?.stringValue ?? "需要你确认"
            return ToolCard(id: "tool-\(callId)", callId: callId, name: name, kind: .question, title: question, rawArguments: raw)

        default:
            let title = args["description"]?.stringValue
                ?? args["file_path"]?.stringValue
                ?? args["path"]?.stringValue
                ?? args["pattern"]?.stringValue
                ?? args["url"]?.stringValue
                ?? name
            return ToolCard(id: "tool-\(callId)", callId: callId, name: name, kind: .generic, title: title, rawArguments: raw)
        }
    }

    static func exitCode(in text: String) -> Int? {
        let pattern = #"\[exit code:\s*(-?\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    /// M1 简化 diff：整段删除 + 整段新增，每侧最多 24 行。
    static func diffLines(old: String, new: String) -> [ToolFileDiff.Line] {
        var lines: [ToolFileDiff.Line] = []
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        for (index, text) in oldLines.prefix(24).enumerated() {
            lines.append(.init(id: "old-\(index)", kind: .removed, text: text))
        }
        for (index, text) in newLines.prefix(24).enumerated() {
            lines.append(.init(id: "new-\(index)", kind: .added, text: text))
        }
        return lines
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").first ?? text
        return line.isEmpty ? "命令" : line
    }
}
