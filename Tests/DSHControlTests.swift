import XCTest
@testable import DSHControl

// MARK: - 折叠去重

final class SessionFoldTests: XCTestCase {
    private func event(seq: Int, type: String, data: JSONValue = .object([:])) -> FoldEvent {
        FoldEvent(seq: seq, type: type, data: data)
    }

    func testDuplicateSequenceIsIgnored() {
        var fold = SessionFold()
        let user = event(
            seq: 0,
            type: "user/message",
            data: ["id": "u1", "content": [["type": "text", "text": "看一下构建为什么挂"]]]
        )

        XCTAssertTrue(fold.apply(user))
        XCTAssertEqual(fold.items.count, 1)
        XCTAssertEqual(fold.appliedCount, 1)

        // 同一 seq 第二次到达：整体丢弃，不能出现两个气泡。
        XCTAssertFalse(fold.apply(user))
        XCTAssertEqual(fold.items.count, 1)
        XCTAssertEqual(fold.appliedCount, 1)
    }

    func testSnapshotReplacesWindowWithoutDuplicates() {
        var fold = SessionFold()
        _ = fold.apply(event(seq: 0, type: "user/message", data: ["id": "u1", "content": "旧"]))
        _ = fold.apply(event(seq: 1, type: "user/message", data: ["id": "u2", "content": "也旧"]))

        fold.replace(with: [
            event(seq: 3, type: "user/message", data: ["id": "u3", "content": "新窗口"]),
        ])

        XCTAssertEqual(fold.items.count, 1)
        XCTAssertTrue(fold.seen.contains(3))
        XCTAssertFalse(fold.seen.contains(0))
    }

    func testTurnEndFinishesStreamingAndUnknownEventsAreSilent() {
        var fold = SessionFold()
        _ = fold.apply(event(seq: 0, type: "assistant/chunk", data: ["turn": 1, "step": 1, "text": "正在改"]))
        _ = fold.apply(event(seq: 1, type: "plugin/whatever", data: ["foo": "bar"]))
        _ = fold.apply(event(seq: 2, type: "turn/start"))
        _ = fold.apply(event(seq: 3, type: "turn/end", data: ["reason": ["kind": "success"]]))

        XCTAssertEqual(fold.items.count, 1)
        guard case .message(_, _, let text, _, let complete, _) = fold.items[0] else {
            return XCTFail("期望一条助手消息")
        }
        XCTAssertEqual(text, "正在改")
        XCTAssertTrue(complete)
        XCTAssertFalse(fold.isRunning)
    }

    func testToolCallAndResultArePairedByCallId() {
        var fold = SessionFold()
        _ = fold.apply(event(
            seq: 0,
            type: "tool/call",
            data: ["callId": "c1", "name": "bash", "arguments": "{\"command\":\"ls -la\"}"]
        ))
        // 孤儿结果：没有对应 call 时必须丢弃，不能造一张空卡。
        _ = fold.apply(event(seq: 1, type: "tool/result", data: ["message": ["source": ["callId": "missing"]]]))
        XCTAssertEqual(fold.items.count, 1)

        _ = fold.apply(event(
            seq: 2,
            type: "tool/result",
            data: ["message": ["source": ["callId": "c1"], "content": "total 0\n[exit code: 0]"]]
        ))
        guard case .tool(let card) = fold.items[0] else {
            return XCTFail("期望工具卡")
        }
        XCTAssertFalse(card.isRunning)
        XCTAssertEqual(card.exitCode, 0)
    }
}

// MARK: - 深链解析（dshcontrol://add）

