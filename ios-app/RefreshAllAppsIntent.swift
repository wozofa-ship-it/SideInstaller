import AppIntents
import UIKit
import Foundation

extension Notification.Name {
    static let refreshAllApps = Notification.Name("sideinstaller.refreshAllApps")
}

/// Shortcuts action: Resign all sideloaded apps.
/// Runs in background; posts notification that the app handles.
struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "全部续签"
    static var description = IntentDescription("重新签名所有侧载应用，延长7天有效期")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult {
        // App 正开着且界面在：走原有通知路径，界面上的 manager 立即接手。
        NotificationCenter.default.post(name: .refreshAllApps, object: nil)
        // App 没开着/已被杀时通知没人接，这里自己在后台把续签跑起来
        // （与界面共用同一个 manager，靠 isRefreshing 互斥不会重复跑）。
        await SideloadedAppsManager.shared.refreshAllFromShortcut()
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let msg):
            return LocalizedStringResource(stringLiteral: msg)
        }
    }
}
