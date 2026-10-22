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
