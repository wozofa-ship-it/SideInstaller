import Foundation
import UserNotifications

/// 常驻后台自动续签（照 Seal 的配方拼现成件）：无声音频＋定位双保活让进程
/// 留在后台，每 30 分钟巡检一次；描述文件 3 天内到期且隧道已连上时，只续
/// 到期的那几个。两轮自动续签至少间隔 6 小时，避免反复打扰苹果接口。
/// 隧道没通时不硬跑：清单里有今天/明天就过期的 App 时，一天最多提醒一次。
@MainActor
final class AutoRefreshService {

    static let shared = AutoRefreshService()

    /// 设置页开关的 UserDefaults 键（SettingsView 的 @AppStorage 用同一键）。
    static let enabledKey = "SIDAutoRefreshEnabled"
    private static let lastRoundKey = "SIDAutoRefreshLastRound"
    private static let lastAlertKey = "SIDAutoRefreshLastAlert"

    /// 巡检间隔：30 分钟。
    private static let checkInterval: UInt64 = 30 * 60 * 1_000_000_000
    /// 两轮自动续签的最小间隔：6 小时。
    private static let minRoundInterval: TimeInterval = 6 * 3600
    /// 到期提醒（隧道没通时）的最小间隔：12 小时。
    private static let minAlertInterval: TimeInterval = 12 * 3600

    private let keepAlive = KeepAlive()
    private var loopTask: Task<Void, Never>?
    private var isRunning = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// 开关开着且巡检没在跑时启动：双保活＋巡检循环。重复调用无副作用。
    func start() {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        keepAlive.startAudio()
        keepAlive.startLocation()
        Engine.shared.log("Auto refresh: resident patrol started.")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: Self.checkInterval)
            }
        }
    }

    /// 停巡检并撤双保活。正在跑的续签由 manager 自己的保活撑完，不受影响。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        keepAlive.stopAll()
        Engine.shared.log("Auto refresh: resident patrol stopped.")
    }

    /// 设置页开关变化时调用：开→启动，关→停止。
    func applySetting() {
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: - 巡检

    private func tick() async {
        let manager = SideloadedAppsManager.shared
        let engine = Engine.shared
        guard isEnabled, !manager.isRefreshing, !engine.isRunning else { return }

        engine.refreshNetworkStatus()
        guard engine.vpnConnected else {
            await alertIfCritical(manager: manager)
            return
        }

        // 读一次设备清单（安静模式，失败就等下一轮）。
        manager.load(quiet: true)
        for _ in 0..<40 {
            if !manager.isWorking { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard manager.hasLoaded, !manager.isRefreshing else { return }

        // 可续签的 App 里，描述文件已过期或 3 天内到期的才算到期。
        let dueIDs = Set(manager.refreshable.filter { job in
            guard let entry = manager.entries.first(where: { $0.app.bundleID == job.bundleID })
            else { return false }
            switch ExpiryUrgency.of(entry.current) {
            case .expired, .critical, .soon: return true
            default: return false
            }
        }.map(\.bundleID))
        guard !dueIDs.isEmpty else { return }

        // 最短间隔：上一轮自动续签在 6 小时内就不重复跑。
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastRoundKey)
        guard now - last >= Self.minRoundInterval else { return }
        UserDefaults.standard.set(now, forKey: Self.lastRoundKey)

        engine.log("Auto refresh: \(dueIDs.count) app(s) due within 3 days; refreshing.")
        manager.refreshAll(onlyBundleIDs: dueIDs)
    }

    /// 隧道没通时没法续签；若已加载的清单显示有 App 今天/明天就过期，
    /// 12 小时最多提醒一次，让用户去连 LocalDevVPN。
    private func alertIfCritical(manager: SideloadedAppsManager) async {
        guard manager.hasLoaded else { return }
        let critical = manager.entries.filter {
            switch ExpiryUrgency.of($0.current) {
            case .expired, .critical: return true
            default: return false
            }
        }
        guard !critical.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastAlertKey)
        guard now - last >= Self.minAlertInterval else { return }
        UserDefaults.standard.set(now, forKey: Self.lastAlertKey)
        await postNotification(
            title: L("续签提醒"),
            body: L("有 %d 个应用即将过期，但 LocalDevVPN 未连接。连接后将自动续签。", critical.count))
    }

    private func postNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "resign-auto-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
