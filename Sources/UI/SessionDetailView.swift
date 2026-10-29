import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SessionDetailView: View {
    let session: SessionSummary
    @EnvironmentObject private var app: AppModel
    @State private var model: SessionDetailModel?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let model {
                SessionDetailBody(model: model)
            } else {
                ProgressView("加载会话…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            if model == nil { model = app.detail(for: session) }
            model?.start()
        }
        .onChange(of: session) { _, newValue in
            // 列表刷新只同步内容，不改变导航身份（导航由 sessionId 驱动）。
            model?.updateSession(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model?.retry() }
            else if phase == .background { model?.stopStreaming() }
        }
        .onDisappear { model?.stopStreaming() }
    }
}

private struct SessionDetailBody: View {
    @ObservedObject var model: SessionDetailModel
    @EnvironmentObject private var app: AppModel
    @State private var showInfo = false
    @State private var showModelPicker = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showStats = false

    private var pendingItems: [ApprovalItem] {
        app.pendingApprovals.filter { $0.sessionId == model.session.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcript(proxy: proxy)
                    .padding(Theme.pagePadding)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.revision) {
                guard model.hasLoadedSnapshot, !model.isRenderPaused else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                guard model.hasLoadedSnapshot, !model.isRenderPaused else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.hasLoadedSnapshot) { _, loaded in
                if loaded { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // sheet 打开期间冻结 transcript flush，保证 UI 立即可交互。
            .onChange(of: showModelPicker || showInfo || showStats) { _, presented in
                model.setRenderPaused(presented)
            }
            .safeAreaInset(edge: .bottom) { composer }
            .toolbar { detailToolbar }
            .sheet(isPresented: $showInfo) {
                SessionInfoSheet(model: model)
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(session: model.session)
            }
            .sheet(isPresented: $showStats) {
                SessionStatsSheet(stats: model.sessionStats, tokenUsage: model.session.tokenUsage)
            }
        }
    }

    @ViewBuilder
    private func transcript(proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            summaryHeader
            olderHistoryHeader(proxy: proxy)
            if let error = model.errorMessage {
                LoadErrorCard(message: error) { model.retry() }
            }
            if !model.hasLoadedSnapshot, model.fold.items.isEmpty, model.errorMessage == nil {
                loadingHistoryRow
            }
            transcriptItems
            approvalCards
            emptyStateRow
            Color.clear.frame(height: 1).id("bottom")
        }
    }

