//
//  BuiltinTunnel.swift
//  Side+
//
//  Side+ 自带的本地隧道：Packet Tunnel 扩展（TunnelProv，移植自开源的
//  LocalDevVPN —— 同为 SideStore 团队的 StosVPN 许可）建一条
//  10.7.0.0/24 的回环隧道，扩展把发往 10.7.0.1 的包原路反射回来，
//  minimuxer 因此能连上本机的 lockdown 服务，地址与 LocalDevVPN
//  完全一致，Engine/NetworkStatus 那侧不用改。
//
//  需要隧道时 Engine.tunnelUp() 先走这里；起不来（比如签名把网络
//  扩展权限剥掉了）才回退去唤起独立装的 LocalDevVPN。
//

import Foundation
import NetworkExtension

enum BuiltinTunnel {

    /// 扩展的 Bundle ID：主 App 的 ID + ".TunnelProv"（与 project.yml
    /// 里 TunnelProv 目标的 PRODUCT_BUNDLE_IDENTIFIER 必须一致）。
    static var providerBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.frizzle.sideinstaller") + ".TunnelProv"
    }

    /// 扩展在包里是否真的存在（PlugIns/TunnelProv.appex）。
    static var isBundled: Bool {
        Bundle.main.path(forResource: "TunnelProv", ofType: "appex", inDirectory: "PlugIns") != nil
    }

    /// 确保内置隧道已连接：没有配置就建（首次会弹系统的 VPN 许可
    /// 提示），已在连/已连上直接等结果。给两次机会：第一次若是刚
    /// 保存完配置、系统还没就绪而失败，重新读一遍配置再启一次。
    /// 成功返回 true；两次都失败返回 false，交给调用方回退
    /// LocalDevVPN。失败原因写进 App 日志，方便定位。
    @MainActor
    static func startAndWait(timeout: TimeInterval = 10) async -> Bool {
        guard isBundled else {
            Engine.shared.log("Built-in tunnel: TunnelProv.appex is missing from the app bundle.")
            return false
        }
        for attempt in 1...2 {
            let manager: NETunnelProviderManager
            do {
                manager = try await loadOrCreateManager()
            } catch {
                Engine.shared.log("Built-in tunnel: load/create configuration failed on attempt \(attempt): \(error.localizedDescription)")
                continue
            }
            if manager.connection.status == .connected { return true }
            do {
                try manager.connection.startVPNTunnel()
            } catch {
                Engine.shared.log("Built-in tunnel: startVPNTunnel failed on attempt \(attempt): \(error.localizedDescription) (enabled=\(manager.isEnabled))")
                continue
            }
            let deadline = Date().addingTimeInterval(timeout)
            var invalid = false
            while Date() < deadline, !invalid {
                switch manager.connection.status {
                case .connected:
                    return true
                case .invalid:
                    invalid = true
                default:
                    break
                }
                if !invalid {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                if Task.isCancelled { return false }
            }
            if invalid {
                Engine.shared.log("Built-in tunnel: connection went invalid on attempt \(attempt).")
            }
        }
        Engine.shared.log("Built-in tunnel: not connected after 2 attempts.")
        return false
    }

    /// 找到我们自己的 VPN 配置；没有就按 LocalDevVPN 的默认地址建
    /// 一份（接口 10.7.1.1/32、对端 10.7.0.1/32 —— minimuxer 连的
    /// 就是对端地址，不能改）。
    private static func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        }) {
            // 已有配置若是禁用状态，startVPNTunnel 会立刻抛
            // NEVPNErrorDomain error 2（ConfigurationDisabled）：
            // 先启用、保存、重读，再交给启动流程。
            if !existing.isEnabled {
                existing.isEnabled = true
                try await existing.saveToPreferences()
                try await existing.loadFromPreferences()
                Engine.shared.log("Built-in tunnel: existing configuration was disabled; re-enabled it.")
            }
            return existing
        }
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = String(TunnelConstants.defaultPeerIP.split(separator: "/").first ?? "10.7.0.1")
        proto.providerConfiguration = [
            TunnelConstants.ifaceIPConfigurationKey: TunnelConstants.defaultIfaceIP,
            TunnelConstants.peerIPConfigurationKey: TunnelConstants.defaultPeerIP,
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Side+ Tunnel"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }
}