final class MachineLinkTests: XCTestCase {
    func testParsesAddLinkWithOptionalKey() {
        let link = MachineLink.parse("dshcontrol://add?host=http%3A%2F%2F127.0.0.1%3A8787&key=secret")

        XCTAssertEqual(link?.host.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(link?.key, "secret")
        XCTAssertEqual(link?.displayHost, "127.0.0.1")
        XCTAssertNil(MachineLink.parse("dshcontrol://add?host=https%3A%2F%2Fa.ts.net")?.key)
    }

    func testLegacyPairLinkStillParsesHostOnly() {
        // 旧版配对链接兼容：只取 host，忽略 code/fp。
        let link = MachineLink.parse("dshcontrol://pair?host=https%3A%2F%2Fmac-studio.tailnet-abc.ts.net&code=482913&fp=9F4C")

        XCTAssertEqual(link?.host.absoluteString, "https://mac-studio.tailnet-abc.ts.net")
        XCTAssertNil(link?.key)
    }

    func testParsesBareAddressAndRejectsGarbage() {
        XCTAssertEqual(MachineLink.parseAddress("127.0.0.1:8787")?.host.absoluteString, "http://127.0.0.1:8787")
        XCTAssertNil(MachineLink.parse("https://example.com/add?host=x"))
        XCTAssertNil(MachineLink.parse("dshcontrol://add?host=ftp%3A%2F%2Fa.ts.net"))
        XCTAssertNil(MachineLink.parse(""))
    }
}

// MARK: - 多机状态合并

final class MachineStatusMergeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewerObservationWins() {
        let observations = [
            MachineObservation(machineId: "mac", state: .offline, pendingCount: 0, sessionCount: 2, at: base, source: .health),
            MachineObservation(machineId: "mac", state: .busy, pendingCount: 1, sessionCount: 3, at: base.addingTimeInterval(30), source: .event),
        ]
        let merged = MachineStatusMerger.merge(observations)

        XCTAssertEqual(merged["mac"]?.state, .busy)
        XCTAssertEqual(merged["mac"]?.pendingCount, 1)
        XCTAssertEqual(merged["mac"]?.sessionCount, 3)
    }

    func testStaleEventDoesNotOverwriteNewerHealth() {
        let observations = [
            MachineObservation(machineId: "win", state: .online, pendingCount: 0, at: base.addingTimeInterval(60), source: .health),
            MachineObservation(machineId: "win", state: .offline, pendingCount: 0, at: base, source: .event),
        ]
        let merged = MachineStatusMerger.merge(observations)

        XCTAssertEqual(merged["win"]?.state, .online)
    }

    func testSourcePriorityBreaksTimestampTie() {
        let observations = [
            MachineObservation(machineId: "mac", state: .online, pendingCount: 0, at: base, source: .cache),
            MachineObservation(machineId: "mac", state: .busy, pendingCount: 2, at: base, source: .event),
        ]
        let merged = MachineStatusMerger.merge(observations)

        XCTAssertEqual(merged["mac"]?.state, .busy)
        XCTAssertEqual(merged["mac"]?.pendingCount, 2)

        let aggregate = MachineStatusMerger.aggregate(merged)
        XCTAssertEqual(aggregate.busy, 1)
        XCTAssertEqual(aggregate.pending, 2)
    }
}

// MARK: - 工作区同步 / 模型目录

final class WorkspaceSyncTests: XCTestCase {
    func testDecodesWorkspaceBaselineOrderAndUpsert() {
        let baseline: JSONValue = .object([
            "type": .string("baseline"),
            "value": .object([
                "items": .array([
                    .object([
                        "workspaceId": .string("w1"),
                        "path": .string("/Users/me/code"),
                        "title": .string("code"),
                        "sessionIds": .array([.string("s1")]),
                    ]),
                    .object([
                        "workspaceId": .string("w2"),
                        "path": .string("/Users/me/docs"),
                        "title": .string("docs"),
                        "sessionIds": .array([]),
                    ]),
                ]),
                "archivedSessionIds": .array([.string("s9")]),
                "pinnedSessionIds": .array([.string("s1")]),
            ]),
        ])

        guard case .baseline(let workspaces, let archived, let pinned)? = WorkspaceFrame.decode(baseline) else {
            return XCTFail("期望 baseline 帧")
        }
        XCTAssertEqual(workspaces.map(\.title), ["code", "docs"])
        XCTAssertEqual(archived, ["s9"])
        XCTAssertEqual(pinned, ["s1"])

        let order: JSONValue = .object([
            "type": .string("order"),
            "value": .object(["workspaceIds": .array([.string("w2"), .string("w1")])]),
        ])
        guard case .order(let ids)? = WorkspaceFrame.decode(order) else {
            return XCTFail("期望 order 帧")
        }
        XCTAssertEqual(ids, ["w2", "w1"])

        let unknown: JSONValue = .object(["type": .string("plugin/whatever")])
        guard case .unknown? = WorkspaceFrame.decode(unknown) else {
            return XCTFail("未知类型应静默归为 unknown")
        }
    }

