import Foundation

/// 机器运行状态。`busy` = agent 正在跑，`online` = 空闲在线。
enum MachineState: String, Codable, Sendable, CaseIterable {
    case online
    case busy
    case offline
    case unknown

    var label: String {
        switch self {
        case .online: return "在线"
        case .busy: return "忙碌"
        case .offline: return "离线"
        case .unknown: return "未知"
        }
    }

    var isReachable: Bool { self == .online || self == .busy }
}

/// 同一台机器的状态会从多个来源到达（缓存、hello、health、事件），
/// 合并规则：新观测覆盖旧观测；时间相同时来源优先级高者胜。
struct MachineObservation: Sendable, Equatable {
    enum Source: Int, Sendable, Comparable {
        case cache = 0
        case hello = 1
        case health = 2
        case event = 3

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var machineId: String
    var state: MachineState
    var pendingCount: Int?
    var sessionCount: Int?
    var at: Date
    var source: Source
}

struct MachineRuntime: Sendable, Equatable {
    var state: MachineState = .unknown
    var pendingCount: Int = 0
    var sessionCount: Int = 0
    var updatedAt: Date = .distantPast

    var reachable: Bool { state.isReachable }
}

enum MachineStatusMerger {
    /// 按时间升序应用观测，后到的覆盖先到的；缺失的计数信息沿用上一次观测。
    static func merge(_ observations: [MachineObservation]) -> [String: MachineRuntime] {
        let sorted = observations.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.source < rhs.source
        }

        var result: [String: MachineRuntime] = [:]
        for observation in sorted {
            var runtime = result[observation.machineId] ?? MachineRuntime()
            runtime.state = observation.state
            if let pending = observation.pendingCount { runtime.pendingCount = pending }
            if let sessions = observation.sessionCount { runtime.sessionCount = sessions }
            runtime.updatedAt = observation.at
            result[observation.machineId] = runtime
        }
        return result
    }

    static func aggregate(_ runtimes: [String: MachineRuntime]) -> (online: Int, busy: Int, pending: Int) {
        var online = 0
        var busy = 0
        var pending = 0
        for runtime in runtimes.values {
            if runtime.state == .online { online += 1 }
            if runtime.state == .busy { busy += 1 }
            pending += runtime.pendingCount
        }
        return (online, busy, pending)
    }
}
