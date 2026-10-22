import SwiftUI
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

    private var ipas: [LocalFileItem] { files.filter { $0.isIPA } }
    private var others: [LocalFileItem] { files.filter { !$0.isIPA } }
    private var totalSize: Int { files.reduce(0) { $0 + $1.size } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    importCard.cascadeItem(1)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(L("文件"))
                .font(.largeTitle.weight(.bold))
            Text(L("%d 个文件 · %@", files.count,
                   ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
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
            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text("\(item.relativeDir.isEmpty ? L("根目录") : item.relativeDir) · \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))\(item.modified.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .contextMenu {
            ShareLink(item: item.url) {
                Label(L("分享"), systemImage: "square.and.arrow.up")
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
}
