import Foundation
import Security
import SideInstallerFFI
import SwiftUI
import UniformTypeIdentifiers

/// 企业证书签名的材料存储：.p12 与 .mobileprovision 复制进
/// App 自己的支持目录，密码存 UserDefaults（本机自用）。
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
        get { UserDefaults.standard.string(forKey: "CZFEnterpriseCertPassword") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "CZFEnterpriseCertPassword") }
    }
    static var ready: Bool { hasP12 && hasProvision && !password.isEmpty }

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
        let expiration: Date?
        let uuid: String
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
                             expiration: dict["ExpirationDate"] as? Date,
                             uuid: dict["UUID"] as? String ?? "")
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

    /// 签名前校验（两条签名路共用：CertSigner 和 Engine 流水线）。
    /// 只拦板上钉钉的过期——过期材料签出来的包装上去也是闪退，
    /// 不如签之前就明说。解析不出来的项不拦，免得误杀能签的。
    static func validateForSigning() throws {
        let now = Date()
        if let expiration = provisionInfo?.expiration, expiration < now {
            throw EngineError.message(L("描述文件已过期（%@），签出来的包装上去也是闪退，先换一张没过期的描述文件。",
                                        expiration.formatted(date: .abbreviated, time: .omitted)))
        }
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
            let record = SignedIPARecord(
                fileName: outURL.lastPathComponent,
                appName: mods.name.isEmpty ? (info?.name ?? ipa.deletingPathExtension().lastPathComponent) : mods.name,
                bundleID: mods.bundleID.isEmpty ? (info?.bundleID ?? "") : mods.bundleID,
                version: mods.version.isEmpty ? info?.version : mods.version,
                date: Date(), size: size)
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
