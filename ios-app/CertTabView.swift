import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 证书页：企业证书专区（与个人 ID 签名分开，ID 签名在应用页）。
/// 三段切栏（轻松签式分屏）：证书管理 / 签名 IPA / 应用库
/// （未签名按目录分组、已签名列表）；一次只显示一段，
/// 不再三卡叠在一个长滚动里。
/// 企业安装走独立安装（LocalHTTPInstallServer 本地回环，
/// 不走共用 Engine、不走隧道、不要 WiFi）；回环失败时原因
/// 只在企业页内显示 + 重试回环，绝不去共享「安装」页。
/// OTAInstallServer.swift 是 HTTPS 旧版，留着不用、不删。
struct CertTabView: View {
    /// Declared so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var workspace: CertWorkspace


    // 证书材料状态
    @State private var hasP12 = EnterpriseCertStore.hasP12
    @State private var hasProvision = EnterpriseCertStore.hasProvision
    @State private var password = EnterpriseCertStore.password
    @State private var provisionInfo = EnterpriseCertStore.provisionInfo
    @State private var certInfo = EnterpriseCertStore.certInfo
    @State private var showP12Picker = false
    @State private var showProvisionPicker = false
    // 轻松签式“导入证书库”：一次选 .p12 + 描述文件，配对才进。
    @State private var showCertLibraryPicker = false
    @State private var importError: String?
    @State private var confirmingRemoveCert = false

    // 吊销状态（手动刷新，警告不拦截）
    @State private var revocationStatus: CertRevocationStatus = .unknown
    @State private var revocationChecking = false
    @State private var revocationCheckedAt: Date?

    // 待签 IPA 与修改项
    @State private var selectedIPA: URL?
    @State private var mods = CertSignMods()
    @State private var showIPAPicker = false
    @State private var showLibraryPicker = false
    @State private var showPluginPicker = false
    @State private var pluginError: String?
    @State private var iconItem: PhotosPickerItem?
    @State private var signBusy = false
    @State private var signOnlyMessage: String?
    @State private var signOnlyFailed = false
    // 轻松签式“签名后立即安装”开关：开 = 开始签名后直接装，
    // 关 = 开始签名只签存已签名；“仅签名”按钮仍在下面。
    @AppStorage("CZFEnterpriseInstallWhenSign") private var installWhenSign = true
    // 选中 IPA 的脱壳预检结果（nil = 还没算出来）：加密的在表单上
    // 直接提示；真正签的时候 startSign 还会再算一次 gate。
    @State private var selectedCryptid: Int?

    // 多开：数量与起始序号（只对「仅签名」生效，见 multiOpenSection）
    @State private var multiCountText = "1"
    @State private var multiStartText = "1"

    // 签前警告（掉签/未脱壳）：警告不拦截，用户点继续才执行。
    @State private var pendingWarnings: [String] = []
    @State private var pendingSignKind: CertSignKind?
    @State private var pendingSignURL: URL?
    @State private var pendingSignMods = CertSignMods()
    @State private var showingWarningAlert = false

    // 企业独立安装：本地回环服务（不走共用 Engine）。
    // 回环失败后重试用的记录，就是这次要装的包。
    @StateObject private var localInstall = LocalHTTPInstallServer()
    @State private var localFallbackRecord: SignedIPARecord?

    // 应用库
    @State private var certPage = CertPage.certificate
    @State private var libraryTab = CertLibraryTab.unsigned
    @State private var librarySearchText = ""
    @State private var unsignedIPAs: [LocalFileItem] = []
    /// 未签名栏的 IPA 信息缓存（路径 → Info.plist 解析结果），只解析一次。
    @State private var unsignedInfo: [String: IPALibrary.AppInfo] = [:]
    /// 已经试过的路径（含解析失败），避免重复读盘。
    @State private var unsignedInfoTried: Set<String> = []
    @State private var signedRecords = SignedIPAStore.load()
    @State private var selectingSigned = false
    @State private var selectedSignedIDs: Set<String> = []
    @State private var recordPendingDelete: SignedIPARecord?
    @State private var showingDeleteConfirm = false
    @State private var showingBatchDeleteConfirm = false
    // 批量签名（未签名栏）：只签名不安装，跟多开同理。
    @State private var batchingUnsigned = false
    @State private var selectedUnsignedIDs: Set<String> = []
    @State private var batchBusy = false
    @State private var batchMessage: String?
    @State private var batchFailed = false
    // 签名预设（签名段）：只存跨 App 通用的项。
    @State private var presets: [CertSignPreset] = []
    @State private var presetNameText = ""
    @State private var presetMessage: String?
    // 签名日志（应用库「记录」栏）。
    @State private var logEntries: [CertSignLogEntry] = []
    @State private var showingLogClearConfirm = false