    func testWorkspacePathOwnershipUsesPathSegments() {
        let workspace = Workspace(id: "w1", path: "/Users/me/code", title: "code", sessionIds: [], updatedAt: Date())

        XCTAssertTrue(workspace.contains(cwd: "/Users/me/code"))
        XCTAssertTrue(workspace.contains(cwd: "/Users/me/code/sub"))
        XCTAssertFalse(workspace.contains(cwd: "/Users/me/code2"))
        XCTAssertFalse(workspace.contains(cwd: nil))
    }

    @MainActor
    func testSessionBelongsToWorkspaceBySessionIdsFirstAndCwdSecond() {
        let workspace = Workspace(
            id: "w1",
            path: "/Users/me/code",
            title: "code",
            sessionIds: ["listed"],
            updatedAt: Date()
        )
        let byList = SessionSummary(id: "listed", machineId: "m", title: "t", cwd: "/elsewhere")
        let byCwd = SessionSummary(id: "cwd-only", machineId: "m", title: "t", cwd: "/Users/me/code/x")
        let unrelated = SessionSummary(id: "nope", machineId: "m", title: "t", cwd: "/Users/me/other")

        XCTAssertTrue(AppModel.belongsTo(workspace: workspace, session: byList))
        XCTAssertTrue(AppModel.belongsTo(workspace: workspace, session: byCwd))
        XCTAssertFalse(AppModel.belongsTo(workspace: workspace, session: unrelated))
    }

    func testModelCatalogDecodeHandlesGroupsAndDefaultFallback() {
        let catalog = ModelCatalog.decode(.object([
            "default": .object([
                "provider": .string("deepseek-official"),
                "model": .string("deepseek-flash"),
            ]),
            "groups": .array([
                .object([
                    "provider": .string("deepseek-official"),
                    "models": .array([
                        .object(["model": .string("deepseek-flash"), "displayName": .string("Flash")]),
                        .object(["id": .string("deepseek-pro")]),
                    ]),
                ]),
            ]),
        ]))

        XCTAssertEqual(catalog.defaultModel, "deepseek-flash")
        XCTAssertEqual(catalog.options.count, 2)
        XCTAssertEqual(catalog.options.first?.displayName, "Flash")
        XCTAssertEqual(catalog.options.last?.provider, "deepseek-official")
    }
}

// MARK: - WebSocket 大帧分块重组

final class ChunkAssemblerTests: XCTestCase {
    private func split(_ text: String, into count: Int) -> [String] {
        let characters = Array(text)
        let size = max(1, (characters.count + count - 1) / count)
        var parts: [String] = []
        var start = 0
        while start < characters.count {
            let end = min(start + size, characters.count)
            parts.append(String(characters[start..<end]))
            start = end
        }
        return parts
    }

    private func chunkFrame(id: String, index: Int, total: Int, data: String) -> JSONValue {
        .object([
            "op": .string("chunk"),
            "chunkId": .string(id),
            "index": .int(index),
            "total": .int(total),
            "data": .string(data),
        ])
    }

    func testOutOfOrderChunksReassembleOriginalJSON() {
        let original = #"{"op":"item","streamId":"s","value":{"type":"snapshot","records":[{"type":"event","event":{"type":"user/message","seq":1,"data":{"text":"你好"}}}]}}"#
        let parts = split(original, into: 3)
        XCTAssertEqual(parts.count, 3)

        var assembler = ChunkAssembler()
        XCTAssertNil(assembler.accept(chunkFrame(id: "c1", index: 2, total: 3, data: parts[2])))
        XCTAssertNil(assembler.accept(chunkFrame(id: "c1", index: 0, total: 3, data: parts[0])))
        XCTAssertEqual(assembler.pending.count, 1)

        let assembled = assembler.accept(chunkFrame(id: "c1", index: 1, total: 3, data: parts[1]))
        XCTAssertEqual(assembled, JSONValue.parse(original))
        XCTAssertTrue(assembler.pending.isEmpty, "收齐后必须删除 chunkId，避免内存泄漏")
    }

