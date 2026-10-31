import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Documents 里的一个文件或文件夹（递归，含子文件夹）。
struct LocalFileItem: Identifiable {
    let url: URL
    let name: String
    /// 相对 Documents 的目录（"" 是根目录，如 "Custom"、"Signed"）。
    let relativeDir: String
    let size: Int
    let modified: Date?
    /// 是不是文件夹：轻松签文件列表式，文件夹也是一行。
    let isDirectory: Bool
    /// 文件夹的直接子项数（不含隐藏项），文件恒为 0。
    let childCount: Int
    var id: String { url.path }
    var isIPA: Bool { name.lowercased().hasSuffix(".ipa") }
    var isZip: Bool { name.lowercased().hasSuffix(".zip") }
    var isInSignedDir: Bool { relativeDir == "Signed" }
    /// App 自己用的 DDI 支撑文件，不是用户文件：DDI 文件夹、以及根
    /// 目录或 DDI/ 里的 Image.dmg、trustcache、BuildManifest。文件页
    /// 默认不把它们混在用户文件里，收到系统文件组里，需要时再展开。
    var isSystem: Bool {
        if isDirectory { return name == "DDI" }
        let ddiNames: Set<String> = ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"]
        guard ddiNames.contains(name) else { return false }
        return relativeDir.isEmpty || relativeDir == "DDI" || relativeDir.hasPrefix("DDI/")
    }
}

/// App 自己 Documents 目录的文件扫描（下载/导入/已签名都在这）。
enum AppFileLibrary {
    static func scan() -> [LocalFileItem] {
        let root = IPALibrary.documentsDir
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var items: [LocalFileItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory == true
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let dir = (rel as NSString).deletingLastPathComponent
            // 文件夹数直接子项（不含隐藏项），文件恒为 0。
            let childCount: Int
            if isDirectory {
                let children = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                childCount = children.filter { !$0.hasPrefix(".") }.count
            } else {
                childCount = 0
            }
            items.append(LocalFileItem(
                url: url,
                name: url.lastPathComponent,
                relativeDir: dir == "." ? "" : dir,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate,
                isDirectory: isDirectory,
                childCount: childCount))
        }
        return items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// 把外部文件拷进 Documents 根目录，重名自动改名，返回落点。
    static func importIntoDocuments(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = IPALibrary.documentsDir.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = IPALibrary.documentsDir.appendingPathComponent(name)
            counter += 1
        }
        try fm.copyItem(at: source, to: candidate)
        return candidate
    }
}

/// 文件页：管理 App 沙盒 Documents 里的文件——导入、分享、删除，
/// IPA 可以直接去企业证书签名或（已签名的）直接安装。
struct FilesTabView: View {
    // 注意：这里不再声明 engine（v63 起文件页不观察 Engine 了——
    // 企业安装走本地服务，安装 tab 的 ID 线与文件页彻底脱钩；
    // 要动 Engine 请去安装 tab 那边，勿往回加）。
    /// 企业本地安装服务（单例，与证书页共用同一实例，状态不分裂）。
    @ObservedObject private var localInstall = LocalHTTPInstallServer.shared
    /// IPA 文件行图标缓存（路径 → 图标数据）与已试集合（键 =
    /// 路径#大小#修改时间，文件换了就重取，不死循环重试）。
    @State private var fileIcons: [String: Data] = [:]
    @State private var fileIconsTried: Set<String> = []
    /// Declared so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var workspace: CertWorkspace
    /// 切到证书页（RootView 给的）。
    var onGoCert: () -> Void

