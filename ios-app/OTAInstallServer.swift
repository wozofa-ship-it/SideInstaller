import Foundation
import Network
import Security
import UIKit

/// 本机直装：App 内起一个本地 HTTPS 服务，生成 OTA 清单，
/// 用 itms-services 拉起系统安装——不走配对、不走隧道、不要 WiFi。
/// 路子就是轻松签 / 易能签那套「本机安装」：签好的包只在本机
/// 回环上走一圈，系统安装器直接把它装进桌面。
/// 限制先说明白：
/// - 只能装企业证书签好的包（个人 ID 签的包走这条路装不上，
///   系统安装器验签名那关就过不了，仍走配对安装）。
/// - 服务只在安装期间跑，装完自动停；路径带随机 ID，不猜到；
///   TLS 身份就是用户自己导入的这张企业证书，不出本机。
final class OTAInstallServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?

    private var listener: NWListener?
    private var activeCandidate = 0
    private let queue = DispatchQueue(label: "czf.ota.install")
    private var installID = ""
    private var ipaURL: URL?
    private var manifestData = Data()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopWork: DispatchWorkItem?
    private var hardStopWork: DispatchWorkItem?

    /// 对一个已签好的 IPA 拉起本机安装。
    func install(record: SignedIPARecord) {
        guard !record.bundleID.isEmpty else {
            setStatus(L("这个已签名记录没有 Bundle ID，装不了，先重签一次。"))
            return
        }
        install(ipaURL: SignedIPAStore.url(for: record), appName: record.appName,
                bundleID: record.bundleID, version: record.version ?? "1.0")
    }

    /// 对一个刚签好的文件拉起本机安装（签名页「签名并安装」用）。
    func install(ipaURL: URL, appName: String, bundleID: String, version: String) {
        stop()
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            setStatus(L("签好的文件找不到了，先重签一次。"))
            return
        }
        setStatus(L("正在启动本机安装服务…"))
        beginBackgroundTask()
        installID = UUID().uuidString
        self.ipaURL = ipaURL
        // 清单等端口定下来再生成（里面要写 127.0.0.1:端口）。
        pendingMeta = (appName: appName, bundleID: bundleID, version: version)
        hardStopWork = DispatchWorkItem { [weak self] in self?.stop() }
        if let hardStopWork {
            queue.asyncAfter(deadline: .now() + 600, execute: hardStopWork)
        }
        tryPort(18080)
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
        }
    }

    // MARK: - 服务

    private var pendingMeta: (appName: String, bundleID: String, version: String)?

    private func tryPort(_ candidate: Int) {
        guard candidate <= 18090 else {
            setStatus(L("本机端口 18080-18090 都被占用了，本机安装起不来，改用配对安装。"))
            stop()
            return
        }
        do {
            let tlsOptions = NWProtocolTLS.Options()
            let identity = try EnterpriseCertStore.identity()
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions, sec_identity_create(identity), queue)
            let params = NWParameters(tls: tlsOptions)
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
                        self.setStatus(L("本机安装服务断了，改用配对安装。"))
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
            setStatus((error as? LocalizedError)?.errorDescription
                ?? String(describing: error))
            stop()
        }
    }

    private func onReady(port: Int) {
        guard let meta = pendingMeta else { return }
        let base = "https://127.0.0.1:\(port)/\(installID)"
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
            stop()
            return
        }
        setStatus(L("已拉起系统安装：点「安装」后服务保持到下载完成，装完自动停。"))
        DispatchQueue.main.async {
            UIApplication.shared.open(link)
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
            // 别把 17MB 一次塞进内存。
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
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "OTAInstall") {
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
}
