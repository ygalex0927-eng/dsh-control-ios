import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var app: AppModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statsRow
                    machinesSection
                    needsYouSection
                    runningSection
                    recentSection
                }
                .padding(Theme.pagePadding)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollIndicators(.hidden)
            .navigationTitle("总控台")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await app.refreshLive() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailHost(sessionId: sessionId) {
                    path.removeAll()
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("三台电脑，一个入口")
                    .font(.title2.bold())
                Text(app.isDemoMode ? "演示模式 · 本地 Mock 数据，无需网络" : "已配对 \(app.machines.count) 台机器 · 通过 Tailscale 直连")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if app.isDemoMode {
                TagChip(text: "DEMO", symbol: "sparkles", tint: .orange)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatCard(value: "\(app.stats.online)", label: "在线", symbol: "wifi", tint: .green)
            StatCard(value: "\(app.stats.busy)", label: "忙碌", symbol: "bolt.fill", tint: .orange)
            StatCard(value: "\(app.stats.pending)", label: "待处理", symbol: "bell.badge.fill", tint: .accentColor)
        }
    }

    // MARK: - 机器

    private var machinesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("机器").font(.headline)
                Spacer()
                Button("全部会话") {
                    app.filterMachineId = nil
                    app.tab = .sessions
                }
                .font(.footnote)
            }

            if app.machines.isEmpty {
                SectionCard {
                    EmptyStateView(symbol: "desktopcomputer", title: "还没有配对机器", message: "去「设置 · 添加机器」扫码或粘贴配对链接")
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(app.machines) { machine in
                            MachineCardView(
                                machine: machine,
                                runtime: app.runtime(for: machine.id),
                                pendingCount: app.sessions(for: machine.id).reduce(0) { $0 + $1.pendingCount }
                            ) {
                                app.filterMachineId = machine.id
                                app.tab = .sessions
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - 待你处理

    private var needsYouSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("待你处理").font(.headline)
                if !app.pendingApprovals.isEmpty {
                    Text("\(app.pendingApprovals.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                if !app.pendingApprovals.isEmpty {
                    Button("查看会话") { app.tab = .sessions }
                        .font(.footnote)
                }
            }

            if app.pendingApprovals.isEmpty {
                SectionCard {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("没有待办").font(.subheadline.weight(.medium))
                            Text("agent 跑完或需要你时会出现在这里").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                ForEach(app.pendingApprovals.prefix(2)) { item in
                    ApprovalCardView(
                        item: item,
                        onApprove: { withAnimation(.snappy) { app.answerApproval(item, decision: .allowedOnce) } },
                        onReject: { withAnimation(.snappy) { app.answerApproval(item, decision: .rejected) } },
                        onAnswers: { answers in withAnimation(.snappy) { app.answerQuestions(item, answers: answers) } },
                        onSkip: { withAnimation(.snappy) { app.skipApproval(item) } }
                    )
                }
            }
        }
    }

    // MARK: - 正在运行

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在运行").font(.headline)
                Spacer()
                Text("\(app.runningSessions.count) 个会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if app.runningSessions.isEmpty {
                SectionCard {
                    Text("现在没有 agent 在跑").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                SectionCard {
                    ForEach(app.runningSessions.prefix(3)) { session in
                        NavigationLink(value: session.id) {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(app.machineName(for: session.machineId)) · \(session.workspace)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 最近会话

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近会话").font(.headline)
                Spacer()
                Button("查看全部") { app.tab = .sessions }
                    .font(.footnote)
            }

            SectionCard {
                ForEach(app.sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(4)) { session in
                    NavigationLink(value: session.id) {
                        SessionRowView(session: session, machineName: app.machineName(for: session.machineId))
                    }
                    .buttonStyle(.plain)
                    if session.id != app.sessions.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(4).last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}
