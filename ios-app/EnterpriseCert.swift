import Foundation
import Security
import SideInstallerFFI
import SwiftUI
import UniformTypeIdentifiers

/// 企业证书签名的材料存储：.p12 与 .mobileprovision 复制进
/// App 自己的支持目录，密码存钥匙串（Keychain，不再是明文
/// UserDefaults）。注意：这里是导入证书时填的密码，和证书页
/// 导出个人证书 p12 的密码“1”完全是两回事，那处在
/// rust-core/src/certs.rs 里，本文件不碰它。
enum EnterpriseCertStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnterpriseCert", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static var p12URL: URL { dir.appendingPathComponent("cert.p12") }
    static var provisionURL: URL { dir.appendingPathComponent("profile.mobileprovision") }
    static var hasP12: Bool { FileManager.default.fileExists(atPath: p12URL.path) }
    static var hasProvision: Bool { FileManager.default.fileExists(atPath: provisionURL.path) }
    static var password: String {
        get {
            if let stored = keychainRead() { return stored }
            if let fallback = memoryFallback { return fallback }
            // 一次性迁移：旧版存在 UserDefaults 的明文密码搬进
            // 钥匙串后清掉旧键，之后再读就只走钥匙串。
            let legacy = UserDefaults.standard.string(forKey: "CZFEnterpriseCertPassword") ?? ""
            if !legacy.isEmpty {
                if keychainWrite(legacy) == nil {
                    UserDefaults.standard.removeObject(forKey: "CZFEnterpriseCertPassword")
                } else {
                    // 钥匙串写不进：先留内存给本次用，旧键也留着，
                    // 下次启动再试迁移，免得密码丢了要重填。
                    memoryFallback = legacy
                }
                return legacy
            }
            return ""
        }
        set {
            UserDefaults.standard.removeObject(forKey: "CZFEnterpriseCertPassword")
            if newValue.isEmpty {
                keychainDelete()
                memoryFallback = nil
            } else {
                // 钥匙串万一写不进（极少见），只留在内存里撑到
                // App 退出，不回写 UserDefaults 明文。
                memoryFallback = keychainWrite(newValue) == nil ? nil : newValue
            }
        }
    }
    /// 钥匙串写失败时的当会话 fallback（AccountStore 的
    /// volatilePasswords 同款做法），App 退出即丢。
    private static var memoryFallback: String?
    static var ready: Bool { hasP12 && hasProvision && !password.isEmpty }

    // MARK: - 钥匙串（AccountStore 的 Keychain 模板同款）

    private static var keychainService: String { "czf.enterprise.cert" }
    private static var keychainAccount: String { "password" }

    private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func keychainRead() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 成功返回 nil，失败返回 OSStatus（调用方据此决定要不要
    /// 用内存 fallback）。
    private static func keychainWrite(_ value: String) -> OSStatus? {
        let data = Data(value.utf8)
        let update = SecItemUpdate(keychainQuery() as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return nil }
        guard update == errSecItemNotFound else { return update }
        var add = keychainQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess ? nil : status
    }

    private static func keychainDelete() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    static func importP12(from url: URL) throws {
        try Data(contentsOf: url).write(to: p12URL, options: .atomic)
    }
    static func importProvision(from url: URL) throws {
        try Data(contentsOf: url).write(to: provisionURL, options: .atomic)
    }

    /// 已导入描述文件的信息（名称/团队/到期），证书页展示用。
    struct ProvisionInfo {
        let name: String
        let teamName: String
        /// TeamIdentifier 数组的第一个（团队 ID，如 HP24Y7433B），没有就 ""。
        let teamID: String
        let expiration: Date?
        let uuid: String
        /// ProvisionedDevices 数组长度：企业描述文件通常没有这一项
        ///（0 = 不限设备）；开发/AdHoc 描述文件有，长度就是限定台数。
        /// ProvisionedDevices 数组本身：证书页拿它跟本机 UDID 比对，
        /// 断言本机在不在列表里（轻松签同款）；本机 UDID 用
        /// MobileGestalt 的 MGCopyAnswer 读（轻松签二进制实证同款
        /// 办法），读不到就回落到只提示台数，不假断言。
        let provisionedDeviceCount: Int
        let provisionedDevices: [String]
    }

    static var provisionInfo: ProvisionInfo? {
        guard let data = try? Data(contentsOf: provisionURL),
              let start = data.range(of: Data("<?xml".utf8)),
              let endMark = data.range(of: Data("</plist>".utf8)) else { return nil }
        let xml = data[start.lowerBound..<endMark.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return ProvisionInfo(name: dict["Name"] as? String ?? "",
                             teamName: dict["TeamName"] as? String ?? "",
                             teamID: (dict["TeamIdentifier"] as? [String])?.first ?? "",
                             expiration: dict["ExpirationDate"] as? Date,
                             uuid: dict["UUID"] as? String ?? "",
                             provisionedDeviceCount: (dict["ProvisionedDevices"] as? [String])?.count ?? 0,
                             provisionedDevices: dict["ProvisionedDevices"] as? [String] ?? [])
    }

    /// 删除已导入的证书材料（证书页的「移除证书」）。
    static func removeAll() {
        try? FileManager.default.removeItem(at: p12URL)
        try? FileManager.default.removeItem(at: provisionURL)
        password = ""
    }

    /// 用 Security 框架解开 .p12，取出证书与私钥的 DER（私钥是
    /// RSA 的 PKCS#1 形式，Rust 侧会包成 PKCS#8 再解析）。
    static func identityDERs() throws -> (cert: Data, key: Data) {
        let data = try Data(contentsOf: p12URL)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let rawIdentity = first[kSecImportItemIdentity as String] else {
            throw EngineError.message(L("证书解不开——密码不对，或者 .p12 文件有问题。"))
        }
        let identity = rawIdentity as! SecIdentity
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef else {
            throw EngineError.message(L("证书读取失败。"))
        }
        var keyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else {
            throw EngineError.message(L("证书里没有私钥——要带私钥的 .p12。"))
        }
        var cfError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &cfError) as Data? else {
            throw EngineError.message(L("私钥读取失败。"))
        }
        return (SecCertificateCopyData(cert) as Data, keyData)
    }

    /// 本机直装的 TLS 服务用：直接拿 .p12 里现成的身份，
    /// 不经过 DER 来回倒（私钥是 RSA 还是 EC 都不用猜）。
    static func identity() throws -> SecIdentity {
        let data = try Data(contentsOf: p12URL)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let rawIdentity = first[kSecImportItemIdentity as String] else {
            throw EngineError.message(L("证书解不开——密码不对，或者 .p12 文件有问题。"))
        }
        return rawIdentity as! SecIdentity
    }

    /// 证书本身的信息（名头）：证书卡上要显示。解不开（比如
    /// 密码不对）就返回 nil，不拦着原来的显示；密码错到签名
    /// 那步还是会明说。
    /// 注意：证书到期日不要用 SecCertificateCopyValues 拿——
    /// 它和 kSecOIDX509V1ValidityNotAfter 是 macOS 才有的，
    /// iOS 上编不过（构建 #50 红字实证）。iOS 没有现成的
    /// 证书到期 API，所以证书过期那一档不做，过期校验只看
    /// 描述文件（描述文件到期日从 plist 里直接读得到）。
    struct CertInfo {
        let name: String
    }

    static var certInfo: CertInfo? {
        guard let identity = try? identity() else { return nil }
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let cert = certRef else { return nil }
        let name = SecCertificateCopySubjectSummary(cert) as String? ?? ""
        return CertInfo(name: name)
    }

    /// 描述文件里内嵌的开发证书 DER 列表（DeveloperCertificates）。
    /// 和 provisionInfo 同一套 plist 提取：描述文件是 CMS 套着
    /// plist，这里只取 plist 那段。读不出来返回 nil（不拦）。
    static var provisionDeveloperCertificates: [Data]? {
        guard let data = try? Data(contentsOf: provisionURL),
              let start = data.range(of: Data("<?xml".utf8)),
              let endMark = data.range(of: Data("</plist>".utf8)) else { return nil }
        let xml = data[start.lowerBound..<endMark.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["DeveloperCertificates"] as? [Data]
    }

    /// 签名前校验（两条签名路共用：CertSigner 和 Engine 流水线）。
    /// 只拦板上钉钉的两档——过期，和证书与描述文件对不上（
    /// 描述文件里根本没有这张证书，签出来的包装上去也装不上，
    /// 不如签之前就明说）。解析不出来的项不拦，免得误杀能签的。
    /// 证书对不上的判断走描述文件内嵌的证书列表：证书在列表里
    /// 就说明团队也是同一家，不用再单独比团队名。
    static func validateForSigning() throws {
        let now = Date()
        if let expiration = provisionInfo?.expiration, expiration < now {
            throw EngineError.message(L("描述文件已过期（%@），签出来的包装上去也是闪退，先换一张没过期的描述文件。",
                                        expiration.formatted(date: .abbreviated, time: .omitted)))
        }
        // p12 解不开（比如密码不对）时这里不重复报错：后面签
        // 名那步的 identityDERs 会明说，校验直接跳过这一档。
        if let certDER = try? identityDERs().cert,
           let devCerts = provisionDeveloperCertificates,
           !devCerts.isEmpty,
           !devCerts.contains(certDER) {
            throw EngineError.message(L("描述文件里的证书和已导入的 .p12 对不上，签出来的包装上去也装不上，先换一张和这张证书配对的描述文件。"))
        }
    }
}

