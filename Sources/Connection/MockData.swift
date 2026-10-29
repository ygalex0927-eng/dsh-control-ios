import Foundation

/// M1 演示数据。三台机器、两个工作区以上的会话、两条待办，以及可播放的聊天脚本。
enum MockData {
    static let macId = "demo-mac"
    static let win1Id = "demo-win-01"
    static let win2Id = "demo-win-02"

    // MARK: - 机器

    static func machines(now: Date = Date()) -> [Machine] {
        [
            Machine(
                id: macId,
                name: "Mac Studio",
                host: "https://mac-studio.tailnet-abc.ts.net",
                kind: .macOS,
                bridgeVersion: "0.1.0-dev",
                dshVersion: "0.2.1-rc.3",
                addedAt: now.addingTimeInterval(-86400 * 12),
                isDemo: true
            ),
            Machine(
                id: win1Id,
                name: "Windows-01",
                host: "https://win-01.tailnet-abc.ts.net",
                kind: .windows,
                bridgeVersion: "0.1.0-dev",
                dshVersion: "0.2.1-rc.3",
                addedAt: now.addingTimeInterval(-86400 * 9),
                isDemo: true
            ),
            Machine(
                id: win2Id,
                name: "Windows-02",
                host: "https://win-02.tailnet-abc.ts.net",
                kind: .windows,
                bridgeVersion: "0.1.0-dev",
                dshVersion: "0.2.1-rc.3",
                addedAt: now.addingTimeInterval(-86400 * 3),
                isDemo: true
            ),
        ]
    }

    static func observations(now: Date = Date()) -> [MachineObservation] {
        [
            MachineObservation(machineId: macId, state: .busy, pendingCount: 1, sessionCount: 3, at: now, source: .event),
            MachineObservation(machineId: win1Id, state: .busy, pendingCount: 1, sessionCount: 2, at: now, source: .event),
            MachineObservation(machineId: win2Id, state: .offline, pendingCount: 0, sessionCount: 2, at: now, source: .health),
        ]
    }

    // MARK: - 会话

    static func sessions(now: Date = Date()) -> [SessionSummary] {
        [
            SessionSummary(
                id: "session-ios-m1",
                machineId: macId,
                title: "M1：iOS 骨架与连接层",
                workspace: "dsh-control",
                status: .running,
                modelName: "DeepSeek-V4.1",
                updatedAt: now.addingTimeInterval(-60),
                pendingCount: 0,
                cwd: "~/Documents/dsh-control",
                lastSnippet: "正在跑 xcodebuild -scheme DSHControl …"
            ),
            SessionSummary(
                id: "session-bridge-pair",
                machineId: macId,
                title: "桥：配对与设备 token",
                workspace: "dsh-control",
                status: .waiting,
                modelName: "DeepSeek-V4.1",
                updatedAt: now.addingTimeInterval(-60 * 6),
                pendingCount: 1,
                cwd: "~/Documents/dsh-control/bridge",
                lastSnippet: "需要你批准写入 bridge/src/pairing.js"
            ),
            SessionSummary(
                id: "session-fold",
                machineId: macId,
                title: "事件折叠规范对齐",
                workspace: "deepseek-harness",
                status: .idle,
                modelName: "GLM-4.6",
                updatedAt: now.addingTimeInterval(-3600 * 5),
                pendingCount: 0,
                cwd: "~/Documents/deepseek-harness",
                lastSnippet: "快照替换窗口以后，翻页的 generation 需要作废"
            ),
            SessionSummary(
                id: "session-backtest",
                machineId: win1Id,
                title: "回测引擎重构",
                workspace: "quant-playground",
                status: .waiting,
                modelName: "DeepSeek-V4.1",
                updatedAt: now.addingTimeInterval(-60 * 2),
                pendingCount: 1,
                cwd: "C:\\work\\quant-playground",
                lastSnippet: "回测区间需要你确认"
            ),
            SessionSummary(
                id: "session-strategy",
                machineId: win1Id,
                title: "策略参数搜索",
                workspace: "quant-playground",
                status: .running,
                modelName: "DeepSeek-V4.1",
                updatedAt: now.addingTimeInterval(-60 * 9),
                pendingCount: 0,
                cwd: "C:\\work\\quant-playground",
                lastSnippet: "第 3/8 组参数运行中"
            ),
            SessionSummary(
                id: "session-notes",
                machineId: win2Id,
                title: "周报草稿",
                workspace: "notes",
                status: .idle,
                modelName: "GLM-4.6",
                updatedAt: now.addingTimeInterval(-86400),
                pendingCount: 0,
                cwd: "C:\\work\\notes",
                lastSnippet: "已把本周的提交整理成三条"
            ),
            SessionSummary(
                id: "session-docs",
                machineId: win2Id,
                title: "文档站重构",
                workspace: "notes",
                status: .idle,
                modelName: "DeepSeek-V4.1",
                updatedAt: now.addingTimeInterval(-86400 * 2),
                pendingCount: 0,
                cwd: "C:\\work\\docs-site",
                lastSnippet: "首页结构已改完，等你看一眼"
            ),
        ]
    }