    /// First scan happens in onAppear; starting empty so the list isn't
    /// scanned twice on first appearance.
    @State private var files: [LocalFileItem] = []
    @State private var showImporter = false
    @State private var importError: String?
    // 多选 / 重命名 / 压缩解压
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var renameItem: LocalFileItem?
    @State private var renameText = ""
    @State private var opBusy = false
    @State private var opMessage: String?
    @State private var opFailed = false
    // Mach-O 查看 / 局域网传输
    @State private var machoItem: LocalFileItem?
    /// ⓘ 详情 sheet 正在看的行。
    @State private var detailItem: LocalFileItem?
    /// 系统文件组是否展开（默认折叠，文件页先只看用户文件）。
    @State private var showSystemFiles = false
    /// 文件页搜索（轻松签文件列表顶部搜索条同款）：按名字过滤当前视图。
    @State private var fileSearchText = ""
    /// 当前进的文件夹（相对 Documents 的路径，"" = 根目录）：
    /// 点文件夹行就进，返回条回上级；删了当前文件夹就回根目录。
    @State private var currentDir = ""
    /// 新建文件夹：名字输入（alert 里填）+ 是否弹出。
    @State private var newFolderName = ""
    @State private var showNewFolderAlert = false
    /// 要移动的文件/文件夹（sheet 的 item，nil 就不弹）。
    @State private var moveItem: LocalFileItem?
    @StateObject private var lanServer = LANTransferServer()
    /// 文件页已签名安装：走轻松签式本地安装（LocalHTTPInstallServer，
    /// v63 起，企业签的包专用）。进行中标志 + 拉起成功弹框
    ///（证书页同款，inFlight 隔离：两页的 completion 各只认自己
    /// 起的安装）；重试用的记录/文件地址（装时记下，无记录的
    /// 现解析安装记地址）；失败原因快照（证书页同款，不直接读
    /// localInstall 全局量，免得别的页的失败串到这里）。
    @State private var fileInstallInFlight = false
    @State private var showingFileInstallSuccessAlert = false
    @State private var fileInstallRecord: SignedIPARecord?
    @State private var fileInstallURL: URL?
    @State private var fileInstallErrorText: String?
    /// 局域网地址点按复制后的短暂「已复制」提示。
    @State private var lanCopied = false

    private var ipas: [LocalFileItem] { files.filter { $0.isIPA } }
    private var others: [LocalFileItem] { files.filter { !$0.isIPA && !$0.isSystem } }
    private var systemFiles: [LocalFileItem] { files.filter { $0.isSystem } }
    private var totalSize: Int { files.reduce(0) { $0 + $1.size } }

    /// 搜索过滤（当前视图）：名字含查询串就算，不区分大小写。
    private func matching(_ items: [LocalFileItem]) -> [LocalFileItem] {
        guard !fileSearchText.isEmpty else { return items }
        let query = fileSearchText.lowercased()
        return items.filter { $0.name.lowercased().contains(query) }
    }

    /// 当前文件夹的直接子项（文件夹 + 文件同一列表，扫描顺序）。
    private var currentDirItems: [LocalFileItem] {
        matching(files.filter { $0.relativeDir == currentDir })
    }

    /// 文件夹的相对路径（进文件夹用）：根目录下的文件夹就是名字，
    /// 深层的就是“父目录/名字”。
    private func folderPath(_ item: LocalFileItem) -> String {
        item.relativeDir.isEmpty ? item.name : "\(item.relativeDir)/\(item.name)"
    }

    /// 当前文件夹的显示名（返回条用）。
    private var currentDirName: String {
        (currentDir as NSString).lastPathComponent
    }

    /// 文件页已签名 IPA 安装：只走轻松签式本地安装（v63 起），
    /// 不碰 Engine/共享「安装」页；记录找得到就用记录里的
    /// 包名/Bundle ID/版本，找不到（手动拷进已签名目录的）就
    /// 现解析 Info.plist（只读 central directory + 单条目，不整
    /// 包解压，主线程也快）——解析不到 Bundle ID 就明说装不了，
    /// 不静默失败、不拿空 Bundle ID 去拼清单。
    private func installSignedFile(_ item: LocalFileItem) {
        if let record = SignedIPAStore.load().first(where: { SignedIPAStore.url(for: $0) == item.url }) {
            startEnterpriseInstall(ipaURL: item.url, record: record)
            return
        }
        startEnterpriseInstall(ipaURL: item.url, record: nil)
    }

