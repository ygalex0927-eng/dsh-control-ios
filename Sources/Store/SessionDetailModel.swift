import Foundation
import UniformTypeIdentifiers

/// 单个会话的详情状态：折叠结果 + 演示用的流式回合。
@MainActor
final class SessionDetailModel: ObservableObject {
    @Published private(set) var session: SessionSummary
    private(set) var fold: SessionFold
    @Published private(set) var status: SessionStatus
    @Published private(set) var currentModel: String?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    /// 首帧 snapshot 是否已到；用于区分「加载中 / 加载失败 / 真的没有消息」。
    @Published private(set) var hasLoadedSnapshot = false
    /// 首帧被截断（还有更早的历史）时显示「加载更早的消息」。
    @Published private(set) var hasOlderHistory = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var olderError: String?
    /// fold 的内容版本号，流式 chunk 让同一 item 变长时也会递增。
    @Published private(set) var revision = 0
    /// 折叠状态放 ViewModel（按条目 id），流式重绘不会把用户展开的思考/输出弹回。
    @Published private(set) var expandedItemIDs: Set<String> = []
    /// 输入框上方的待发送附件（图片内联 / 文件上传 receipt）。
    @Published var attachments: [ChatAttachment] = []
    @Published private(set) var uploadError: String?
    @Published private(set) var isUploading = false
    /// 流式思考开始时间（assistant-stream start），用于「深度求索中 · Xs」。
    @Published private(set) var thinkingStartedAt: Date?
    /// 模型切换中（输入框上方紧凑条显示 spinner）。
    @Published private(set) var isSwitchingModel = false
    /// 最近一次对外发布的更新类型：思考增长不触发自动滚动。
    @Published private(set) var lastRenderKind: FoldChangeKind = .structural
    /// sheet 打开时冻结 transcript 刷新，保证 UI 立刻可交互。
    @Published private(set) var isRenderPaused = false
    private var revisionFlushTask: Task<Void, Never>?
    /// sheet 打开期间到达的帧先按序入队，关闭后一次性补上（不丢不重）。
    private var queuedFrames: [SessionFrame] = []
    private var resumeTask: Task<Void, Never>?
    @Published var draft: String = ""

    private let isDemo: Bool
    private let machine: Machine?
    private var turnTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = UUID()

    var onBusyChanged: (@MainActor (Bool) -> Void)?

    init(session: SessionSummary, isDemo: Bool, machine: Machine?, seedItems: [ConversationItem] = []) {
        self.session = session
        self.isDemo = isDemo
        self.machine = machine
        self.fold = SessionFold(items: seedItems)
        self.status = session.status
        self.currentModel = session.modelName
    }

    /// 刷新列表（改名/改状态）后同步详情页展示，但不改导航身份。
    func updateSession(_ summary: SessionSummary) {
        guard summary != session else { return }
        session = summary
        // 模型显示名由 AppModel 用 catalog 解析后通过 updateModel 设置，避免把 id 当名字。
    }

    var tokenLine: String? { session.tokenUsage?.compactLine }
    var sessionStats: SessionStats? { session.sessionStats }

    /// 有上传中/失败的附件时禁止发送。
    var hasBlockingAttachments: Bool {
        attachments.contains { attachment in
            switch attachment.state {
            case .uploading, .failed: return true
            case .ready, .uploaded: return false
            }
        }
    }

    func isExpanded(_ id: String) -> Bool { expandedItemIDs.contains(id) }

    func toggleExpanded(_ id: String) {
        if expandedItemIDs.contains(id) {
            expandedItemIDs.remove(id)
        } else {
            expandedItemIDs.insert(id)
        }
    }

    private func syncRevision() {
        revisionFlushTask?.cancel()
        revisionFlushTask = nil
        _ = fold.flushStreaming()
        revision = fold.revision
        lastRenderKind = fold.lastChangeKind
    }

