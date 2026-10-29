import Foundation

/// 一台被手机管理的电脑（一台 DSH 宿主 = 一个桥 = 一台机器）。
struct Machine: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case macOS = "macos"
        case windows = "windows"
        case linux = "linux"
        case unknown = "unknown"

        var label: String {
            switch self {
            case .macOS: return "macOS"
            case .windows: return "Windows"
            case .linux: return "Linux"
            case .unknown: return "未知系统"
            }
        }

        var symbolName: String {
            switch self {
            case .macOS: return "laptopcomputer"
            case .windows: return "pc"
            case .linux: return "server.rack"
            case .unknown: return "desktopcomputer"
            }
        }

        static func from(platform: String?) -> Kind {
            switch platform?.lowercased() {
            case "darwin", "macos", "mac": return .macOS
            case "win32", "windows": return .windows
            case "linux": return .linux
            default: return .unknown
            }
        }
    }

    var id: String
    var name: String
    /// 桥的基地址，例如 `https://mac.tailnet.ts.net`。
    var host: String
    var kind: Kind
    var bridgeVersion: String?
    var dshVersion: String?
    var protocolVersion: Int?
    var addedAt: Date
    var isDemo: Bool

    var url: URL? { URL(string: host) }

    var shortHost: String {
        guard let url else { return host }
        return url.host ?? host
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        kind: Kind,
        bridgeVersion: String? = nil,
        dshVersion: String? = nil,
        protocolVersion: Int? = 1,
        addedAt: Date = Date(),
        isDemo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.kind = kind
        self.bridgeVersion = bridgeVersion
        self.dshVersion = dshVersion
        self.protocolVersion = protocolVersion
        self.addedAt = addedAt
        self.isDemo = isDemo
    }
}