    /// 文件页安装统一入口（证书页 startEnterpriseInstall 同款）：
    /// 调本地安装服务（本机 HTTP + itms-services），全程只在
    /// 文件页内反馈——进行中显示服务状态 +“取消安装”，拉起
    /// 成功弹框，失败快照原因 +“重试安装”。绝不调
    /// engine.runInstallSignedIPA（那是 ID/Engine 路）。无记录
    /// 时 Bundle ID/版本现解析（见 installSignedFile）；有记录
    /// 时直接用记录值。文件页安装不写 CertSignLogStore（v62
    /// 也不写；日志的 kind 没有“仅安装”一项，硬记会把一次
    /// 只装没签的说成“签名并安装”，误导——文件页自己的
    /// 状态条 + 成功弹框就是反馈）。
    private func startEnterpriseInstall(ipaURL: URL, record: SignedIPARecord?) {
        fileInstallRecord = record
        fileInstallURL = ipaURL
        fileInstallErrorText = nil
        let appName: String
        let bundleID: String
        let version: String?
        if let record {
            appName = record.appName
            bundleID = record.bundleID
            version = record.version
        } else if let info = IPALibrary.appInfo(at: ipaURL) {
            appName = info.name
            bundleID = info.bundleID
            version = info.version
        } else {
            fileInstallErrorText = L("这个 IPA 解析不到 Bundle ID，装不了，请重新签名或换个包。")
            return
        }
        // isBusy（同步）不用 isRunning（异步置位）：理由见证书页
        // 同款 guard——启动窗口里的第二次点按在这里就挡住，只显
        // 错误文本，不进 install()、不记失败。
        guard !localInstall.isBusy else {
            fileInstallErrorText = L("已有本地安装在进行，先取消当前安装再试。")
            return
        }
        fileInstallInFlight = true
        localInstall.install(ipaURL: ipaURL, appName: appName, bundleID: bundleID, version: version ?? "1.0") { [self] ok, message in
            fileInstallInFlight = false
            if ok {
                showingFileInstallSuccessAlert = true
            } else {
                fileInstallErrorText = message ?? L("本地安装没能启动，点重试。")
            }
        }
    }