// MARK: - 吊销状态与脱壳检查（轻松签对齐，警告不拦截）

/// 吊销检查结果：unknown = 查不出来（离线、链不全、评估失败），
/// 一律不报警告；ok = 评估通过；revoked = 系统评估明确拒绝。
enum CertRevocationStatus {
    case unknown
    case ok
    case revoked
}

/// 吊销检查：用系统信任评估给已导入的企业证书验一遍，评估
/// 时允许联网（OCSP 在线查）。只有评估失败且结果是 Deny 才
/// 算掉签——其他失败（离线、链不全、策略原因）都算查不出来，
/// 绝不报假警告。调用方必须在后台线程调（评估可能联网）。
/// 注意：这组 SecTrust API 是本文件新写的，仓库里没有现成
/// 用例，CI 是最终 verdict。
enum CertRevocationChecker {
    static func check() -> CertRevocationStatus {
        guard let trust = currentTrust() else { return .unknown }
        SecTrustSetNetworkFetchAllowed(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return .ok }
        var result = SecTrustResultType.invalid
        guard SecTrustGetTrustResult(trust, &result) == errSecSuccess else { return .unknown }
        return result == .deny ? .revoked : .unknown
    }

    /// p12 导入时系统顺手建好的信任对象优先（链最全）；没有
    /// 就用证书本身加基础 X.509 策略现建一个。
    private static func currentTrust() -> SecTrust? {
        let data = try? Data(contentsOf: EnterpriseCertStore.p12URL)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: EnterpriseCertStore.password]
        if let data,
           SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
           let array = items as? [[String: Any]],
           let rawTrust = array.first?[kSecImportItemTrust as String] as? AnyObject,
           CFGetTypeID(rawTrust) == SecTrustGetTypeID() {
            // 这里不能写 as? SecTrust：编译器认定对 CoreFoundation
            // 类型的条件转换恒成功而直接报错；先验 typeID 再硬转。
            return unsafeBitCast(rawTrust, to: SecTrust.self)
        }
        guard let identity = try? EnterpriseCertStore.identity() else { return nil }
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let cert = certRef else { return nil }
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess else { return nil }
        return trust
    }
}

