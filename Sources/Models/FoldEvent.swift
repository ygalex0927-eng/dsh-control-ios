import Foundation

/// DSH 的 append-only 事件日志项。桥原样透传，形状是
/// `{ "type": "...", "seq": 12, "time": 1700000000000, "data": { ... } }`。
struct FoldEvent: Sendable, Hashable {
    var seq: Int
    var type: String
    var time: Date
    var data: JSONValue

    init(seq: Int, type: String, time: Date = Date(), data: JSONValue = .object([:])) {
        self.seq = seq
        self.type = type
        self.time = time
        self.data = data
    }

    static func decode(_ value: JSONValue) -> FoldEvent? {
        guard let type = value["type"]?.stringValue, let seq = value["seq"]?.intValue else {
            return nil
        }
        let time: Date
        if let millis = value["time"]?.intValue {
            time = Date(timeIntervalSince1970: Double(millis) / 1000)
        } else {
            time = Date()
        }
        return FoldEvent(seq: seq, type: type, time: time, data: value["data"] ?? .object([:]))
    }
}

/// `session/follow` 的下行帧：快照、增量事件，或临时流式帧（不落盘）。
enum SessionFrame: Sendable {
    /// 首帧快照：records 是以 seq 递增的事件；cursor 是最新 seq；hasMore 表示还有更早的历史。
    case snapshot(events: [FoldEvent], cursor: Int?, hasMore: Bool)
    case event(FoldEvent)
    /// `{type:"assistant-stream", frame:{type:"start"|"chunk"|"end", …}}`
    case stream(JSONValue)
}
