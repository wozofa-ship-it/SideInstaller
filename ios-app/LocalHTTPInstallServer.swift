import AVFAudio
import Foundation
import UIKit

/// 本地直装（轻松签式）：App 内起一个明文 HTTP 服务，生成 OTA
/// 清单，用 itms-services 拉起系统安装——不走配对、不走隧道、
/// 不要 WiFi。关键区别：这里是明文 HTTP 回环（http://localhost），
/// 不用 TLS、不用企业证书当服务身份。之前那版 HTTPS + 证书 TLS
/// 在 iOS 26 上系统安装器建不起连接（实测“无法连接 127.0.0.1”），
/// 所以这条路特意不用证书做 TLS；地址也照轻松签用 localhost
///（不用 127.0.0.1 字面地址），跟轻松签实证做法对齐。
/// 服务本身就是轻松签实证在用的 GCDWebServer（vendored 在
/// ios-app/GCDWebServer/，上游未改）：BindToLocalhost 双栈
///（127.0.0.1 + ::1 同端口）、动态端口（Port=0，起完读 .port）、
/// FileResponse 自带 Range/206、keep-alive、正确的 Content-Length
///（IPA 默认 application/octet-stream）和 manifest 的
/// application/xml。v58/v59 手写 BSD 版被真机证伪（双栈 + 后台
/// 到期不停服 + 发完不停服 + 路径容错，仍弹“无法连接
/// localhost”），所以整套 BSD socket 代码已删，不再手写修补，
/// 只留这一套在跑（OTAInstallServer.swift 是 HTTPS 旧版，留着
/// 不用、不删、不再接线）。
/// 限制先说明白：
/// - 只能装企业证书签好的包（个人 ID 签的包走这条路装不上，
///   系统安装器验签名那关就过不了，仍走配对安装）。
/// - 服务只在安装期间跑，装完自动停；路径带随机 ID，不猜到。
final class LocalHTTPInstallServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    /// 最近一次失败原因：企业页/文件页据此在页内显示 + 重试回环，
    /// 不弹兜底、不碰配对/共享安装页；下次 install() 时清掉。
    @Published private(set) var lastError: String?

    private var webServer: GCDWebServer?
    /// 安装期间的独立静音音频（轻松签式）：Playback 类别、循环播
    /// 1 秒静音，靠 audio 后台模式无限时保活，不受 background
    /// task 到期限制。必须独立起，不能只依赖全局 keepAlive——
    /// 全局那只是 App 起动时起一次（起动失败/路由变化/静态计数
    /// 被别的实例耗到 0 都会悄悄死掉，安装时早已不在跑，v59
    /// 仍弹的另一半原因就在这）。这个 keeper 是实例私有的：
    /// start/stop 只动自己的 engine，stop 时不动 AVAudioSession
    ///（不 setActive(false)、不改类别），免得把全局 keepAlive 踩掉。
    private let installAudio = InstallAudioKeeper()
    private var installID = ""
    private var ipaURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var hardStopWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "czf.localhttp.install")

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

    /// 对一个刚签好的文件拉起本地安装（签名页「开始签名」用）。
    /// 必须在主线程调：状态/音频的启停都走主队列异步（见 stop()
    /// 的顺序注释），主线程调才能保证调用顺序就是执行顺序。
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

        // GCDWebServer：BindToLocalhost 双栈（127.0.0.1 + ::1 同端口，
        // 库内两个监听口，起完才返回，无 ready 竞态）、Port=0 动态
        // 端口（起完读 .port，轻松签 localInstallInfoWithPort 同款）、
        // 后台不自动挂起（音频保活 + background task 双保险）。
        // 不开 Bonjour、不设认证：回环 + 随机路径已够，安装器只认
        // 这两个 handler，别的不暴露。
        let server = GCDWebServer()
        do {
            try server.start(options: [
                GCDWebServerOption_BindToLocalhost: true,
                GCDWebServerOption_Port: 0,
                GCDWebServerOption_AutomaticallySuspendInBackground: false,
            ])
        } catch {
            let msg = L("本地安装服务启动失败，点安装重试。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            stop()
            return
        }
        // 先存进 webServer 再拼清单：清单生成万一失败走 stop() 时
        // 才能停掉已起的服务，不然起完没存、stop() 够不着就漏跑。
        webServer = server
        let port = Int(server.port)
        let base = "http://localhost:\(port)/\(installID)"
        let manifestURL = "\(base)/manifest.plist"
        let item: [String: Any] = [
            "assets": [
                ["kind": "software-package", "url": "\(base)/app.ipa"],
            ],
            "metadata": [
                "bundle-identifier": bundleID,
                "bundle-version": version,
                "kind": "software",
                "title": appName,
            ],
        ]
        guard let manifest = try? PropertyListSerialization.data(
            fromPropertyList: ["items": [item]], format: .xml, options: 0) else {
            let msg = L("安装清单生成失败，点安装重试。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            stop()
            return
        }
        // handler 是起完服务才注册的：GCDWebServer 的连接是按请求
        // 现查 handlers（不是起动时快照），所以先起服务、再拿端口
        // 拼清单、再注册 handler 是合法顺序；且在 itms-services 拉
        // 起前没人知道随机路径，不存在空窗被误击中的问题。
        // 路由沿用老结构（/<installID>/manifest.plist + /app.ipa，
        // 轻松签报告核过：功能上等价，不必改）。
        // handler 只抓 manifest/ipaPath 两个值，不抓 self：server
        // 持有 handler，handler 再抓 self 就是循环引用，停不掉。
        server.addHandler(forMethod: "GET", path: "/\(installID)/manifest.plist",
                          requestClass: GCDWebServerRequest.self) { _ in
            GCDWebServerDataResponse(data: manifest, contentType: "application/xml")
        }
        let ipaPath = ipaURL.path
        server.addHandler(forMethod: "GET", path: "/\(installID)/app.ipa",
                          requestClass: GCDWebServerRequest.self) { request in
            // 文件起服时已验过存在；装的过程中被删了就明给 404，
            // 不返回 nil（nil 在连接层行为未定义，别依赖它）。
            guard FileManager.default.fileExists(atPath: ipaPath) else {
                return GCDWebServerResponse(statusCode: 404)
            }
            // request.byteRange 直传：没 Range 就是全量 200，有
            // Range 就是 206 + Content-Range + Accept-Ranges，
            // 断点续传不用自己算（轻松签 FileResponse 同款）。
            return GCDWebServerFileResponse(file: ipaPath, byteRange: request.byteRange)
        }
        webServer = server
        hardStopWork = DispatchWorkItem { [weak self] in self?.stop() }
        if let hardStopWork {
            queue.asyncAfter(deadline: .now() + 600, execute: hardStopWork)
        }
        // 状态/音频一律走主队列异步（跟 stop() 里同一条纪律）：
        // 调用顺序就是执行顺序——stop() 的清场块先进队，音频起、
        // isRunning/status 后进队，绝不会出现“新音频起了又被旧
        // stop 块关掉”的倒序。音频起在 itms-services 拉起前排队，
        // 毫秒级就跑到，用户点系统“安装”时早已在播。
        DispatchQueue.main.async { [weak self] in
            self?.installAudio.start()
            self?.isRunning = true
        }
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

    func stop() {
        hardStopWork?.cancel()
        hardStopWork = nil
        webServer?.stop()
        webServer = nil
        ipaURL = nil
        installID = ""
        endBackgroundTask()
        // 顺序纪律（跟 install() 里同一条）：音频停、isRunning、
        // status 全走主队列异步，不在任何队列上同步动——这样
        // stop() 的清场块和 install() 的启动块按调用顺序排队，
        // 旧 stop 永远跑在新 start 前面，不会倒序关掉新音频。
        // 失败原因不在这里清（lastError 要留给页内显示 + 重试，
        // 下次 install() 时才清）。
        DispatchQueue.main.async { [weak self] in
            self?.installAudio.stop()
            self?.isRunning = false
            // 服务停了就把旧状态清掉，免得证书页一直挂着上一次的
            // “已拉起系统安装”。
            self?.status = nil
        }
    }

    // MARK: - 后台与状态

    private func beginBackgroundTask() {
        endBackgroundTask()
        // 到期只结束任务、不停服务：停服务只走 600 秒硬停、下次
        // 安装的 stop()，不走任务到期（v59 已改，沿用；音频保活
        // 才是安装期间不挂起的主力，task 只是补充）。
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

    /// 安装期间的独立静音音频（见 installAudio 注释）：Playback
    /// 类别、循环播 1 秒静音。跟全局 KeepAlive 同款 engine 写法
    ///（本仓已验证的路子），但状态是实例私有的，不参与全局
    /// keepAlive 的静态计数，stop 时不动 session，互不踩。
    /// 调用纪律：start/stop 只在主队列上跑（install()/stop() 里
    /// 都已排主队列），不在后台队列直接碰 engine。
    private final class InstallAudioKeeper {
        private let engine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private var running = false

        func start() {
            guard !running else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                let format = engine.outputNode.inputFormat(forBus: 0)
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                let frames = AVAudioFrameCount(format.sampleRate)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                buffer.frameLength = frames
                try engine.start()
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.play()
                running = true
            } catch {
                running = false
                engine.stop()
            }
        }

        func stop() {
            guard running else { return }
            player.stop()
            engine.stop()
            engine.detach(player)
            running = false
            // 故意不动 session：全局 keepAlive 若在跑，setActive(false)
            // 或改类别会把它一起踩掉；若没在跑，App 挂起时系统自会收回。
        }
    }

}
