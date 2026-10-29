import Foundation

struct ModelEffort: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

struct ModelOption: Identifiable, Hashable, Sendable {
    var provider: String
    var providerName: String
    var model: String
    var label: String
    var efforts: [ModelEffort]
    var defaultEffort: String?

    var id: String { "\(provider)#\(model)" }
    var displayName: String { label.isEmpty ? model : label }

    func effortName(for effort: String?) -> String? {
        guard let effort, !effort.isEmpty else { return nil }
        return efforts.first(where: { $0.id == effort })?.name ?? effort
    }

    /// `DeepSeek-V4.1-Flash · high`
    func displayTitle(effort: String?) -> String {
        guard let name = effortName(for: effort) else { return displayName }
        return "\(displayName) · \(name)"
    }
}

struct ModelGroup: Identifiable, Hashable, Sendable {
    /// provider id
    var id: String
    var name: String
    var models: [ModelOption]
}

/// `session/modelCatalog`（实测形状）：
/// `{default:{provider,model,reasoningEffort}, routableProviders:[…],
///   groups:[{id,name,models:[{id,name,reasoning:{efforts:[{id,name}],defaultEffort}}]}]}`
struct ModelCatalog: Sendable, Equatable {
    var groups: [ModelGroup] = []
    var defaultProvider: String?
    var defaultModel: String?
    var defaultEffort: String?
    /// 解析时预计算好，sheet 渲染不再每行 flatMap。
    private(set) var flatOptions: [ModelOption] = []

    var options: [ModelOption] { flatOptions }
    var isEmpty: Bool { options.isEmpty }

    var defaultTitle: String? {
        // 默认 provider 可能未列在 groups 中；仅展示名称可借用同 model 的标签。
        displayTitle(provider: option(provider: defaultProvider, model: defaultModel) == nil ? nil : defaultProvider,
                     model: defaultModel, effort: defaultEffort)
    }

    func option(provider: String?, model: String?) -> ModelOption? {
        guard let model else { return nil }
        return options.first { option in
            option.model == model && (provider == nil || option.provider == provider)
        }
    }

    /// 当前选择的显示名。优先用会话里的 modelSelection，其次 catalog.default。
    func displayTitle(provider: String?, model: String?, effort: String?) -> String? {
        if let option = option(provider: provider, model: model) {
            let resolvedEffort = effort ?? option.defaultEffort
            return option.displayTitle(effort: resolvedEffort)
        }
        guard let model else { return nil }
        if let effort, !effort.isEmpty { return "\(model) · \(effort)" }
        return model
    }

    static func decode(_ value: JSONValue) -> ModelCatalog {
        var catalog = ModelCatalog()
        if let def = value["default"] {
            catalog.defaultProvider = def["provider"]?.stringValue
            catalog.defaultModel = def["model"]?.stringValue
            catalog.defaultEffort = def["reasoningEffort"]?.stringValue
        }

        var groups: [ModelGroup] = []
        for rawGroup in value["groups"]?.arrayValue ?? [] {
            let provider = rawGroup["id"]?.stringValue
                ?? rawGroup["provider"]?.stringValue
                ?? rawGroup["providerId"]?.stringValue
                ?? ""
            let groupName = rawGroup["name"]?.stringValue ?? provider
            var models: [ModelOption] = []
            for rawModel in rawGroup["models"]?.arrayValue ?? [] {
                if let modelName = rawModel.stringValue {
                    models.append(ModelOption(
                        provider: provider,
                        providerName: groupName,
                        model: modelName,
                        label: modelName,
                        efforts: [],
                        defaultEffort: nil
                    ))
                    continue
                }
                guard let modelId = rawModel["id"]?.stringValue ?? rawModel["model"]?.stringValue else { continue }
                let label = rawModel["name"]?.stringValue ?? rawModel["displayName"]?.stringValue ?? modelId
                let reasoning = rawModel["reasoning"]
                let efforts = (reasoning?["efforts"]?.arrayValue ?? []).compactMap { rawEffort -> ModelEffort? in
                    if let effortId = rawEffort.stringValue {
                        return ModelEffort(id: effortId, name: effortId)
                    }
                    guard let effortId = rawEffort["id"]?.stringValue else { return nil }
                    return ModelEffort(id: effortId, name: rawEffort["name"]?.stringValue ?? effortId)
                }
                models.append(ModelOption(
                    provider: provider,
                    providerName: groupName,
                    model: modelId,
                    label: label,
                    efforts: efforts,
                    defaultEffort: reasoning?["defaultEffort"]?.stringValue
                ))
            }
            guard !models.isEmpty else { continue }
            groups.append(ModelGroup(id: provider, name: groupName, models: models))
        }
        catalog.groups = groups
        catalog.flatOptions = groups.flatMap(\.models)
        return catalog
    }
}