    // MARK: - 待办

    static func approvals(now: Date = Date()) -> [ApprovalItem] {
        [
            ApprovalItem(
                id: "event-approval-1",
                kind: .approval,
                machineId: macId,
                sessionId: "session-bridge-pair",
                agentId: "agent-demo",
                callId: "call-demo-1",
                sessionTitle: "桥：配对与设备 token",
                toolName: "bash",
                reason: "写入前需要你确认：这会新增 bridge/src/pairing.js 并重启桥。",
                commandPreview: "cat > bridge/src/pairing.js <<'EOF' … EOF && npm restart",
                questions: [],
                raw: ["command": .string("cat > bridge/src/pairing.js …")],
                createdAt: now.addingTimeInterval(-120),
                decision: nil,
                isUnread: true
            ),
            ApprovalItem(
                id: "event-question-1",
                kind: .question,
                machineId: win1Id,
                sessionId: "session-backtest",
                agentId: "agent-demo",
                callId: nil,
                sessionTitle: "回测引擎重构",
                toolName: "ask_user_question",
                reason: "回测区间需要你确认，确认后继续。",
                commandPreview: nil,
                questions: [
                    ApprovalQuestion(
                        id: "q1",
                        prompt: "回测用 2023 全年还是近 90 天？",
                        options: [
                            ApprovalQuestionOption(id: "q1-a", label: "2023 全年"),
                            ApprovalQuestionOption(id: "q1-b", label: "近 90 天"),
                            ApprovalQuestionOption(id: "q1-c", label: "两者都跑"),
                        ],
                        multi: false,
                        allowCustom: false
                    ),
                ],
                raw: nil,
                createdAt: now.addingTimeInterval(-300),
                decision: nil,
                isUnread: true
            ),
        ]
    }

    // MARK: - 工作区（演示左侧栏）

    static func workspaces() -> [Workspace] {
        [
            Workspace(id: "ws-dsh-control", path: "/Users/me/Documents/dsh-control", title: "dsh-control", sessionIds: ["session-ios-m1", "session-bridge-pair"], updatedAt: Date()),
            Workspace(id: "ws-harness", path: "/Users/me/Documents/deepseek-harness", title: "deepseek-harness", sessionIds: ["session-fold"], updatedAt: Date()),
            Workspace(id: "ws-quant", path: "C:/work/quant-playground", title: "quant-playground", sessionIds: ["session-backtest", "session-strategy"], updatedAt: Date()),
            Workspace(id: "ws-notes", path: "C:/work/notes", title: "notes", sessionIds: ["session-notes", "session-docs"], updatedAt: Date()),
        ]
    }

    // MARK: - 会话详情种子

    static func seedItems(for session: SessionSummary, now: Date = Date()) -> [ConversationItem] {
        switch session.id {
        case "session-ios-m1":
            return iosSeed(now: now)
        case "session-bridge-pair":
            return bridgeSeed(now: now)
        case "session-backtest":
            return backtestSeed(now: now)
        case "session-fold":
            return foldSeed(now: now)
        default:
            return genericSeed(session: session, now: now)
        }
    }