    private var certReady: Bool { hasP12 && hasProvision && !password.isEmpty }
    /// 选中 IPA 的 Info.plist 解析结果：select() 时算一次存下来，
    /// 后续表单重绘直接复用，不再每敲一键就重新解压读盘。
    /// select() 是唯一的选中入口（库里点选、别页传过来都走它），
    /// 取消选中时一并清空，不会残留旧值。
    @State private var selectedInfo: IPALibrary.AppInfo?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .cascadeItem(0)
                    .padding(.horizontal, 20)
                Picker("", selection: $certPage) {
                    Text(L("证书")).tag(CertPage.certificate)
                    Text(L("签名")).tag(CertPage.signing)
                    Text(L("应用库")).tag(CertPage.library)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                ScrollView {
                    pageContent
                        .padding([.horizontal, .top], 20)
                        .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(AppBackground())
        }
        .onAppear {
            refreshCertState()
            signedRecords = SignedIPAStore.load()
            unsignedIPAs = unsignedItems()
            ensureUnsignedInfo()
            presets = CertSignPresetStore.load()
            logEntries = CertSignLogStore.load()
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
        .onChange(of: libraryTab) { _, tab in
            if tab == .unsigned {
                unsignedIPAs = unsignedItems()
                ensureUnsignedInfo()
            }
        }
        // 回环失败不再弹配对兜底：原因只在企业页内显示 + 重试
        // 回环（见 enterpriseInstallError），绝不去共享「安装」页。
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

    /// 企业证书页分屏：一次只显示一段（轻松签式），不再三卡叠滚。
    /// 切栏本身不改任何状态，卡片还是原来那三张。
    @ViewBuilder
    private var pageContent: some View {
        switch certPage {
        case .certificate:
            certCard.cascadeItem(1)
        case .signing:
            signCard.cascadeItem(2)
        case .library:
            libraryCard.cascadeItem(3)
        }
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
                            Text(expiration.formatted(date: .abbreviated, time: .omitted) + remainingText(expiration))
                                .foregroundStyle(expiration < Date() ? .red : .primary)
                        }
                        .font(.footnote)
                    }
                    // 轻松签式设备提示：描述文件限定了设备台数时提醒。
                    // 本机 UDID 公开 API 拿不到，只能提示“限定了设备”，
                    // 不能断言本机在不在列表里（企业证书通常不限设备，
                    // 这一行也就不出现）。
                    if info.provisionedDeviceCount > 0 {
                        Text(L("描述文件限定了设备（共 %d 台）：如果是开发证书且本机不在列表里，签名后装不上；企业证书通常不限设备。", info.provisionedDeviceCount))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                if let cert = certInfo, !cert.name.isEmpty {
                    infoRow(L("证书"), cert.name)
                }
                // 吊销状态：手动刷新，系统信任评估联网查（OCSP）。
                // 查不出来（离线、链不全）不报假警告，只显示查不出来。
                HStack(spacing: 10) {
                    Text(L("吊销状态"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(revocationText)
                        .font(.footnote)
                        .foregroundStyle(revocationColor)
                    Spacer()
                    Button {
                        checkRevocation()
                    } label: {
                        Text(revocationChecking ? L("检查中…") : L("检查吊销状态"))
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .disabled(revocationChecking || !hasP12)
                }
                if revocationStatus == .revoked {
                    Text(L("证书已经掉签，签名后可能无法安装。"))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if let checked = revocationCheckedAt {
                    Text(L("上次检查：%@", checked.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
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
                // 轻松签式“导入证书库”：一次选 .p12 + 描述文件两个，
                // 配对才进；缺描述文件按轻松签原文报错（单导 p12 走上面）。
                HStack(spacing: 10) {
                    Button {
                        showCertLibraryPicker = true
                    } label: {
                        Text(L("导入证书库"))
                    }
                }
                .buttonStyle(.bordered)
                Text(L("证书库一次选 .p12 和描述文件两个，配不上会报错；单导 p12 走上面那个按钮。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // 导出给 LiveContainer：只发 .p12 文件和描述文件本身，
                // 密码不一起导出，LiveContainer 导入时再填一次密码。
                // 这样同一张企业证书不用再找原文件就能在另一边用。
                if hasP12 || hasProvision {
                    HStack(spacing: 10) {
                        if hasP12 {
                            ShareLink(item: EnterpriseCertStore.p12URL) {
                                Label(L("Export certificate (p12)"), systemImage: "square.and.arrow.up")
                            }
                        }
                        if hasProvision {
                            ShareLink(item: EnterpriseCertStore.provisionURL) {
                                Label(L("导出描述文件"), systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .font(.footnote)
                    Text(L("导出后可在 LiveContainer 里导入同一张证书，不用再找原文件；密码不一起导出，导入时再填一次。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if certReady {
                    Text(L("企业证书装完后，首次打开 App 前要去「设置 → 通用 → VPN 与设备管理」信任这张证书。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                SecureField(L("证书密码"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: password) { _, newValue in
                        EnterpriseCertStore.password = newValue
                    }
                    .onSubmit {
                        // 密码输完回车才刷新证书信息：每敲一下都解一次 p12 没必要。
                        refreshCertState()
                    }
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if hasP12 || hasProvision {
                    Divider()
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
        .sheet(isPresented: $showCertLibraryPicker) {
            FileImporterRepresentableView(
                allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data,
                                      UTType(filenameExtension: "mobileprovision") ?? .data],
                allowsMultipleSelection: true
            ) { urls in
                importCertLibrary(urls)
            }
        }
    }

    /// 轻松签式“导入证书库”：一次选 .p12 + 描述文件，配对才进；
    /// 只给一个（缺描述文件）就按轻松签原文报错，不单吞 p12
    ///（单导 p12 走上面那个“导入 .p12 证书”按钮）。多选了几个
    /// 时只取每种的第一个，不猜配对。
    private func importCertLibrary(_ urls: [URL]) {
        let p12 = urls.first { $0.pathExtension.lowercased() == "p12" }
        let provision = urls.first { $0.pathExtension.lowercased() == "mobileprovision" }
        guard let p12, let provision else {
            importError = L("未找到与本证书相匹配的mobileprovision文件，请将mobileprovision文件放在与p12文件相同的目录下。")
            return
        }
        do {
            try EnterpriseCertStore.importP12(from: p12)
            try EnterpriseCertStore.importProvision(from: provision)
            importError = nil
        } catch {
            importError = L("证书库导入失败：%@", error.localizedDescription)
        }
        refreshCertState()
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

    private func remainingText(_ expiration: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiration).day ?? 0
        if days < 0 { return L("（已过期）") }
        if days == 0 { return L("（今天到期）") }
        return L("（剩 %d 天）", days)
    }

    private func refreshCertState() {
        hasP12 = EnterpriseCertStore.hasP12
        hasProvision = EnterpriseCertStore.hasProvision
        provisionInfo = EnterpriseCertStore.provisionInfo
        certInfo = EnterpriseCertStore.certInfo
    }

    private var revocationText: String {
        switch revocationStatus {
        case .revoked: return L("已掉签")
        case .ok: return L("未发现掉签")
        case .unknown: return revocationCheckedAt == nil ? L("未检查") : L("查不出来")
        }
    }

    private var revocationColor: Color {
        switch revocationStatus {
        case .revoked: return .red
        case .ok: return .green
        case .unknown: return .secondary
        }
    }

    /// 吊销检查放后台线程跑（信任评估可能联网 OCSP）。
    private func checkRevocation() {
        guard !revocationChecking, hasP12 else { return }
        revocationChecking = true
        Task.detached(priority: .userInitiated) {
            let status = CertRevocationChecker.check()
            await MainActor.run {
                self.revocationStatus = status
                self.revocationCheckedAt = Date()
                self.revocationChecking = false
            }
        }
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
                    Text(L("修改（框里是原值，改了才生效）"))
                        .font(.subheadline.weight(.semibold))
                    modField(L("名称"), text: $mods.name,
                             placeholder: selectedInfo?.name ?? "")
                    modField(L("Bundle ID"), text: $mods.bundleID,
                             placeholder: selectedInfo?.bundleID ?? "")
                    modField(L("版本号"), text: $mods.version,
                             placeholder: selectedInfo?.version ?? "")
                    modField(L("最低系统版本"), text: $mods.minOS,
                             placeholder: "如 15.0")
                    iconRow
                    presetSection
                    pluginSection
                    multiOpenSection
                    Divider()
                    // 轻松签式脱壳提示：选好 IPA 就预检，加密的直接在
                    // 表单上提示（签时 startSign 还会再算一次 gate）。
                    if let cryptid = selectedCryptid, cryptid != 0 {
                        Text(L("程序未脱壳，签名后可能无法安装，建议重新脱壳签名。"))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    // 轻松签式：一个“开始签名” + “签名后立即安装”开关
                    //（开 = 签完直接装，关 = 只签存已签名）；下面“仅签名”
                    // 按钮仍在，两个去向都是一键直达。
                    Toggle(L("签名后立即安装"), isOn: $installWhenSign)
                        .font(.footnote)
                    Button {
                        startSign(kind: installWhenSign ? .signAndInstall : .signOnly)
                    } label: {
                        HStack {
                            if signBusy { ProgressView() }
                            Text(L("开始签名"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(signBusy || localInstall.isRunning || !certReady)
                    Button {
                        startSign(kind: .signOnly)
                    } label: {
                        HStack {
                            if signBusy { ProgressView() }
                            Text(L("仅签名（存到已签名）"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(signBusy || localInstall.isRunning || !certReady)
                    if let status = localInstall.status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    enterpriseInstallError
                    if let signOnlyMessage {
                        Text(signOnlyMessage)
                            .font(.footnote)
                            .foregroundStyle(signOnlyFailed ? .red : .green)
                    }
                    if !certReady {
                        Text(L("先去「证书」页把证书、描述文件和密码备齐。"))
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
        .sheet(isPresented: $showPluginPicker) {
            FileImporterRepresentableView(
                allowedContentTypes: [.item]
            ) { urls in
                for url in urls {
                    if let staged = CertPluginStore.stage(url) {
                        mods.plugins.append(staged)
                        pluginError = nil
                    } else {
                        pluginError = L("插件只支持 .dylib / .deb / .zip")
                    }
                }
            }
        }
        .alert(L("签名提醒"), isPresented: $showingWarningAlert) {
            Button(L("继续签名")) {
                if let kind = pendingSignKind, let url = pendingSignURL {
                    executeSign(kind: kind, url: url, mods: pendingSignMods)
                }
                clearPendingSign()
            }
            Button(L("取消"), role: .cancel) {
                clearPendingSign()
            }
        } message: {
            Text(pendingWarnings.joined(separator: "\n"))
        }
    }

    /// 多开：数量与起始序号。iOS 不给 App 装完回调，逐个自动
    /// 安装做不出来，所以多开只对「仅签名」生效：一次签出 N 个
    /// 副本（Bundle ID 加 .序号区分，名字也加序号），装的时候
    /// 去「已签名」里逐个点安装。数量上限 20，防手滑签一堆。
    private var multiOpenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L("多开"))
                    .font(.footnote)
                    .frame(width: 92, alignment: .leading)
                Text(L("数量"))
                    .font(.footnote)
                TextField("1", text: $multiCountText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(width: 52)
                Text(L("起始序号"))
                    .font(.footnote)
                TextField("1", text: $multiStartText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(width: 52)
                Spacer()
            }
            if multiCount > 1 {
                Text(L("会签出 %d 个副本（Bundle ID 加 .序号区分），多开只对「仅签名」生效；开着「签名后立即安装」时「开始签名」仍只签 1 个。", multiCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("可选：一次签出多个副本，装到桌面上互不冲突。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var multiCount: Int { max(1, min(20, Int(multiCountText) ?? 1)) }
    private var multiStart: Int { max(1, min(999, Int(multiStartText) ?? 1)) }

    /// 签名预设：存跨 App 通用的项（插件、最低系统版本、多开），
    /// 名字/Bundle ID/版本是每 App 自己的，不进预设。
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L("预设"))
                    .font(.footnote)
                    .frame(width: 92, alignment: .leading)
                TextField(L("新预设名称"), text: $presetNameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                Button(L("保存")) { saveCurrentPreset() }
                    .font(.footnote)
                    .disabled(presetNameText.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            if presets.isEmpty {
                Text(L("把常用的插件、最低系统版本、多开数量存成预设，下次直接套用（名字、Bundle ID、版本是每 App 自己的，不进预设）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presets) { preset in
                    HStack(spacing: 8) {
                        Button { applyPreset(preset) } label: {
                            Text(preset.name)
                                .font(.footnote)
                        }
                        Spacer()
                        Button { removePreset(preset) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let presetMessage {
                Text(presetMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveCurrentPreset() {
        let name = presetNameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        _ = CertSignPresetStore.save(name: name, minOS: mods.minOS,
            multiCount: multiCount, multiStart: multiStart,
            icon: mods.icon, pluginURLs: mods.plugins)
        presets = CertSignPresetStore.load()
        presetNameText = ""
        presetMessage = L("预设“%@”已保存。", name)
    }

    private func applyPreset(_ preset: CertSignPreset) {
        // 先清掉表单里已暂存的插件（跟换 IPA 时 resetMods 同例），
        // 再把预设的插件文件重新暂存一份进表单（预设原件不动）。
        for url in mods.plugins { CertPluginStore.remove(url) }
        mods.plugins = []
        var staged: [URL] = []
        for url in CertSignPresetStore.pluginURLs(for: preset) {
            if let stagedURL = CertPluginStore.stage(url) { staged.append(stagedURL) }
        }
        mods.plugins = staged
        mods.minOS = preset.minOS
        mods.icon = preset.icon
        iconItem = nil
        multiCountText = String(preset.multiCount)
        multiStartText = String(preset.multiStart)
        presetMessage = L("已套用预设“%@”。", preset.name)
    }

    private func removePreset(_ preset: CertSignPreset) {
        CertSignPresetStore.remove(preset)
        presets = CertSignPresetStore.load()
    }

    /// 插件注入：选好的插件（dylib/deb/zip）在签名之前注进
    /// App，不选就是不注入。
    private var pluginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L("插件注入"))
                    .font(.footnote)
                    .frame(width: 92, alignment: .leading)
                Button {
                    showPluginPicker = true
                } label: {
                    Text(L("添加插件"))
                        .font(.footnote)
                }
                Spacer()
            }
            if mods.plugins.isEmpty {
                Text(L("可选：.dylib / .deb / .zip，签名前注入"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mods.plugins, id: \.path) { url in
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            mods.plugins.removeAll { $0 == url }
                            CertPluginStore.remove(url)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let pluginError {
                Text(pluginError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func selectedIPASummary(_ url: URL) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: "app.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
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
                selectedInfo = nil
                resetMods()
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

    /// 换一个 IPA 时清掉修改项，并删掉已暂存的插件文件。
    private func resetMods() {
        for url in mods.plugins {
            CertPluginStore.remove(url)
        }
        mods = CertSignMods()
        pluginError = nil
        multiCountText = "1"
        multiStartText = "1"
        selectedCryptid = nil
    }

    private func select(_ url: URL) {
        selectedIPA = url
        // 从库里点选就是来签名的，直接切到签名段，别让用户再往上翻。
        certPage = .signing
        resetMods()
        iconItem = nil
        signOnlyMessage = nil
        // 框里预填这个 IPA 的原值，用户在原值上改；解析结果存下来，
        // 后续表单重绘直接复用，不再每敲一键重新解压读盘。
        selectedInfo = IPALibrary.appInfo(at: url)
        if let info = selectedInfo {
            mods.name = info.name
            mods.bundleID = info.bundleID
            mods.version = info.version ?? ""
            mods.minOS = info.minOS ?? ""
        }
        // 脱壳预检（轻松签式）：选好就在后台算 cryptid，加密的
        // 直接在表单上提示；选中的还是这个 IPA 才写，免得切走后
        // 旧结果盖住新表单。签时 startSign 还会再算一次 gate。
        selectedCryptid = nil
        Task.detached(priority: .userInitiated) {
            let cryptid = IPADecryptionCheck.cryptid(of: url)
            await MainActor.run {
                if self.selectedIPA == url { self.selectedCryptid = cryptid }
            }
        }
    }

    /// 签名时真正提交的改动：框里和原值一样（或被清空）的项不提交，
    /// 免得把原名、原 ID、原版本号原样再写一遍。
    private var effectiveMods: CertSignMods {
        guard let info = selectedInfo else { return mods }
        var result = mods
        let name = result.name.trimmingCharacters(in: .whitespaces)
        result.name = (name.isEmpty || name == info.name) ? "" : name
        let bundleID = result.bundleID.trimmingCharacters(in: .whitespaces)
        result.bundleID = (bundleID.isEmpty || bundleID == info.bundleID) ? "" : bundleID
        let version = result.version.trimmingCharacters(in: .whitespaces)
        result.version = (version.isEmpty || version == (info.version ?? "")) ? "" : version
        let minOS = result.minOS.trimmingCharacters(in: .whitespaces)
        result.minOS = (minOS.isEmpty || minOS == (info.minOS ?? "")) ? "" : minOS
        return result
    }

    /// 签名入口：先在后台做签前警告检查（脱壳要解压，耗时），
    /// 有警告先弹提醒（警告不拦截，点继续才执行），没警告直接执行。
    /// 吊销状态读上次手动检查的结果——没查过就不警告，不猜。
    private func startSign(kind: CertSignKind) {
        guard let url = selectedIPA, !signBusy, certReady else { return }
        signBusy = true
        signOnlyMessage = nil
        let currentMods = effectiveMods
        Task.detached(priority: .userInitiated) {
            let cryptid = IPADecryptionCheck.cryptid(of: url)
            await MainActor.run {
                var warnings: [String] = []
                if self.revocationStatus == .revoked {
                    warnings.append(L("证书已经掉签，签名后可能无法安装。"))
                }
                if let cryptid, cryptid != 0 {
                    warnings.append(L("程序未脱壳，签名后可能无法安装，建议重新脱壳签名。"))
                }
                if warnings.isEmpty {
                    self.executeSign(kind: kind, url: url, mods: currentMods)
                } else {
                    self.pendingWarnings = warnings
                    self.pendingSignKind = kind
                    self.pendingSignURL = url
                    self.pendingSignMods = currentMods
                    self.showingWarningAlert = true
                    self.signBusy = false
                }
            }
        }
    }

    private func clearPendingSign() {
        pendingWarnings = []
        pendingSignKind = nil
        pendingSignURL = nil
        pendingSignMods = CertSignMods()
    }

    private func executeSign(kind: CertSignKind, url: URL, mods: CertSignMods) {
        signBusy = true
        switch kind {
        case .signOnly:
            Task {
                do {
                    if multiCount > 1 {
                        // 多开：同表单、同插件、同图标，逐个换 Bundle ID
                        // 后缀和名字后缀签。原值被 effectiveMods 清空时
                        // 回落到 IPA 本身的名字和 Bundle ID。
                        let baseName = mods.name.isEmpty
                            ? (selectedInfo?.name ?? url.deletingPathExtension().lastPathComponent)
                            : mods.name
                        let baseID = mods.bundleID.isEmpty
                            ? (selectedInfo?.bundleID ?? "")
                            : mods.bundleID
                        for j in 0..<multiCount {
                            let idx = multiStart + j
                            var copy = mods
                            copy.name = "\(baseName) \(idx)"
                            // Bundle ID 实在读不出来就不加后缀（签出来
                            // 和原包同 ID，装的时候会顶掉原包，不静默造假）。
                            copy.bundleID = baseID.isEmpty ? "" : "\(baseID).\(idx)"
                            _ = try await CertSigner.signToFile(ipa: url, mods: copy)
                        }
                        signedRecords = SignedIPAStore.load()
                        unsignedIPAs = unsignedItems()
                        ensureUnsignedInfo()
                        CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                            appName: baseName, kind: .signOnly, success: true,
                            detail: L("已签出 %d 个副本，存到「已签名」。", multiCount)))
                        signOnlyMessage = L("已签出 %d 个副本，存到「应用库 → 已签名」，逐个点安装。", multiCount)
                        signOnlyFailed = false
                    } else {
                        let record = try await CertSigner.signToFile(ipa: url, mods: mods)
                        signedRecords = SignedIPAStore.load()
                        unsignedIPAs = unsignedItems()
                        ensureUnsignedInfo()
                        CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                            appName: record.appName, kind: .signOnly, success: true,
                            detail: L("已存到「已签名」")))
                        signOnlyMessage = L("签好了，已存到「应用库 → 已签名」。")
                        signOnlyFailed = false
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                    signOnlyMessage = message
                    signOnlyFailed = true
                    CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                        appName: selectedInfo?.name ?? url.deletingPathExtension().lastPathComponent,
                        kind: .signOnly, success: false, detail: message))
                }
                logEntries = CertSignLogStore.load()
                signBusy = false
            }
        case .signAndInstall:
            Task {
                do {
                    // 先签好存进「已签名」，再走企业独立安装（本地
                    // 回环，不走共用 Engine、不走隧道、不要 WiFi）。
                    let record = try await CertSigner.signToFile(ipa: url, mods: mods)
                    signedRecords = SignedIPAStore.load()
                    unsignedIPAs = unsignedItems()
                    ensureUnsignedInfo()
                    CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                        appName: record.appName, kind: .signAndInstall, success: true,
                        detail: L("已签好，已拉起安装。")))
                    await MainActor.run {
                        self.localFallbackRecord = record
                        self.localInstall.install(record: record)
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                    signOnlyMessage = message
                    signOnlyFailed = true
                    CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                        appName: selectedInfo?.name ?? url.deletingPathExtension().lastPathComponent,
                        kind: .signAndInstall, success: false, detail: message))
                }
                logEntries = CertSignLogStore.load()
                signBusy = false
            }
        }
    }

    /// 已签名行「安装」：走企业独立安装（本地回环，不走共用
    /// Engine、不走隧道、不要 WiFi）。回环失败时原因只在
    /// 企业页内显示 + 重试回环，绝不去共享「安装」页。
    private func installSigned(_ record: SignedIPARecord) {
        localFallbackRecord = record
        localInstall.install(record: record)
    }

    // MARK: 应用库（未签名/已签名切栏）

    /// 文件页（Documents 管理）原样保留；这里只是证书页里的
    /// 一个应用库切栏：未签名栏复用文件库数据（只读展示 +
    /// 点进签名），已签名栏就是原来的已签名列表。
    private var libraryCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack")
                        .foregroundStyle(.secondary)
                    Text(L("应用库"))
                        .font(.headline)
                    Spacer()
                }
                // 轻松签应用页同款浅灰搜索框，两个切栏都按名字过滤。
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L("搜索"), text: $librarySearchText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
                Picker("", selection: $libraryTab) {
                    Text(L("未签名")).tag(CertLibraryTab.unsigned)
                    Text(L("已签名")).tag(CertLibraryTab.signed)
                    Text(L("记录")).tag(CertLibraryTab.log)
                }
                .pickerStyle(.segmented)
                libraryContent
            }
        }
        .alert(L("删除这个已签名 IPA？"), isPresented: $showingDeleteConfirm) {
            Button(L("删除"), role: .destructive) {
                if let record = recordPendingDelete {
                    SignedIPAStore.remove(record)
                    signedRecords = SignedIPAStore.load()
                }
                recordPendingDelete = nil
            }
            Button(L("取消"), role: .cancel) {
                recordPendingDelete = nil
            }
        } message: {
            Text(L("会删掉文件和这条记录，之后要重签才能再装。"))
        }
        .alert(L("删除选中的已签名 IPA？"), isPresented: $showingBatchDeleteConfirm) {
            Button(L("删除"), role: .destructive) {
                let targets = signedRecords.filter { selectedSignedIDs.contains($0.id) }
                SignedIPAStore.remove(targets)
                signedRecords = SignedIPAStore.load()
                selectedSignedIDs.removeAll()
                selectingSigned = false
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("一次删掉选中的 %d 个，文件和记录一起删。", selectedSignedIDs.count))
        }
    }

    /// switch 返回两种不同 View，普通函数必须加 @ViewBuilder
    /// 才能编（body 自带，普通函数没有）。
    @ViewBuilder
    private var libraryContent: some View {
        switch libraryTab {
        case .unsigned:
            unsignedList
        case .signed:
            signedList
        case .log:
            logList
        }
    }

    /// 未签名栏：文件库里还没签过的 IPA（Signed 目录里的已签
    /// 成品不算未签名）。只读展示名字、目录、大小，不逐行解
    /// Info.plist（证书页每敲一键都重读是已知性能坑）；点
    /// 「去签名」就进签名段表单。
    /// 按目录分组（轻松签应用库式）：根目录在前，其余按目录名排。
    private var unsignedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if filteredUnsigned.isEmpty {
                Text(librarySearchText.isEmpty
                     ? L("文件库里还没有没签过的 IPA。去文件页导入一个，或者去「签名」页点「从文件导入」。")
                     : L("没有匹配的 IPA。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Text(L("共 %d 个", filteredUnsigned.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        batchingUnsigned.toggle()
                        if !batchingUnsigned { selectedUnsignedIDs.removeAll() }
                    } label: {
                        Text(batchingUnsigned ? L("完成") : L("批量"))
                            .font(.footnote)
                    }
                    .disabled(batchBusy)
                }
                ForEach(groupedUnsigned, id: \.key) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.key.isEmpty ? L("根目录") : group.key)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(group.items) { item in
                            unsignedRow(item)
                            if item.id != group.items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                if batchingUnsigned {
                    HStack(spacing: 12) {
                        Button { selectedUnsignedIDs = Set(filteredUnsigned.map { $0.id }) } label: {
                            Text(L("全选")).font(.footnote)
                        }
                        Button { selectedUnsignedIDs.removeAll() } label: {
                            Text(L("取消全选")).font(.footnote)
                        }
                        Spacer()
                        Button { batchSign() } label: {
                            Text(L("签名选中（%d）", selectedUnsignedIDs.count)).font(.footnote)
                        }
                        .disabled(selectedUnsignedIDs.isEmpty || batchBusy)
                    }
                    if let batchMessage {
                        Text(batchMessage)
                            .font(.footnote)
                            .foregroundStyle(batchFailed ? .red : .green)
                    }
                }
            }
        }
    }

    /// 未签名栏按目录分组：同一目录的放一组，组内保持原顺序。
    private var groupedUnsigned: [(key: String, items: [LocalFileItem])] {
        let groups = Dictionary(grouping: filteredUnsigned, by: { $0.relativeDir })
        return groups.keys.sorted(by: { a, b in
            if a.isEmpty { return true }
            if b.isEmpty { return false }
            return a < b
        }).map { key in (key: key, items: groups[key] ?? []) }
    }

    /// 搜索过滤只读缓存：名字命中文件名或解析出的 App 名都算，
    /// 敲键绝不触发解析（解析只在切栏/进页/签完刷新时跑一次）。
    private var filteredUnsigned: [LocalFileItem] {
        guard !librarySearchText.isEmpty else { return unsignedIPAs }
        let query = librarySearchText.lowercased()
        return unsignedIPAs.filter { item in
            item.name.lowercased().contains(query)
                || (unsignedInfo[item.url.path]?.name.lowercased().contains(query) == true)
        }
    }

    /// 轻松签应用页未签名行：名字 / V版本 | 大小 | Bundle ID / 文件名，
    /// 整行可点进签名段表单（不要行内按钮）。
    private func unsignedRowTexts(_ item: LocalFileItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(unsignedDisplayName(item))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(unsignedSecondLine(item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// if 两分支是两种不同 View，普通函数必须加 @ViewBuilder
    ///（跟 libraryContent 的 switch 同例，不加编不过）。
    @ViewBuilder
    private func unsignedRow(_ item: LocalFileItem) -> some View {
        if batchingUnsigned {
            Button {
                if selectedUnsignedIDs.contains(item.id) {
                    selectedUnsignedIDs.remove(item.id)
                } else {
                    selectedUnsignedIDs.insert(item.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedUnsignedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedUnsignedIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                    unsignedRowTexts(item)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                select(item.url)
            } label: {
                unsignedRowTexts(item)
            }
            .buttonStyle(.plain)
        }
    }

    /// 批量签名：只签名不安装（一次装多个做不出来，跟多开同理），
    /// 每 App 原信息不动（名字、Bundle ID 等都不改），逐个签进「已签名」。
    private func batchSign() {
        guard !batchBusy, !selectedUnsignedIDs.isEmpty else { return }
        guard certReady else {
            batchMessage = L("先去「证书」页把证书、描述文件和密码备齐。")
            batchFailed = true
            return
        }
        let targets = unsignedIPAs.filter { selectedUnsignedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        batchBusy = true
        batchMessage = nil
        Task {
            var ok = 0
            var fail = 0
            var firstError: String?
            for item in targets {
                do {
                    _ = try await CertSigner.signToFile(ipa: item.url, mods: CertSignMods())
                    CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                        appName: unsignedDisplayName(item), kind: .batch, success: true,
                        detail: L("已存到「已签名」")))
                    ok += 1
                } catch {
                    fail += 1
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    if firstError == nil { firstError = message }
                    CertSignLogStore.append(CertSignLogEntry(id: UUID(), date: Date(),
                        appName: unsignedDisplayName(item), kind: .batch, success: false,
                        detail: message))
                }
            }
            await MainActor.run {
                self.signedRecords = SignedIPAStore.load()
                self.unsignedIPAs = self.unsignedItems()
                self.ensureUnsignedInfo()
                self.logEntries = CertSignLogStore.load()
                self.selectedUnsignedIDs = self.selectedUnsignedIDs.intersection(self.unsignedIPAs.map { $0.id })
                self.batchBusy = false
                if fail == 0 {
                    self.batchMessage = L("批量签完：%d 个已存到「已签名」。", ok)
                    self.batchFailed = false
                } else {
                    var message = L("批量签完：成功 %d 个，失败 %d 个。", ok, fail)
                    if let firstError { message += " " + firstError }
                    self.batchMessage = message
                    self.batchFailed = true
                }
            }
        }
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if logEntries.isEmpty {
                Text(L("还没有签名记录。签一次就会记一条，成功失败都有。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Text(L("共 %d 条", logEntries.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { showingLogClearConfirm = true } label: {
                        Text(L("清空")).font(.footnote)
                    }
                }
                ForEach(logEntries) { entry in
                    logRow(entry)
                    if entry.id != logEntries.last?.id { Divider() }
                }
            }
        }
        .alert(L("清空签名记录？"), isPresented: $showingLogClearConfirm) {
            Button(L("清空"), role: .destructive) {
                CertSignLogStore.clear()
                logEntries = []
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("只删记录，不动已签名的 IPA 文件。"))
        }
    }

    private func logRow(_ entry: CertSignLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.appName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(entry.success ? L("成功") : L("失败"))
                    .font(.caption)
                    .foregroundStyle(entry.success ? .green : .red)
            }
            Text("\(logKindText(entry.kind)) · \(Self.logDateFormatter.string(from: entry.date))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func logKindText(_ kind: CertSignLogKind) -> String {
        switch kind {
        case .signOnly: return L("仅签名")
        case .signAndInstall: return L("签名并安装")
        case .batch: return L("批量签名")
        }
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func unsignedDisplayName(_ item: LocalFileItem) -> String {
        if let name = unsignedInfo[item.url.path]?.name, !name.isEmpty {
            return name
        }
        return (item.name as NSString).deletingPathExtension
    }

    /// 第二行：V版本 | 大小 | Bundle ID；版本缺了就省掉 V 那段，
    /// 解析失败只显示大小，不造假。
    private func unsignedSecondLine(_ item: LocalFileItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        guard let info = unsignedInfo[item.url.path] else { return size }
        var parts: [String] = []
        if let version = info.version, !version.isEmpty {
            parts.append("V\(version)")
        }
        parts.append(size)
        if !info.bundleID.isEmpty {
            parts.append(info.bundleID)
        }
        return parts.joined(separator: " | ")
    }

    private func unsignedItems() -> [LocalFileItem] {
        AppFileLibrary.scan().filter { $0.isIPA && !$0.isInSignedDir }
    }

    /// 未签名栏的 IPA 信息只解析一次：切到未签名栏/进页/签完刷新时，
    /// 把还没试过的路径在后台统一解析，结果按路径缓存；解析失败也记
    /// 已尝试，不重复读盘。删掉的路径清掉缓存，免得同名新文件沿用旧信息。
    private func ensureUnsignedInfo() {
        let current = Set(unsignedIPAs.map { $0.url.path })
        unsignedInfo = unsignedInfo.filter { current.contains($0.key) }
        unsignedInfoTried = unsignedInfoTried.intersection(current)
        let pending = unsignedIPAs.filter { !unsignedInfoTried.contains($0.url.path) }
        guard !pending.isEmpty else { return }
        for item in pending { unsignedInfoTried.insert(item.url.path) }
        let urls = pending.map { $0.url }
        Task.detached(priority: .userInitiated) {
            var found: [String: IPALibrary.AppInfo] = [:]
            for url in urls {
                if let info = IPALibrary.appInfo(at: url) {
                    found[url.path] = info
                }
            }
            await MainActor.run {
                for (path, info) in found {
                    self.unsignedInfo[path] = info
                }
            }
        }
    }

    /// 企业安装失败提示 + 回环重试：只在企业页内显示，
    /// 不弹配对兜底、不碰共享「安装」页。
    @ViewBuilder
    private var enterpriseInstallError: some View {
        if let error = localInstall.lastError, !localInstall.isRunning {
            HStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Spacer()
                if let record = localFallbackRecord {
                    Button(L("重试回环安装")) { localInstall.install(record: record) }
                        .font(.footnote)
                }
            }
        }
    }

    private var signedList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = localInstall.status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            enterpriseInstallError
            if signedRecords.isEmpty {
                Text(L("还没有已签名的 IPA。用「签名」页的「仅签名」签好就会存到这里，随时能装、能分享。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if filteredSigned.isEmpty {
                Text(L("没有匹配的已签名 IPA。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Text(L("共 %d 个", filteredSigned.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        selectingSigned.toggle()
                        if !selectingSigned { selectedSignedIDs.removeAll() }
                    } label: {
                        Text(selectingSigned ? L("完成") : L("选择"))
                            .font(.footnote)
                    }
                }
                ForEach(filteredSigned) { record in
                    signedRow(record)
                    if record.id != filteredSigned.last?.id {
                        Divider()
                    }
                }
                if selectingSigned {
                    HStack(spacing: 12) {
                        Button {
                            // 全选只选当前可见的（搜了就只选搜到的）。
                            selectedSignedIDs = Set(filteredSigned.map { $0.id })
                        } label: {
                            Text(L("全选"))
                                .font(.footnote)
                        }
                        Button {
                            selectedSignedIDs.removeAll()
                        } label: {
                            Text(L("取消全选"))
                                .font(.footnote)
                        }
                        Spacer()
                        Button {
                            showingBatchDeleteConfirm = true
                        } label: {
                            Text(L("删除选中（%d）", selectedSignedIDs.count))
                                .font(.footnote)
                        }
                        .disabled(selectedSignedIDs.isEmpty)
                    }
                }
            }
        }
    }

    private func signedRow(_ record: SignedIPARecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if selectingSigned {
                    Button {
                        if selectedSignedIDs.contains(record.id) {
                            selectedSignedIDs.remove(record.id)
                        } else {
                            selectedSignedIDs.insert(record.id)
                        }
                    } label: {
                        Image(systemName: selectedSignedIDs.contains(record.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedSignedIDs.contains(record.id) ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.appName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(signedSecondLine(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let certLine = signedCertLine(record) {
                        Text(certLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            if !selectingSigned {
                HStack(spacing: 14) {
                    Button {
                        installSigned(record)
                    } label: {
                        Text(L("安装"))
                            .font(.footnote.weight(.semibold))
                    }
                    .disabled(localInstall.isRunning)
                    ShareLink(item: SignedIPAStore.url(for: record)) {
                        Text(L("分享"))
                            .font(.footnote)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        recordPendingDelete = record
                        showingDeleteConfirm = true
                    } label: {
                        Text(L("删除"))
                            .font(.footnote)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// 搜索过滤：名字命中 App 名或文件名都算。
    private var filteredSigned: [SignedIPARecord] {
        guard !librarySearchText.isEmpty else { return signedRecords }
        let query = librarySearchText.lowercased()
        return signedRecords.filter { record in
            record.appName.lowercased().contains(query)
                || record.fileName.lowercased().contains(query)
        }
    }

    /// 轻松签已签名行第二行：v版本 - 签名时间:yyyy-MM-dd HH:mm:ss。
    private func signedSecondLine(_ record: SignedIPARecord) -> String {
        let time = Self.esignDateFormatter.string(from: record.date)
        if let version = record.version, !version.isEmpty {
            return L("v%@ - 签名时间:%@", version, time)
        }
        return L("签名时间:%@", time)
    }

    /// 轻松签已签名行第三行：iPhone Distribution: 证书名 (团队ID)。
    /// 老记录没这两个字段就不显示这一行；团队 ID 没有就只显示证书名。
    private func signedCertLine(_ record: SignedIPARecord) -> String? {
        guard let certName = record.certName, !certName.isEmpty else { return nil }
        if let teamID = record.teamID, !teamID.isEmpty {
            return "\(certName) (\(teamID))"
        }
        return certName
    }

    /// 签名时间的固定格式（轻松签同款 yyyy-MM-dd HH:mm:ss）。
    private static let esignDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// 签名流程两种去向：仅签名存已签名，或签名后走本地直装。
private enum CertSignKind {
    case signOnly
    case signAndInstall
}

/// 企业证书页切栏：证书 / 签名 / 应用库。
private enum CertPage: Identifiable {
    case certificate
    case signing
    case library

    var id: String {
        switch self {
        case .certificate: return "certificate"
        case .signing: return "signing"
        case .library: return "library"
        }
    }
}

/// 应用库切栏。
private enum CertLibraryTab: Identifiable, Hashable {
    case unsigned
    case signed
    case log

    var id: String {
        switch self {
        case .unsigned: return "unsigned"
        case .signed: return "signed"
        case .log: return "log"
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