/// 脱壳检查：读 IPA 主程序 Mach-O 的 LC_ENCRYPTION_INFO，cryptid
/// 非 0 说明还是加密的（没脱壳），签完可能装不上。
/// 返回 nil = 查不出来（不警告）；0 = 已脱壳；>0 = 未脱壳。
/// 调用方在后台线程调：大包解压到临时目录要几秒，查完即删。
enum IPADecryptionCheck {
    static func cryptid(of ipaURL: URL) -> Int? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("EnterpriseCryptCheck-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch { return nil }
        defer { try? fm.removeItem(at: tmp) }
        guard FileZipTool.unzip(archive: ipaURL, to: tmp) == nil else { return nil }
        guard let payload = try? fm.contentsOfDirectory(at: tmp.appendingPathComponent("Payload"), includingPropertiesForKeys: nil),
              let appDir = payload.first(where: { $0.pathExtension == "app" }) else { return nil }
        let executableName: String
        if let plistData = try? Data(contentsOf: appDir.appendingPathComponent("Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
           let dict = plist as? [String: Any],
           let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty {
            executableName = exe
        } else {
            executableName = appDir.deletingPathExtension().lastPathComponent
        }
        let exeURL = appDir.appendingPathComponent(executableName)
        guard let header = readHeader(of: exeURL) else { return nil }
        return parseCryptid(header, exeURL: exeURL)
    }

    /// 先读文件头（胖二进制的头 + 架构表，4KB 够放几百项），
    /// 再按需到切片偏移处读 1MB（load commands 都在文件头附近）。
    /// 读法用 OTA 已在用的 readData(ofLength:)（不抛错、无版本疑问）。
    private static func readHeader(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4096)
    }

    private static func parseCryptid(_ head: Data, exeURL: URL) -> Int? {
        guard head.count >= 4 else { return nil }
        let magic = head[0..<4]
        if magic.elementsEqual([0xCA, 0xFE, 0xBA, 0xBE]) {
            // 胖二进制：大端序，找 arm64 切片再读它的头。
            guard head.count >= 8 else { return nil }
            let narch = Int(u32be(head, 4))
            var offset = 8
            for _ in 0..<narch {
                guard head.count >= offset + 20 else { return nil }
                let cputype = u32be(head, offset)
                let sliceOffset = Int(u32be(head, offset + 8))
                // cputype arm64 = 0x0100000C
                if cputype == 0x0100_000C {
                    guard let handle = try? FileHandle(forReadingFrom: exeURL) else { return nil }
                    defer { try? handle.close() }
                    guard (try? handle.seek(toOffset: UInt64(sliceOffset))) != nil else { return nil }
                    return thinCryptid(handle.readData(ofLength: 1 << 20))
                }
                offset += 20
            }
            return nil
        }
        if magic.elementsEqual([0xCA, 0xFE, 0xBA, 0xBF]) {
            // 64 位胖二进制：每项 32 字节，offset 是 8 字节大端值，
            // 低 32 位在 +12 处（IPA 不到 4GB，低 32 位够用）。
            guard head.count >= 8 else { return nil }
            let narch = Int(u32be(head, 4))
            var offset = 8
            for _ in 0..<narch {
                guard head.count >= offset + 32 else { return nil }
                let cputype = u32be(head, offset)
                let sliceOffset = Int(u32be(head, offset + 12))
                if cputype == 0x0100_000C {
                    guard let handle = try? FileHandle(forReadingFrom: exeURL) else { return nil }
                    defer { try? handle.close() }
                    guard (try? handle.seek(toOffset: UInt64(sliceOffset))) != nil else { return nil }
                    return thinCryptid(handle.readData(ofLength: 1 << 20))
                }
                offset += 32
            }
            return nil
        }
        // 瘦二进制：整个文件头就是 Mach-O 头，1MB 够走 load commands。
        guard let handle = try? FileHandle(forReadingFrom: exeURL) else { return nil }
        defer { try? handle.close() }
        return thinCryptid(handle.readData(ofLength: 1 << 20))
    }

    /// 瘦 Mach-O 里走 load commands 找 LC_ENCRYPTION_INFO(_64)。
    /// 没有加密命令 = 已脱壳（或本来就没加密），返回 0。
    private static func thinCryptid(_ data: Data) -> Int? {
        guard data.count >= 32 else { return nil }
        let magic = data[0..<4]
        let is64 = magic.elementsEqual([0xCF, 0xFA, 0xED, 0xFE])
        let is32 = magic.elementsEqual([0xCE, 0xFA, 0xED, 0xFE])
        guard is64 || is32 else { return nil }
        let ncmds = Int(u32le(data, 16))
        var cursor = is64 ? 32 : 28
        for _ in 0..<ncmds {
            guard data.count >= cursor + 8 else { return nil }
            let cmd = u32le(data, cursor)
            let cmdsize = Int(u32le(data, cursor + 4))
            guard cmdsize >= 8, data.count >= cursor + cmdsize else { return nil }
            if cmd == 0x2C, data.count >= cursor + 24 {
                // LC_ENCRYPTION_INFO_64：cryptid 在命令 +20 处。
                return Int(u32le(data, cursor + 20))
            }
            if cmd == 0x21, data.count >= cursor + 20 {
                // LC_ENCRYPTION_INFO：cryptid 在命令 +16 处。
                return Int(u32le(data, cursor + 16))
            }
            cursor += cmdsize
        }
        return 0
    }

    /// 手动拼字节，不用 load(as:)——切片偏移不一定 4 字节对齐。
    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func u32be(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}

// MARK: - 签名前修改项

/// 证书页的签名前修改项：留空的项不改。对应 Rust 侧 SignMods 的
/// JSON 字段（name/bundleId/version/minOS/iconPng/outIpa）。
struct CertSignMods {
    var name = ""
    var bundleID = ""
    var version = ""
    var minOS = ""
    /// 新图标的 PNG 数据（选了才有）。
    var icon: Data? = nil
    /// 要注入的插件文件（已复制到暂存目录的 .dylib/.deb/.zip）。
    var plugins: [URL] = []

    var isEmpty: Bool {
        name.isEmpty && bundleID.isEmpty && version.isEmpty && minOS.isEmpty && icon == nil && plugins.isEmpty
    }

    func json(iconPath: String?, outIpaPath: String?) -> String {
        var dict: [String: Any] = [:]
        if !name.isEmpty { dict["name"] = name }
        if !bundleID.isEmpty { dict["bundleId"] = bundleID }
        if !version.isEmpty { dict["version"] = version }
        if !minOS.isEmpty { dict["minOS"] = minOS }
        if let iconPath { dict["iconPng"] = iconPath }
        if let outIpaPath { dict["outIpa"] = outIpaPath }
        if !plugins.isEmpty { dict["plugins"] = plugins.map { $0.path } }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// 插件暂存：从文件 App 选来的插件先复制到 Documents/CertPlugins，
/// 签名时 Rust 侧按路径读（原文件可能在沙盒外、随时会被收回）。
enum CertPluginStore {
    static var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CertPlugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    /// Copy a picked plugin into the staging folder; returns the
    /// staged URL, or nil when the file type is not supported.
    static func stage(_ source: URL) -> URL? {
        let ext = source.pathExtension.lowercased()
        guard ["dylib", "deb", "zip"].contains(ext) else { return nil }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var dest = dir.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            dest = dir.appendingPathComponent("\(stem) \(counter).\(ext)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 已签名 IPA

/// 一条「已签名」记录，清单存 Application Support，IPA 文件存
/// Documents/Signed（文件页和文件 App 都能看到）。
struct SignedIPARecord: Codable, Identifiable {
    var fileName: String
    var appName: String
    var bundleID: String
    var version: String?
    var date: Date
    var size: Int
    /// 签名时用的证书名（如 iPhone Distribution: hu jing）。
    /// 可选：老记录没有这两个字段，解码得 nil，已签名行就不显示第三行。
    var certName: String?
    /// 描述文件里的 TeamIdentifier（如 HP24Y7433B），没有就 nil。
    var teamID: String?
    var id: String { fileName }
}

enum SignedIPAStore {
    static var dir: URL {
        let url = IPALibrary.documentsDir.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("SignedIPA-manifest.json")
    }

    static func url(for record: SignedIPARecord) -> URL {
        dir.appendingPathComponent(record.fileName)
    }

    static func load() -> [SignedIPARecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([SignedIPARecord].self, from: data)
        else { return [] }
        return records
            .filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
            .sorted { $0.date > $1.date }
    }

    private static func save(_ records: [SignedIPARecord]) {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    static func add(_ record: SignedIPARecord) {
        save([record] + load())
    }

    static func remove(_ record: SignedIPARecord) {
        try? FileManager.default.removeItem(at: url(for: record))
        save(load().filter { $0.fileName != record.fileName })
    }

    /// 批量删除：一次读清单、一次写回，不按条循环调 remove。
    static func remove(_ records: [SignedIPARecord]) {
        let names = Set(records.map { $0.fileName })
        for record in records {
            try? FileManager.default.removeItem(at: url(for: record))
        }
        save(load().filter { !names.contains($0.fileName) })
    }

    /// 老记录证书段补齐：v61 之前签的记录没存 certName/teamID，
    /// 行里不显示证书段。逐条读已签 IPA 里的 embedded.mobileprovision
    ///（CMS 包着 plist，照 BuiltinTunnel 的 latin1 截 XML 办法），
    ///取 TeamIdentifier；团队与当前描述文件一致时才用当前证书名
    ///补 certName（同团队才敢认是同一张证，团队不同就不猜）。
    ///已补过的记录不再重读；读不到/解不出就跳过，不报错。
    ///返回 true 表示改过清单（调用方重读一次）。
    ///注意：解压整个 IPA 只为读一个小文件，大包会慢一截——
    ///调用方须在后台跑、每条只跑一次，跑完就不再碰。
    static func fillMissingCertInfo() -> Bool {
        guard let currentTeam = EnterpriseCertStore.provisionInfo?.teamID,
              !currentTeam.isEmpty,
              let currentName = EnterpriseCertStore.certInfo?.name,
              !currentName.isEmpty else { return false }
        var records = load()
        var changed = false
        for index in records.indices {
            let old = records[index]
            guard old.certName == nil || old.teamID == nil else { continue }
            // 已有团队号且与当前团队不同：这条记录对应的文件后来
            // 换证重签过（或记录本身就是旧证的），不拿当前证书名
            // 去盖它。
            if let storedTeam = old.teamID, storedTeam != currentTeam { continue }
            guard let team = provisionTeamID(of: url(for: old)), team == currentTeam else { continue }
            if records[index].certName == nil { records[index].certName = currentName }
            if records[index].teamID == nil { records[index].teamID = team }
            changed = true
        }
        if changed { save(records) }
        return changed
    }

    /// 已签 IPA 里的描述文件团队号：解压到暂存目录，读
    /// Payload/*.app/embedded.mobileprovision 的 TeamIdentifier。
    /// 解不出就 nil（调用方跳过，不报错）。
    private static func provisionTeamID(of ipaURL: URL) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CZFProvision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard FileZipTool.unzip(archive: ipaURL, to: tmp) == nil,
              let payload = try? FileManager.default.contentsOfDirectory(
                  at: tmp.appendingPathComponent("Payload", isDirectory: true),
                  includingPropertiesForKeys: nil),
              let appDir = payload.first(where: { $0.pathExtension == "app" }),
              let data = try? Data(contentsOf: appDir.appendingPathComponent("embedded.mobileprovision")),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", options: .backwards) else {
            return nil
        }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let xmlData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: xmlData, options: [], format: nil) as? [String: Any],
              let teams = plist["TeamIdentifier"] as? [String],
              let team = teams.first, !team.isEmpty else {
            return nil
        }
        return team
    }

    /// 文件页改名后同步清单里的文件名。
    static func renameFile(from oldName: String, to newName: String) {
        var records = load()
        for index in records.indices where records[index].fileName == oldName {
            records[index].fileName = newName
        }
        save(records)
    }

    /// 给源 IPA 起一个不重名的输出文件（Documents/Signed 内）。
    static func uniqueOutputURL(baseName: String) -> URL {
        let stem = baseName.isEmpty ? "App" : baseName
        var candidate = dir.appendingPathComponent("\(stem)-已签.ipa")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)-已签\(counter).ipa")
            counter += 1
        }
        return candidate
    }
}

// MARK: - 签名日志

/// 签名操作种类（存码，显示时再翻成文案）。
enum CertSignLogKind: String, Codable {
    case signOnly
    case signAndInstall
    case batch
}

/// 一条签名记录：只记结果，不记证书密码等敏感信息。
struct CertSignLogEntry: Codable, Identifiable {
    var id: UUID
    var date: Date
    var appName: String
    var kind: CertSignLogKind
    var success: Bool
    /// 成功是结果说明，失败是报错原文。
    var detail: String
}

/// 签名日志清单：存 Application Support，最新在前，最多留 100 条。
enum CertSignLogStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("CertSignLog.json")
    }

    static func load() -> [CertSignLogEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CertSignLogEntry].self, from: data)
        else { return [] }
        return entries.sorted { $0.date > $1.date }
    }

    private static func save(_ entries: [CertSignLogEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func append(_ entry: CertSignLogEntry) {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > 100 { entries = Array(entries.prefix(100)) }
        save(entries)
    }

    static func clear() { save([]) }
}

// MARK: - 签名预设

/// 一条签名预设：只存跨 App 通用的项。名字/Bundle ID/版本是
/// 每 App 自己的，不进预设；插件文件另存预设目录（套用时
/// 重新暂存一份，换 IPA 清暂存时不伤预设原件）。
struct CertSignPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var minOS: String
    var multiCount: Int
    var multiStart: Int
    var icon: Data?
    var pluginFileNames: [String]
}