    private static func iosSeed(now: Date) -> [ConversationItem] {
        [
            .message(
                id: "ios-u1",
                role: .user,
                text: "按 docs/protocol.md 把 iOS 端的 M1 骨架搭起来：连接层、总览、会话列表、会话详情、审批收件箱、设置。先 mock 跑通。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-900)
            ),
            .message(
                id: "a1.1",
                role: .assistant,
                text: "先确认协议面：`GET /v1/hello` 免鉴权、`POST /v1/rpc` 透传、`WS /v1/stream` 复用多条流、`WS /v1/events` 走 waterfall。M0 的桥目前只有 health/rpc，所以连接层按定稿协议写、界面先走 Mock。",
                reasoning: "要点：桥是透传层，手机端做折叠与呈现；不要把 DSH 的端点语义搬进桥。",
                complete: true,
                at: now.addingTimeInterval(-880)
            ),
            .tool(
                ToolCard(
                    id: "tool-bash-m1",
                    callId: "bash-m1",
                    name: "bash",
                    kind: .terminal,
                    title: "xcodegen generate && xcodebuild build",
                    subtitle: "~/Documents/dsh-control/ios",
                    command: "xcodegen generate && xcodebuild -scheme DSHControl -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build",
                    output: "Resolved project…\nCompileSwift Sources…\n** BUILD SUCCEEDED **",
                    exitCode: 0,
                    isRunning: false,
                    rawArguments: "{\"command\":\"xcodegen generate && xcodebuild …\"}"
                )
            ),
            .plan(
                PlanCard(
                    id: "plan",
                    title: "M1 计划",
                    items: [
                        PlanItem(id: "todo-0", text: "XcodeGen 工程 + Swift 6 配置", status: .completed),
                        PlanItem(id: "todo-1", text: "连接层（HTTP / WS / 事件）", status: .completed),
                        PlanItem(id: "todo-2", text: "四个 P0 界面 + 会话详情", status: .inProgress),
                        PlanItem(id: "todo-3", text: "Mock 演示路径与单元测试", status: .pending),
                    ]
                )
            ),
            .tool(
                ToolCard(
                    id: "tool-edit-m1",
                    callId: "edit-m1",
                    name: "write",
                    kind: .diff,
                    title: "ios/Sources/Store/SessionFold.swift",
                    files: [
                        ToolFileDiff(
                            path: "ios/Sources/Store/SessionFold.swift",
                            lines: ToolPresentation.diffLines(
                                old: "struct SessionFold {\n    var items: [ConversationItem] = []\n}",
                                new: "struct SessionFold: Sendable {\n    private(set) var items: [ConversationItem] = []\n    private(set) var seen: Set<Int> = []\n    private(set) var isRunning = false\n\n    mutating func apply(_ event: FoldEvent) -> Bool {\n        guard !seen.contains(event.seq) else { return false }\n        …\n    }\n}"
                            )
                        )
                    ],
                    isRunning: false,
                    rawArguments: "{\"file_path\":\"ios/Sources/Store/SessionFold.swift\"}"
                )
            ),
            .image(id: "img-m1", caption: "模拟器截图 · 三机总览"),
            .subagent(
                SubagentCard(
                    id: "subagent-m1",
                    name: "design-review",
                    status: "已结束",
                    detail: "子代理检查了配色与深色模式对比度，提出 3 条建议"
                )
            ),
            .message(
                id: "a1.2",
                role: .assistant,
                text: "骨架已经能编译。现在我在补审批卡与收件箱；下一步会把 `session/follow` 的真实事件接进来。",
                reasoning: "正在等桥的 WS 实现，Mock 数据已经覆盖四类卡片。",
                complete: false,
                at: now.addingTimeInterval(-45)
            ),
        ]
    }