    /// 文件页本地安装状态：只在文件页内显示，不碰共享「安装」页。
    /// 进行中显示服务状态 +“取消安装”（停本地服务；取消不记
    /// 成功也不记失败，inFlight 由这里直接清，不等 completion）；
    /// 失败时显示快照的原因 +“重试安装”（原因来自
    /// startEnterpriseInstall 的 completion，不直接读 localInstall
    /// 的全局 lastError，免得别的页的失败串到这里）。
    @ViewBuilder
    private var fileInstallStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 进行中 = 服务在跑或刚调 install、异步块还没跑到
            //（证书页同款，启动窗口里也显示状态 + 取消）。
            if localInstall.isRunning || fileInstallInFlight {
                HStack(spacing: 8) {
                    Text(localInstall.status ?? L("本地安装进行中"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("取消安装")) {
                        localInstall.stop()
                        fileInstallInFlight = false
                        fileInstallErrorText = nil
                    }
                    .font(.footnote)
                }
            } else if let error = fileInstallErrorText {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                    if let record = fileInstallRecord {
                        Button(L("重试安装")) { startEnterpriseInstall(ipaURL: SignedIPAStore.url(for: record), record: record) }
                            .font(.footnote)
                    } else if let url = fileInstallURL {
                        Button(L("重试安装")) { startEnterpriseInstall(ipaURL: url, record: nil) }
                            .font(.footnote)
                    }
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    importCard.cascadeItem(1)
                    fileInstallStatus
                    if selecting {
                        selectionBar.cascadeItem(2)
                    }
                    fileSearchBar
                    fileActionRow
                    if !currentDir.isEmpty {
                        currentDirBar
                        if currentDirItems.isEmpty {
                            emptyCard.cascadeItem(2)
                        } else {
                            folderSection(items: currentDirItems).cascadeItem(2)
                        }
                    } else if files.isEmpty {
                        emptyCard.cascadeItem(2)
                    } else {
                        if !matching(ipas).isEmpty {
                            fileSection(title: L("IPA 文件"), items: matching(ipas)).cascadeItem(2)
                        }
                        if !matching(others).isEmpty {
                            fileSection(title: L("其他文件"), items: matching(others)).cascadeItem(3)
                        }
                        if !matching(systemFiles).isEmpty {
                            systemSection.cascadeItem(4)
                        }
                    }
                }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(AppBackground())
        }
        .onAppear { files = AppFileLibrary.scan() }
        // 文件页安装不再走 Engine：结果由 startEnterpriseInstall
        // 的 completion 直接回（拉起成功弹框、失败快照原因），
        // 不再监听 engine.isRunning（那是 ID 线的全局量）。
        .alert(L("安装已拉起"), isPresented: $showingFileInstallSuccessAlert) {
            Button(L("知道了"), role: .cancel) {}
        } message: {
            Text(L("已拉起系统安装，点「安装」后回桌面查看安装进度。"))
        }
        .alert(L("重命名"), isPresented: Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField(L("文件名"), text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("取消"), role: .cancel) { renameItem = nil }
            Button(L("保存")) { performRename() }
        } message: {
            Text(L("扩展名别改错，不然文件可能打不开。"))
        }
        .alert(L("新建文件夹"), isPresented: $showNewFolderAlert) {
            TextField(L("请输入文件夹名字"), text: $newFolderName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("取消"), role: .cancel) { showNewFolderAlert = false }
            Button(L("创建")) {
                showNewFolderAlert = false
                createFolder()
            }
        }
        .sheet(item: $machoItem) { item in
            MachOView(url: item.url, fileName: item.name)
        }
        .sheet(item: $detailItem) { item in
            FileDetailSheet(item: item, onDelete: {
                detailItem = nil
                delete(item)
            }, onRename: {
                detailItem = nil
                renameText = item.name
                renameItem = item
            }, onMove: {
                detailItem = nil
                moveItem = item
            }, onDuplicate: {
                detailItem = nil
                duplicate(item)
            })
        }
        .sheet(item: $moveItem) { item in
            NavigationStack {
                List {
                    if moveDestinations(for: item).isEmpty {
                        Text(L("没有可移动到的文件夹，先新建一个。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(moveDestinations(for: item), id: \.dir) { dest in
                        Button {
                            moveItem = nil
                            moveItemToFolder(item, dest.dir)
                        } label: {
                            HStack {
                                Image(systemName: dest.dir.isEmpty ? "house" : "folder")
                                Text(dest.name)
                                Spacer()
                            }
                        }
                    }
                }
                .navigationTitle(L("移动到"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("取消")) { moveItem = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            FileImporterRepresentableView(
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { urls in
                for url in urls {
                    do {
                        _ = try AppFileLibrary.importIntoDocuments(url)
                        importError = nil
                    } catch {
                        importError = L("导入失败：%@", error.localizedDescription)
                    }
                }
                files = AppFileLibrary.scan()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("文件"))
                    .font(.largeTitle.weight(.bold))
                Text(L("%d 个文件 · %@", files.count,
                       ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !files.isEmpty {
                Button {
                    selecting.toggle()
                    selection = []
                } label: {
                    Text(selecting ? L("完成") : L("选择"))
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    /// 多选时的操作条：压缩成一个 zip / 批量删除。
    private var selectionBar: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("已选 %d 个", selection.count))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    Button {
                        zipSelection()
                    } label: {
                        HStack {
                            if opBusy { ProgressView() }
                            Text(L("压缩成 ZIP"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(selection.isEmpty || opBusy)
                    Button(role: .destructive) {
                        deleteSelection()
                    } label: {
                        Text(L("删除所选"))
                    }
                    .buttonStyle(.bordered)
                    .disabled(selection.isEmpty || opBusy)
                }
            }
        }
    }

    private var importCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                    Text(L("文件管理"))
                        .font(.headline)
                }
                Text(L("这里是 App 自己的文件目录：下载的、导入的、已签名的 IPA 都在这。也可以在「文件」App 里往 SideInstaller 的目录放文件，回到这里就能看到。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    showImporter = true
                } label: {
                    Text(L("导入文件"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let importError {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if opBusy {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(L("处理中…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let opMessage {
                    Text(opMessage)
                        .font(.footnote)
                        .foregroundStyle(opFailed ? .red : .green)
                }
                Divider()
                lanSection
            }
        }
    }

    /// 局域网传输开关：开着时同 Wi-Fi 的浏览器能管理这个目录。
    private var lanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Text(L("局域网传输"))
                    .font(.headline)
            }
            if lanServer.isRunning {
                Text(L("电脑和手机连同一个 Wi-Fi，浏览器打开这个地址就能上传、下载、删除这里的文件："))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = lanServer.addressText
                    withAnimation { lanCopied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { lanCopied = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(lanServer.addressText)
                            .font(.footnote.monospaced().weight(.semibold))
                        Image(systemName: lanCopied ? "checkmark" : "doc.on.doc")
                            .font(.footnote)
                            .foregroundStyle(lanCopied ? Color.green : Color.secondary)
                        if lanCopied {
                            Text(L("已复制"))
                                .font(.footnote)
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    lanServer.stop()
                } label: {
                    Text(L("关闭局域网传输"))
                        .font(.footnote)
                }
            } else {
                Text(L("开启后，同一 Wi-Fi 下的电脑打开网页就能往这里传文件，不用数据线。关掉就停，只在本机开着时有效。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    lanServer.start()
                } label: {
                    Text(L("开启局域网传输"))
                        .font(.footnote)
                }
                if let error = lanServer.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var emptyCard: some View {
        PanelCard {
            Text(L("还没有文件。点上面「导入文件」放 IPA 进来，或在安装页下载/导入后这里会出现。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 文件页顶部搜索条（轻松签文件列表同款浅灰搜索框）：
    /// 按名字过滤当前视图（根目录各组、或当前文件夹内）。
    private var fileSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("搜索"), text: $fileSearchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(8)
    }

    /// 文件页操作行（轻松签文件列表同款动作入口）：新建文件夹 +
    /// 手动刷新（平时列表只在进页/操作后重扫，手动刷新兜底）。
    private var fileActionRow: some View {
        HStack(spacing: 12) {
            Button {
                newFolderName = ""
                showNewFolderAlert = true
            } label: {
                Label(L("新建文件夹"), systemImage: "folder.badge.plus")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                files = AppFileLibrary.scan()
                resetCurrentDirIfNeeded()
            } label: {
                Label(L("刷新"), systemImage: "arrow.clockwise")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
    }

    /// 当前文件夹返回条：点回上级（根目录就回文件组）。
    private var currentDirBar: some View {
        PanelCard {
            HStack(spacing: 8) {
                Button {
                    currentDir = (currentDir as NSString).deletingLastPathComponent
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text(L("返回"))
                    }
                    .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text(currentDirName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(L("%d 项", currentDirItems.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 当前文件夹内的直接子项（文件夹 + 文件同一列表，轻松签式）：
    /// 行格式跟根目录 fileRow 一模一样，不另起一套。
    private func folderSection(items: [LocalFileItem]) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    fileRow(item)
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func fileSection(title: String, items: [LocalFileItem]) -> some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: title == L("IPA 文件") ? "app.badge" : "doc")
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text("\(items.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    fileRow(item)
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    /// 系统文件组：默认折叠，只露一行标题和个数；点开后和别的
    /// 文件一样看详情、分享、删除。DDI 挂载走自己的路径，不靠
    /// 文件列表找文件，所以收起来不影响 DDI，只是不让它 clutter。
    /// 搜索时也按名字过滤（跟别的组一样）。
    private var systemSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { showSystemFiles.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(L("系统文件"))
                            .font(.headline)
                        Spacer()
                        Text("\(matching(systemFiles).count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: showSystemFiles ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
                .buttonStyle(.plain)
                if showSystemFiles {
                    ForEach(matching(systemFiles)) { item in
                        fileRow(item)
                        if item.id != matching(systemFiles).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// 轻松签文件列表式第二行：文件夹是“n 项”，文件是“大小  时间”。
    private func fileSecondLine(_ item: LocalFileItem) -> String {
        if item.isDirectory {
            return L("%d 项", item.childCount)
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        guard let modified = item.modified else { return size }
        return "\(size)  \(fileTimeText(modified))"
    }

    /// 今天显示时间（14:38:19），以前的显示日期（2026/10/27），轻松签同款。
    private func fileTimeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .standard)
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// 文件行图标：IPA 真图 / 文件夹蓝标 / 其他灰标，三路不同
    /// View 类型，函数前必须加 @ViewBuilder（AGENTS.md 血泪）。
    /// 真图 52×52 圆角填满；系统标放 52×52 框里居中，行高对齐。
    @ViewBuilder
    private func fileIcon(for item: LocalFileItem) -> some View {
        if item.isDirectory {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .font(.title3)
                .frame(width: 52, height: 52)
        } else if item.isIPA,
                  let data = fileIcons[item.id],
                  let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            // IPA 还没取到图、取图失败、非 IPA 文件：一律中性占位，
            // 不造假图、不空框（IPA 占位与应用库同款灰色文档标）。
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .font(.title3)
                .frame(width: 52, height: 52)
        }
    }

    /// 图标取图键：路径 + 大小 + 修改时间——文件被覆盖换了就重取。
    private func fileIconKey(_ item: LocalFileItem) -> String {
        "\(item.id)#\(item.size)#\(item.modified?.timeIntervalSince1970 ?? 0)"
    }

    /// IPA 行图标解析：复用应用库那套 IPALibrary.iconData（只读
    /// central directory + 单个图标条目，不整包解压），不为文件页
    /// 单开一套；耗时放 Task.detached，取到回主线程写缓存；
    /// Assets.car 独占图标时 iconData 返回 nil，行里显示中性占位。
    private func loadFileIcon(for item: LocalFileItem) {
        guard item.isIPA else { return }
        let key = fileIconKey(item)
        guard !fileIconsTried.contains(key) else { return }
        fileIconsTried.insert(key)
        Task.detached { [url = item.url, id = item.id] in
            guard let data = IPALibrary.iconData(at: url) else { return }
            await MainActor.run { fileIcons[id] = data }
        }
    }

    private func fileRow(_ item: LocalFileItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if selecting {
                    Image(systemName: selection.contains(item.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
                }
                // 轻松签文件列表式：IPA 有真实图标就显示真图（应用库
                // 同款解析，见 loadFileIcon），没取到就中性占位；
                // 文件夹蓝色、其他文件灰色文档图标。图标区统一
                // 52×52 框，行高对齐，不晃。
                fileIcon(for: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(fileSecondLine(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if item.isDirectory {
                    // 文件夹入口标识：点行就进，ⓘ 仍是详情。
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                Button {
                    detailItem = item
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
            if !selecting {
            HStack(spacing: 14) {
                if item.isDirectory {
                    // 文件夹是新增的行：分享/签名/安装都是文件的操作，
                    // 这里只留删除（重命名在长按菜单里）。
                    Spacer()
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Text(L("删除"))
                            .font(.footnote)
                    }
                } else {
                    ShareLink(item: item.url) {
                        Text(L("分享"))
                            .font(.footnote)
                    }
                    if item.isIPA {
                        Button {
                            workspace.selectedIPA = item.url
                            onGoCert()
                        } label: {
                            Text(L("去签名"))
                                .font(.footnote.weight(.semibold))
                        }
                        if item.isInSignedDir {
                            Button {
                                installSignedFile(item)
                            } label: {
                                Text(L("安装"))
                                    .font(.footnote.weight(.semibold))
                            }
                            .disabled(localInstall.isRunning || fileInstallInFlight)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        delete(item)
                    } label: {
                        Text(L("删除"))
                            .font(.footnote)
                    }
                }
            }
            }
        }
        .contentShape(Rectangle())
        // IPA 行图标：行出现时触发一次取图（文件换了就重取，
        // 键里带大小 + 修改时间；取不到也记 tried，不死循环）。
        .task(id: fileIconKey(item)) { loadFileIcon(for: item) }
        .onTapGesture {
            if selecting {
                if selection.contains(item.id) {
                    selection.remove(item.id)
                } else {
                    selection.insert(item.id)
                }
            } else if item.isDirectory {
                // 点文件夹行就进文件夹（轻松签文件列表同款入口，
                // 不藏在详情或长按里）；文件行点着没事（操作在行内按钮）。
                currentDir = folderPath(item)
            }
        }
        .contextMenu {
            // 文件夹是新增的行：分享/Mach-O/压缩/解压/签名/安装都是
            // 文件的操作，文件夹是重命名/移动/复制/删除。
            if !item.isDirectory {
                ShareLink(item: item.url) {
                    Label(L("分享"), systemImage: "square.and.arrow.up")
                }
                Button {
                    machoItem = item
                } label: {
                    Label(L("Mach-O 依赖"), systemImage: "list.bullet.rectangle")
                }
            }
            Button {
                renameText = item.name
                renameItem = item
            } label: {
                Label(L("重命名"), systemImage: "pencil")
            }
            Button {
                moveItem = item
            } label: {
                Label(L("移动"), systemImage: "folder")
            }
            Button {
                duplicate(item)
            } label: {
                Label(L("复制"), systemImage: "doc.on.doc")
            }
            if !item.isDirectory {
                Button {
                    zipSingle(item)
                } label: {
                    Label(L("压缩成 ZIP"), systemImage: "archivebox")
                }
                if item.isZip {
                    Button {
                        unzip(item)
                    } label: {
                        Label(L("解压"), systemImage: "tray.and.arrow.up")
                    }
                }
                if item.isIPA {
                    Button {
                        workspace.selectedIPA = item.url
                        onGoCert()
                    } label: {
                        Label(L("去企业证书签名"), systemImage: "checkmark.seal")
                    }
                    if item.isInSignedDir {
                        Button {
                            installSignedFile(item)
                        } label: {
                            Label(L("安装"), systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(L("删除"), systemImage: "trash")
            }
        }
    }

    /// 当前文件夹不存在了就回根目录（删/改名/移走当前文件夹后都调，
    /// 免得停在一个不存在的目录里）。
    private func resetCurrentDirIfNeeded() {
        if !currentDir.isEmpty,
           !files.contains(where: { $0.isDirectory && folderPath($0) == currentDir }) {
            currentDir = ""
        }
    }

    private func delete(_ item: LocalFileItem) {
        if item.isInSignedDir,
           let record = SignedIPAStore.load().first(where: { $0.fileName == item.name }) {
            SignedIPAStore.remove(record)
        } else {
            try? FileManager.default.removeItem(at: item.url)
        }
        files = AppFileLibrary.scan()
        resetCurrentDirIfNeeded()
    }

    /// 在当前目录（根目录或进的文件夹里）新建文件夹（轻松签
    /// 新建文件夹同款）：重名就拒，不覆盖。
    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        let root = IPALibrary.documentsDir
        let parent = currentDir.isEmpty ? root : root.appendingPathComponent(currentDir)
        let dest = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            opMessage = L("已有同名文件")
            opFailed = true
            return
        }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            files = AppFileLibrary.scan()
            opMessage = L("已创建文件夹 %@", name)
            opFailed = false
        } catch {
            opMessage = error.localizedDescription
            opFailed = true
        }
    }

    /// 移动的目的地（根目录 + 全部文件夹，排除三类：自己当前所在
    /// 目录（移了等于没移）、自己、自己的子文件夹（移进去就丢了）。
    private func moveDestinations(for item: LocalFileItem) -> [(dir: String, name: String)] {
        var out: [(dir: String, name: String)] = []
        if !item.relativeDir.isEmpty {
            out.append(("", L("根目录")))
        }
        let selfPath = item.isDirectory ? folderPath(item) : nil
        for folder in files.filter({ $0.isDirectory }) {
            let path = folderPath(folder)
            if path == item.relativeDir { continue }
            if let selfPath, (path == selfPath || path.hasPrefix(selfPath + "/")) { continue }
            out.append((path, path))
        }
        return out
    }

    /// 把文件/文件夹移到目标目录（轻松签移动文件同款）：同名就拒，
    /// 移完重扫 + 当前目录复位；已签名 IPA 移出 Signed 目录时，
    /// 清单下次 load 会自动滤掉无文件记录，不用这里手动删。
    private func moveItemToFolder(_ item: LocalFileItem, _ destDir: String) {
        let root = IPALibrary.documentsDir
        let parent = destDir.isEmpty ? root : root.appendingPathComponent(destDir)
        let dest = parent.appendingPathComponent(item.name)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            opMessage = L("目标文件夹里已有同名文件")
            opFailed = true
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            files = AppFileLibrary.scan()
            resetCurrentDirIfNeeded()
            opMessage = L("已移动到 %@", destDir.isEmpty ? L("根目录") : destDir)
            opFailed = false
        } catch {
            opMessage = error.localizedDescription
            opFailed = true
        }
    }

    /// 复制文件/文件夹（轻松签复制同款）：同目录下起不重名的新名字，
    /// 文件夹整目录拷；已签名 IPA 的副本只是文件，不自动进已签名
    /// 清单（清单是记录制，跟手动拷进 Signed 目录同例）。
    private func duplicate(_ item: LocalFileItem) {
        let stem = item.url.deletingPathExtension().lastPathComponent
        let dest = uniqueSibling(of: item, stem: stem, ext: item.url.pathExtension)
        do {
            try FileManager.default.copyItem(at: item.url, to: dest)
            files = AppFileLibrary.scan()
            opMessage = L("已复制为 %@", dest.lastPathComponent)
            opFailed = false
        } catch {
            opMessage = error.localizedDescription
            opFailed = true
        }
    }

    private func deleteSelection() {
        for item in files where selection.contains(item.id) {
            delete(item)
        }
        selection = []
        selecting = false
    }

    /// 在同目录里找一个不重名的目标 URL。
    private func uniqueSibling(of item: LocalFileItem, stem: String, ext: String) -> URL {
        let dir = item.url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = dir.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    private func performRename() {
        guard let item = renameItem else { return }
        renameItem = nil
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name,
              !newName.contains("/") else { return }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            opMessage = L("已有同名文件")
            opFailed = true
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            if item.isInSignedDir {
                SignedIPAStore.renameFile(from: item.name, to: newName)
            }
            files = AppFileLibrary.scan()
            resetCurrentDirIfNeeded()
            opMessage = L("已改名")
            opFailed = false
        } catch {
            opMessage = error.localizedDescription
            opFailed = true
        }
    }

    private func zipSingle(_ item: LocalFileItem) {
        let out = uniqueSibling(of: item, stem: item.url.deletingPathExtension().lastPathComponent, ext: "zip")
        runZip(paths: [item.url], out: out)
    }

    private func zipSelection() {
        // 只打包文件：文件夹以前根本不在列表里，Rust 压包接不接
        // 目录项没验证过，别在这里新开行为，选了文件夹就跳过它。
        let items = files.filter { selection.contains($0.id) && !$0.isDirectory }
        guard !items.isEmpty else { return }
        let root = IPALibrary.documentsDir
        var out = root.appendingPathComponent("打包.zip")
        var counter = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = root.appendingPathComponent("打包 \(counter).zip")
            counter += 1
        }
        runZip(paths: items.map { $0.url }, out: out)
        selection = []
        selecting = false
    }

    private func runZip(paths: [URL], out: URL) {
        opBusy = true
        opMessage = nil
        Task {
            let error = await Task.detached {
                FileZipTool.zip(paths: paths, to: out)
            }.value
            opBusy = false
            files = AppFileLibrary.scan()
            if let error {
                opMessage = error
                opFailed = true
            } else {
                opMessage = L("已压缩到 %@", out.lastPathComponent)
                opFailed = false
            }
        }
    }

    private func unzip(_ item: LocalFileItem) {
        let stem = item.url.deletingPathExtension().lastPathComponent
        let dest = uniqueSibling(of: item, stem: "\(stem)-解压", ext: "")
        opBusy = true
        opMessage = nil
        Task {
            let error = await Task.detached {
                FileZipTool.unzip(archive: item.url, to: dest)
            }.value
            opBusy = false
            files = AppFileLibrary.scan()
            if let error {
                opMessage = error
                opFailed = true
            } else {
                opMessage = L("已解压到 %@", dest.lastPathComponent)
                opFailed = false
            }
        }
    }
}

/// 文件详情（轻松签文件列表右边的 ⓘ）：名字、大小、修改时间、路径，
/// 下面是操作（分享只对文件，文件夹是重命名/移动/复制/删除，
/// 跟行内菜单同例）。
/// 文件夹没有字节大小可言，大小那行显示“共 n 项”。
private struct FileDetailSheet: View {
    let item: LocalFileItem
    var onDelete: () -> Void
    var onRename: () -> Void
    var onMove: () -> Void
    var onDuplicate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                detailRow(L("名字"), item.name)
                detailRow(L("大小"), item.isDirectory
                          ? L("%d 项", item.childCount)
                          : ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                detailRow(L("修改时间"), item.modified?.formatted(date: .abbreviated, time: .standard) ?? L("未知"))
                detailRow(L("路径"), item.url.path)
                Section {
                    if !item.isDirectory {
                        ShareLink(item: item.url) {
                            Label(L("分享"), systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        onRename()
                    } label: {
                        Label(L("重命名"), systemImage: "pencil")
                    }
                    Button {
                        onMove()
                    } label: {
                        Label(L("移动"), systemImage: "folder")
                    }
                    Button {
                        onDuplicate()
                    } label: {
                        Label(L("复制"), systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label(L("删除"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(L("详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("完成")) { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}
