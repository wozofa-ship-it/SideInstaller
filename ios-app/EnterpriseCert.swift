import Foundation
import Security
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
}

/// 安装页的企业证书签名卡：导入 .p12 + 描述文件、填密码，
/// 然后用上面导入的 IPA 本地签名并安装（不走 Apple ID）。
struct EnterpriseCertCard: View {
    @EnvironmentObject private var engine: Engine
    @State private var showP12Picker = false
    @State private var showProvisionPicker = false
    @State private var password = EnterpriseCertStore.password
    @State private var hasP12 = EnterpriseCertStore.hasP12
    @State private var hasProvision = EnterpriseCertStore.hasProvision
    @State private var importError: String?

    private var ready: Bool { hasP12 && hasProvision && !password.isEmpty }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                    Text(L("企业证书签名"))
                        .font(.headline)
                    Spacer()
                    if ready {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(L("用自己的企业证书在本机签名安装，不用 Apple ID、没有 7 天过期。先导入证书和描述文件、填好密码，再用上面导入的 IPA 点签名安装。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showP12Picker = true
                    } label: {
                        Text(hasP12 ? L("证书已导入 ✓") : L("导入 .p12 证书"))
                    }
                    Button {
                        showProvisionPicker = true
                    } label: {
                        Text(hasProvision ? L("描述文件已导入 ✓") : L("导入描述文件"))
                    }
                }
                .buttonStyle(.bordered)
                SecureField(L("证书密码"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: password) { newValue in
                        EnterpriseCertStore.password = newValue
                    }
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    engine.runEnterpriseCertInstall()
                } label: {
                    Text(L("用企业证书签名并安装"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isRunning || !ready)
            }
        }
        .sheet(isPresented: $showP12Picker) {
            FileImporterRepresentableView(
                allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data]
            ) { urls in
                if let url = urls.first {
                    do {
                        try EnterpriseCertStore.importP12(from: url)
                        hasP12 = true
                        importError = nil
                    } catch {
                        importError = L("证书导入失败：%@", error.localizedDescription)
                    }
                }
            }
        }
        .sheet(isPresented: $showProvisionPicker) {
            FileImporterRepresentableView(
                allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data]
            ) { urls in
                if let url = urls.first {
                    do {
                        try EnterpriseCertStore.importProvision(from: url)
                        hasProvision = true
                        importError = nil
                    } catch {
                        importError = L("描述文件导入失败：%@", error.localizedDescription)
                    }
                }
            }
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

    var isEmpty: Bool {
        name.isEmpty && bundleID.isEmpty && version.isEmpty && minOS.isEmpty && icon == nil
    }

    func json(iconPath: String?, outIpaPath: String?) -> String {
        var dict: [String: String] = [:]
        if !name.isEmpty { dict["name"] = name }
        if !bundleID.isEmpty { dict["bundleId"] = bundleID }
        if !version.isEmpty { dict["version"] = version }
        if !minOS.isEmpty { dict["minOS"] = minOS }
        if let iconPath { dict["iconPng"] = iconPath }
        if let outIpaPath { dict["outIpa"] = outIpaPath }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
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
