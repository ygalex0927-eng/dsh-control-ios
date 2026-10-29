import Foundation

struct BridgeError: Codable, Error, Hashable, Sendable {
    var code: String
    var message: String
    var details: JSONValue?

    init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? "bridge/unknown"
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? "桥返回了未知错误"
        details = try? container.decodeIfPresent(JSONValue.self, forKey: .details)
    }

    enum CodingKeys: String, CodingKey {
        case code, message, details
    }
}

/// `GET /v1/hello`（唯一免鉴权接口）
struct BridgeHello: Codable, Sendable {
    struct BridgeInfo: Codable, Sendable {
        var version: String?
        var protocolNumber: Int?
        var capabilities: [String]?

        enum CodingKeys: String, CodingKey {
            case version
            case protocolNumber = "protocol"
            case capabilities
        }
    }

    struct MachineInfo: Codable, Sendable {
        var name: String?
        var platform: String?
        var arch: String?
    }

    struct DshInfo: Codable, Sendable {
        var origin: String?
        var version: String?
        var clientId: String?
        var connected: Bool?
    }

    var protocolVersion: Int
    var bridge: BridgeInfo?
    var machine: MachineInfo?
    var dsh: DshInfo?
    var pairedDevices: Int?
    var tailnetUrl: String?
    /// 桥自报的鉴权状态（默认零鉴权；有值也只是展示用）。
    var auth: JSONValue?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case bridge, machine, dsh, pairedDevices, tailnetUrl, auth
    }

    func makeMachine(host: String) -> Machine {
        Machine(
            id: "\(host)#\(machine?.name ?? "unknown")",
            name: machine?.name ?? (URL(string: host)?.host ?? "未知机器"),
            host: host,
            kind: Machine.Kind.from(platform: machine?.platform),
            bridgeVersion: bridge?.version,
            dshVersion: dsh?.version,
            protocolVersion: protocolVersion,
            isDemo: false
        )
    }
}

/// `GET /v1/health`
struct BridgeHealth: Decodable, Sendable {
    struct PendingCounts: Decodable, Sendable {
        var approvals: Int?
        var questions: Int?
        var total: Int?

        var count: Int { total ?? ((approvals ?? 0) + (questions ?? 0)) }
    }

    struct DeviceInfo: Decodable, Identifiable, Sendable {
        var id: String
        var name: String?
        var lastSeenAt: String?
    }

    var ok: Bool
    var machine: BridgeHello.MachineInfo?
    var dsh: BridgeHello.DshInfo?
    var pendingCount: Int
    var devices: [DeviceInfo]?

    var isDshConnected: Bool { dsh?.connected ?? ok }

    enum CodingKeys: String, CodingKey {
        case ok, machine, dsh, pending, devices
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        machine = try? container.decodeIfPresent(BridgeHello.MachineInfo.self, forKey: .machine)
        dsh = try? container.decodeIfPresent(BridgeHello.DshInfo.self, forKey: .dsh)
        devices = try? container.decodeIfPresent([DeviceInfo].self, forKey: .devices)
        if let int = try? container.decodeIfPresent(Int.self, forKey: .pending) {
            pendingCount = int
        } else if let counts = try? container.decodeIfPresent(PendingCounts.self, forKey: .pending) {
            pendingCount = counts.count
        } else {
            pendingCount = 0
        }
    }
}

struct RPCRequest: Encodable, Sendable {
    var id: String
    var endpoint: String
    var args: JSONValue
}

struct RPCResponse: Decodable, Sendable {
    var id: String?
    var ok: Bool
    var value: JSONValue?
    var error: BridgeError?
}

/// `WS /v1/events` 的下行帧
enum BridgeEventFrame: Sendable {
    case ready(clientId: String, home: String?)
    case emit(name: String, args: [JSONValue])
    case request(eventId: String, name: String, agentId: String?, request: JSONValue)
    case cancel(eventId: String)
    case unknown(op: String)

    static func decode(_ value: JSONValue) -> BridgeEventFrame? {
        guard let op = value["op"]?.stringValue else { return nil }
        switch op {
        case "ready":
            return .ready(
                clientId: value["clientId"]?.stringValue ?? "",
                home: value["host"]?["home"]?.stringValue
            )
        case "emit":
            return .emit(
                name: value["event"]?.stringValue ?? "",
                args: value["args"]?.arrayValue ?? []
            )
        case "request":
            return .request(
                eventId: value["eventId"]?.stringValue ?? "",
                name: value["event"]?.stringValue ?? "",
                agentId: value["agentId"]?.stringValue,
                request: value["request"] ?? .object([:])
            )
        case "cancel":
            return .cancel(eventId: value["eventId"]?.stringValue ?? "")
        default:
            return .unknown(op: op)
        }
    }
}

struct EventResultFrame: Encodable, Sendable {
    var op: String = "result"
    var eventId: String
    var outcome: JSONValue

    static func result(eventId: String, value: JSONValue) -> EventResultFrame {
        EventResultFrame(eventId: eventId, outcome: ["kind": "result", "value": value])
    }

    static func next(eventId: String) -> EventResultFrame {
        EventResultFrame(eventId: eventId, outcome: ["kind": "next"])
    }

    static func rejected(eventId: String, code: String, message: String) -> EventResultFrame {
        EventResultFrame(eventId: eventId, outcome: ["kind": "rejected", "error": ["code": .string(code), "message": .string(message)]])
    }
}
