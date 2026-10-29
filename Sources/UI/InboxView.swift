import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var app: AppModel
    @State private var filter: InboxFilter = .all
    @State private var path: [String] = []

    enum InboxFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case approval = "审批"
        case question = "提问"

        var id: String { rawValue }
    }

    private var items: [ApprovalItem] {
        app.pendingApprovals.filter { item in
            switch filter {
            case .all: return true
            case .approval: return item.kind == .approval
            case .question: return item.kind == .question
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("筛选", selection: $filter) {
                        ForEach(InboxFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    header

                    if items.isEmpty {
                        SectionCard {
                            EmptyStateView(
                                symbol: "checkmark.seal",
                                title: "收件箱是空的",
                                message: "agent 需要审批或提问时会出现在这里；也可以点开任意会话来继续任务"
                            )
                        }
                    } else {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                ApprovalCardView(
                                    item: item,
                                    onApprove: { withAnimation(.snappy) { app.answerApproval(item, decision: .allowedOnce) } },
                                    onReject: { withAnimation(.snappy) { app.answerApproval(item, decision: .rejected) } },
                                    onAnswers: { answers in withAnimation(.snappy) { app.answerQuestions(item, answers: answers) } },
                                    onSkip: { withAnimation(.snappy) { app.skipApproval(item) } }
                                )

                                if let session = app.session(id: item.sessionId) {
                                    NavigationLink(value: session.id) {
                                        Label("打开会话「\(session.title)」", systemImage: "arrow.up.right.square")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.pagePadding)
                .padding(.bottom, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("收件箱")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.tab = .overview
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityLabel("回到总览")
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailHost(sessionId: sessionId) {
                    path.removeAll()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("先答者生效").font(.subheadline.weight(.semibold))
                Text("你在手机上批准后，电脑网页端会自动收起这张卡；反之亦然。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TagChip(text: "\(app.pendingApprovals.count) 件", symbol: "tray.full", tint: .accentColor)
        }
    }
}
