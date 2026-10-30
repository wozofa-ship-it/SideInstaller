import Darwin
import Foundation
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
    /// 最近一次失败原因：企业页/文件页据此在页内显示 + 重试回环，
    /// 不弹兜底、不碰配对/共享安装页；下次 install() 时清掉。
    @Published private(set) var lastError: String?

    // BSD 直绑回环：NWListener 的 on: 只收端口、收不了 host
    //（0.9.6 编译红字），且它报 ready 也不等于系统安装器能连上
    // localhost；轻松签就是 BSD socket 绑 127.0.0.1，同款做法。
    private var listenFD: Int32 = -1
    private var listenFD6: Int32 = -1
    private let fdLock = NSLock()
    private var activeCandidate = 0
    private let queue = DispatchQueue(label: "czf.localhttp.install")
    // 双栈要同时 accept 两个口：串行队列会让第二个 acceptLoop
    // 永远排不上（第一个 accept 一直阻塞），所以用并发队列。
    private let acceptQueue = DispatchQueue(label: "czf.localhttp.accept", attributes: .concurrent)
    private var clientFDs = Set<Int32>()
    private var installID = ""
    private var ipaURL: URL?
    private var manifestData = Data()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stopWork: DispatchWorkItem?
    private var hardStopWork: DispatchWorkItem?

    /// 对一个已签好的记录拉起本地安装。
    func install(record: SignedIPARecord) {
        lastError = nil
        guard !record.bundleID.isEmpty else {
            setStatus(L("这个已签名记录没有 Bundle ID，装不了，先重签一次。"))
            return
        }
        install(ipaURL: SignedIPAStore.url(for: record), appName: record.appName,
                bundleID: record.bundleID, version: record.version ?? "1.0")
    }

    /// 对一个刚签好的文件拉起本地安装（签名页「签名并安装」用）。
    /// 必须在主线程调：这里同步清掉上一轮的失败原因（stop() 里
    /// 不清，免得失败原因还没被页内读到就被后来的一次 stop 吞掉）。
    func install(ipaURL: URL, appName: String, bundleID: String, version: String) {
        stop()
        lastError = nil
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
        // 关监听口：阻塞在 accept 里的循环会被 EBADF 唤醒退出。
        // fdLock 防 double-close（stop 可能在主线程和 work 队列
        // 上同时进来，close 同一个号两次会误关后来复用的号）。
        // 双栈两个口一起关，缺一个都会让另一半继续占端口。
        fdLock.lock()
        let fd = listenFD
        let fd6 = listenFD6
        listenFD = -1
        listenFD6 = -1
        fdLock.unlock()
        if fd >= 0 { close(fd) }
        if fd6 >= 0 { close(fd6) }
        // 已接进来的连接在 work 队列上关（不阻塞主线程）。
        queue.async { [weak self] in
            guard let self else { return }
            let fds = self.clientFDs
            self.clientFDs.removeAll()
            for c in fds { close(c) }
        }
        ipaURL = nil
        pendingMeta = nil
        manifestData = Data()
        endBackgroundTask()
        DispatchQueue.main.async {
            self.isRunning = false
            // 服务停了就把旧状态清掉，免得证书页一直挂着上一次的
            // “已拉起系统安装”；失败原因不在这里清（lastError 要
            // 留给页内显示 + 重试，下次 install() 时才清）。
            self.status = nil
        }
    }

    // MARK: - 服务

    private var pendingMeta: (appName: String, bundleID: String, version: String)?

    private func tryPort(_ candidate: Int) {
        guard candidate <= 18110 else {
            let msg = L("本地端口 18100-18110 都被占用了，本地安装起不来。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            stop()
            return
        }
        // 明文 TCP，不挂 TLS：系统安装器连不上带证书身份的
        // HTTPS 回环，但明文 HTTP 回环是轻松签同款做法。
        // 关键：BSD 直接绑 127.0.0.1（轻松签 BindToLocalhost
        // 同款）。NWListener 的 on: 只收端口、收不了 host，
        // 0.9.6 因此编译失败；且它报 ready 也不等于系统安装器
        // 能连上 localhost——0.9.5 分离版只分了路、没定死绑定
        // 地址，系统安装器照样弹“无法连接 localhost”。
        // BSD bind+listen 是同步的：到这里端口已经绑死在回环
        // 上，不用等异步 ready，直接生成清单、拉起系统安装。
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { tryPort(candidate + 1); return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(candidate).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else {
            close(fd)
            tryPort(candidate + 1)
            return
        }
        // 双栈：localhost 可能解析到 ::1（IPv6），只绑 IPv4 时系统
        // 安装器连 ::1 直接被拒——v58 在真机上仍弹“无法连接
        // localhost”就是这个缺口（ESign 的 GCDWebServer 绑回环是
        // 双栈同款）。IPv6 口单独 v6only，不跟 IPv4 口抢地址；
        // 任一口绑不上都换下一个端口（两口必须同端口，清单里
        // 只写一个端口，缺一半就等于另一半白绑）。
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd6 >= 0 else { close(fd); tryPort(candidate + 1); return }
        var reuse6: Int32 = 1
        setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &reuse6,
                   socklen_t(MemoryLayout<Int32>.size))
        var v6only: Int32 = 1
        setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &v6only,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr6 = sockaddr_in6()
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = UInt16(candidate).bigEndian
        addr6.sin6_addr = in6addr_loopback
        let bound6 = withUnsafePointer(to: &addr6) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd6, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound6 == 0, listen(fd6, 5) == 0 else {
            close(fd)
            close(fd6)
            tryPort(candidate + 1)
            return
        }
        fdLock.lock()
        listenFD = fd
        listenFD6 = fd6
        fdLock.unlock()
        activeCandidate = candidate
        // 接受循环放独立队列：accept 会阻塞，不能占 work 队列
        //（stopWork/hardStopWork 的定时器还在上面）。双栈两个
        // 口各一条 acceptLoop（队列已改并发，两条能同时阻塞）。
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd) }
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd6) }
        onReady(port: candidate)
    }

    /// 阻塞接受循环（跑在 acceptQueue 上）。stop() 关掉监听口
    /// 后，阻塞的 accept 返回 EBADF，循环退出；EINTR 只重等一次。
    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            queue.async { [weak self] in self?.handleClient(client) }
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
            let msg = L("安装清单生成失败，点安装重试。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            stop()
            return
        }
        manifestData = data
        DispatchQueue.main.async { self.isRunning = true }
        // 每次安装换一个随机路径，系统安装器不会吃到上次缓存的旧清单。
        let encoded = manifestURL.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? manifestURL
        guard let link = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            let msg = L("安装链接生成失败，点安装重试。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            stop()
            return
        }
        setStatus(L("已拉起系统安装：点「安装」后服务保持到下载完成，装完自动停，进度回桌面看。"))
        DispatchQueue.main.async {
            UIApplication.shared.open(link, options: [:]) { [weak self] opened in
                if !opened {
                    let msg = L("系统安装没拉起来，点安装重试。")
                    self?.setStatus(msg)
                    DispatchQueue.main.async { self?.lastError = msg }
                    self?.stop()
                }
            }
        }
    }

    // MARK: - HTTP（只认 GET，两条路由）

    /// 一个已接受的连接（跑在 work 队列上，串行，clientFDs
    /// 的增删都在这条队列上，不用另加锁）。读到完整 HTTP 头
    /// 就按路径回包；对端断开、出错、头超 1MB 都直接关。
    private func handleClient(_ fd: Int32) {
        clientFDs.insert(fd)
        defer {
            clientFDs.remove(fd)
            close(fd)
        }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        while buf.count <= (1 << 20) {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return }
            buf.append(tmp, count: n)
            if let path = Self.requestPath(buf) {
                respond(fd: fd, path: path)
                return
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
        var raw = String(parts[1])
        // 容错：安装器可能发绝对地址（GET http://localhost:端口/...）
        // 或带查询串，原样精确匹配会 404。绝对地址只取路径部分
        //（URL.path 本来就不含查询串），相对地址顺手去掉 ? 之后。
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            if let url = URL(string: raw) {
                raw = url.path
            }
        } else if let q = raw.firstIndex(of: "?") {
            raw = String(raw[..<q])
        }
        return raw
    }

    private func respond(fd: Int32, path: String) {
        if path == "/\(installID)/manifest.plist" {
            send(fd: fd, status: "200 OK", contentType: "text/xml",
                 length: manifestData.count, body: manifestData)
            return
        }
        if path == "/\(installID)/app.ipa", let ipaURL {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path))?[.size] as? Int,
                  let handle = try? FileHandle(forReadingFrom: ipaURL) else {
                send(fd: fd, status: "404 Not Found", contentType: "text/plain",
                     length: 0, body: Data())
                return
            }
            // 安装器下载包时 App 已退到后台，分片发、发完不停
            //（停服务走 600 秒硬停），别把大包一次塞进内存。
            send(fd: fd, status: "200 OK", contentType: "application/octet-stream",
                 length: size, body: nil)
            sendFile(fd: fd, handle: handle, remaining: size)
            return
        }
        send(fd: fd, status: "404 Not Found", contentType: "text/plain",
             length: 0, body: Data())
    }

    /// 同步发完一整段：send 可能只发出去一部分，循环发完
    ///（或对端断开就停）。发完由调用方关连接。
    private func send(fd: Int32, status: String, contentType: String,
                      length: Int, body: Data?) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        payload.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            guard let base = raw.baseAddress else { return }
            while sent < total {
                let n = Darwin.send(fd, base.advanced(by: sent), total - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private func sendFile(fd: Int32, handle: FileHandle, remaining: Int) {
        var left = remaining
        while left > 0 {
            let chunk = handle.readData(ofLength: min(left, 64 * 1024))
            guard !chunk.isEmpty else { break }
            var ok = true
            chunk.withUnsafeBytes { raw in
                var sent = 0
                let total = raw.count
                guard let base = raw.baseAddress else { ok = false; return }
                while sent < total {
                    let n = Darwin.send(fd, base.advanced(by: sent), total - sent, 0)
                    if n <= 0 { ok = false; return }
                    sent += n
                }
            }
            guard ok else { break }
            left -= chunk.count
        }
        try? handle.close()
        // 整包发完不停服务：安装器可能重试/断点续传，20 秒就停
        // 会把重试挡在外面（ESign 是装完才停，不设 20 秒）。
        // 停服务只走 600 秒硬停、下次安装的 stop()，不走发完计时。
        // 中途断开也只关连接，同样不走停服务。
        guard left == 0 else { return }
    }

    // MARK: - 后台与状态

    private func beginBackgroundTask() {
        endBackgroundTask()
        // 到期只结束任务、不停服务：ESign 靠静音音频无限时保活，
        // Side 起动时也已起 keepAlive 音频（Shortcuts 续签用），
        // App 不会因此挂起；到期就停服务的话，用户在系统安装
        // 弹窗上多停 30 秒、服务就没了，安装器再连就是“无法连接”。
        // 停服务只走 600 秒硬停、下次安装的 stop()，不走任务到期。
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocalHTTPInstall") {
            [weak self] in self?.endBackgroundTask()
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