    @ViewBuilder
    private func olderHistoryHeader(proxy: ScrollViewProxy) -> some View {
        if model.hasOlderHistory || model.isLoadingOlder {
            Button {
                loadOlder(using: proxy)
            } label: {
                HStack(spacing: 6) {
                    if model.isLoadingOlder {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up.circle")
                    }
                    Text(model.isLoadingOlder ? "正在加载更早的消息…" : "加载更早的消息")
                }
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isLoadingOlder)
        }

        if let olderError = model.olderError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(olderError)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("重试") { loadOlder(using: proxy) }
                    .font(.caption.weight(.semibold))
            }
            .padding(10)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var loadingHistoryRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("加载会话历史…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var transcriptItems: some View {
        ForEach(model.fold.items) { item in
            TranscriptRow(
                item: item,
                reasoningExpanded: model.isExpanded("reason-\(item.id)"),
                toolExpanded: model.isExpanded("tool-\(item.id)"),
                usage: model.fold.usage(for: item.id),
                thinkingSeconds: model.fold.thinkingSeconds(for: item.id),
                fullTextExpanded: model.isExpanded("full-\(item.id)"),
                onToggleFullText: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        model.toggleExpanded("full-\(item.id)")
                    }
                },
                onToggleReasoning: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        model.toggleExpanded("reason-\(item.id)")
                    }
                },
                onToggleTool: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        model.toggleExpanded("tool-\(item.id)")
                    }
                }
            )
            .equatable()
        }
    }

    private var approvalCards: some View {
        ForEach(pendingItems) { item in
            ApprovalCardView(
                item: item,
                onApprove: { withAnimation(.snappy) { app.answerApproval(item, decision: .allowedOnce) } },
                onReject: { withAnimation(.snappy) { app.answerApproval(item, decision: .rejected) } },
                onAnswers: { answers in withAnimation(.snappy) { app.answerQuestions(item, answers: answers) } },
                onSkip: { withAnimation(.snappy) { app.skipApproval(item) } }
            )
        }
    }

    @ViewBuilder
    private var emptyStateRow: some View {
        if model.fold.items.isEmpty, pendingItems.isEmpty,
           model.hasLoadedSnapshot, model.errorMessage == nil {
            EmptyStateView(
                symbol: "text.bubble",
                title: "还没有消息",
                message: "发第一条消息，让 agent 开始干活"
            )
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(model.session.title).font(.headline).lineLimit(1)
                Text("\(model.machineName) · \(model.session.workspace)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("模型") {
                    Label(model.currentModel ?? app.catalog(for: model.session.machineId).defaultTitle ?? "默认模型", systemImage: "cpu")
                    Button("切换模型…") { showModelPicker = true }
                }
                Button("会话统计") { showStats = true }
                Button("查看会话信息") { showInfo = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 头部

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusChip(status: model.status)
                if let modelName = model.currentModel {
                    TagChip(text: modelName, symbol: "cpu")
                }
                Spacer(minLength: 4)

            }
            if let tokenLine = model.tokenLine, !tokenLine.isEmpty {
                Label(tokenLine, systemImage: "chart.bar")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                if let cwd = model.session.cwd {
                    Label(cwd, systemImage: "folder")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - 历史翻页

    private func loadOlder(using proxy: ScrollViewProxy) {
        let anchor = model.fold.items.first?.id
        Task {
            await model.loadOlder()
            if let anchor {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }

    // MARK: - 输入区

    private var modelBarTitle: String {
        if app.catalog(for: model.session.machineId).isEmpty { return "模型不可用" }
        return model.currentModel
            ?? app.currentModelTitle(for: model.session)
            ?? "选择模型"
    }

    private var composer: some View {
        VStack(spacing: 8) {
            // 紧凑模型条：点击打开分 provider 的模型选择 sheet。
            HStack(spacing: 8) {
                Button {
                    showModelPicker = true
                } label: {
                    HStack(spacing: 5) {
                        if model.isSwitchingModel {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "cpu")
                        }
                        Text(modelBarTitle)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(app.catalog(for: model.session.machineId).isEmpty || model.isSwitchingModel)
                .accessibilityLabel("切换模型")

                Spacer()

                if let thinking = model.thinkingStartedAt {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        TimelineView(.periodic(from: .now, by: 0.2)) { context in
                            Text("思考中 · \(DurationFormat.compact(context.date.timeIntervalSince(thinking)))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if !model.attachments.isEmpty {
                attachmentChips
            }

            if let error = model.uploadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                    Spacer()
                    Button("知道了") { model.clearUploadError() }
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption2)
                .foregroundStyle(.red)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("从相册选择图片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("选择文件", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 38)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityLabel("添加附件")

                TextField("给 agent 发消息…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textInputAutocapitalization(.sentences)

                if model.canStop {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(Color.red.opacity(0.15), in: Circle())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停止")
                } else {
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 8)
        .background(.bar)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls { model.addFile(from: url) }
            case .failure(let error):
                model.reportError("选择文件失败：\(error.localizedDescription)")
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await loadPhotos(items)
                photoItems = []
            }
        }
    }

    private var canSend: Bool {
        let hasText = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = !model.attachments.isEmpty
        return (hasText || hasAttachment) && !model.hasBlockingAttachments
    }

    @ViewBuilder
    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func attachmentChip(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 7) {
            if attachment.kind == .image, let data = attachment.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName.isEmpty ? "附件" : attachment.fileName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                switch attachment.state {
                case .ready:
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .uploading(let progress):
                    Text("上传中 \(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .uploaded:
                    Text("已上传")
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .failed:
                    Text("失败")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 130, alignment: .leading)

            if case .failed = attachment.state {
                Button {
                    model.retryUpload(id: attachment.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            Button {
                model.removeAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let type = item.supportedContentTypes.first
                    let ext = type?.preferredFilenameExtension ?? "png"
                    let mime = type?.preferredMIMEType
                    model.addImage(data: data, fileName: "photo-\(UUID().uuidString.prefix(8)).\(ext)", mimeType: mime)
                }
            } catch {
                model.reportError("读取图片失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 会话信息

private struct SessionInfoSheet: View {
    let model: SessionDetailModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("机器", value: model.machineName)
                LabeledContent("工作区", value: model.session.workspace)
                LabeledContent("状态", value: model.status.label)
                LabeledContent("模型", value: model.currentModel ?? "默认")
                if let cwd = model.session.cwd {
                    LabeledContent("目录", value: cwd)
                }
                LabeledContent("转录条目", value: "\(model.fold.items.count)")
                LabeledContent("已折叠事件", value: "\(model.fold.appliedCount)")
                LabeledContent("会话 ID", value: model.session.id)
            }
            .navigationTitle("会话信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 模型切换（分 provider + 思考强度）

struct ModelPickerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let session: SessionSummary

    @State private var selectedProvider: String?
    @State private var selectedModel: String?
    @State private var selectedEffort: String?
    @State private var errorText: String?

    private var selectedOption: ModelOption? {
        app.catalog(for: session.machineId).option(provider: selectedProvider, model: selectedModel)
    }

    var body: some View {
        NavigationStack {
            List {
                if app.catalog(for: session.machineId).options.isEmpty {
                    Section {
                        if let error = app.modelCatalogError {
                            Text("模型目录不可用：\(error)")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else {
                            Text("模型不可用：桥没有返回可用模型（测试实例未配置 provider 时正常）。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button("重新加载模型目录") {
                            Task { await app.reloadModelCatalog(for: session.machineId) }
                        }
                    }
                } else {
                    ForEach(app.catalog(for: session.machineId).groups) { group in
                        Section(group.name.isEmpty ? group.id : group.name) {
                            ForEach(group.models) { option in
                                modelRow(option)
                            }
                        }
                    }

                    if let option = selectedOption, !option.efforts.isEmpty {
                        Section("思考强度") {
                            ForEach(option.efforts) { effort in
                                effortRow(effort, option: option)
                            }
                        }
                    }

                    if let message = errorText ?? app.modelSelectionError {
                        Section("切换失败") {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                        .disabled(selectedOption == nil)
                }
            }
            .onAppear(perform: seedSelection)
            .task {
                // 打开立即用缓存渲染；只有缓存为空时才请求一次。
                if app.catalog(for: session.machineId).isEmpty {
                    await app.reloadModelCatalog(for: session.machineId)
                }
            }
        }
    }

    private func modelRow(_ option: ModelOption) -> some View {
        let isSelected = selectedProvider == option.provider && selectedModel == option.model
        return Button {
            selectedProvider = option.provider
            selectedModel = option.model
            if !option.efforts.contains(where: { $0.id == (selectedEffort ?? "") }) {
                selectedEffort = option.defaultEffort ?? option.efforts.first?.id
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName).font(.subheadline)
                    Text(option.model)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func effortRow(_ effort: ModelEffort, option: ModelOption) -> some View {
        let isSelected = (selectedEffort ?? option.defaultEffort) == effort.id
        return Button {
            selectedEffort = effort.id
        } label: {
            HStack {
                Text(effort.name).font(.subheadline)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func seedSelection() {
        if let option = app.catalog(for: session.machineId).option(provider: session.modelProvider, model: session.modelName) {
            selectedProvider = option.provider
            selectedModel = option.model
            selectedEffort = session.modelEffort ?? option.defaultEffort
        } else if let option = app.catalog(for: session.machineId).options.first {
            selectedProvider = option.provider
            selectedModel = option.model
            selectedEffort = option.defaultEffort
        }
    }

    private func apply() {
        guard let option = selectedOption else { return }
        // 乐观更新：立刻改模型条/头部并关 sheet，不等网络；失败由 AppModel 回滚 + 报错。
        app.applyModelSelection(option, effort: selectedEffort ?? option.defaultEffort, for: session)
        dismiss()
    }
}

// MARK: - 会话统计

struct SessionStatsSheet: View {
    let stats: SessionStats?
    let tokenUsage: TokenUsage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let stats {
                    Section("回合") {
                        LabeledContent("turns", value: "\(stats.turns)")
                        LabeledContent("steps", value: "\(stats.steps)")
                    }
                    Section("耗时") {
                        LabeledContent("模型用时", value: seconds(stats.llmMs))
                        LabeledContent("工具用时", value: seconds(stats.toolMs))
                        if let ttft = stats.averageTTFTMs {
                            LabeledContent("平均 TTFT", value: "\(ttft) ms")
                        }
                        if let tps = stats.tokensPerSecond {
                            LabeledContent("TPS", value: String(format: "%.2f tok/s", tps))
                        }
                    }
                }
                if let tokenUsage {
                    Section("Token") {
                        LabeledContent("输入", value: TokenFormat.human(tokenUsage.totalTokens ?? tokenUsage.uncachedInputTokens + tokenUsage.cacheReadTokens))
                        LabeledContent("输出", value: TokenFormat.human(tokenUsage.outputTokens))
                        LabeledContent("缓存读", value: TokenFormat.human(tokenUsage.cacheReadTokens))
                        if let rate = cacheHitRate(tokenUsage) {
                            LabeledContent("缓存命中率", value: String(format: "%.1f%%", rate * 100))
                        }
                    }
                }
                if stats == nil && tokenUsage == nil {
                    Text("暂无会话统计").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("会话统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func seconds(_ millis: Int) -> String {
        String(format: "%.1f s", Double(millis) / 1000)
    }

    private func cacheHitRate(_ usage: TokenUsage) -> Double? {
        let total = usage.uncachedInputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        guard total > 0 else { return nil }
        return Double(usage.cacheReadTokens) / Double(total)
    }
}

// MARK: - 加载失败卡

private struct LoadErrorCard: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("会话加载失败")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: onRetry) {
                Label("重试", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        )
    }
}

// MARK: - 转录行（Equatable：内容没变就不重建）

private nonisolated struct TranscriptRow: View, Equatable {
    let item: ConversationItem
    let reasoningExpanded: Bool
    let toolExpanded: Bool
    let usage: TokenUsage?
    let thinkingSeconds: Double?
    let fullTextExpanded: Bool
    let onToggleFullText: @MainActor () -> Void
    let onToggleReasoning: @MainActor () -> Void
    let onToggleTool: @MainActor () -> Void

    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.item == rhs.item
            && lhs.reasoningExpanded == rhs.reasoningExpanded
            && lhs.toolExpanded == rhs.toolExpanded
            && lhs.usage == rhs.usage
            && lhs.thinkingSeconds == rhs.thinkingSeconds
            && lhs.fullTextExpanded == rhs.fullTextExpanded
    }

    var body: some View {
        switch item {
        case .message(_, let role, let text, let reasoning, let complete, let at):
            if !complete || !text.isEmpty || !(reasoning ?? "").isEmpty {
                MessageBubbleView(
                role: role,
                text: text,
                reasoning: reasoning,
                complete: complete,
                at: at,
                reasoningExpanded: reasoningExpanded,
                onToggleReasoning: onToggleReasoning,
                usage: usage,
                thinkingSeconds: thinkingSeconds,
                fullTextExpanded: fullTextExpanded,
                onToggleFullText: onToggleFullText
            )
            }
        case .tool(let card):
            ToolCardView(card: card, isExpanded: toolExpanded, onToggleExpanded: onToggleTool)
        case .plan(let plan):
            PlanCardView(plan: plan)
        case .image(_, let caption):
            ImagePlaceholderView(caption: caption)
        case .subagent(let card):
            SubagentCardView(card: card)
        case .notice(_, let text, let isError):
            NoticeView(text: text, isError: isError)
        }
    }
}


