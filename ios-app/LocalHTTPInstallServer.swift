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
    /// 全局唯一：证书页与文件页共用同一实例，isRunning/status/
    /// lastError 不再两边分裂（以前各 @StateObject 一个，A 页起的
    /// 安装 B 页看不到、两边各起一个服务还互相踩音频）。
    static let shared = LocalHTTPInstallServer()
    private init() {}

    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    /// 最近一次失败原因：企业页/文件页据此在页内显示 + 重试回环，
    /// 不弹兜底、不碰配对/共享安装页；下次 install() 时清掉。
    @Published private(set) var lastError: String?
    /// 接线诊断日志（下次再弹“无法连接 localhost”时看这个）：
    /// handler 命中、起服端口都记一行；Console 可见，页内也可直接
    /// 读这个数组展示。只留最近 100 行。
    @Published private(set) var diagnosticLog: [String] = []

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
    /// 20 秒无连接看门狗：起服后 20 秒内没有任何 handler 被命中就
    /// 触发（见 handleNoHitTimeout）。handler 命中即取消；stop()
    /// 时取消 + 置 nil（所有权点只在 stop()/install()，handler 线程
    /// 上只 cancel、不置 nil，幂等、无竞态后果）。
    private var noHitWatchdog: DispatchWorkItem?
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
        // handler 必须在起服前注册（GCDWebServer.h 警告：运行中加
        // handler 行为未定义）。manifest 数据要等起服读到端口才拼
        // 得出来，所以 manifest handler 不直接抓数据，改读一个盒子：
        // 起服前注册占位、起服后立刻填满；itms-services 拉起前没人
        // 知道随机路径，不存在空窗被误击中的问题；盒子没填满时命中
        // 返回 503（理论上到不了）。路由沿用老结构
        //（/<installID>/manifest.plist + /app.ipa，轻松签报告核过：
        // 功能上等价，不必改）。handler 只抓 manifestPath/ipaPath/
        // 盒子三个局部值，self 只弱引用：server 持有 handler，handler
        // 再强抓 self 就是循环引用，停不掉。
        final class ManifestBox { var data: Data? }
        let manifestBox = ManifestBox()
        let manifestPath = "/\(installID)/manifest.plist"
        let ipaRoutePath = "/\(installID)/app.ipa"
        let ipaPath = ipaURL.path
        let server = GCDWebServer()
        server.addHandler(forMethod: "GET", path: manifestPath,
                          request: GCDWebServerRequest.self) { [weak self] request in
            self?.cancelNoHitWatchdog()
            self?.log("GET \(manifestPath) \(self?.rangeDescription(for: request) ?? "range=none")")
            guard let data = manifestBox.data else {
                return GCDWebServerResponse(statusCode: 503)
            }
            return GCDWebServerDataResponse(data: data, contentType: "application/xml")
        }
        server.addHandler(forMethod: "GET", path: ipaRoutePath,
                          request: GCDWebServerRequest.self) { [weak self] request in
            self?.cancelNoHitWatchdog()
            self?.log("GET \(ipaRoutePath) \(self?.rangeDescription(for: request) ?? "range=none")")
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
        log("server started port=\(port) id=\(installID)")
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
        manifestBox.data = manifest
        hardStopWork = DispatchWorkItem { [weak self] in self?.stop() }
        if let hardStopWork {
            queue.asyncAfter(deadline: .now() + 600, execute: hardStopWork)
        }
        // 20 秒无连接看门狗（见 scheduleNoHitWatchdog）：起服后 20 秒
        // 内没有任何 handler 被命中，说明 itms-services 拉起了、但
        // installd 没连进来（弹窗那一路），别让 isRunning 锁死到
        // 600 秒硬停；看门狗只看“有无命中”，用户在系统弹窗前犹豫
        // 超过 20 秒也会触发——有意取舍：宁可让慢用户点一次重试，
        // 也不让失败用户卡 600 秒没法重试；一旦 manifest 被命中
        // （用户点了安装），看门狗即取消，下载再慢也不停。
        scheduleNoHitWatchdog()
        // 状态/音频一律走主队列异步（跟 stop() 里同一条纪律）：
        // 调用顺序就是执行顺序——stop() 的清场块先进队，音频起、
        // isRunning/status 后进队，绝不会出现“新音频起了又被旧
        // stop 块关掉”的倒序。音频起在 itms-services 拉起前排队，
        // 毫秒级就跑到，用户点系统“安装”时早已在播。
        DispatchQueue.main.async { [weak self] in
            // 音频起失败不再静默（以前 start() 内部 catch 后只置 false，
            // 页内看不到）：写 lastError，失败时用户知道后台可能挂起服务。
            // 注意：这时 isRunning 随即置 true，页内 isRunning 分支只显示
            // “取消安装”，这条 lastError 在停服后才露出（若随后看门狗
            // 触发，它的 lastError 会覆盖这条，以最近的为准）。
            let audioOK = self?.installAudio.start() ?? false
            if audioOK == false {
                self?.lastError = L("安装期静音保活启动失败，后台可能挂起服务，失败时点重试。")
            }
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
        noHitWatchdog?.cancel()
        noHitWatchdog = nil
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

    /// 接线诊断日志：Console 可见（NSLog 自带时间），同时进
    /// diagnosticLog 数组（页内可读）。handler 在 GCDWebServer 线程
    /// 上调 log()，所以时间格式每次现建（DateFormatter 非线程安全，
    /// 不能共用静态实例），数组追加走主队列（@Published 须主线程改）。
    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        NSLog("[LocalHTTPInstall] %@", line)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.diagnosticLog.append(line)
            if self.diagnosticLog.count > 100 {
                self.diagnosticLog.removeFirst(self.diagnosticLog.count - 100)
            }
        }
    }

    /// handler 的 Range 头描述（日志用）：有 Range 头就原样贴出
    ///（如 bytes=0-1023、bytes=-500），没有就是 range=none。
    /// 不用 byteRange.location 判断：无 Range 时 GCDWebServer 填
    /// NSUIntegerMax（转 Int 是 -1），后缀 Range 时 location 同样
    /// 是 NSUIntegerMax，location 判断会把后缀 Range 误判成无 Range。
    private func rangeDescription(for request: GCDWebServerRequest) -> String {
        for (key, value) in request.headers where key.lowercased() == "range" {
            return "range=\(value)"
        }
        return "range=none"
    }

    private func scheduleNoHitWatchdog() {
        noHitWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleNoHitTimeout()
        }
        noHitWatchdog = work
        queue.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// handler 线程上只 cancel、不置 nil（见 noHitWatchdog 注释）。
    private func cancelNoHitWatchdog() {
        noHitWatchdog?.cancel()
    }

    /// 20 秒内无任何 handler 命中：itms-services 拉起了、但 installd
    /// 没连进来。别等 600 秒硬停：自动停服 + 置失败原因，页内
    /// “重试回环安装”立刻可用（stop() 不清 lastError，原因留得住）。
    private func handleNoHitTimeout() {
        let msg = L("系统安装没连上本地服务，点重试。")
        setStatus(msg)
        DispatchQueue.main.async { [weak self] in self?.lastError = msg }
        stop()
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    /// 安装期间的独立静音音频（见 installAudio 注释）：Playback
    /// 类别、循环播 1 秒静音。跟全局 KeepAlive 同款 engine 写法
    ///（本仓已验证的路子），但 engine 是实例私有的；session 则
    /// 不再私有：start 成功时向全局 KeepAlive 计数 +1（只动计数、
    /// 不启动全局 engine），这样全局最后一个 holder 停掉时不会
    /// 误调 releaseSession() 把安装音频的 session 一起杀掉；stop
    /// 时计数 -1，归零才释放。stop 时仍不动 session 的类别/激活
    ///（除非计数归零走全局释放），互不踩。
    /// 调用纪律：start/stop 只在主队列上跑（install()/stop() 里
    /// 都已排主队列），不在后台队列直接碰 engine；也因此这里用
    /// MainActor.assumeIsolated 调全局计数（KeepAlive 是 @MainActor
    /// 类），主队列上必成立。
    /// start() 返回 Bool：失败不再静默置 false 了事，调用方
    ///（install()）据此写 lastError，页内可见。
    private final class InstallAudioKeeper {
        private let engine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private var running = false
        private var interruptionObserver: NSObjectProtocol?

        deinit {
            if let observer = interruptionObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        @discardableResult
        func start() -> Bool {
            guard !running else { return true }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                let format = engine.outputNode.inputFormat(forBus: 0)
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                let frames = AVAudioFrameCount(format.sampleRate)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                    // 已 attach 但没起：先 detach，免得下次 start() 重复 attach。
                    engine.detach(player)
                    return false
                }
                buffer.frameLength = frames
                try engine.start()
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.play()
                running = true
                // 中断监听：电话/Siri 打断后，中断结束要重起引擎，
                // 否则安装期静音一断就不再保活（后台挂起 → installd
                // 连不上）。observer 在 stop()/deinit 时移除。
                if interruptionObserver == nil {
                    interruptionObserver = NotificationCenter.default.addObserver(
                        forName: AVAudioSession.interruptionNotification,
                        object: session, queue: .main) { [weak self] note in
                        self?.handleInterruption(note)
                    }
                }
                // 先占全局计数：此后全局 holder 停掉也不会释放 session。
                MainActor.assumeIsolated { KeepAlive.retainAudioSession() }
                return true
            } catch {
                running = false
                engine.stop()
                engine.detach(player)
                return false
            }
        }

        func stop() {
            guard running else { return }
            if let observer = interruptionObserver {
                NotificationCenter.default.removeObserver(observer)
                interruptionObserver = nil
            }
            player.stop()
            engine.stop()
            engine.detach(player)
            running = false
            // 计数 -1：归零时全局释放 session；不归零时不动 session，
            // 全局 keepAlive 若在跑不受影响。
            MainActor.assumeIsolated { KeepAlive.releaseAudioSession() }
            // 故意不动 session 的类别/激活（除非上面计数归零已释放）：
            // 全局 keepAlive 若在跑，setActive(false) 或改类别会把它
            // 一起踩掉；若没在跑，App 挂起时系统自会收回。
        }

        /// 中断结束：engine 可能已停，重起（player 仍在 schedule，
        /// 没在播就再 play）。中断类型不是 .ended 不管；running
        /// 已是 false（停服中）也不管。
        private func handleInterruption(_ note: Notification) {
            guard running else { return }
            guard let info = note.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
                  type == .ended else { return }
            do {
                if !engine.isRunning { try engine.start() }
                if !player.isPlaying { player.play() }
            } catch {
                // 重起失败不静默吞掉：下次 install() 的 start() 会重新
                // 建 engine 并把失败写进 lastError；这里 engine 已 attach
                // 过，重起只是尽力恢复，不断言。
            }
        }
    }

}
