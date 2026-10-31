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
    // 文件页企业安装走 Engine 配对链路（v68 回退，证书页同款）：
    // 这里重新观察 Engine（v63 曾拿掉，v68 拿回来，只为企业已
    // 签名安装；安装 tab 的 ID 线与文件页仍是各认各次安装的状
    // 态，不串台——结果判定只看 fileInstallInFlight 期间的变化）。
    @EnvironmentObject private var engine: Engine
    /// 步骤日志存放处（单例，与证书页共用同一份 diagnosticLog）：
    /// 文件页安装的传输不再走它的 install()，只用 appendStepLog
    /// 记配对安装开始/完成/失败，证书页的诊断日志里能看到。
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
    /// 轻松签文件列表式切栏：未签名 = 不在 Signed 目录的 IPA，
    /// 已签名 = 在 Signed 目录的 IPA；只过滤 IPA 行，其他文件、
    /// 文件夹、系统文件不受切栏影响。
    @State private var fileTab = FileListTab.unsigned
    /// IPA 行信息缓存（路径 → Info.plist 解析结果）：行格式第二行
    /// 要版本/Bundle ID，文件页以前只取图标不解析，这里按行在后台
    /// 解析一次；键带大小 + 修改时间，文件换了就重解析。
    @State private var fileIPAInfo: [String: IPALibrary.AppInfo] = [:]
    @State private var fileIPAInfoTried: Set<String> = []
    /// 点行弹出的底部动作菜单正在操作的行（nil = 不弹）。
    @State private var actionItem: LocalFileItem?
    /// 当前进的文件夹（相对 Documents 的路径，"" = 根目录）：
    /// 点文件夹行就进，返回条回上级；删了当前文件夹就回根目录。
    @State private var currentDir = ""
    /// 新建文件夹：名字输入（alert 里填）+ 是否弹出。
    @State private var newFolderName = ""
    @State private var showNewFolderAlert = false
    /// 要移动的文件/文件夹（sheet 的 item，nil 就不弹）。
    @State private var moveItem: LocalFileItem?
    @StateObject private var lanServer = LANTransferServer()
    /// 文件页已签名安装：走 Engine 配对链路（v68 回退，证书页
    /// startEngineInstall 同款）。进行中标志 + 完成弹框（inFlight
    /// 隔离：结果判定只看 fileInstallInFlight 期间 engine.isRunning
    /// 的变化，ID 线的安装跑完不会误弹到这里）；重试用的记录/
    /// 文件地址（装时记下）；失败原因快照（证书页同款，不直接
    /// 读 engine 的全局 lastError，免得别的页的失败串到这里）。
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

    /// 切栏是否命中这行 IPA：已签名的判定跟行内「安装」按钮同例
    ///（在 Signed 目录里），跟证书页已签名清单的落点一致。
    private func fileTabMatches(_ item: LocalFileItem) -> Bool {
        switch fileTab {
        case .unsigned: return !item.isInSignedDir
        case .signed: return item.isInSignedDir
        }
    }

    /// 切栏 + 搜索过滤后的 IPA 列表（根目录视图用，递归扫描的全量）。
    private var filteredIPAs: [LocalFileItem] {
        matching(ipas).filter { fileTabMatches($0) }
    }

    /// 当前文件夹视图里切栏过滤后的可见项：非 IPA 行不受切栏影响，
    /// IPA 行按切栏过滤（搜不到/切栏外就不显示，不进空文件夹误判）。
    private var visibleDirItems: [LocalFileItem] {
        currentDirItems.filter { !$0.isIPA || fileTabMatches($0) }
    }

    /// IPA 行显示名：解析出的 App 名优先，解析不到回落文件名去后缀。
    private func ipaDisplayName(_ item: LocalFileItem) -> String {
        if let name = fileIPAInfo[item.url.path]?.name, !name.isEmpty {
            return name
        }
        return (item.name as NSString).deletingPathExtension
    }

    /// IPA 行第二行（轻松签文件列表同款）：V版本 | 大小 | Bundle ID；
    /// 版本缺了就省掉 V 那段，解析失败只显示大小，不造假。
    private func ipaSecondLine(_ item: LocalFileItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        guard let info = fileIPAInfo[item.url.path] else { return size }
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

    /// IPA 行信息解析（只取可见行，行 .task 触发）：键里带大小 +
    /// 修改时间，文件被覆盖换了就重解析；解析失败也记已尝试，
    /// 不重复读盘。跟证书页未签名栏同例，只解析 Info.plist。
    private func loadFileIPAInfo(for item: LocalFileItem) {
        guard item.isIPA else { return }
        let key = "\(item.url.path)#\(item.size)#\(item.modified?.timeIntervalSince1970 ?? 0)"
        guard !fileIPAInfoTried.contains(key) else { return }
        fileIPAInfoTried.insert(key)
        // 显式捕获（loadFileIcon 同例）：不把整个 item 隐式带进
        // detached 任务，免得 Swift 6 并发检查找麻烦。
        Task.detached(priority: .userInitiated) { [url = item.url, path = item.url.path] in
            guard let info = IPALibrary.appInfo(at: url) else { return }
            await MainActor.run { self.fileIPAInfo[path] = info }
        }
    }

    /// 动作菜单里的分享：系统分享面板（ReportProblemView 同例，
    /// UIActivityViewController + topViewController，iPad 锚点居中）。
    /// present 包一层 main.async：菜单按钮点按时菜单本身正在收起，
    /// 下一轮再 present，免得两个 presented 控制器抢窗口层级。
    private func shareFile(_ item: LocalFileItem) {
        DispatchQueue.main.async {
            let sheet = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
            guard let top = UIApplication.shared.topViewController else { return }
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                                                     width: 0, height: 0)
            top.present(sheet, animated: true)
        }
    }

    /// 动作菜单里的查看文件位置：切到这行 IPA 所在的切栏 + 文件夹，
    /// 清掉搜索，让这一行在当前视图里直接可见；位置在操作提示里明说。
    private func locateFile(_ item: LocalFileItem) {
        fileTab = item.isInSignedDir ? .signed : .unsigned
        currentDir = item.relativeDir
        fileSearchText = ""
        opMessage = L("已定位到：%@", item.relativeDir.isEmpty ? L("根目录") : item.relativeDir)
        opFailed = false
    }

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

    /// 文件页安装统一入口（证书页 startEngineInstall 同款）：
    /// 调 Engine 的 runInstallSignedIPA（配对设备链路，v45 那套），
    /// 全程只在文件页内反馈——进行中显示 Engine 进度 +“取消安装”，
    /// 跑完成功弹框，失败快照原因 +“重试安装”。前置检查（配对文件、
    /// 隧道、设备 IP）不过时 Engine 直接返回、isRunning 根本没置位，
    /// 这时就别留着进行中标志，并把原因快照到页内（证书页同款：
    /// 优先用 Engine 的前置向导，向导没变或是上一次跑剩的旧向导时
    /// 给通用提示，不读 lastError——前置失败不置它）。名字只用于
    /// 步骤日志：有记录用记录名，没记录现解析，解析不到就用文件名，
    /// Engine 安装本身不需要 Bundle ID，不再因解析不到而拒装。
    /// 文件页安装不写 CertSignLogStore（v62 也不写；日志的 kind
    /// 没有“仅安装”一项，硬记会把一次只装没签的说成“签名并安装”，
    /// 误导——文件页自己的状态条 + 成功弹框就是反馈）。
    private func startEnterpriseInstall(ipaURL: URL, record: SignedIPARecord?) {
        fileInstallRecord = record
        fileInstallURL = ipaURL
        fileInstallErrorText = nil
        let appName = record?.appName
            ?? IPALibrary.appInfo(at: ipaURL)?.name
            ?? ipaURL.deletingPathExtension().lastPathComponent
        // 别的 tab 的安装在跑时不新起（Engine 单管线）：只显错误
        // 文本，不进 runInstallSignedIPA、不记失败。
        guard !engine.isRunning else {
            fileInstallErrorText = L("已有安装在进行，先等当前安装完成再试。")
            return
        }
        let guideBefore = engine.guide
        fileInstallInFlight = true
        localInstall.appendStepLog(L("配对安装开始：%@", appName))
        engine.runInstallSignedIPA(ipaURL: ipaURL)
        if !engine.isRunning {
            fileInstallInFlight = false
            if let guide = engine.guide,
               guide != guideBefore
               || guide == Guides.importPairing || guide == Guides.vpn
               || guide == Guides.deviceIPMismatch {
                fileInstallErrorText = ([guide.title] + guide.steps).joined(separator: "\n")
            } else {
                fileInstallErrorText = L("配对安装没能启动：请检查配对文件与隧道是否就绪，或去「安装」页看日志。")
            }
            localInstall.appendStepLog(L("配对安装失败：%@", fileInstallErrorText ?? ""))
        }
    }

    /// 文件页配对安装状态：只在文件页内显示，不碰共享「安装」页。
    /// 进行中显示 Engine 进度 +“取消安装”（调 Engine 的
    /// cancelOneClick，中止 pipelineTask；取消后 isRunning 落下触发
    /// onChange 清 inFlight，取消不算成功也不记失败）；失败时显示
    /// 快照的原因 +“重试安装”（原因来自 startEnterpriseInstall /
    /// onChange 的快照，不直接读 engine 的全局 lastError，免得别的
    /// 页的失败串到这里）。进行中只认 fileInstallInFlight（ID 线
    /// 的安装跑起来时这里不跟着亮，免得串台）。
    @ViewBuilder
    private var fileInstallStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fileInstallInFlight {
                HStack(spacing: 8) {
                    if engine.installProgress > 0 {
                        Text(L("配对安装进行中（%d%%）", Int(engine.installProgress * 100)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("配对安装进行中"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("取消安装")) { engine.cancelOneClick() }
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
                    // 轻松签文件列表式切栏（只过滤 IPA 行）：放搜索框上面，
                    // 跟证书页应用库切栏同例，segmented 样式。
                    Picker("", selection: $fileTab) {
                        Text(L("未签名")).tag(FileListTab.unsigned)
                        Text(L("已签名")).tag(FileListTab.signed)
                    }
                    .pickerStyle(.segmented)
                    fileSearchBar
                    fileActionRow
                    if !currentDir.isEmpty {
                        currentDirBar
                        if currentDirItems.isEmpty {
                            emptyCard.cascadeItem(2)
                        } else if visibleDirItems.isEmpty {
                            Text(L("没有匹配的 IPA。"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            folderSection(items: visibleDirItems).cascadeItem(2)
                        }
                    } else if files.isEmpty {
                        emptyCard.cascadeItem(2)
                    } else {
                        // IPA 行不再单开「IPA 文件」组：切栏 + 搜索过滤
                        // 后的 ipaList 就是全部 IPA（轻松签文件列表式，
                        // 无卡片头）；其他文件、系统文件仍用旧组。
                        ipaList.cascadeItem(2)
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
        // 配对安装跑完：finished 置位才算成功（取消不算）。只认
        // fileInstallInFlight 期间的变化，ID 线的安装跑完不会误弹
        // 到这里；失败原因快照到页内本地量，不直接绑 engine 的
        // 全局量。文件页安装不写签名日志（见 startEnterpriseInstall）。
        .onChange(of: engine.isRunning) { old, new in
            if old && !new && fileInstallInFlight {
                fileInstallInFlight = false
                if engine.finished {
                    showingFileInstallSuccessAlert = true
                    localInstall.appendStepLog(L("配对安装完成"))
                } else if let error = engine.lastError {
                    fileInstallErrorText = error
                    localInstall.appendStepLog(L("配对安装失败：%@", error))
                }
            }
        }
        .alert(L("安装完成"), isPresented: $showingFileInstallSuccessAlert) {
            Button(L("知道了"), role: .cancel) {}
        } message: {
            Text(L("装好了，可以回桌面查看安装进度。"))
        }
        // 点 IPA 行弹出的底部动作菜单（轻松签文件列表同款顺序）：
        // 签名 / 安装（仅已签名行）/ 提取库 / 详情 / 分享 / 查看文件
        // 位置 / 删除 / 取消。提取库在 Side 没有同名功能，映射到现
        // 有的 Mach-O 依赖查看（看包里带了哪些库）；详情是原有的
        // FileDetailSheet；分享走系统分享面板；查看文件位置切到该
        // 行所在的切栏 + 文件夹并清搜索，让行直接可见。
        .confirmationDialog("", isPresented: Binding(
            get: { actionItem != nil },
            set: { if !$0 { actionItem = nil } }
        )) {
            if let item = actionItem, item.isIPA {
                Button {
                    workspace.selectedIPA = item.url
                    onGoCert()
                    actionItem = nil
                } label: {
                    Text(L("签名"))
                }
                if item.isInSignedDir {
                    Button {
                        installSignedFile(item)
                        actionItem = nil
                    } label: {
                        Text(L("安装"))
                    }
                }
                Button {
                    machoItem = item
                    actionItem = nil
                } label: {
                    Text(L("提取库"))
                }
                Button {
                    detailItem = item
                    actionItem = nil
                } label: {
                    Text(L("详情"))
                }
                Button {
                    shareFile(item)
                    actionItem = nil
                } label: {
                    Text(L("分享"))
                }
                Button {
                    locateFile(item)
                    actionItem = nil
                } label: {
                    Text(L("查看文件位置"))
                }
                Button(role: .destructive) {
                    delete(item)
                    actionItem = nil
                } label: {
                    Text(L("删除"))
                }
            }
            Button(L("取消"), role: .cancel) {
                actionItem = nil
            }
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

    /// 轻松签文件列表式 IPA 列表（切栏 + 搜索过滤后）：行格式见
    /// fileRow 的 IPA 分支（图标 + 名 + 版本|大小|Bundle ID + 文件名），
    /// 点行弹底部动作菜单；空态按切栏/搜索区分文案，不空白。
    /// 无卡片头（参考图里列表就是平铺的），跟其他文件组区分开。
    private var ipaList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if filteredIPAs.isEmpty {
                Text(fileSearchText.isEmpty
                     ? (fileTab == .unsigned ? L("还没有未签名的 IPA。") : L("还没有已签名的 IPA。"))
                     : L("没有匹配的 IPA。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredIPAs) { item in
                    fileRow(item)
                    if item.id != filteredIPAs.last?.id {
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
                if item.isIPA {
                    // IPA 行三行格式（轻松签文件列表同款）：解析出的
                    // App 名 / V版本 | 大小 | Bundle ID / 文件名。
                    // 行内不再放分享/去签名/安装/删除按钮——点行弹
                    // 底部动作菜单，菜单里全有；ⓘ 也不放，菜单里
                    // 有详情。
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ipaDisplayName(item))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(ipaSecondLine(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        Text(fileSecondLine(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if item.isDirectory {
                    // 文件夹入口标识：点行就进，ⓘ 仍是详情。
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                if !item.isIPA {
                    Button {
                        detailItem = item
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !selecting && !item.isIPA {
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
        // IPA 行信息：行出现时触发一次解析（版本/Bundle ID 用），
        // 非 IPA 行直接跳过（loadFileIPAInfo 里 guard）。
        .task(id: "\(item.url.path)#\(item.size)#\(item.modified?.timeIntervalSince1970 ?? 0)") { loadFileIPAInfo(for: item) }
        .onTapGesture {
            if selecting {
                if selection.contains(item.id) {
                    selection.remove(item.id)
                } else {
                    selection.insert(item.id)
                }
            } else if item.isDirectory {
                // 点文件夹行就进文件夹（轻松签文件列表同款入口，
                // 不藏在详情或长按里）；非 IPA 文件行点着没事
                //（操作在行内按钮 / 长按菜单里）。
                currentDir = folderPath(item)
            } else if item.isIPA {
                // 点 IPA 行弹底部动作菜单（轻松签文件列表同款），
                // 不再是点着没事；长按菜单仍在，更多操作走长按。
                actionItem = item
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

/// 文件页 IPA 切栏：未签名 / 已签名（轻松签文件列表同款）。
private enum FileListTab: Hashable {
    case unsigned
    case signed
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