    private static func bridgeSeed(now: Date) -> [ConversationItem] {
        [
            .message(
                id: "bridge-u1",
                role: .user,
                text: "把配对流程按协议实现：二维码里放 host/code/fp，换设备 token，桥只存 SHA-256。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-600)
            ),
            .message(
                id: "a2.1",
                role: .assistant,
                text: "配对入口已经写好：`POST /v1/pair` 校验一次性码、生成 32 字节 token，只落 SHA-256 摘要。下面这条写入需要你批准。",
                reasoning: "拒绝理由：文件写入属于需要人工确认的操作。",
                complete: true,
                at: now.addingTimeInterval(-480)
            ),
            .tool(
                ToolCard(
                    id: "tool-bash-pair",
                    callId: "bash-pair",
                    name: "bash",
                    kind: .terminal,
                    title: "写 pairing.js 并重启桥",
                    subtitle: "~/Documents/dsh-control",
                    command: "cat > bridge/src/pairing.js <<'EOF' … EOF && node --run restart",
                    output: "等待审批…",
                    isRunning: true,
                    rawArguments: "{\"command\":\"cat > bridge/src/pairing.js …\"}"
                )
            ),
        ]
    }

    private static func backtestSeed(now: Date) -> [ConversationItem] {
        [
            .message(
                id: "bt-u1",
                role: .user,
                text: "把回测引擎按新的 bar 结构重构，参数搜索先跑小样本。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-1800)
            ),
            .message(
                id: "a3.1",
                role: .assistant,
                text: "重构完成，参数搜索脚本也跑通了。开始前需要你定一下回测区间。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-400)
            ),
            .tool(
                ToolCard(
                    id: "tool-q1",
                    callId: "q-1",
                    name: "ask_user_question",
                    kind: .question,
                    title: "回测用 2023 全年还是近 90 天？",
                    isRunning: false,
                    rawArguments: "{\"questions\":[{\"question\":\"回测用 2023 全年还是近 90 天？\"}]}"
                )
            ),
        ]
    }

    private static func foldSeed(now: Date) -> [ConversationItem] {
        [
            .message(
                id: "fold-u1",
                role: .user,
                text: "手机端折叠要保证重连不重复、不丢，翻页不能打乱流式气泡。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-3600 * 5)
            ),
            .message(
                id: "a4.1",
                role: .assistant,
                text: "结论：`seq` 去重兜住重复；重连用新快照整体替换窗口；翻页在临时折叠器里折完再 prepend，并重建索引。",
                reasoning: "折叠必须是纯函数，才能和分页边界解耦。",
                complete: true,
                at: now.addingTimeInterval(-3600 * 5 + 40)
            ),
        ]
    }

    private static func genericSeed(session: SessionSummary, now: Date) -> [ConversationItem] {
        [
            .message(
                id: "\(session.id)-u1",
                role: .user,
                text: "继续之前那件事。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-7200)
            ),
            .message(
                id: "\(session.id)-a1",
                role: .assistant,
                text: session.lastSnippet ?? "已经处理完了，等你看一眼。",
                reasoning: nil,
                complete: true,
                at: now.addingTimeInterval(-7000)
            ),
        ]
    }

    // MARK: - 回复脚本

    static func replyChunks(topic: String, session: SessionSummary) -> [String] {
        [
            "收到。",
            "先按「\(topic.prefix(18))」这件事拆成三步：确认现状、动手改、跑验证。",
            "现状已经确认：\(session.title) 在当前工作区里，还没有未提交的冲突。",
            "现在开始改第一处——",
            "改完了，接下来跑一遍构建。",
        ]
    }

    static func replyFinalText(topic: String, session: SessionSummary) -> String {
        """
        做完了，三件事都收尾：

        1. 现状确认：读取了 `\(session.workspace)` 下的工程文件；
        2. 动手修改：两处改动，见上面的 diff 卡；
        3. 验证：`xcodebuild` 通过，退出码 0。

        关于「\(topic.prefix(20))」还有一处需要你拍板：要不要把 mock 模式做成默认入口？我在排队等你，随时可以继续。
        """
    }

    static func replyToolCard(now: Date = Date()) -> ToolCard {
        ToolCard(
            id: "tool-bash-reply",
            callId: "bash-reply",
            name: "bash",
            kind: .terminal,
            title: "xcodebuild -scheme DSHControl build",
            subtitle: "~/Documents/dsh-control/ios",
            command: "xcodebuild -scheme DSHControl -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build",
            output: "Compiling DSHControl…\n** BUILD SUCCEEDED **",
            exitCode: 0,
            isRunning: true,
            rawArguments: "{\"command\":\"xcodebuild …\"}"
        )
    }
}
