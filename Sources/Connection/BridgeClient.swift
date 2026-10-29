import Foundation

/// 桥的手机协议客户端（协议 v1，零鉴权默认）：
/// - `GET /v1/hello`（免鉴权）、`GET /v1/health`
/// - `POST /v1/rpc`（unary 透传）
/// - `WS /v1/stream`（`open` / `item` / `end` / `error`）
/// - `WS /v1/events`（`ready` / `emit` / `request` / `cancel` ↔ `result`）
///
/// 用户一个人用，不做设备配对/设备 token。桥默认零鉴权；如果桥开了访问密钥，
/// HTTP 带 `x-bridge-key` 头，WS 在 open 之前先发 `{"op":"auth","key":…}`。
actor BridgeClient {
    static let shared = BridgeClient()

    private let session: URLSession
    private var eventSocket: URLSessionWebSocketTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // WebSocket 是长连接：resource timeout 必须远大于 30s，否则流会在 30s 被 URLSession 杀掉。
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - HTTP

    func hello(host: URL) async throws -> BridgeHello {
        let data = try await get(url: endpointURL(host: host, path: "/v1/hello"), key: nil)
        return try JSONDecoder().decode(BridgeHello.self, from: data)
    }

    func health(host: URL, key: String?) async throws -> BridgeHealth {
        let data = try await get(url: endpointURL(host: host, path: "/v1/health"), key: key)
        return try JSONDecoder().decode(BridgeHealth.self, from: data)
    }

    func rpc(host: URL, key: String?, endpoint: String, args: JSONValue) async throws -> JSONValue {
        var request = makeRequest(url: endpointURL(host: host, path: "/v1/rpc"), key: key)
        request.httpMethod = "POST"
        let payload = RPCRequest(id: UUID().uuidString, endpoint: endpoint, args: args)
        let data = try await send(request, body: try JSONEncoder().encode(payload))
        let response = try JSONDecoder().decode(RPCResponse.self, from: data)
        if let error = response.error { throw error }
        guard response.ok else { throw BridgeError(code: "rpc/failed", message: "调用失败") }
        return response.value ?? .null
    }

    func registerPush(host: URL, key: String?, deviceToken: String, environment: String) async throws {
        var request = makeRequest(url: endpointURL(host: host, path: "/v1/push/register"), key: key)
        request.httpMethod = "POST"
        let body: JSONValue = ["token": .string(deviceToken), "environment": .string(environment)]
        _ = try await send(request, body: try JSONEncoder().encode(body))
    }

    struct UploadReceipt: Sendable {
        var receiptId: String
        var name: String
        var bytes: Int
        var attachmentId: String?
    }

    /// 上传附件：`POST /v1/upload?sessionId=&name=`，body 是原始字节。
    /// 返回 DSH 的 `{ok:true,value:{receiptId,file:{attachmentId,name,bytes}}}`。
    func upload(
        host: URL,
        key: String?,
        sessionId: String,
        fileName: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadReceipt {
        var components = URLComponents(url: endpointURL(host: host, path: "/v1/upload"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "name", value: fileName),
        ]
        guard let url = components?.url else {
            throw BridgeError(code: "upload/bad-url", message: "无法构造上传地址")
        }
        var request = makeRequest(url: url, key: key)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(handler: progress)
        let (responseData, response) = try await session.upload(for: request, from: data, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: responseData) {
                throw envelope.error
            }
            throw BridgeError(code: "upload/http-\( (response as? HTTPURLResponse)?.statusCode ?? 0 )", message: "上传失败")
        }
        let value = (try? JSONDecoder().decode(JSONValue.self, from: responseData)) ?? .object([:])
        let payload = value["value"] ?? value
        guard let receiptId = payload["receiptId"]?.stringValue else {
            throw BridgeError(code: "upload/no-receipt", message: "上传响应缺少 receiptId")
        }
        let file = payload["file"]
        return UploadReceipt(
            receiptId: receiptId,
            name: file?["name"]?.stringValue ?? fileName,
            bytes: file?["bytes"]?.intValue ?? data.count,
            attachmentId: file?["attachmentId"]?.stringValue
        )
    }

    // MARK: - WebSocket

    /// `/v1/events`：常驻通道，审批/提问请求与 `api-session/*` 变化都走它。
    /// 返回的帧流用于读取；应答用 `answerEvent(eventId:outcome:)`。
    func startEvents(host: URL, key: String?) -> AsyncThrowingStream<BridgeEventFrame, Error> {
        closeEvents()
        let url = webSocketURL(host: host, path: "/v1/events")
        var request = URLRequest(url: url)
        if let key, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-bridge-key")
        }
        let socket = session.webSocketTask(with: request)
        eventSocket = socket
        socket.resume()

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var assembler = ChunkAssembler()
                defer { assembler.reset() }
                do {
                    if let key, !key.isEmpty {
                        try await Self.send(socket, ["op": "auth", "key": .string(key)])
                    }
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let value = try Self.decode(message)
                        // 桥把超大帧拆成 op=chunk 的多条消息，收齐再分发。
                        guard let payload = assembler.accept(value) else { continue }
                        if let frame = BridgeEventFrame.decode(payload) {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
                socket.cancel(with: .goingAway, reason: nil)
                await self?.clearEventSocket(ifMatches: socket)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 应答审批/提问：`{"op":"result","eventId":…,"outcome":{…}}`。
    func answerEvent(eventId: String, outcome: JSONValue) async throws {
        guard let socket = eventSocket else {
            throw BridgeError(code: "events/closed", message: "事件通道未连接")
        }
        let frame: JSONValue = ["op": "result", "eventId": .string(eventId), "outcome": outcome]
        try await socket.send(.string(frame.rawText))
    }

    func closeEvents() {
        eventSocket?.cancel(with: .goingAway, reason: nil)
        eventSocket = nil
    }

    private func clearEventSocket(ifMatches socket: URLSessionWebSocketTask) {
        if eventSocket === socket { eventSocket = nil }
    }

    /// `/v1/stream` + `workspace/follow`：左侧栏的工作区、排序、归档与置顶。
    func workspaceStream(host: URL, key: String?) -> AsyncThrowingStream<WorkspaceFrame, Error> {
        let url = webSocketURL(host: host, path: "/v1/stream")
        return AsyncThrowingStream { continuation in
            let task = Task { [session] in
                var assembler = ChunkAssembler()
                defer { assembler.reset() }
                var request = URLRequest(url: url)
                if let key, !key.isEmpty {
                    request.setValue(key, forHTTPHeaderField: "x-bridge-key")
                }
                let socket = session.webSocketTask(with: request)
                socket.resume()
                do {
                    if let key, !key.isEmpty {
                        try await Self.send(socket, ["op": "auth", "key": .string(key)])
                    }
                    // 实测：workspace/follow 的 args 必须是空对象，传 _request 会 400。
                    let open: JSONValue = [
                        "op": "open",
                        "streamId": .string(UUID().uuidString),
                        "endpoint": .string("workspace/follow"),
                        "args": .object([:]),
                    ]
                    try await Self.send(socket, open)
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let value = try Self.decode(message)
                        guard let payload = assembler.accept(value) else { continue }
                        switch payload["op"]?.stringValue {
                        case "item":
                            guard let item = payload["value"] else { continue }
                            if let frame = WorkspaceFrame.decode(item) {
                                continuation.yield(frame)
                            }
                        case "end":
                                    continuation.finish()
                            socket.cancel(with: .normalClosure, reason: nil)
                            return
                        case "error":
                            let error = value["error"]
                            throw BridgeError(
                                code: error?["code"]?.stringValue ?? "stream/failed",
                                message: error?["message"]?.stringValue ?? "工作区流异常结束"
                            )
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
                socket.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct PageResult: Sendable {
        var events: [FoldEvent]
        var hasMore: Bool
    }

    /// 往前翻页：`session/page`（实测 `throughSeq` 为返回窗口的最晚 seq，`hasMore` 表示还有更早的）。
    func sessionPage(
        host: URL,
        key: String?,
        sessionId: String,
        throughSeq: Int,
        maxMessages: Int = 60
    ) async throws -> PageResult {
        let value = try await rpc(
            host: host,
            key: key,
            endpoint: "session/page",
            args: [
                "request": [
                    "address": ["kind": "session", "sessionId": .string(sessionId)],
                    "throughSeq": .int(throughSeq),
                    "maxMessages": .int(maxMessages),
                ],
            ]
        )
        let records = value["records"]?.arrayValue ?? []
        let events = Self.recordsToEvents(records)
        let hasMore = value["hasMore"]?.boolValue ?? (events.first.map { $0.seq > 0 } ?? false)
        return PageResult(events: events, hasMore: hasMore)
    }

    /// `session/modelCatalog`（实测可传 `{}`）。
    func modelCatalog(host: URL, key: String?) async throws -> ModelCatalog {
        let value = try await rpc(host: host, key: key, endpoint: "session/modelCatalog", args: [:])
        return ModelCatalog.decode(value)
    }

    func selectModel(
        host: URL,
        key: String?,
        sessionId: String,
        option: ModelOption,
        effort: String?
    ) async throws {
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "provider": .string(option.provider),
            "model": .string(option.model),
        ]
        if let resolvedEffort = effort ?? option.defaultEffort, !resolvedEffort.isEmpty {
            request["reasoningEffort"] = .string(resolvedEffort)
        }
        _ = try await rpc(host: host, key: key, endpoint: "session/selectModel", args: ["request": .object(request)])
    }

    /// `/v1/stream`：打开一个 `session/follow` 流，产出快照与增量事件。
    func sessionStream(host: URL, key: String?, sessionId: String) -> AsyncThrowingStream<SessionFrame, Error> {
        let url = webSocketURL(host: host, path: "/v1/stream")
        return AsyncThrowingStream { continuation in
            let task = Task { [session] in
                var assembler = ChunkAssembler()
                defer { assembler.reset() }
                var request = URLRequest(url: url)
                if let key, !key.isEmpty {
                    request.setValue(key, forHTTPHeaderField: "x-bridge-key")
                }
                let socket = session.webSocketTask(with: request)
                socket.resume()
                do {
                    if let key, !key.isEmpty {
                        try await Self.send(socket, ["op": "auth", "key": .string(key)])
                    }
                    let open: JSONValue = [
                        "op": "open",
                        "streamId": .string(UUID().uuidString),
                        "endpoint": .string("session/follow"),
                        "args": [
                            "request": [
                                "address": ["kind": "session", "sessionId": .string(sessionId)],
                                "assistantStream": true,
                                // 首屏只拉 60 条消息：大会话（2~5MB）也不会一次灌进手机；
                                // 更早的历史点「加载更早的消息」走 session/page。
                                "maxMessages": 60,
                            ],
                        ],
                    ]
                    try await Self.send(socket, open)

                    // 后台接收循环里合并 assistant-stream 的 chunk：
                    // 字符串层拼接，最多 ~100ms yield 一次，主线程帧数从 ~100/s 降到 ~10/s。
                    var pendingText = ""
                    var pendingReasoning = ""
                    var pendingTurn = 0
                    var pendingStep = 0
                    var pendingTime: Int?
                    var windowStart = Date()

                    func yieldFrame(_ frame: SessionFrame) {
                        Diagnostics.shared.recordFrame()
                        continuation.yield(frame)
                    }

                    func flushMergedChunk() {
                        guard !pendingText.isEmpty || !pendingReasoning.isEmpty else { return }
                        var chunk: [String: JSONValue] = ["type": .string("text-delta")]
                        if !pendingText.isEmpty { chunk["text"] = .string(pendingText) }
                        if !pendingReasoning.isEmpty { chunk["reasoning"] = .string(pendingReasoning) }
                        var frame: [String: JSONValue] = [
                            "type": .string("chunk"),
                            "turn": .int(pendingTurn),
                            "step": .int(pendingStep),
                            "chunk": .object(chunk),
                        ]
                        if let pendingTime { frame["time"] = .int(pendingTime) }
                        yieldFrame(.stream(.object([
                            "type": .string("assistant-stream"),
                            "frame": .object(frame),
                        ])))
                        pendingText = ""
                        pendingReasoning = ""
                        pendingTime = nil
                        windowStart = Date()
                    }

                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let value = try Self.decode(message)
                        // 桥把超大帧（如 2.4MB 的 session/follow snapshot）拆成多条 chunk。
                        guard let payload = assembler.accept(value) else { continue }
                        switch payload["op"]?.stringValue {
                        case "item":
                            guard let item = payload["value"] else { continue }
                            if let snapshot = Self.snapshot(from: item) {
                                flushMergedChunk()
                                yieldFrame(.snapshot(
                                    events: snapshot.events,
                                    cursor: snapshot.cursor,
                                    hasMore: snapshot.hasMore
                                ))
                            } else if item["type"]?.stringValue == "assistant-stream" {
                                let frame = item["frame"]
                                let phase = frame?["type"]?.stringValue ?? ""
                                switch phase {
                                case "start":
                                    flushMergedChunk()
                                    pendingTurn = frame?["turn"]?.intValue ?? 0
                                    pendingStep = frame?["step"]?.intValue ?? 0
                                    windowStart = Date()
                                    yieldFrame(.stream(item))
                                case "chunk":
                                    if pendingTurn == 0, pendingStep == 0 {
                                        pendingTurn = frame?["turn"]?.intValue ?? 0
                                        pendingStep = frame?["step"]?.intValue ?? 0
                                    }
                                    let chunk = frame?["chunk"]
                                    if let text = chunk?["text"]?.stringValue ?? chunk?["delta"]?.stringValue, !text.isEmpty {
                                        if chunk?["type"]?.stringValue == "reasoning-delta" {
                                            pendingReasoning += text
                                        } else {
                                            pendingText += text
                                        }
                                    }
                                    if let reasoning = chunk?["reasoning"]?.stringValue, !reasoning.isEmpty {
                                        pendingReasoning += reasoning
                                    }
                                    if let time = frame?["time"]?.intValue { pendingTime = time }
                                    if Date().timeIntervalSince(windowStart) >= 0.1 {
                                        flushMergedChunk()
                                    }
                                case "end":
                                    flushMergedChunk()
                                    yieldFrame(.stream(item))
                                default:
                                    flushMergedChunk()
                                    yieldFrame(.stream(item))
                                }
                            } else {
                                flushMergedChunk()
                                if let event = FoldEvent.decode(item) {
                                    yieldFrame(.event(event))
                                } else if let wrapped = item["event"], let event = FoldEvent.decode(wrapped) {
                                    yieldFrame(.event(event))
                                }
                            }
                        case "end":
                            flushMergedChunk()
                            continuation.finish()
                            socket.cancel(with: .normalClosure, reason: nil)
                            return
                        case "error":
                            let error = value["error"]
                            throw BridgeError(
                                code: error?["code"]?.stringValue ?? "stream/failed",
                                message: error?["message"]?.stringValue ?? "流异常结束"
                            )
                        default:
                            break
                        }
                    }
                    flushMergedChunk()
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                socket.cancel(with: .goingAway, reason: nil)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    private func endpointURL(host: URL, path: String) -> URL {
        var components = URLComponents()
        components.scheme = host.scheme ?? "https"
        components.host = host.host
        components.port = host.port
        components.path = path
        return components.url ?? host
    }

    /// URLSessionWebSocketTask 只接受 ws / wss：http → ws，https → wss。
    private func webSocketURL(host: URL, path: String) -> URL {
        var components = URLComponents()
        components.scheme = (host.scheme?.lowercased() == "https") ? "wss" : "ws"
        components.host = host.host
        components.port = host.port
        components.path = path
        return components.url ?? host
    }

    private func makeRequest(url: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-bridge-key")
        }
        return request
    }

    private func get(url: URL, key: String?) async throws -> Data {
        try await send(makeRequest(url: url, key: key), body: nil)
    }

    private func send(_ request: URLRequest, body: Data?) async throws -> Data {
        var request = request
        request.httpBody = body
        let (data, response) = try await session.data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError(code: "bridge/bad-response", message: "桥返回了无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw BridgeError(code: "unauthorized", message: "桥要求访问密钥（x-bridge-key）")
            }
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw envelope.error
            }
            throw BridgeError(code: "http/\(http.statusCode)", message: "HTTP \(http.statusCode)")
        }
        return data
    }

    private static func send(_ socket: URLSessionWebSocketTask, _ value: JSONValue) async throws {
        try await socket.send(.string(value.rawText))
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> JSONValue {
        switch message {
        case .string(let text):
            guard let value = JSONValue.parse(text) else {
                throw BridgeError(code: "protocol/invalid-json", message: "无法解析桥的帧")
            }
            return value
        case .data(let data):
            return try JSONDecoder().decode(JSONValue.self, from: data)
        @unknown default:
            throw BridgeError(code: "protocol/unknown-frame", message: "未知的 WebSocket 帧")
        }
    }

    struct SnapshotPayload: Sendable {
        var events: [FoldEvent]
        var cursor: Int?
        var hasMore: Bool
    }

    /// `session/follow` 首帧：`{type:"snapshot", header, cursor, records:[{type:"event", event:{type,seq,data}}]}`。
    private static func snapshot(from value: JSONValue) -> SnapshotPayload? {
        let snapshot = value["snapshot"] ?? value
        let isSnapshot = snapshot["type"]?.stringValue == "snapshot"
            || snapshot["kind"]?.stringValue == "snapshot"
            || snapshot["type"]?.stringValue == "session/snapshot"
            || value["snapshot"] != nil
        guard isSnapshot else { return nil }
        let records = snapshot["records"]?.arrayValue
            ?? snapshot["events"]?.arrayValue
            ?? snapshot["items"]?.arrayValue
            ?? []
        let events = Self.recordsToEvents(records)
        let cursor = snapshot["cursor"]?.intValue
        let hasMore = snapshot["hasMore"]?.boolValue
            ?? (events.first.map { $0.seq > 0 } ?? false)
        return SnapshotPayload(events: events, cursor: cursor, hasMore: hasMore)
    }

    private static func recordsToEvents(_ records: [JSONValue]) -> [FoldEvent] {
        records.compactMap { record in
            if let event = record["event"] { return FoldEvent.decode(event) }
            return FoldEvent.decode(record)
        }
    }

    private struct ErrorEnvelope: Decodable {
        var error: BridgeError
    }
}

/// 上传进度回调（URLSessionTaskDelegate 要求 NSObject）。
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }
}