/// 签名预设：索引存 Application Support，插件文件存同目录下
/// 每预设一个子目录（同名插件互不干扰）。
enum CertSignPresetStore {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CertSignPresets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var indexURL: URL { dir.appendingPathComponent("presets.json") }

    static func load() -> [CertSignPreset] {
        guard let data = try? Data(contentsOf: indexURL),
              let presets = try? JSONDecoder().decode([CertSignPreset].self, from: data)
        else { return [] }
        return presets.sorted { $0.name < $1.name }
    }

    private static func save(_ presets: [CertSignPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func pluginDir(for id: UUID) -> URL {
        let url = dir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 预设的插件文件（只返回还存在的，删过的不算）。
    static func pluginURLs(for preset: CertSignPreset) -> [URL] {
        let d = pluginDir(for: preset.id)
        return preset.pluginFileNames.map { d.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 保存当前可复用项为预设；同名预设直接覆盖（旧目录一起删）。
    /// 插件拷失败的跳过，不记入；索引写失败也不抛，调用方照常报保存。
    static func save(name: String, minOS: String, multiCount: Int, multiStart: Int,
                     icon: Data?, pluginURLs: [URL]) -> CertSignPreset {
        var presets = load()
        if let old = presets.first(where: { $0.name == name }) {
            try? FileManager.default.removeItem(at: pluginDir(for: old.id))
            presets.removeAll { $0.id == old.id }
        }
        let preset = CertSignPreset(id: UUID(), name: name, minOS: minOS,
                                    multiCount: multiCount, multiStart: multiStart,
                                    icon: icon, pluginFileNames: [])
        let pdir = pluginDir(for: preset.id)
        var names: [String] = []
        for url in pluginURLs {
            let dest = pdir.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                names.append(url.lastPathComponent)
            }
        }
        var seen = Set<String>()
        var final = preset
        final.pluginFileNames = names.filter { seen.insert($0).inserted }
        presets.append(final)
        save(presets)
        return final
    }

    static func remove(_ preset: CertSignPreset) {
        try? FileManager.default.removeItem(at: pluginDir(for: preset.id))
        save(load().filter { $0.id != preset.id })
    }
}

// MARK: - 独立签名器（只签名不安装，不走 Engine 流水线）

enum CertSigner {
    /// 用企业证书把 IPA 签好并存进「已签名」，返回记录。
    static func signToFile(ipa: URL, mods: CertSignMods) async throws -> SignedIPARecord {
        guard EnterpriseCertStore.ready else {
            throw EngineError.message(L("企业证书材料不齐：需要 .p12、描述文件和证书密码。"))
        }
        try EnterpriseCertStore.validateForSigning()
        return try await Task.detached(priority: .userInitiated) {
            let (certDER, keyDER) = try EnterpriseCertStore.identityDERs()
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
                .appendingPathComponent("EnterpriseSign-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let certPath = tmp.appendingPathComponent("cert.der")
            let keyPath = tmp.appendingPathComponent("key.der")
            try certDER.write(to: certPath)
            try keyDER.write(to: keyPath)
            var iconPath: String? = nil
            if let icon = mods.icon {
                let path = tmp.appendingPathComponent("icon.png")
                try icon.write(to: path)
                iconPath = path.path
            }
            let outURL = SignedIPAStore.uniqueOutputURL(
                baseName: ipa.deletingPathExtension().lastPathComponent)
            let json = mods.json(iconPath: iconPath, outIpaPath: outURL.path)
            var signed: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let rc = si_sign_ipa_with_cert_ex(ipa.path, certPath.path, keyPath.path,
                                              EnterpriseCertStore.provisionURL.path,
                                              json, &signed, &error)
            if rc != 0 {
                let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
                error.map { si_string_free($0) }
                throw EngineError.message(L("企业证书签名失败：%@", msg))
            }
            signed.map { si_string_free($0) }
            let info = IPALibrary.appInfo(at: ipa)
            let size = (try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? Int ?? 0
            // 已签名行第三行用：证书名取 p12 的名头，团队 ID 取描述文件
            // 的 TeamIdentifier；读不出来就留空，行里不显示第三行。
            let certName = EnterpriseCertStore.certInfo?.name
            let teamID = EnterpriseCertStore.provisionInfo?.teamID
            let record = SignedIPARecord(
                fileName: outURL.lastPathComponent,
                appName: mods.name.isEmpty ? (info?.name ?? ipa.deletingPathExtension().lastPathComponent) : mods.name,
                bundleID: mods.bundleID.isEmpty ? (info?.bundleID ?? "") : mods.bundleID,
                version: mods.version.isEmpty ? info?.version : mods.version,
                date: Date(), size: size,
                certName: (certName?.isEmpty == false) ? certName : nil,
                teamID: (teamID?.isEmpty == false) ? teamID : nil)
            SignedIPAStore.add(record)
            return record
        }.value
    }
}

// MARK: - 证书页/文件页共享的选择

/// 文件页点「去签名」时把 IPA 交给证书页。
final class CertWorkspace: ObservableObject {
    @Published var selectedIPA: URL?
}


// MARK: - 文件页用的压缩 / 解压（Rust 的 zip 实现）

enum FileZipTool {
    /// 把文件/文件夹压成 zip。成功返回 nil，失败返回错误文本。
    static func zip(paths: [URL], to out: URL) -> String? {
        let json = (try? JSONSerialization.data(withJSONObject: paths.map { $0.path }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var error: UnsafeMutablePointer<CChar>?
        let rc = json.withCString { j in
            out.path.withCString { o in
                si_zip_create(j, o, &error)
            }
        }
        return takeError(rc, &error)
    }

    /// 把 zip 解压到指定目录。成功返回 nil，失败返回错误文本。
    static func unzip(archive: URL, to dir: URL) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        let rc = archive.path.withCString { a in
            dir.path.withCString { d in
                si_unzip_archive(a, d, &error)
            }
        }
        return takeError(rc, &error)
    }

    private static func takeError(
        _ rc: Int32, _ error: inout UnsafeMutablePointer<CChar>?
    ) -> String? {
        defer {
            if let error { si_string_free(error) }
        }
        guard rc != 0 else { return nil }
        if let error { return String(cString: error) }
        return L("操作失败")
    }
}
