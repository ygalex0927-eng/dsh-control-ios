import Foundation
import Security

/// 已添加机器的持久化（URL 等非敏感信息）。
struct MachineStore {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("DSHControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("machines.json")
    }

    func load() -> [Machine] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Machine].self, from: data)) ?? []
    }

    func save(_ machines: [Machine]) {
        let persisted = machines.filter { !$0.isDemo }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 每台机器可选的桥访问密钥（`x-bridge-key`）。
/// 桥默认零鉴权，所以大多数机器这里没有值。旧版的设备 token 仍留在 Keychain 里，
/// 这里不读也不删（另一个 service 名），避免动用户已有数据。
enum KeychainKeyStore {
    private static let service = "dev.dsh.control.bridge-key"

    private static func baseQuery(for machineId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: machineId,
        ]
    }

    static func key(for machineId: String) -> String? {
        var query = baseQuery(for: machineId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, for machineId: String) {
        guard let data = key.data(using: .utf8) else { return }
        let query = baseQuery(for: machineId)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(for machineId: String) {
        SecItemDelete(baseQuery(for: machineId) as CFDictionary)
    }
}

@MainActor
final class BridgeKeyStore {
    static let shared = BridgeKeyStore()

    func key(for machineId: String) -> String? { KeychainKeyStore.key(for: machineId) }
    func set(_ key: String, for machineId: String) { KeychainKeyStore.set(key, for: machineId) }
    func remove(for machineId: String) { KeychainKeyStore.remove(for: machineId) }
}