    func testIncompleteChunksAreNotDispatched() {
        let original = #"{"op":"chunk-test","value":42}"#
        let parts = split(original, into: 3)
        XCTAssertEqual(parts.count, 3)

        var assembler = ChunkAssembler()
        // 只到两片：不能派发。
        XCTAssertNil(assembler.accept(chunkFrame(id: "abc", index: 0, total: 3, data: parts[0])))
        XCTAssertNil(assembler.accept(chunkFrame(id: "abc", index: 2, total: 3, data: parts[2])))
        XCTAssertEqual(assembler.pending.count, 1)

        // 普通（非分块）帧原样透传，不受影响。
        let plain: JSONValue = ["op": "item", "streamId": "s"]
        XCTAssertEqual(assembler.accept(plain), plain)
        XCTAssertEqual(assembler.pending.count, 1)

        // 补齐第三片才派发，并清空缓存。
        XCTAssertEqual(assembler.accept(chunkFrame(id: "abc", index: 1, total: 3, data: parts[1])), JSONValue.parse(original))
        XCTAssertTrue(assembler.pending.isEmpty)
    }
}

// MARK: - 历史翻页（session/page）

final class HistoryPagingTests: XCTestCase {
    func testPrependingOlderEventsDedupesOverlapAndKeepsSeqOrder() {
        var fold = SessionFold()
        _ = fold.apply(FoldEvent(seq: 10, type: "user/message", data: ["id": "u10", "content": "较新的一条"]))
        XCTAssertEqual(fold.oldestSeq, 10)

        // 翻页返回的事件与当前窗口在 seq=10 处重叠（throughSeq 是闭区间）。
        let page = [
            FoldEvent(seq: 9, type: "user/message", data: ["id": "u9", "content": "更早的一条"]),
            FoldEvent(seq: 10, type: "user/message", data: ["id": "u10", "content": "较新的一条"]),
        ]
        XCTAssertEqual(fold.prepend(page), 1)
        XCTAssertEqual(fold.items.map(\.id), ["u9", "u10"])
        XCTAssertEqual(fold.oldestSeq, 9)
        XCTAssertEqual(fold.appliedCount, 2)
    }
}

// MARK: - 流式跟随 / 折叠状态稳定性

final class StreamingFollowTests: XCTestCase {
    func testRevisionIncrementsOnStreamingChunksEvenWhenItemStaysSame() {
        var fold = SessionFold()
        XCTAssertEqual(fold.revision, 0)

        _ = fold.apply(FoldEvent(seq: 0, type: "user/message", data: ["id": "u0", "content": "开始"]))
        let afterUser = fold.revision
        XCTAssertGreaterThan(afterUser, 0)

        // 同一个 turn/step 的两个 chunk：item id 不变，但 revision 必须递增，
        // 否则详情页无法跟随最新字节。
        _ = fold.apply(FoldEvent(seq: 1, type: "assistant/chunk", data: ["turn": 1, "step": 1, "text": "流"]))
        let afterFirstChunk = fold.revision
        XCTAssertGreaterThan(afterFirstChunk, afterUser)
        let itemCount = fold.items.count

        _ = fold.apply(FoldEvent(seq: 2, type: "assistant/chunk", data: ["turn": 1, "step": 1, "text": "式输出"]))
        XCTAssertGreaterThan(fold.revision, afterFirstChunk)
        XCTAssertEqual(fold.items.count, itemCount, "同一气泡变长，不应新增 item")

        // 重复 seq 不应该让 revision 动。
        let beforeDuplicate = fold.revision
        XCTAssertFalse(fold.apply(FoldEvent(seq: 2, type: "assistant/chunk", data: ["turn": 1, "step": 1, "text": "x"])))
        XCTAssertEqual(fold.revision, beforeDuplicate)
    }

