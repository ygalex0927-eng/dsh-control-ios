import SwiftUI

// MARK: - 主题

enum Theme {
    static let cardCorner: CGFloat = 16
    static let pagePadding: CGFloat = 16
}

extension MachineState {
    var tint: Color {
        switch self {
        case .online: return .green
        case .busy: return .orange
        case .offline: return .gray
        case .unknown: return .gray
        }
    }
}

extension SessionStatus {
    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .orange
        case .waiting: return .accentColor
        case .failed: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "pause.circle"
        case .running: return "play.circle.fill"
        case .waiting: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

enum RelativeTime {
    static func text(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 基础组件

struct StatusDot: View {
    let state: MachineState
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: size, height: size)
            .shadow(color: state.tint.opacity(0.5), radius: 3)
            .accessibilityLabel(state.label)
    }
}

struct StatusChip: View {
    let status: SessionStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14), in: Capsule())
    }
}

struct TagChip: View {
    var text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct SectionCard<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    Text(title).font(.subheadline.weight(.semibold))
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

struct StatCard: View {
    var value: String
    var label: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption).foregroundStyle(tint)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        Label(toast.text, systemImage: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.footnote.weight(.medium))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder((toast.isError ? Color.red : Color.green).opacity(0.35)))
            .padding(.horizontal, 24)
            .shadow(radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 机器卡

struct MachineCardView: View {
    let machine: Machine
    let runtime: MachineRuntime
    var pendingCount: Int
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: machine.kind.symbolName)
                        .font(.title3)
                        .foregroundStyle(runtime.reachable ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(machine.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(machine.shortHost).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    StatusDot(state: runtime.state)
                }

                HStack(spacing: 6) {
                    TagChip(text: runtime.state.label, symbol: "dot.radiowaves.left.and.right", tint: runtime.state.tint)
                    TagChip(text: "\(runtime.sessionCount) 会话", symbol: "bubble.left.and.bubble.right")
                    if pendingCount > 0 {
                        TagChip(text: "\(pendingCount) 待办", symbol: "bell.badge", tint: .accentColor)
                    }
                }

                HStack(spacing: 4) {
                    Text(runtime.updatedAt == .distantPast ? "尚未连接" : "更新于 \(RelativeTime.text(runtime.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(13)
            .frame(width: 246, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(runtime.reachable ? Color.clear : Color.secondary.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 会话行

struct SessionRowView: View {
    let session: SessionSummary
    let machineName: String
    var isPinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if session.pendingCount > 0 {
                    Text("\(session.pendingCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            if let snippet = session.lastSnippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                StatusChip(status: session.status)
                if let model = session.modelName {
                    TagChip(text: model, symbol: "cpu")
                }
                Spacer()
                Text(machineName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(RelativeTime.text(session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 消息气泡

struct MessageBubbleView: View {
    let role: MessageRole
    let text: String
    let reasoning: String?
    let complete: Bool
    let at: Date
    /// 折叠状态由 ViewModel 持有（按消息 id），流式重绘不会重置。
    var reasoningExpanded: Bool = false
    var onToggleReasoning: @MainActor () -> Void = {}
    /// 单条消息的 token 用量与思考时长（拿不到就不显示）。
    var usage: TokenUsage? = nil
    var thinkingSeconds: Double? = nil
    /// 超长消息（>2 万字）默认折叠，状态在 ViewModel（key: full-<id>）。
    var fullTextExpanded: Bool = false
    var onToggleFullText: @MainActor () -> Void = {}

    private static let streamingTailLimit = 3000
    private static let longTextLimit = 20_000
    private static let collapsedPreviewLimit = 1200

    private var isLongText: Bool { text.count > Self.longTextLimit }

    /// 流式中只渲染尾部 3000 字（能看到最新字节）；完成后长消息默认折叠。
    private var displayText: String {
        if !complete {
            guard text.count > Self.streamingTailLimit else { return text }
            return "…" + String(text.suffix(Self.streamingTailLimit))
        }
        if isLongText && !fullTextExpanded {
            return String(text.prefix(Self.collapsedPreviewLimit)) + "…"
        }
        return text
    }

    private var showLongTextToggle: Bool { complete && isLongText }

    private var isUser: Bool { role == .user }

    private var reasoningTitleText: String {
        if !complete { return "正在思考" }
        if let seconds = thinkingSeconds { return "已思考 \(DurationFormat.compact(seconds))" }
        return "思考过程"
    }

    private var visibleReasoning: String {
        guard let reasoning else { return "" }
        return complete ? reasoning : String(reasoning.suffix(1800))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reasoning, !reasoning.isEmpty, !isUser {
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: onToggleReasoning) {
                        HStack(spacing: 7) {
                            if !complete { ProgressView().controlSize(.mini) }
                            Text(reasoningTitleText)
                            Image(systemName: reasoningExpanded || !complete ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if reasoningExpanded || !complete {
                        Text(visibleReasoning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.leading, 14)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 1)
                            }
                    }
                }
            }

            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(displayText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showLongTextToggle {
                        Button(fullTextExpanded ? "收起全文" : "展开全文（\(text.count) 字）") {
                            onToggleFullText()
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, isUser ? 14 : 0)
                .padding(.vertical, isUser ? 11 : 2)
                .background {
                    if isUser {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                }
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }

            if !complete, reasoning?.isEmpty != false, text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在处理…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if complete {
                HStack(spacing: 4) {
                    Text(RelativeTime.text(at))
                    if !isUser, let usage, !usage.compactLine.isEmpty {
                        Text("·")
                        Text(usage.compactLine)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isUser ? 40 : 0)
        .padding(.vertical, 4)
    }
}

// MARK: - 计划卡

struct PlanCardView: View {
    let plan: PlanCard

    var body: some View {
        SectionCard(title: plan.title, symbol: "checklist") {
            ProgressView(value: plan.progress)
                .tint(.accentColor)
            ForEach(plan.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: item.status))
                        .foregroundStyle(item.status == .completed ? .green : (item.status == .inProgress ? .accentColor : .secondary))
                        .font(.footnote)
                    Text(item.text)
                        .font(.footnote)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func icon(for status: PlanItem.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.dotted"
        case .pending: return "circle"
        }
    }
}

// MARK: - 工具卡

struct ToolCardView: View {
    let card: ToolCard
    /// 折叠状态由 ViewModel 持有（按工具卡 id），流式重绘不会重置。
    var isExpanded: Bool = false
    var onToggleExpanded: @MainActor () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: card.kind.symbolName)
                    .font(.caption)
                    .foregroundStyle(card.isFailed ? .red : .accentColor)
                Text(card.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(card.title)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer(minLength: 4)
                if card.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let exitCode = card.exitCode {
                    TagChip(text: "exit \(exitCode)", tint: exitCode == 0 ? .green : .red)
                } else if card.isFailed {
                    TagChip(text: "失败", tint: .red)
                }
            }

            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if card.kind == .diff, !card.files.isEmpty {
                diffContent
            } else if let output = card.output, !output.isEmpty {
                outputContent(output)
            } else if card.isRunning {
                Text("等待结果…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let raw = card.rawArguments {
                Text(raw)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(card.isFailed ? Color.red.opacity(0.35) : Color.secondary.opacity(0.12))
        )
    }

    private var diffContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.files) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(file.lines.prefix(isExpanded ? file.lines.count : 8))) { line in
                        HStack(spacing: 6) {
                            Text(line.kind == .added ? "+" : "-")
                                .foregroundStyle(line.kind == .added ? .green : .red)
                                .frame(width: 8, alignment: .leading)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            (line.kind == .added ? Color.green : Color.red).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                    }
                    if file.lines.count > 8 {
                        Button(isExpanded ? "收起" : "展开全部 \(file.lines.count) 行") {
                            onToggleExpanded()
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func outputContent(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(output)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
            if output.count > 80 {
                Button(isExpanded ? "收起输出" : "展开输出") {
                    onToggleExpanded()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - 图片 / 子代理 / 提示

struct ImagePlaceholderView: View {
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 150)
            Text("\(caption) · 附件字节走 `/v1/file`（M2）")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct SubagentCardView: View {
    let card: SubagentCard

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.title3)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("子代理").font(.caption.weight(.semibold))
                    Text(card.name).font(.caption).foregroundStyle(.secondary)
                    TagChip(text: card.status, tint: .purple)
                }
                if let detail = card.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct NoticeView: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background((isError ? Color.red : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 审批卡（真实 approval/request + user-questions/request）

struct ApprovalCardView: View {
    let item: ApprovalItem
    var onApprove: () -> Void
    var onReject: () -> Void
    var onAnswers: ([JSONValue]) -> Void
    var onSkip: () -> Void

    @State private var selections: [String: Set<String>] = [:]
    @State private var customTexts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: item.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .foregroundStyle(item.kind == .approval ? Color.orange : Color.accentColor)
                Text(item.kind == .approval ? "需要审批" : "需要你回答")
                    .font(.subheadline.weight(.semibold))
                if item.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Spacer()
                Text(item.sessionTitle.isEmpty ? item.sessionId : item.sessionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if item.kind == .approval {
                approvalBody
            } else {
                questionBody
            }

            Text("\(item.kind == .approval ? "审批" : "提问") · \(RelativeTime.text(item.createdAt)) · 先答者生效")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25))
        )
    }

    // MARK: 审批

    private var approvalBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(item.toolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let callId = item.callId {
                    Text(callId.prefix(12))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            Text(item.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let command = item.commandPreview, !command.isEmpty {
                Text(command)
                    .font(.caption2.monospaced())
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }

            if let raw = item.raw, item.commandPreview == nil {
                DisclosureGroup("原始请求") {
                    Text(raw.rawText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .font(.caption2)
                .tint(.secondary)
            }

            HStack(spacing: 8) {
                Button(action: onReject) {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: onApprove) {
                    Text("允许一次").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .font(.footnote.weight(.semibold))
        }
    }

    // MARK: 提问

    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.questions.isEmpty {
                Text(item.reason).font(.footnote)
                if let raw = item.raw {
                    Text(raw.rawText)
                        .font(.caption2.monospaced())
                        .lineLimit(8)
                        .foregroundStyle(.secondary)
                }
                Button(action: onSkip) {
                    Text("跳过（交给电脑处理）").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                ForEach(item.questions) { question in
                    questionView(question)
                }

                HStack(spacing: 8) {
                    Button(action: onSkip) {
                        Text("跳过").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onAnswers(buildAnswers())
                    } label: {
                        Text("提交回答").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allQuestionsAnswered)
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    private func questionView(_ question: ApprovalQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(question.prompt).font(.callout)
            if !question.options.isEmpty {
                ForEach(question.options) { option in
                    Button {
                        toggle(option: option.label, for: question)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: isSelected(option.label, for: question) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected(option.label, for: question) ? Color.accentColor : Color.secondary)
                            Text(option.label).font(.footnote)
                            Spacer()
                            if question.multi {
                                Text("多选")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            isSelected(option.label, for: question)
                                ? Color.accentColor.opacity(0.14)
                                : Color(uiColor: .tertiarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if question.allowCustom || question.options.isEmpty {
                TextField("补充说明（可选）", text: customBinding(question))
                    .font(.footnote)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: 交互

    private func isSelected(_ label: String, for question: ApprovalQuestion) -> Bool {
        selections[question.id]?.contains(label) == true
    }

    private func toggle(option label: String, for question: ApprovalQuestion) {
        var current = selections[question.id] ?? []
        if question.multi {
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
        } else {
            current = current.contains(label) ? [] : [label]
        }
        selections[question.id] = current
    }

    private var allQuestionsAnswered: Bool {
        item.questions.contains { question in
            let selected = selections[question.id] ?? []
            let custom = customTexts[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !selected.isEmpty || !custom.isEmpty
        }
    }

    private func buildAnswers() -> [JSONValue] {
        item.questions.map { question in
            let selected = Array(selections[question.id] ?? []).sorted()
            var answer: [String: JSONValue] = [
                "id": .string(question.id),
                "selected": .array(selected.map { .string($0) }),
            ]
            if let custom = customTexts[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                answer["custom"] = .string(custom)
            }
            return .object(answer)
        }
    }

    private func customBinding(_ question: ApprovalQuestion) -> Binding<String> {
        Binding(
            get: { customTexts[question.id] ?? "" },
            set: { customTexts[question.id] = $0 }
        )
    }
}
