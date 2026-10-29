import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showNewSession = false
    /// 导航身份 = sessionId（稳定），列表刷新不会改变它。
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                machineFilterBar
                Divider()
                listOrEmpty
            }
            .refreshable { await app.refreshLive() }
            .navigationTitle("会话")
            .searchable(text: $app.searchText, prompt: "搜索会话或工作区")
            .toolbar { toolbarContent }
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailHost(sessionId: sessionId) {
                    path.removeAll()
                }
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionSheet()
            }
            .onChange(of: app.pendingOpenSessionID) { _, sessionId in
                guard let sessionId else { return }
                path = [sessionId]
                app.pendingOpenSessionID = nil
            }
            .onAppear {
                if let sessionId = app.pendingOpenSessionID {
                    path = [sessionId]
                    app.pendingOpenSessionID = nil
                }
            }
        }
    }

    @ViewBuilder
    private var listOrEmpty: some View {
        if app.filteredSessions.isEmpty {
            ScrollView {
                EmptyStateView(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "没有匹配的会话",
                    message: app.searchText.isEmpty ? "换一台机器，或去「设置」添加新的电脑" : "换个关键词试试"
                )
                .padding(.top, 40)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        } else {
            List {
                ForEach(app.sidebarGroups) { group in
                    Section {
                        sectionRows(group)
                    } header: {
                        sectionHeader(group)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func sectionRows(_ group: SidebarGroup) -> some View {
        if group.sessions.isEmpty {
            Text(group.kind == .workspace ? "还没有会话" : "没有会话")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(group.sessions) { session in
                NavigationLink(value: session.id) {
                    SessionRowView(
                        session: session,
                        machineName: app.machineName(for: session.machineId),
                        isPinned: app.pinnedSessionIds.contains(session.id)
                    )
                    .opacity(group.kind == .archived ? 0.55 : 1)
                }
            }
        }
    }

    private func sectionHeader(_ group: SidebarGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.kind.symbolName)
                .font(.caption2)
            Text(group.title)
            Spacer()
            Text("\(group.sessions.count)")
                .foregroundStyle(.tertiary)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle("显示已归档会话", isOn: $app.showArchived)
                if let activeId = app.activeMachineId, let machine = app.machine(id: activeId) {
                    Text("实时连接：\(machine.name)")
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("筛选")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showNewSession = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("新建会话")
        }
    }

    private var machineFilterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filterChip(title: "全部机器", symbol: "square.grid.2x2", machineId: nil)
                ForEach(app.machines) { machine in
                    filterChip(title: machine.name, symbol: machine.kind.symbolName, machineId: machine.id)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func filterChip(title: String, symbol: String, machineId: String?) -> some View {
        let isSelected = app.filterMachineId == machineId
        return Button {
            withAnimation(.snappy) { app.filterMachineId = machineId }
        } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 新建会话

struct NewSessionSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var workspace = "dsh-control"
    @State private var machineId: String = ""

    private var workspaces: [String] {
        Array(Set(app.sessions.map(\.workspace))).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("会话标题") {
                    TextField("例如：修一下登录页", text: $title)
                }

                Section("机器") {
                    Picker("运行在哪台机器", selection: $machineId) {
                        ForEach(app.machines) { machine in
                            Text(machine.name).tag(machine.id)
                        }
                    }
                }

                Section("工作区") {
                    TextField("工作区名", text: $workspace)
                    if !workspaces.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(workspaces, id: \.self) { name in
                                    Button(name) { workspace = name }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                Section {
                    Text("M1 演示：新会话只写本地列表；真机走 `session/create` + `workspace/create`。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        app.createSession(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            workspace: workspace,
                            machineId: machineId.isEmpty ? (app.machines.first?.id ?? "") : machineId
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.machines.isEmpty)
                }
            }
            .onAppear {
                if machineId.isEmpty { machineId = app.machines.first?.id ?? "" }
            }
        }
    }
}

extension SidebarGroup.Kind {
    var symbolName: String {
        switch self {
        case .pinned: return "pin.fill"
        case .workspace: return "folder"
        case .unassigned: return "tray"
        case .archived: return "archivebox"
        }
    }
}
