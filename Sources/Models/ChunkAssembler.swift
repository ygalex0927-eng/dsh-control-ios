import Foundation

/// 桥对超大 JSON 帧做分块发送（>200KB）：
/// `{"op":"chunk","chunkId":"uuid","index":0,"total":N,"data":"<原文片段>"}`
///
/// 手机按 chunkId 收集、按 index 拼接、JSON 解析，然后把完整帧交给原来的分发逻辑。
/// 非分块帧原样透传；未收齐的分块返回 nil（不派发）。
struct ChunkAssembler: Sendable {
    struct Pending: Sendable {
        var total: Int
        var parts: [Int: String]
        var bytes: Int
        var startedAt: Date
    }

    private(set) var pending: [String: Pending] = [:]
    private let maxPendingChunkIDs: Int
    private let maxPendingBytes: Int
    private let staleAfter: TimeInterval

    init(
        maxPendingChunkIDs: Int = 4,
        maxPendingBytes: Int = 32 * 1024 * 1024,
        staleAfter: TimeInterval = 60
    ) {
        self.maxPendingChunkIDs = maxPendingChunkIDs
        self.maxPendingBytes = maxPendingBytes
        self.staleAfter = staleAfter
    }

    /// 输入一条已解码的 WS 消息；可派发时返回完整 JSON（非分块帧原样返回）。
    mutating func accept(_ value: JSONValue) -> JSONValue? {
        guard value["op"]?.stringValue == "chunk" else { return value }
        guard let chunkId = value["chunkId"]?.stringValue,
              let index = value["index"]?.intValue,
              let total = value["total"]?.intValue,
              total > 0,
              index >= 0,
              index < total,
              let data = value["data"]?.stringValue
        else { return nil }

        dropExpired()

        var entry = pending[chunkId] ?? Pending(total: total, parts: [:], bytes: 0, startedAt: Date())
        if entry.total != total {
            // 同一 chunkId 换了 total：视为新一轮。
            entry = Pending(total: total, parts: [:], bytes: 0, startedAt: Date())
        }
        if entry.parts[index] == nil {
            entry.bytes += data.utf8.count
        }
        entry.parts[index] = data
        pending[chunkId] = entry

        guard entry.parts.count == total else {
            enforceLimits()
            return nil
        }
        guard let joined = Self.join(entry) else {
            pending.removeValue(forKey: chunkId)
            return nil
        }
        pending.removeValue(forKey: chunkId)
        return JSONValue.parse(joined)
    }

    /// 连接断开/重连时清空所有未完成分块。
    mutating func reset() {
        pending.removeAll()
    }

    private static func join(_ entry: Pending) -> String? {
        var pieces: [String] = []
        pieces.reserveCapacity(entry.total)
        for index in 0..<entry.total {
            guard let part = entry.parts[index] else { return nil }
            pieces.append(part)
        }
        return pieces.joined()
    }

    private mutating func dropExpired() {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.startedAt) < staleAfter }
    }

    private mutating func enforceLimits() {
        let totalBytes = pending.values.reduce(0) { $0 + $1.bytes }
        guard pending.count > maxPendingChunkIDs || totalBytes > maxPendingBytes else { return }
        while pending.count > maxPendingChunkIDs, let oldest = pending.min(by: { $0.value.startedAt < $1.value.startedAt }) {
            pending.removeValue(forKey: oldest.key)
        }
        while pending.values.reduce(0, { $0 + $1.bytes }) > maxPendingBytes,
              let oldest = pending.min(by: { $0.value.startedAt < $1.value.startedAt }) {
            pending.removeValue(forKey: oldest.key)
        }
    }
}
