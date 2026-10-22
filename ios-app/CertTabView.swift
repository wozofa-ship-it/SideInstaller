import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 证书页：企业证书管理（导入/信息/移除）、选 IPA 改信息后签名
/// （名称/Bundle ID/版本/最低系统版本/图标）、已签名列表。
/// 签名并安装走 Engine 的流水线（进度在安装页），仅签名走
/// CertSigner 存进「已签名」。
struct CertTabView: View {
    @EnvironmentObject private var engine: Engine
    /// Declared so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var workspace: CertWorkspace

    // 证书材料状态
    @State private var hasP12 = EnterpriseCertStore.hasP12
    @State private var hasProvision = EnterpriseCertStore.hasProvision
    @State private var password = EnterpriseCertStore.password
    @State private var provisionInfo = EnterpriseCertStore.provisionInfo
    @State private var showP12Picker = false
    @State private var showProvisionPicker = false
    @State private var importError: String?
    @State private var confirmingRemoveCert = false

    // 待签 IPA 与修改项
    @State private var selectedIPA: URL?
    @State private var mods = CertSignMods()
    @State private var showIPAPicker = false
    @State private var showLibraryPicker = false
    @State private var iconItem: PhotosPickerItem?
    @State private var signOnlyBusy = false
    @State private var signOnlyMessage: String?
    @State private var signOnlyFailed = false

    // 已签名
    @State private var signedRecords = SignedIPAStore.load()

