import Foundation

/// 会话级 token 用量（`session/list` 的 `projections.values.tokenUsage`）。
struct TokenUsage: Codable, Hashable, Sendable {
    var uncachedInputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int

    /// 每条 `assistant/message` 的 `data.usage`。
    var inputTokens: Int?
    var totalTokens: Int?

    init(
        uncachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        inputTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.inputTokens = inputTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, inputTokens, totalTokens
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uncachedInputTokens = (try? container.decodeIfPresent(Int.self, forKey: .uncachedInputTokens)) ?? 0
        outputTokens = (try? container.decodeIfPresent(Int.self, forKey: .outputTokens)) ?? 0
        cacheReadTokens = (try? container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)) ?? 0
        cacheWriteTokens = (try? container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens)) ?? 0
        inputTokens = try? container.decodeIfPresent(Int.self, forKey: .inputTokens)
        totalTokens = try? container.decodeIfPresent(Int.self, forKey: .totalTokens)
    }

    static func decode(_ value: JSONValue?) -> TokenUsage? {
        guard let value else { return nil }
        let usage = TokenUsage(
            uncachedInputTokens: value["uncachedInputTokens"]?.intValue ?? 0,
            outputTokens: value["outputTokens"]?.intValue ?? 0,
            cacheReadTokens: value["cacheReadTokens"]?.intValue ?? 0,
            cacheWriteTokens: value["cacheWriteTokens"]?.intValue ?? 0,
            inputTokens: value["inputTokens"]?.intValue,
            totalTokens: value["totalTokens"]?.intValue
        )
        if usage.uncachedInputTokens == 0, usage.outputTokens == 0, usage.cacheReadTokens == 0,
           usage.cacheWriteTokens == 0, usage.totalTokens == nil, usage.inputTokens == nil {
            return nil
        }
        return usage
    }

    /// `↑340.2k · ↓301.9k · 缓存 139.4M`（输入拆成未缓存 + 缓存读两段，跟电脑一致）
    var compactLine: String {
        var parts: [String] = []
        let uncached = uncachedInputTokens > 0 ? uncachedInputTokens : (inputTokens ?? totalTokens ?? 0)
        if uncached > 0 { parts.append("↑\(TokenFormat.human(uncached))") }
        if outputTokens > 0 { parts.append("↓\(TokenFormat.human(outputTokens))") }
        if cacheReadTokens > 0 { parts.append("缓存 \(TokenFormat.human(cacheReadTokens))") }
        return parts.joined(separator: " · ")
    }
}

/// `projections.values.sessionStats`。
struct SessionStats: Codable, Hashable, Sendable {
    var turns: Int
    var steps: Int
    var llmMs: Int
    var toolMs: Int
    var ttftMs: Int
    var ttftSteps: Int
    var decodeMs: Int
    var decodeTokens: Int

    static func decode(_ value: JSONValue?) -> SessionStats? {
        guard let value else { return nil }
        let stats = SessionStats(
            turns: value["turns"]?.intValue ?? 0,
            steps: value["steps"]?.intValue ?? 0,
            llmMs: value["llmMs"]?.intValue ?? 0,
            toolMs: value["toolMs"]?.intValue ?? 0,
            ttftMs: value["ttftMs"]?.intValue ?? 0,
            ttftSteps: value["ttftSteps"]?.intValue ?? 0,
            decodeMs: value["decodeMs"]?.intValue ?? 0,
            decodeTokens: value["decodeTokens"]?.intValue ?? 0
        )
        if stats.turns == 0, stats.steps == 0, stats.llmMs == 0, stats.toolMs == 0 { return nil }
        return stats
    }

    var averageTTFTMs: Int? { ttftSteps > 0 ? ttftMs / ttftSteps : nil }
    var tokensPerSecond: Double? { decodeMs > 0 ? Double(decodeTokens) / (Double(decodeMs) / 1000) : nil }
    var cacheHitRate: Double? {
        let total = decodeTokens
        return total > 0 ? nil : nil
    }
}

enum TokenFormat {
    /// 329_100 → "329.1k"；131_500_000 → "131.5M"；987 → "987"。
    static func human(_ value: Int) -> String {
        let number = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        switch number {
        case 1_000_000_000...:
            return sign + String(format: "%.1fB", number / 1_000_000_000)
        case 1_000_000...:
            return sign + String(format: "%.1fM", number / 1_000_000)
        case 1_000...:
            return sign + String(format: "%.1fk", number / 1_000)
        default:
            return sign + String(Int(number))
        }
    }
}

enum DurationFormat {
    /// 4.234 → "4.2s"；75 → "1m15s"。
    static func compact(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 1 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes)m\(rest)s"
    }
}
