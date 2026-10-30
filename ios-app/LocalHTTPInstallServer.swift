import Foundation
import Network
import UIKit

/// 本地直装（轻松签式）：App 内起一个明文 HTTP 服务，生成 OTA
/// 清单，用 itms-services 拉起系统安装——不走配对、不走隧道、
/// 不要 WiFi。关键区别：这里是明文 HTTP 回环（http://localhost），
/// 不用 TLS、不用企业证书当服务身份。之前那版 HTTPS + 证书 TLS
/// 在 iOS 26 上系统安装器建不起连接（实测“无法连接 127.0.0.1”），
/// 所以这条路特意不用证书做 TLS；地址也照轻松签用 localhost
///（不用 127.0.0.1 字面地址），跟轻松签实证做法对齐。
/// 限制先说明白：
/// - 只能装企业证书签好的包（个人 ID 签的包走这条路装不上，
///   系统安装器验签名那关就过不了，仍走配对安装）。
/// - 服务只在安装期间跑，装完自动停；路径带随机 ID，不猜到。
/// - 本文件和 OTAInstallServer.swift 是两套实现：那份是 HTTPS
///   旧版，留着不用、不删、不再接线；这份是当前默认走的。
final class LocalHTTPInstallServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    /// 起不来时置 true，证书页据此弹“改用配对安装”兜底。
    @Published private(set) var failedToStart = false

    private var listener: NWListener?
    private var activeCandidate = 0
    private let queue = DispatchQueue(label: "czf.localhttp.install")
    private var installID = ""
    private var ipaURL: URL?
    private var manifestData = Data()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopWork: DispatchWorkItem?
    private var hardStopWork: DispatchWorkItem?

    /// 对一个已签好的记录拉起本地安装。
    func install(record: SignedIPARecord) {
        guard !record.bundleID.isEmpty else {
            setStatus(L("这个已签名记录没有 Bundle ID，装不了，先重签一次。"))
            return
        }
        install(ipaURL: SignedIPAStore.url(for: record), appName: record.appName,
                bundleID: record.bundleID, version: record.version ?? "1.0")
    }

    /// 对一个刚签好的文件拉起本地安装（签名页「签名并安装」用）。
    /// 必须在主线程调：这里同步清掉上一轮的失败标志（stop() 里
    /// 不清，免得失败信号还没被证书页读到就被后来的一次 stop 吞掉）。
    func install(ipaURL: URL, appName: String, bundleID: String, version: String) {
        stop()
        failedToStart = false
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            setStatus(L("签好的文件找不到了，先重签一次。"))
            return
        }
        setStatus(L("正在启动本地安装服务…"))
        beginBackgroundTask()
        installID = UUID().uuidString
        self.ipaURL = ipaURL
        // 清单等端口定下来再生成（里面要写 localhost:端口）。
        pendingMeta = (appName: appName, bundleID: bundleID, version: version)
        hardStopWork = DispatchWorkItem { [weak self] in self?.stop() }
        if let hardStopWork {
            queue.asyncAfter(deadline: .now() + 600, execute: hardStopWork)
        }
        tryPort(18100)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        hardStopWork?.cancel()
        hardStopWork = nil
        activeCandidate = 0
        listener?.cancel()
        listener = nil
        ipaURL = nil
        pendingMeta = nil
        manifestData = Data()
        endBackgroundTask()
        DispatchQueue.main.async {
            self.isRunning = false
            // 服务停了就把旧状态清掉，免得证书页一直挂着上一次的
            // “已拉起系统安装”；失败标志不在这里清（失败信号要
            // 留给证书页读到、弹兜底，见 failedToStart）。
            self.status = nil
        }
    }

    // MARK: - 服务

    private var pendingMeta: (appName: String, bundleID: String, version: String)?

    private func tryPort(_ candidate: Int) {
        guard candidate <= 18110 else {
            setStatus(L("本地端口 18100-18110 都被占用了，本地安装起不来，改用配对安装。"))
            DispatchQueue.main.async { self.failedToStart = true }
            stop()
            return
        }
        do {
            // 明文 TCP，不挂 TLS：系统安装器连不上带证书身份的
            // HTTPS 回环，但明文 HTTP 回环是轻松签同款做法。
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(
                using: params, on: NWEndpoint.Port(rawValue: UInt16(candidate))!)
            activeCandidate = candidate
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.activeCandidate == candidate else { return }
                switch state {
                case .ready:
                    self.onReady(port: candidate)
                case .failed:
                    self.listener = nil
                    if self.manifestData.isEmpty {
                        // 还没对外公布清单：换个端口再试。
                        self.tryPort(candidate + 1)
                    } else {
                        // 清单已发出、安装进行中，服务挂了就明说，
                        // 别悄悄换端口（安装器手里的旧地址就失效了）。
                        self.setStatus(L("本地安装服务断了，改用配对安装。"))
                        DispatchQueue.main.async { self.failedToStart = true }
                        self.stop()
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            tryPort(candidate + 1)
        }
    }

    private func onReady(port: Int) {
        guard let meta = pendingMeta else { return }
        let base = "http://localhost:\(port)/\(installID)"
        let manifestURL = "\(base)/manifest.plist"
        let item: [String: Any] = [
            "assets": [
                ["kind": "software-package", "url": "\(base)/app.ipa"],
            ],
            "metadata": [
                "bundle-identifier": meta.bundleID,
                "bundle-version": meta.version,
                "kind": "software",
                "title": meta.appName,
            ],
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["items": [item]], format: .xml, options: 0) else {
            setStatus(L("安装清单生成失败，改用配对安装。"))
            DispatchQueue.main.async { self.failedToStart = true }
            stop()
            return
        }
        manifestData = data
        DispatchQueue.main.async { self.isRunning = true }
        // 每次安装换一个随机路径，系统安装器不会吃到上次缓存的旧清单。
        let encoded = manifestURL.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? manifestURL
        guard let link = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            setStatus(L("安装链接生成失败，改用配对安装。"))
            DispatchQueue.main.async { self.failedToStart = true }
            stop()
            return
        }
        setStatus(L("已拉起系统安装：点「安装」后服务保持到下载完成，装完自动停，进度回桌面看。"))
        DispatchQueue.main.async {
            UIApplication.shared.open(link, options: [:]) { [weak self] opened in
                if !opened {
                    self?.setStatus(L("系统安装没拉起来，改用配对安装。"))
                    DispatchQueue.main.async { self?.failedToStart = true }
                    self?.stop()
                }
            }
        }
    }

    // MARK: - HTTP（只认 GET，两条路由）

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            if let path = Self.requestPath(buf) {
                self.respond(connection, path: path)
            } else if isComplete || error != nil || buf.count > (1 << 20) {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buf)
            }
        }
    }

    private static func requestPath(_ buf: Data) -> String? {
        let headerEnd = Data("\r\n\r\n".utf8)
        guard let range = buf.range(of: headerEnd) else { return nil }
        let headText = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
        guard let first = headText.components(separatedBy: "\r\n").first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func respond(_ connection: NWConnection, path: String) {
        if path == "/\(installID)/manifest.plist" {
            send(connection, status: "200 OK", contentType: "text/xml",
                 length: manifestData.count, body: manifestData) {
                connection.cancel()
            }
            return
        }
        if path == "/\(installID)/app.ipa", let ipaURL {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path))?[.size] as? Int,
                  let handle = try? FileHandle(forReadingFrom: ipaURL) else {
                send(connection, status: "404 Not Found", contentType: "text/plain",
                     length: 0, body: Data()) { connection.cancel() }
                return
            }
            // 安装器下载包时 App 已退到后台，分片发、发完再停，
            // 别把大包一次塞进内存。
            send(connection, status: "200 OK", contentType: "application/octet-stream",
                 length: size, body: nil) { [weak self] in
                self?.sendFile(connection, handle: handle, remaining: size)
            }
            return
        }
        send(connection, status: "404 Not Found", contentType: "text/plain",
             length: 0, body: Data()) { connection.cancel() }
    }

    private func send(_ connection: NWConnection, status: String, contentType: String,
                      length: Int, body: Data?, done: @escaping () -> Void) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in done() })
    }

    private func sendFile(_ connection: NWConnection, handle: FileHandle, remaining: Int) {
        guard remaining > 0 else {
            try? handle.close()
            connection.cancel()
            // 包发完了：留 20 秒给安装器重试，之后停服务。
            stopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            stopWork = work
            queue.asyncAfter(deadline: .now() + 20, execute: work)
            return
        }
        let chunk = handle.readData(ofLength: min(remaining, 64 * 1024))
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.sendFile(connection, handle: handle, remaining: remaining - chunk.count)
        })
    }

    // MARK: - 后台与状态

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocalHTTPInstall") {
            [weak self] in self?.stop()
        }
    }

    private func endBackgroundTask() {
        let task = backgroundTask
        backgroundTask = .invalid
        guard task != .invalid else { return }
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    /// 兜底弹过后清掉标志，免得下次启动又弹。
    func consumeFailedToStart() {
        failedToStart = false
    }
}