    private var certReady: Bool { hasP12 && hasProvision && !password.isEmpty }
    private var selectedInfo: IPALibrary.AppInfo? {
        selectedIPA.flatMap { IPALibrary.appInfo(at: $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    certCard.cascadeItem(1)
                    signCard.cascadeItem(2)
                    signedCard.cascadeItem(3)
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(AppBackground())
        }
        .onAppear {
            refreshCertState()
            signedRecords = SignedIPAStore.load()
            if let shared = workspace.selectedIPA {
                select(shared)
                workspace.selectedIPA = nil
            }
        }
        .onChange(of: workspace.selectedIPA) { _, shared in
            if let shared {
                select(shared)
                workspace.selectedIPA = nil
            }
        }
        .onChange(of: iconItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    mods.icon = data
                }
            }
        }
    }

    private var header: some View {
        Text(L("企业证书"))
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // MARK: 证书管理

    private var certCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                    Text(L("证书管理"))
                        .font(.headline)
                    Spacer()
                    if certReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let info = provisionInfo {
                    infoRow(L("描述文件"), info.name.isEmpty ? L("（无名称）") : info.name)
                    if !info.teamName.isEmpty {
                        infoRow(L("团队"), info.teamName)
                    }
                    if let expiration = info.expiration {
                        HStack {
                            Text(L("到期"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(expiration.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(expiration < Date() ? .red : .primary)
                        }
                        .font(.footnote)
                    }
                }
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
                    .onChange(of: password) { _, newValue in
                        EnterpriseCertStore.password = newValue
                    }
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if hasP12 || hasProvision {
                    Button(role: .destructive) {
                        confirmingRemoveCert = true
                    } label: {
                        Text(L("移除证书材料"))
                            .font(.footnote)
                    }
                }
            }
        }
        .alert(L("移除证书材料？"), isPresented: $confirmingRemoveCert) {
            Button(L("取消"), role: .cancel) {}
            Button(L("移除"), role: .destructive) {
                EnterpriseCertStore.removeAll()
                password = ""
                refreshCertState()
            }
        } message: {
            Text(L("会删掉已导入的 .p12、描述文件和保存的密码，之后要重新导入才能签名。"))
        }
        .sheet(isPresented: $showP12Picker) {
            FileImporterRepresentableView(
                allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data]
            ) { urls in
                if let url = urls.first {
                    do {
                        try EnterpriseCertStore.importP12(from: url)
                        importError = nil
                    } catch {
                        importError = L("证书导入失败：%@", error.localizedDescription)
                    }
                    refreshCertState()
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
                        importError = nil
                    } catch {
                        importError = L("描述文件导入失败：%@", error.localizedDescription)
                    }
                    refreshCertState()
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func refreshCertState() {
        hasP12 = EnterpriseCertStore.hasP12
        hasProvision = EnterpriseCertStore.hasProvision
        provisionInfo = EnterpriseCertStore.provisionInfo
    }

    // MARK: 签名与修改

    private var signCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "signature")
                        .foregroundStyle(.secondary)
                    Text(L("签名 IPA"))
                        .font(.headline)
                }
                if let url = selectedIPA {
                    selectedIPASummary(url)
                    Divider()
                    Text(L("修改（留空不改）"))
                        .font(.subheadline.weight(.semibold))
                    modField(L("新名称"), text: $mods.name,
                             placeholder: selectedInfo?.name ?? "")
                    modField(L("新 Bundle ID"), text: $mods.bundleID,
                             placeholder: selectedInfo?.bundleID ?? "")
                    modField(L("新版本号"), text: $mods.version,
                             placeholder: selectedInfo?.version ?? "")
                    modField(L("最低系统版本"), text: $mods.minOS,
                             placeholder: "如 15.0")
                    iconRow
                    Divider()
                    Button {
                        engine.runEnterpriseCertInstall(ipaURL: url, mods: mods)
                    } label: {
                        Text(L("签名并安装"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isRunning || signOnlyBusy || !certReady)
                    Button {
                        signOnly(url: url)
                    } label: {
                        HStack {
                            if signOnlyBusy { ProgressView() }
                            Text(L("仅签名（存到已签名）"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(signOnlyBusy || engine.isRunning || !certReady)
                    if engine.isRunning {
                        Text(L("正在安装，进度在「安装」页看。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let signOnlyMessage {
                        Text(signOnlyMessage)
                            .font(.footnote)
                            .foregroundStyle(signOnlyFailed ? .red : .green)
                    }
                    if !certReady {
                        Text(L("先在上面把证书、描述文件和密码备齐。"))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(L("选一个 IPA，可以先改名称、Bundle ID、版本、最低系统版本和图标，再用企业证书签名。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            showIPAPicker = true
                        } label: {
                            Text(L("从文件导入"))
                        }
                        Button {
                            showLibraryPicker = true
                        } label: {
                            Text(L("从文件库选择"))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showIPAPicker) {
            FileImporterRepresentableView(
                allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]
            ) { urls in
                if let url = urls.first { select(url) }
            }
        }
        .sheet(isPresented: $showLibraryPicker) {
            LibraryIPAPicker { url in
                select(url)
                showLibraryPicker = false
            }
        }
    }

    private func selectedIPASummary(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedInfo?.name ?? url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let info = selectedInfo {
                    Text("\(info.bundleID)\(info.version.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                selectedIPA = nil
                mods = CertSignMods()
                signOnlyMessage = nil
            } label: {
                Text(L("更换"))
                    .font(.footnote)
            }
        }
    }

    private func modField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.footnote)
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private var iconRow: some View {
        HStack(spacing: 10) {
            Text(L("新图标"))
                .font(.footnote)
                .frame(width: 92, alignment: .leading)
            if let icon = mods.icon, let image = UIImage(data: icon) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Button {
                    mods.icon = nil
                    iconItem = nil
                } label: {
                    Text(L("清除"))
                        .font(.footnote)
                }
            } else {
                PhotosPicker(selection: $iconItem, matching: .images) {
                    Text(L("从相册选择"))
                        .font(.footnote)
                }
            }
            Spacer()
        }
    }

    private func select(_ url: URL) {
        selectedIPA = url
        mods = CertSignMods()
        iconItem = nil
        signOnlyMessage = nil
    }

    private func signOnly(url: URL) {
        signOnlyBusy = true
        signOnlyMessage = nil
        let currentMods = mods
        Task {
            do {
                _ = try await CertSigner.signToFile(ipa: url, mods: currentMods)
                signedRecords = SignedIPAStore.load()
                signOnlyMessage = L("签好了，已存到下面的「已签名」。")
                signOnlyFailed = false
            } catch {
                signOnlyMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                signOnlyFailed = true
            }
            signOnlyBusy = false
        }
    }

    // MARK: 已签名

    private var signedCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.secondary)
                    Text(L("已签名"))
                        .font(.headline)
                    Spacer()
                    if !signedRecords.isEmpty {
                        Text("\(signedRecords.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if signedRecords.isEmpty {
                    Text(L("还没有已签名的 IPA。用上面的「仅签名」签好就会存到这里，随时能装、能分享。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(signedRecords) { record in
                        signedRow(record)
                        if record.id != signedRecords.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func signedRow(_ record: SignedIPARecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.appName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(record.bundleID)\(record.version.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(record.size), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Button {
                    engine.runInstallSignedIPA(ipaURL: SignedIPAStore.url(for: record))
                } label: {
                    Text(L("安装"))
                        .font(.footnote.weight(.semibold))
                }
                .disabled(engine.isRunning)
                ShareLink(item: SignedIPAStore.url(for: record)) {
                    Text(L("分享"))
                        .font(.footnote)
                }
                Spacer()
                Button(role: .destructive) {
                    SignedIPAStore.remove(record)
                    signedRecords = SignedIPAStore.load()
                } label: {
                    Text(L("删除"))
                        .font(.footnote)
                }
            }
        }
    }
}

/// 从文件库（Documents 里的全部 IPA）里挑一个。
private struct LibraryIPAPicker: View {
    @Environment(\.dismiss) private var dismiss
    var onPick: (URL) -> Void

    private var ipas: [LocalFileItem] {
        AppFileLibrary.scan().filter { $0.isIPA }
    }

    var body: some View {
        NavigationStack {
            List(ipas) { item in
                Button {
                    onPick(item.url)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(item.relativeDir.isEmpty ? L("根目录") : item.relativeDir) · \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L("选择 IPA"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("取消")) { dismiss() }
                }
            }
        }
    }
}