    /// 合帧：流式期间最多 ~12Hz 对外发布一次；chunk 路径只 append 缓冲，
    /// 这里才 join 一次并物化 item，避免 O(n²) 与整页刷新。
    private func scheduleRevisionFlush() {
        guard !isRenderPaused else { return }
        guard revisionFlushTask == nil else { return }
        revisionFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.revisionFlushTask = nil
            self.publishRenderSnapshot()
        }
    }

    private func publishRenderSnapshot() {
        guard !isRenderPaused else { return }
        let started = Date()
        _ = fold.flushStreaming()
        Diagnostics.shared.recordFlushDuration(ms: Date().timeIntervalSince(started) * 1000)
        revision = fold.revision
        lastRenderKind = fold.lastChangeKind
    }

    /// 打开/关闭模型、统计、附件等 sheet 时冻结/恢复后台刷新。
    /// 冻结期间帧只入队，关闭后按序一次性应用，主线程在 sheet 期间不做会话工作。
    func setRenderPaused(_ paused: Bool) {
        guard paused != isRenderPaused else { return }
        isRenderPaused = paused
        if paused {
            revisionFlushTask?.cancel()
            revisionFlushTask = nil
            resumeTask?.cancel()
            resumeTask = nil
        } else {
            // 每批让出主线程，避免关闭 sheet 时一次补算整段输出。
            resumeTask = Task { [weak self] in
                guard let self else { return }
                while !self.queuedFrames.isEmpty, !self.isRenderPaused, !Task.isCancelled {
                    let batch = Array(self.queuedFrames.prefix(8))
                    self.queuedFrames.removeFirst(batch.count)
                    for frame in batch { self.applyNow(frame) }
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                self.resumeTask = nil
                self.publishRenderSnapshot()
            }
        }
    }

    /// 电脑端 `api-session/status` 变化时更新顶部状态。
    func applyStatus(_ newStatus: SessionStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }

    func updateModel(_ name: String) {
        guard currentModel != name else { return }
        currentModel = name
    }

    var canStop: Bool { status == .running || isBusy }

    var machineName: String { machine?.name ?? "未连接机器" }

    // MARK: - 生命周期

    func start() {
        guard !isDemo else { return }
        guard streamTask == nil, let machine, let url = machine.url else { return }
        errorMessage = nil
        if fold.items.isEmpty { hasLoadedSnapshot = false }
        let key = BridgeKeyStore.shared.key(for: machine.id)
        let sessionId = session.id
        let generation = UUID()
        streamGeneration = generation
        streamTask = Task { [weak self] in
            defer {
                if self?.streamGeneration == generation { self?.streamTask = nil }
            }
            let stream = await BridgeClient.shared.sessionStream(host: url, key: key, sessionId: sessionId)
            do {
                for try await frame in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.apply(frame)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stopStreaming() {
        streamGeneration = UUID()
        streamTask?.cancel()
        streamTask = nil
        revisionFlushTask?.cancel()
        revisionFlushTask = nil
    }

    /// 加载失败后重试：重新打开 `session/follow`。
    func retry() {
        stopStreaming()
        errorMessage = nil
        hasLoadedSnapshot = false
        start()
    }

    /// 加载更早的消息（`session/page`），失败时给出提示而不是静默。
    func loadOlder() async {
        guard !isLoadingOlder else { return }
        guard let machine, let url = machine.url, let throughSeq = fold.oldestSeq else {
            hasOlderHistory = false
            return
        }
        isLoadingOlder = true
        olderError = nil
        do {
            let page = try await BridgeClient.shared.sessionPage(
                host: url,
                key: BridgeKeyStore.shared.key(for: machine.id),
                sessionId: session.id,
                throughSeq: throughSeq
            )
            _ = fold.prepend(page.events)
            syncRevision()
            hasOlderHistory = page.hasMore || (fold.oldestSeq ?? 0) > 0
        } catch {
            olderError = "加载更早的消息失败：\(error.localizedDescription)"
        }
        isLoadingOlder = false
    }

    // MARK: - 发送

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy else { return }
        guard !hasBlockingAttachments else {
            uploadError = "附件还在上传或上传失败，请稍候或重试"
            return
        }
        let content = PromptContentBuilder.build(text: text, attachments: attachments)
        guard !content.isEmpty else { return }

        draft = ""
        let requestId = UUID().uuidString
        let displayText = text.isEmpty
            ? "已附加 \(attachments.count) 个文件"
            : text
        // 乐观气泡用 requestId 作 id，和 session/prompt 的 requestId 一一对应。
        fold.appendUser(displayText, id: "pending-\(requestId)")
        for attachment in attachments where attachment.kind == .image {
            fold.appendImage(attachment.fileName.isEmpty ? "图片附件" : attachment.fileName)
        }
        syncRevision()
        status = .running
        isBusy = true
        onBusyChanged?(true)

        if isDemo {
            attachments.removeAll()
            turnTask?.cancel()
            turnTask = Task { [weak self] in
                await self?.runDemoTurn(topic: text.isEmpty ? "附件" : text)
            }
        } else {
            sendLive(content: content, requestId: requestId)
        }
    }

    func stop() {
        turnTask?.cancel()
        turnTask = nil
        isBusy = false
        status = .idle
        syncRevision()
        onBusyChanged?(false)

        guard let machine, let url = machine.url else {
            fold.appendNotice("已请求停止（本地无连接）")
            syncRevision()
            return
        }
        if isDemo {
            fold.appendNotice("已请求停止（演示模式）")
            syncRevision()
            return
        }
        fold.appendNotice("已请求停止当前回合…")
        syncRevision()
        let key = BridgeKeyStore.shared.key(for: machine.id)
        let sessionId = session.id
        Task { [weak self] in
            do {
                _ = try await BridgeClient.shared.rpc(
                    host: url,
                    key: key,
                    endpoint: "session/cancel",
                    args: ["request": ["sessionId": .string(sessionId)]]
                )
            } catch {
                self?.errorMessage = "停止失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 附件

    static func imageMediaType(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "image/png": return "image/png"
        case "image/jpeg", "image/jpg": return "image/jpeg"
        case "image/webp": return "image/webp"
        case "image/gif": return "image/gif"
        default: return "image/png"
        }
    }

    func addImage(data: Data, fileName: String, mimeType: String?) {
        guard data.count <= AttachmentLimits.maxImageBytes else {
            uploadError = "图片超过 20MB 限制：\(fileName)"
            return
        }
        let imageCount = attachments.filter { $0.kind == .image }.count
        guard imageCount < AttachmentLimits.maxImagesPerMessage else {
            uploadError = "单条消息最多 \(AttachmentLimits.maxImagesPerMessage) 张图片"
            return
        }
        attachments.append(ChatAttachment(
            id: UUID().uuidString,
            kind: .image,
            fileName: fileName,
            mediaType: Self.imageMediaType(for: mimeType),
            imageData: data,
            fileData: nil,
            byteCount: data.count,
            state: .ready
        ))
        uploadError = nil
    }

    /// 从文件选择器拿到的 URL：读成 Data，图片走内联，其余走 /v1/upload。
    func addFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            uploadError = "读取文件失败：\(url.lastPathComponent)"
            return
        }
        let name = url.lastPathComponent
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            addImage(data: data, fileName: name, mimeType: type.preferredMIMEType)
            return
        }
        let attachment = ChatAttachment(
            id: UUID().uuidString,
            kind: .file,
            fileName: name,
            mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
            imageData: nil,
            fileData: data,
            byteCount: data.count,
            state: .uploading(0)
        )
        attachments.append(attachment)
        startUpload(for: attachment.id)
    }

    func reportError(_ text: String) {
        uploadError = text
    }

    func setSwitchingModel(_ value: Bool) {
        isSwitchingModel = value
    }

    func clearUploadError() {
        uploadError = nil
    }

    func removeAttachment(id: String) {
        attachments.removeAll { $0.id == id }
    }

    func retryUpload(id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = .uploading(0)
        startUpload(for: id)
    }

    private func updateAttachment(id: String, state: AttachmentState) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
        isUploading = attachments.contains { attachment in
            if case .uploading = attachment.state { return true }
            return false
        }
    }

    private func startUpload(for id: String) {
        guard let attachment = attachments.first(where: { $0.id == id }),
              let data = attachment.fileData else { return }
        isUploading = true
        uploadError = nil

        if isDemo {
            Task { [weak self] in
                for step in 1...4 {
                    try? await Task.sleep(for: .milliseconds(120))
                    self?.updateAttachment(id: id, state: .uploading(Double(step) / 4))
                }
                self?.updateAttachment(id: id, state: .uploaded(receiptId: "demo-receipt-\(id.prefix(6))"))
            }
            return
        }

        guard let machine, let url = machine.url else {
            updateAttachment(id: id, state: .failed("未连接机器"))
            uploadError = "未连接机器，无法上传附件"
            return
        }
        let key = BridgeKeyStore.shared.key(for: machine.id)
        let sessionId = session.id
        let fileName = attachment.fileName
        Task {
            do {
                let receipt = try await BridgeClient.shared.upload(
                    host: url,
                    key: key,
                    sessionId: sessionId,
                    fileName: fileName,
                    data: data,
                    progress: { value in
                        Task { @MainActor in
                            self.updateAttachment(id: id, state: .uploading(value))
                        }
                    }
                )
                self.updateAttachment(id: id, state: .uploaded(receiptId: receipt.receiptId))
            } catch {
                self.updateAttachment(id: id, state: .failed(error.localizedDescription))
                self.uploadError = "上传失败：\(error.localizedDescription)"
            }
        }
    }

    func appendNotice(_ text: String, isError: Bool = false) {
        fold.appendNotice(text, isError: isError)
        syncRevision()
    }

    // MARK: - Mock 回合

    private func runDemoTurn(topic: String) async {
        let chunks = MockData.replyChunks(topic: topic, session: session)
        for chunk in chunks {
            if Task.isCancelled { finishTurn(); return }
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { finishTurn(); return }
            fold.appendAssistantDelta(chunk)
            scheduleRevisionFlush()
        }

        var plan = PlanCard(
            id: "plan",
            title: "本轮计划",
            items: [
                PlanItem(id: "todo-0", text: "确认当前工程状态", status: .inProgress),
                PlanItem(id: "todo-1", text: "修改并跑构建", status: .pending),
                PlanItem(id: "todo-2", text: "汇报结果与下一步", status: .pending),
            ]
        )
        fold.upsertPlan(plan)
        syncRevision()

        try? await Task.sleep(for: .milliseconds(220))
        let card = MockData.replyToolCard()
        fold.appendTool(card)
        syncRevision()

        try? await Task.sleep(for: .milliseconds(1100))
        fold.updateTool(callId: card.callId, output: "Compiling DSHControl…\n** BUILD SUCCEEDED **", exitCode: 0)
        syncRevision()

        plan.items[0].status = .completed
        plan.items[1].status = .completed
        plan.items[2].status = .inProgress
        fold.upsertPlan(plan)
        syncRevision()

        try? await Task.sleep(for: .milliseconds(260))
        fold.finalizeAssistant(MockData.replyFinalText(topic: topic, session: session))
        syncRevision()
        finishTurn()
    }

    private func finishTurn() {
        isBusy = false
        status = .idle
        thinkingStartedAt = nil
        onBusyChanged?(false)
    }

    // MARK: - 真机

    private func sendLive(content: [JSONValue], requestId: String) {
        guard let machine, let url = machine.url else {
            errorMessage = "未连接机器，无法发送"
            return
        }
        let key = BridgeKeyStore.shared.key(for: machine.id)
        Task { [weak self] in
            do {
                _ = try await BridgeClient.shared.rpc(
                    host: url,
                    key: key,
                    endpoint: "session/prompt",
                    args: [
                        "request": [
                            "requestId": .string(requestId),
                            "sessionId": .string(self?.session.id ?? ""),
                            "mode": "queue",
                            "content": .array(content),
                        ],
                    ]
                )
                self?.errorMessage = nil
                self?.attachments.removeAll()
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.finishTurn()
            }
            // accepted 仅代表入队；真实 turn/end 才恢复发送按钮。
        }
    }

    private func apply(_ frame: SessionFrame) {
        if isRenderPaused || resumeTask != nil {
            enqueueWhilePaused(frame)
            return
        }
        applyNow(frame)
    }

    private func enqueueWhilePaused(_ frame: SessionFrame) {
        queuedFrames.append(frame)

    }

    private func applyNow(_ frame: SessionFrame) {
        Diagnostics.shared.recordApplied()
        switch frame {
        case .snapshot(let events, _, let hasMore):
            fold.replace(with: events)
            thinkingStartedAt = nil
            syncRevision()
            hasLoadedSnapshot = true
            errorMessage = nil
            olderError = nil
            hasOlderHistory = hasMore || (fold.oldestSeq ?? 0) > 0
            status = fold.isRunning ? .running : .idle
        case .event(let event):
            guard fold.apply(event) else { return }
            if event.type == "assistant/message" || event.type == "turn/end" {
                thinkingStartedAt = nil
            }
            if event.type == "turn/end" { finishTurn() }
            if event.type.contains("chunk") || event.type == "assistant/delta" {
                scheduleRevisionFlush()
            } else {
                syncRevision()
            }
            status = fold.isRunning ? .running : .idle
        case .stream(let value):
            let phase = value["frame"]?["type"]?.stringValue ?? ""
            if phase == "start" {
                thinkingStartedAt = Date()
            } else if phase == "end" {
                thinkingStartedAt = nil
            }
            guard fold.applyAssistantStream(value) else { return }
            scheduleRevisionFlush()
            status = .running
        }
    }
}
