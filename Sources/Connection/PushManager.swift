import Foundation
import UserNotifications
import UIKit

/// 推送注册状态。M1 只做到「申请授权 + 拿 APNs token + 展示状态」；
/// token 上报桥走 `POST /v1/push/register`（真机联调时打开）。
@MainActor
final class PushManager: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deviceToken: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isRegistered = false
    /// 手机上启用的推送开关（本地偏好；真机时同步给桥）。
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "dsh.push.enabled") }
    }

    private var observers: [NSObjectProtocol] = []

    init() {
        enabled = UserDefaults.standard.object(forKey: "dsh.push.enabled") as? Bool ?? true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .pushTokenReceived, object: nil, queue: .main) { [weak self] note in
            let token = note.object as? String
            Task { @MainActor in
                self?.deviceToken = token
                self?.isRegistered = token != nil
            }
        })
        observers.append(center.addObserver(forName: .pushTokenFailed, object: nil, queue: .main) { [weak self] note in
            let message = note.object as? String
            Task { @MainActor in
                self?.lastError = message
                self?.isRegistered = false
            }
        })
    }

    var statusLabel: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return isRegistered ? "已开启" : "已授权，等待 APNs token"
        case .denied:
            return "系统已关闭"
        case .notDetermined:
            return "未申请"
        @unknown default:
            return "未知"
        }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorization()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                lastError = "系统设置里关闭了通知权限"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .pushTokenReceived, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(name: .pushTokenFailed, object: error.localizedDescription)
    }
}

extension Notification.Name {
    static let pushTokenReceived = Notification.Name("dsh.push.token.received")
    static let pushTokenFailed = Notification.Name("dsh.push.token.failed")
}