    @MainActor
    func testExpandedReasoningSurvivesStreamingUpdates() {
        let session = SessionSummary(id: "s1", machineId: "m1", title: "测试会话")
        let model = SessionDetailModel(session: session, isDemo: true, machine: nil, seedItems: [])
        let reasoningID = "reason-a1.1"

        XCTAssertFalse(model.isExpanded(reasoningID))
        model.toggleExpanded(reasoningID)
        XCTAssertTrue(model.isExpanded(reasoningID))

        // 模拟流式/列表刷新：折叠状态必须保留。
        model.appendNotice("流式内容更新")
        XCTAssertGreaterThan(model.revision, 0)
        XCTAssertTrue(model.isExpanded(reasoningID))

        model.updateSession(SessionSummary(id: "s1", machineId: "m1", title: "改名后的会话"))
        XCTAssertTrue(model.isExpanded(reasoningID))

        model.toggleExpanded(reasoningID)
        XCTAssertFalse(model.isExpanded(reasoningID))
    }
}

// MARK: - 模型目录（真实 session/modelCatalog 形状）

final class ModelCatalogTests: XCTestCase {
    func testParsesRealCatalogShapeWithProviderAndEfforts() {
        let catalog = ModelCatalog.decode(.object([
            "default": .object([
                "provider": .string("deepseek-account"),
                "model": .string("deepseek-flash"),
                "reasoningEffort": .string("max"),
            ]),
            "routableProviders": .array([.string("deepseek-official"), .string("deepseek-account"), .string("xai")]),
            "groups": .array([
                .object([
                    "id": .string("deepseek-official"),
                    "name": .string("DeepSeek"),
                    "models": .array([
                        .object([
                            "id": .string("deepseek-flash"),
                            "name": .string("DeepSeek-V4.1-Flash"),
                            "reasoning": .object([
                                "efforts": .array([
                                    .object(["id": .string("off"), "name": .string("Off")]),
                                    .object(["id": .string("low"), "name": .string("Low")]),
                                    .object(["id": .string("high"), "name": .string("High")]),
                                    .object(["id": .string("max"), "name": .string("Max")]),
                                ]),
                                "defaultEffort": .string("high"),
                            ]),
                        ]),
                    ]),
                ]),
                .object([
                    "id": .string("xai"),
                    "name": .string("xAI"),
                    "models": .array([
                        .object(["id": .string("grok-4.7"), "name": .string("Grok 4.7")]),
                    ]),
                ]),
            ]),
        ]))

        // provider 必须来自 group.id，不是 default.provider。
        XCTAssertEqual(catalog.groups.count, 2)
        XCTAssertEqual(catalog.groups.first?.id, "deepseek-official")
        XCTAssertEqual(catalog.groups.first?.name, "DeepSeek")
        let option = catalog.options.first
        XCTAssertEqual(option?.provider, "deepseek-official")
        XCTAssertEqual(option?.model, "deepseek-flash")
        XCTAssertEqual(option?.label, "DeepSeek-V4.1-Flash")
        XCTAssertEqual(option?.efforts.map(\.id), ["off", "low", "high", "max"])
        XCTAssertEqual(option?.defaultEffort, "high")

        // 当前选择的解析：provider + model + effort → 显示名。
        XCTAssertEqual(
            catalog.displayTitle(provider: "deepseek-official", model: "deepseek-flash", effort: "max"),
            "DeepSeek-V4.1-Flash · Max"
        )
        XCTAssertEqual(catalog.defaultTitle, "DeepSeek-V4.1-Flash · Max")
        XCTAssertEqual(catalog.options.count, 2)
    }

    func testEmptyCatalogIsUnavailable() {
        let catalog = ModelCatalog.decode(.object([
            "routableProviders": .array([]),
            "groups": .array([]),
        ]))
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertNil(catalog.defaultTitle)
    }
}

// MARK: - Token 用量 / 思考时间

final class UsageAndTimingTests: XCTestCase {
    func testHumanReadableFormatting() {
        XCTAssertEqual(TokenFormat.human(987), "987")
        XCTAssertEqual(TokenFormat.human(340_234), "340.2k")
        XCTAssertEqual(TokenFormat.human(1_234_567), "1.2M")
        XCTAssertEqual(TokenFormat.human(139_432_320), "139.4M")
        XCTAssertEqual(DurationFormat.compact(4.234), "4.2s")
        XCTAssertEqual(DurationFormat.compact(75), "1m15s")
    }

