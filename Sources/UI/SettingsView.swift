import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var push: PushManager

    @State private var showAddMachine = false
    @State private var removeTarget: Machine?

    var body: some View {
        NavigationStack {
            Form {
                machinesSection
                addMachineSection
                notificationSection
                demoSection
                aboutSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showAddMachine) { AddMachineSheet() }
            .confirmationDialog(
                "移除「\(removeTarget?.name ?? "")」？",
                isPresented: Binding(
                    get: { removeTarget != nil },
                    set: { if !$0 { removeTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("移除这台机器", role: .destructive) {
                    if let machine = removeTarget {
                        withAnimation { app.removeMachine(machine) }
                    }
                    removeTarget = nil
                }
                Button("取消", role: .cancel) { removeTarget = nil }
            } message: {
                Text("只删除手机本地的地址与密钥记录，不影响电脑上的 DSH。需要时重新粘贴地址即可。")
            }
        }
    }

    // MARK: - 已添加机器

    private var machinesSection: some View {
        Section {
            if app.machines.isEmpty {
                Text("还没有添加机器").foregroundStyle(.secondary)
            } else {
                ForEach(app.machines) { machine in
                    HStack(spacing: 10) {
                        Image(systemName: machine.kind.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(machine.name).font(.subheadline.weight(.medium))
                                if machine.isDemo {
                                    TagChip(text: "演示", tint: .orange)
                                }
                                if BridgeKeyStore.shared.key(for: machine.id) != nil {
                                    TagChip(text: "访问密钥", symbol: "key.fill", tint: .accentColor)
                                }
                            }
                            Text(machine.host)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        MachineStateBadge(runtime: app.runtime(for: machine.id))
                        Button(role: .destructive) {
                            removeTarget = machine
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除")
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("已添加机器")
        } footer: {
            Text("没有任何设备授权/配对流程：地址可达、能连上桥即可用。手机上可以发消息、审批、跑命令。")
        }
    }

    // MARK: - 添加机器

    private var addMachineSection: some View {
        Section {
            Button {
                showAddMachine = true
            } label: {
                Label("添加机器（粘贴地址）", systemImage: "plus.circle")
            }
            Text("深链：dshcontrol://add?host=<桥地址>&key=<可选访问密钥>")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        } header: {
            Text("添加机器")
        } footer: {
            Text("无需配对码。Tailscale 用 https://<machine>.<tailnet>.ts.net；本机联调用 http://127.0.0.1:8787。桥默认零鉴权，访问密钥留空即可。")
        }
    }

    // MARK: - 通知

    private var notificationSection: some View {
        Section {
            Toggle("审批与提问推送", isOn: Binding(
                get: { push.enabled },
                set: { newValue in
                    push.enabled = newValue
                    if newValue { Task { await push.requestAuthorization() } }
                }
            ))

            LabeledContent("系统权限", value: push.statusLabel)

            if push.authorizationStatus == .notDetermined {
                Button("申请通知权限") {
                    Task { await push.requestAuthorization() }
                }
            }

            if let token = push.deviceToken {
                LabeledContent("APNs token") {
                    Text(String(token.prefix(16)) + "…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let error = push.lastError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        } header: {
            Text("通知")
        } footer: {
            Text("推送由桥直连 APNs 发送，横幅只含机器名与事件类型；点开后 App 拉取真实内容。")
        }
    }

    // MARK: - 演示

    private var demoSection: some View {
        Section {
            LabeledContent("当前模式", value: app.isDemoMode ? "演示（Mock）" : "真机")
            if app.isDemoMode {
                Button("重新载入演示数据") {
                    withAnimation { app.resetDemo() }
                }
                Button("切换到真机模式") {
                    withAnimation { app.switchToLiveMode() }
                }
            } else {
                Button("切回演示模式") {
                    withAnimation { app.switchToDemoMode() }
                }
                Button("立即刷新真机状态") {
                    Task { await app.refreshLive() }
                }
            }
            Button("移除所有已添加机器（保留演示数据）", role: .destructive) {
                for machine in app.machines where !machine.isDemo {
                    app.removeMachine(machine)
                }
            }
        } header: {
            Text("演示")
        } footer: {
            Text("启动参数 `--mock` 或没有任何已添加机器时自动进入演示模式；数据全部来自本地 Mock，不需要网络。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("协议版本", value: "v1（零鉴权默认）")
            LabeledContent("桥版本", value: "0.1.0-dev（M0/M1）")
            LabeledContent("App 版本", value: "0.1.0 (M1.5)")
            LabeledContent("构建", value: "XcodeGen · Swift 6 · iOS 18+")
        } header: {
            Text("关于")
        } footer: {
            Text("DSH Control · 个人自用的 DeepSeek Harness 手机总控台")
        }
    }
}

private struct MachineStateBadge: View {
    let runtime: MachineRuntime

    var body: some View {
        HStack(spacing: 4) {
            StatusDot(state: runtime.state)
            Text(runtime.state.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 添加机器表单

struct AddMachineSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var key = ""
    @State private var result: String?
    @State private var working = false

    private let exampleAddress = "http://127.0.0.1:8787"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://mac.tailnet.ts.net 或 http://127.0.0.1:8787", text: $address, axis: .vertical)
                        .font(.footnote.monospaced())
                        .lineLimit(1...3)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("粘贴剪贴板") {
                        if let text = UIPasteboard.general.string { address = text }
                    }
                    Button("填入本机示例地址") { address = exampleAddress }
                } header: {
                    Text("桥地址")
                } footer: {
                    Text("只填地址，不需要配对码。地址要能从 iPhone 访问到（Tailscale 的 ts.net 域名最常见）。")
                }

                Section {
                    SecureField("留空 = 零鉴权", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("访问密钥（可选）")
                } footer: {
                    Text("仅当你在桥端启用了访问密钥时才需要填；会作为 `x-bridge-key` 发送，并存进 Keychain。")
                }

                Section {
                    Button {
                        Task {
                            working = true
                            result = await addMachine()
                            working = false
                        }
                    } label: {
                        HStack {
                            Label("添加并连接", systemImage: "link.badge.plus")
                            Spacer()
                            if working { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                } footer: {
                    Text("添加后立即请求 `GET /v1/hello`，成功即视为已连接，并自动加载该机器的会话列表。")
                }

                if let result {
                    Section("结果") {
                        Text(result).font(.footnote)
                    }
                }
            }
            .navigationTitle("添加机器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func addMachine() async -> String {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if let link = MachineLink.parse(trimmedAddress) {
            message = await app.addMachine(url: link.host, key: trimmedKey.isEmpty ? link.key : trimmedKey)
        } else if let link = MachineLink.parseAddress(trimmedAddress) {
            message = await app.addMachine(url: link.host, key: trimmedKey.isEmpty ? nil : trimmedKey)
        } else {
            message = "地址格式不正确。示例：\(exampleAddress)"
        }
        if message.hasPrefix("已连接") { dismiss() }
        return message
    }
}
