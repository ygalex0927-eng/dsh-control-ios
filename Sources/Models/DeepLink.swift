import Foundation

/// 添加机器的深链：`dshcontrol://add?host=<url>[&key=<可选访问密钥>]`。
///
/// 旧版配对链接 `dshcontrol://pair?host=<url>&code=…&fp=…` 仍兼容解析，
/// 但只取 `host`（用户一个人用，不再做配对码/设备校验）。
struct MachineLink: Equatable, Sendable {
    static let scheme = "dshcontrol"

    var host: URL
    /// 可选的桥访问密钥；桥默认零鉴权时留空。
    var key: String?

    var displayHost: String { host.host ?? host.absoluteString }

    static func parse(_ raw: String) -> MachineLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == scheme else { return nil }

        let action = (components.host ?? "").lowercased()
        let path = components.path.lowercased()
        let isAdd = action == "add" || path == "/add" || path == "add"
        let isLegacyPair = action == "pair" || path == "/pair" || path == "pair"
        guard isAdd || isLegacyPair else { return nil }

        let query = Dictionary(
            components.queryItems?.compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name.lowercased(), value)
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )

        guard let hostText = query["host"],
              let hostURL = normalizedURL(hostText)
        else { return nil }

        let key = query["key"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MachineLink(host: hostURL, key: (key?.isEmpty == true) ? nil : key)
    }

    /// 也接受用户直接粘贴的裸地址，方便设置页「只输入地址」。
    static func parseAddress(_ raw: String) -> MachineLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("\(scheme)://") {
            return parse(trimmed)
        }
        guard let url = normalizedURL(trimmed) else { return nil }
        return MachineLink(host: url, key: nil)
    }

    private static func normalizedURL(_ text: String) -> URL? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://") {
            candidate = "http://" + candidate
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }
}