    func testAssistantMessageParsesReasoningAndUsageFromPersistedEvent() {
        var fold = SessionFold()
        let event = FoldEvent(seq: 1, type: "assistant/message", data: .object([
            "turn": .int(1),
            "step": .int(1),
            "usage": .object([
                "inputTokens": .int(24_000),
                "outputTokens": .int(1_400),
                "cacheReadTokens": .int(524_700),
                "cacheWriteTokens": .int(0),
                "totalTokens": .int(548_700),
            ]),
            "message": .object([
                "content": .array([
                    .object(["type": .string("reasoning"), "text": .string("先看看协议文档。")]),
                    .object(["type": .string("text"), "text": .string("结论是……")]),
                ]),
            ]),
        ]))
        _ = fold.apply(event)

        guard case .message(let id, _, let text, let reasoning, _, _) = fold.items.first else {
            return XCTFail("期望 assistant 消息")
        }
        XCTAssertEqual(text, "结论是……")
        XCTAssertEqual(reasoning, "先看看协议文档。", "持久事件里的 reasoning 必须解析出来，否则重开历史思考块会丢")
        XCTAssertEqual(fold.usage(for: id)?.outputTokens, 1_400)
        XCTAssertEqual(fold.usage(for: id)?.cacheReadTokens, 524_700)
        XCTAssertNil(fold.thinkingSeconds(for: id), "没有流式时间戳时不要编思考时长")
    }

    func testThinkingDurationComesFromStreamFrames() {
        var fold = SessionFold()
        let start: JSONValue = .object([
            "type": .string("assistant-stream"),
            "frame": .object(["type": .string("start"), "turn": .int(1), "step": .int(1)]),
        ])
        _ = fold.applyAssistantStream(start)

        let firstReason = 1_700_000_000_000
        let reasoningChunk: JSONValue = .object([
            "type": .string("assistant-stream"),
            "frame": .object([
                "type": .string("chunk"),
                "turn": .int(1),
                "step": .int(1),
                "time": .int(firstReason),
                "chunk": .object(["type": .string("reasoning-delta"), "text": .string("思考…")]),
            ]),
        ])
        _ = fold.applyAssistantStream(reasoningChunk)

        let firstTextChunk: JSONValue = .object([
            "type": .string("assistant-stream"),
            "frame": .object([
                "type": .string("chunk"),
                "turn": .int(1),
                "step": .int(1),
                "time": .int(firstReason + 4_200),
                "chunk": .object(["type": .string("text-delta"), "text": .string("正文")]),
            ]),
        ])
        _ = fold.applyAssistantStream(firstTextChunk)

        let seconds = fold.thinkingSeconds(for: "a1.1")
        XCTAssertNotNil(seconds)
        XCTAssertEqual(seconds ?? 0, 4.2, accuracy: 0.01)
    }
}

// MARK: - 附件 content 构造

final class AttachmentContentTests: XCTestCase {
    func testBuildsTextImageAndFileBlocks() {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let attachments: [ChatAttachment] = [
            ChatAttachment(
                id: "img1",
                kind: .image,
                fileName: "shot.png",
                mediaType: "image/png",
                imageData: imageData,
                fileData: nil,
                byteCount: imageData.count,
                state: .ready
            ),
            ChatAttachment(
                id: "file1",
                kind: .file,
                fileName: "report.pdf",
                mediaType: "application/pdf",
                imageData: nil,
                fileData: Data([0x25, 0x50]),
                byteCount: 2,
                state: .uploaded(receiptId: "receipt-123")
            ),
        ]

        let content = PromptContentBuilder.build(text: "看看这两个文件", attachments: attachments)
        XCTAssertEqual(content.count, 3)

        guard let textBlock = content[0].objectValue,
              let imageBlock = content[1].objectValue,
              let fileBlock = content[2].objectValue else {
            return XCTFail("content 块形状不对")
        }
        XCTAssertEqual(textBlock["type"]?.stringValue, "text")
        XCTAssertEqual(textBlock["text"]?.stringValue, "看看这两个文件")

        XCTAssertEqual(imageBlock["type"]?.stringValue, "image")
        XCTAssertEqual(imageBlock["mediaType"]?.stringValue, "image/png")
        XCTAssertEqual(imageBlock["data"]?.stringValue, imageData.base64EncodedString())
        XCTAssertEqual(imageBlock["name"]?.stringValue, "shot.png")

        XCTAssertEqual(fileBlock["type"]?.stringValue, "file")
        XCTAssertEqual(fileBlock["receiptId"]?.stringValue, "receipt-123")
    }

