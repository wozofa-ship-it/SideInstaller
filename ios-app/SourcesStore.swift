import Foundation

// MARK: - AltStore source format

/// One app in an AltStore-format source. Every field is optional at decode
/// time, since real-world sources omit some and vary others (a `versionDate`
/// can be a full timestamp or a bare date, so it stays a string). Entries
/// without a name or a download link are filtered out in `AltSource.validApps`.
struct AltApp: Codable {
    let name: String?
    let bundleIdentifier: String?
    let version: String?
    let downloadURL: String?
    let iconURL: String?
    let size: Int?
    let subtitle: String?
    let localizedDescription: String?
    let versionDate: String?
    let minOSVersion: String?
    let developerName: String?

    /// Stable identity for lists: the bundle id when there is one, else the
    /// download link, which the filter below guarantees.
    var id: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return downloadURL ?? name ?? ""
    }

    /// The download link as a URL, nil when the string isn't one.
    var downloadLink: URL? {
        guard let downloadURL, !downloadURL.isEmpty else { return nil }
        return URL(string: downloadURL)
    }

    /// The icon as a URL, nil when absent or malformed.
    var iconLink: URL? {
        guard let iconURL, !iconURL.isEmpty else { return nil }
        return URL(string: iconURL)
    }

    /// Human-readable size, e.g. "42.3 MB"; nil when the source doesn't say.
    var sizeText: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// An AltStore-format source document: a name and a list of apps.
struct AltSource: Codable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let iconURL: String?
    let apps: [AltApp]?

    /// The apps that can actually be shown and installed: both a name and a
    /// usable download link are required.
    var validApps: [AltApp] {
        (apps ?? []).filter { app in
            guard let name = app.name, !name.isEmpty else { return false }
            return app.downloadLink != nil
        }
    }

    /// The source's icon as a URL, nil when absent or malformed.
    var iconLink: URL? {
        guard let iconURL, !iconURL.isEmpty else { return nil }
        return URL(string: iconURL)
    }
}

/// A source the user added, with its fetch state.
struct LoadedSource: Identifiable {
    let url: URL
    var model: AltSource?
    var isLoading = false
    var errorMessage: String?

    var id: String { url.absoluteString }

    /// The source's own name once loaded, else its host.
    var displayName: String {
        if let name = model?.name, !name.isEmpty { return name }
        return url.host ?? url.absoluteString
    }

    /// The installable apps in the loaded document.
    var apps: [AltApp] { model?.validApps ?? [] }
}

// MARK: - Store

/// The user's app sources: the list is kept in UserDefaults, the documents
/// themselves are fetched on demand.
@MainActor
final class SourceStore: ObservableObject {

    @Published var sources: [LoadedSource] = []

    /// UserDefaults key for the source URL strings.
    static let urlsKey = "CZFAppSourceURLs"

    /// Preset on first run, when the user has never had a source list.
    static let defaultSourceURL = "https://xiaofang-source.pages.dev/source.json"

    init() {
        var stored = UserDefaults.standard.stringArray(forKey: Self.urlsKey)
        if stored == nil {
            stored = [Self.defaultSourceURL]
            UserDefaults.standard.set(stored, forKey: Self.urlsKey)
        }
        sources = (stored ?? []).compactMap { URL(string: $0) }
            .map { LoadedSource(url: $0) }
    }

    /// Add a source by its address text: validated like a pasted IPA link,
    /// de-duplicated, saved, and fetched. Returns false for an unusable link
    /// or one already in the list.
    @discardableResult
    func addSource(_ urlString: String) -> Bool {
        guard let url = Engine.downloadLink(urlString) else { return false }
        guard !sources.contains(where: { $0.url.absoluteString == url.absoluteString })
        else { return false }
        sources.append(LoadedSource(url: url))
        persist()
        Task { await fetch(url) }
        return true
    }

    /// Remove the sources at `offsets` (a list swipe) and save the list.
    func removeSource(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        persist()
    }

    /// Fetch every source, in parallel.
    func fetchAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.fetch(source.url) }
            }
        }
    }

    /// Fetch (or refetch) one source document. Decoding is tolerant: a body
    /// that isn't a source document is reported as the row's error.
    func fetch(_ url: URL) async {
        guard let index = sources.firstIndex(where: { $0.url == url }) else { return }
        sources[index].isLoading = true
        sources[index].errorMessage = nil
        do {
            var request = URLRequest(url: url)
            request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "SourceStore", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let model = try JSONDecoder().decode(AltSource.self, from: data)
            guard let index = sources.firstIndex(where: { $0.url == url }) else { return }
            sources[index].model = model
            sources[index].isLoading = false
        } catch {
            guard let index = sources.firstIndex(where: { $0.url == url }) else { return }
            sources[index].errorMessage = error.localizedDescription
            sources[index].isLoading = false
        }
    }

    private func persist() {
        UserDefaults.standard.set(sources.map(\.url.absoluteString), forKey: Self.urlsKey)
    }
}

// MARK: - IPA download with progress

/// Downloads one IPA from a source into a private staging folder in the
/// temporary directory, reporting progress. The file keeps the name
/// `Engine.importFileName(for:)` gives its URL, so the custom-import slot it
/// is handed to next names it the same way a pasted link would.
@MainActor
final class IPADownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    @Published private(set) var progress: Double = 0

    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Download `url` and return the staged file. Throws on a non-2xx answer
    /// or a transport error.
    func download(from url: URL) async throws -> URL {
        cancel()
        progress = 0
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("SideInstaller", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    /// Stop an in-flight download, if any.
    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    /// Resume the waiting download exactly once.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    // The delegate callbacks arrive on the session's own queue, so each hops
    // back to the main actor before touching state.

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progress = fraction }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The downloaded file is deleted when this callback returns, so it is
        // moved into staging here, on this queue.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            let error = NSError(domain: "IPADownloader", code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            Task { @MainActor in self.finish(.failure(error)) }
            return
        }
        guard let source = downloadTask.originalRequest?.url else {
            Task { @MainActor in self.finish(.failure(URLError(.badURL))) }
            return
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipa-source-\(UUID().uuidString)", isDirectory: true)
        let dest = staging.appendingPathComponent(Engine.importFileName(for: source))
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in self.finish(.success(dest)) }
        } catch {
            Task { @MainActor in self.finish(.failure(error)) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        // A successful download has already finished in
        // `didFinishDownloadingTo`; this only carries failures and cancels.
        guard let error else { return }
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
