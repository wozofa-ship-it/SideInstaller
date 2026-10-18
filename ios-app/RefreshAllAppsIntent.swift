import AppIntents
import UIKit
import Foundation

extension Notification.Name {
    static let refreshAllApps = Notification.Name("sideinstaller.refreshAllApps")
}

/// Shortcuts action: Resign all sideloaded apps.
/// Opens the app via URL; the app handles the refresh in foreground.
struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "全部续签"
    static var description = IntentDescription("重新签名所有侧载应用，延长7天有效期")
    
    static var openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult {
        // Open the app with refresh-all URL
        guard let url = URL(string: "sideinstaller://refresh-all") else {
            throw IntentError.message("无法构造续签链接")
        }
        await UIApplication.shared.open(url)
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
