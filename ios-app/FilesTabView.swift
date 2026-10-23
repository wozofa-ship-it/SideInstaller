import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Documents 里的一个文件（递归，含子文件夹）。
struct LocalFileItem: Identifiable {
    let url: URL
    let name: String
    /// 相对 Documents 的目录（"" 是根目录，如 "Custom"、"Signed"）。
    let relativeDir: String
    let size: Int
    let modified: Date?
    var id: String { url.path }
    var isIPA: Bool { name.lowercased().hasSuffix(".ipa") }
    var isZip: Bool { name.lowercased().hasSuffix(".zip") }
    var isInSignedDir: Bool { relativeDir == "Signed" }
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
            if values?.isDirectory == true { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let dir = (rel as NSString).deletingLastPathComponent
            items.append(LocalFileItem(
                url: url,
                name: url.lastPathComponent,
                relativeDir: dir == "." ? "" : dir,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate))
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
    @EnvironmentObject private var engine: Engine
    /// Declared so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var workspace: CertWorkspace
    /// 切到证书页（RootView 给的）。
    var onGoCert: () -> Void

    @State private var files = AppFileLibrary.scan()
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
    @StateObject private var lanServer = LANTransferServer()
    /// 局域网地址点按复制后的短暂「已复制」提示。
    @State private var lanCopied = false

    private var ipas: [LocalFileItem] { files.filter { $0.isIPA } }
    private var others: [LocalFileItem] { files.filter { !$0.isIPA } }
    private var totalSize: Int { files.reduce(0) { $0 + $1.size } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    importCard.cascadeItem(1)
                    if selecting {
                        selectionBar.cascadeItem(2)
                    }
                    if files.isEmpty {
                        emptyCard.cascadeItem(2)
                    } else {
                        if !ipas.isEmpty {
                            fileSection(title: L("IPA 文件"), items: ipas).cascadeItem(2)
                        }
                        if !others.isEmpty {
                            fileSection(title: L("其他文件"), items: others).cascadeItem(3)
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
        .sheet(item: $machoItem) { item in
            MachOView(url: item.url, fileName: item.name)
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
                Text(L("这里是 App 自己的文件目录：下载的、导入的、已签名的 IPA 都在这。也可以在「文件」App 里往 Side 🅥 的目录放文件，回到这里就能看到。"))
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

    private func fileRow(_ item: LocalFileItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if selecting {
                    Image(systemName: selection.contains(item.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text("\(item.relativeDir.isEmpty ? L("根目录") : item.relativeDir) · \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))\(item.modified.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !selecting {
            HStack(spacing: 14) {
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
                            engine.runInstallSignedIPA(ipaURL: item.url)
                        } label: {
                            Text(L("安装"))
                                .font(.footnote.weight(.semibold))
                        }
                        .disabled(engine.isRunning)
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard selecting else { return }
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        }
        .contextMenu {
            ShareLink(item: item.url) {
                Label(L("分享"), systemImage: "square.and.arrow.up")
            }
            Button {
                machoItem = item
            } label: {
                Label(L("Mach-O 依赖"), systemImage: "list.bullet.rectangle")
            }
            Button {
                renameText = item.name
                renameItem = item
            } label: {
                Label(L("重命名"), systemImage: "pencil")
            }
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
                        engine.runInstallSignedIPA(ipaURL: item.url)
                    } label: {
                        Label(L("安装"), systemImage: "square.and.arrow.down")
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

    private func delete(_ item: LocalFileItem) {
        if item.isInSignedDir,
           let record = SignedIPAStore.load().first(where: { $0.fileName == item.name }) {
            SignedIPAStore.remove(record)
        } else {
            try? FileManager.default.removeItem(at: item.url)
        }
        files = AppFileLibrary.scan()
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
        let items = files.filter { selection.contains($0.id) }
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