    func testSkipsUnreadyAttachmentsAndSupportsAttachmentOnlySend() {
        var file = ChatAttachment(
            id: "file2",
            kind: .file,
            fileName: "pending.bin",
            mediaType: nil,
            imageData: nil,
            fileData: Data([0x01]),
            byteCount: 1,
            state: .uploading(0.4)
        )
        let content = PromptContentBuilder.build(text: "  ", attachments: [file])
        XCTAssertTrue(content.isEmpty, "空白文本 + 上传中的文件不应产生 content")

        file.state = .uploaded(receiptId: "r-1")
        let ready = PromptContentBuilder.build(text: "", attachments: [file])
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?["type"]?.stringValue, "file")
    }
}

// MARK: - 重复发送（乐观条目 + 落盘事件）

final class DuplicateMessageTests: XCTestCase {
    private func persistedUser(id: String, text: String, rpcId: String? = nil, seq: Int = 0) -> FoldEvent {
        var source: [String: JSONValue] = ["kind": .string("user")]
        if let rpcId { source["rpcId"] = .string(rpcId) }
        return FoldEvent(seq: seq, type: "user/message", data: [
            "id": .string(id),
            "role": .string("user"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "source": .object(source),
        ])
    }

    func testOptimisticMessageReplacedByServerEchoWithRpcId() {
        var fold = SessionFold()
        fold.appendUser("你好", id: "pending-r1")
        XCTAssertEqual(fold.items.count, 1)

        _ = fold.apply(persistedUser(id: "srv-1", text: "你好", rpcId: "r1"))

        XCTAssertEqual(fold.items.count, 1, "乐观条目必须被原地替换，不能出现两条")
        XCTAssertEqual(fold.items.first?.id, "srv-1", "id 应更新为服务端 id，位置不变")
    }

    func testOptimisticMessageReplacedWithoutRpcIdByTextAndTime() {
        var fold = SessionFold()
        fold.appendUser("重复文本", id: "pending-no-rpc")
        XCTAssertEqual(fold.items.count, 1)

        // 真实落盘的 user/message 没有 requestId，靠「pending- + 同文本 + 30s」兜底。
        _ = fold.apply(persistedUser(id: "srv-2", text: "重复文本"))

        XCTAssertEqual(fold.items.count, 1)
        XCTAssertEqual(fold.items.first?.id, "srv-2")
    }

    func testDifferentTextAppendsSecondMessage() {
        var fold = SessionFold()
        fold.appendUser("第一条", id: "pending-a")
        _ = fold.apply(persistedUser(id: "srv-a", text: "第一条"))
        _ = fold.apply(persistedUser(id: "srv-b", text: "第二条", seq: 1))

        XCTAssertEqual(fold.items.count, 2)
        XCTAssertEqual(fold.items.map(\.id), ["srv-a", "srv-b"])
    }

    func testConsecutiveDuplicateUserMessagesCollapseToOne() {
        var fold = SessionFold()
        _ = fold.apply(persistedUser(id: "srv-1", text: "同一条", seq: 0))
        // 5 秒内又来一条完全相同的 user/message（发送侧重复 append 的情况）：只留一条。
        _ = fold.apply(persistedUser(id: "srv-2", text: "同一条", seq: 1))

        XCTAssertEqual(fold.items.count, 1)
        XCTAssertEqual(fold.items.first?.id, "srv-2")
    }
}

// MARK: - 流式增量缓冲（O(1) chunk + flush 快照一致）

final class StreamingBufferTests: XCTestCase {
    private func streamFrame(_ frame: JSONValue) -> JSONValue {
        .object(["type": .string("assistant-stream"), "frame": frame])
    }

