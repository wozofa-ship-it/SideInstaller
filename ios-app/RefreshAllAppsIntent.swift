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
        // Post notification - app handles it in background if kept alive,
        // or when next opened
        NotificationCenter.default.post(name: .refreshAllApps, object: nil)
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