    func testChunksAreBufferedUntilFlushAndSnapshotMatches() {
        var fold = SessionFold()
        _ = fold.applyAssistantStream(streamFrame(.object([
            "type": .string("start"), "turn": .int(1), "step": .int(1),
        ])))

        var expected = ""
        for index in 0..<200 {
            let delta = "段落\(index)；"
            expected += delta
            _ = fold.applyAssistantStream(streamFrame(.object([
                "type": .string("chunk"),
                "turn": .int(1),
                "step": .int(1),
                "chunk": .object(["type": .string("text-delta"), "text": .string(delta)]),
            ])))
        }

        // chunk 路径只 append 缓冲：还没物化 item，主线程不做 O(n²) upsert。
        XCTAssertEqual(fold.items.count, 0)

        XCTAssertTrue(fold.flushStreaming())
        XCTAssertEqual(fold.items.count, 1)
        guard case .message(let id, let role, let text, _, let complete, _) = fold.items[0] else {
            return XCTFail("期望 assistant 气泡")
        }
        XCTAssertEqual(id, "a1.1")
        XCTAssertEqual(role, .assistant)
        XCTAssertEqual(text, expected)
        XCTAssertFalse(complete)

        // 没有新 chunk 时 flush 不重复物化。
        XCTAssertFalse(fold.flushStreaming())
        XCTAssertEqual(fold.items.count, 1)
    }

    func testFinalMessageAfterChunksReplacesBubbleWithoutDuplicates() {
        var fold = SessionFold()
        _ = fold.applyAssistantStream(streamFrame(.object([
            "type": .string("start"), "turn": .int(1), "step": .int(1),
        ])))
        _ = fold.applyAssistantStream(streamFrame(.object([
            "type": .string("chunk"), "turn": .int(1), "step": .int(1),
            "chunk": .object(["type": .string("text-delta"), "text": .string("流式片段")]),
        ])))

        // 落盘 assistant/message 之前应先 flush 缓冲，再整体替换。
        _ = fold.apply(FoldEvent(seq: 5, type: "assistant/message", data: [
            "turn": .int(1),
            "step": .int(1),
            "message": .object([
                "content": .array([.object(["type": .string("text"), "text": .string("最终完整文本")])]),
            ]),
        ]))

        XCTAssertEqual(fold.items.count, 1)
        guard case .message(_, _, let text, _, let complete, _) = fold.items[0] else {
            return XCTFail("期望 assistant 气泡")
        }
        XCTAssertEqual(text, "最终完整文本")
        XCTAssertTrue(complete)
    }
}

final class RenderRegressionTests: XCTestCase {
    func testReasoningFlushDoesNotBecomeTextScroll() {
        var fold = SessionFold()
        _ = fold.applyAssistantStream(["frame": ["type": "start", "turn": 1, "step": 1]])
        _ = fold.applyAssistantStream(["frame": ["type": "chunk", "chunk": ["reasoning": "思考内容"]]])
        XCTAssertTrue(fold.flushStreaming())
        if case .reasoningStream = fold.lastChangeKind {} else {
            XCTFail("纯思考合帧后不能标为正文，避免抢滚动")
        }
        XCTAssertEqual(fold.items.count, 1)
    }
}

final class RemoteTurnControlsTests: XCTestCase {
    @MainActor
    func testComputerStartedTurnExposesBottomStop() {
        let session = SessionSummary(machineId: "remote", title: "外部运行任务")
        let model = SessionDetailModel(session: session, isDemo: false, machine: nil)
        XCTAssertFalse(model.canStop)
        model.applyStatus(.running)
        XCTAssertTrue(model.canStop)
        model.applyStatus(.idle)
        XCTAssertFalse(model.canStop)
    }
}

final class ResumeStreamRegressionTests: XCTestCase {
    func testChunkAfterReconnectUsesServerTurnAndStep() {
        var fold = SessionFold()
        _ = fold.applyAssistantStream(["frame": ["type": "chunk", "turn": 12, "step": 3,
                                                "chunk": ["reasoning": "恢复后"]]])
        _ = fold.flushStreaming()
        XCTAssertEqual(fold.items.first?.id, "a12.3")
    }

    func testNewSnapshotDiscardsUnpublishedOldStreamBuffer() {
        var fold = SessionFold()
        _ = fold.applyAssistantStream(["frame": ["type": "chunk", "turn": 1, "step": 1,
                                                "chunk": ["text": "旧连接残留"]]])
        fold.replace(with: [])
        XCTAssertFalse(fold.flushStreaming())
        XCTAssertTrue(fold.items.isEmpty)
    }
}
