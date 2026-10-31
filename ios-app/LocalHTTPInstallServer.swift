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
/// v63 起重新启用：企业安装改回轻松签式（本机 HTTP + itms-services），
/// 不再走 Engine 配对路；证书页/文件页/源导入的企业安装全走这里，
/// 企业页自己显示进度，绝不弹到安装 tab、绝不出现“登录 Apple ID”。
/// 与 v60 的不同（逐项对过轻松签分析，静态能核的都核了）：
/// - 防重入：install() 时 isRunning 直接拒绝，不停掉已在跑的服务
///   再起新口（v60 无此 guard，二次触发会杀掉第一个服务、旧清单
///   URL 立刻拒连，正好是“无法连接 localhost”的样子）。
/// - 无 20 秒看门狗：v61 的无连接看门狗会在 installd 慢连（用户在
///   系统安装确认上犹豫超 20 秒）时杀服务，轻松签根本没有这种
///   杀法；服务只走 600 秒硬停、手动取消、下次安装的 stop()。
/// - 音频失败可见：保活起失败仍写 lastError（不静默），企业页的
///   安装状态区会把它露出来，不再是只有 Console 能看到的暗线。
/// - IPA 响应显式 Accept-Ranges: bytes（FileResponse 本就处理
///   Range/206，这里再明写一遍，跟轻松签定制 FileResponse 同款）。
/// 其余与轻松签实证对齐项（v60 已有，沿用）：GCDWebServer 双栈
///（库内 v4/v6 同端口，见 GCDWebServer.m _start:）、Port=0 动态
/// 端口、manifest application/xml、IPA FileResponse + byteRange、
/// audio 后台模式 + background task 双保险、随机 installID 路径。
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
    /// 接线诊断日志（v63 起恢复：服务重新跑，handler 命中、起服
    /// 端口记一行，Console 可见，页内也可直接读这个数组展示，
    /// 只留最近 100 行。v62 停用期间恒为空是服务没跑，不是日志
    /// 本身坏了）。
    @Published private(set) var diagnosticLog: [String] = []

    private var webServer: GCDWebServer?
    /// 同步防重入标志：isRunning 是 @Published、经主队列异步置位，
    /// 连续两次 install() 之间有空窗（第一次的 isRunning=true 还没
    /// 跑到，第二次就进了门）；这个标志只在主线程同步置位/清掉，
    /// 堵住空窗。stop() 入口同步清、install() 占位后同步置。
    private var installActive = false
    /// 同步忙标志（供页内 guard 在点按那一刻读一次）：占位中或
    /// 服务在跑都算忙。不是 @Published——按钮禁用仍用 isRunning
    /// + 页内 inFlight（那两个会刷新），这个只作点按时的一次判断。
    var isBusy: Bool { installActive || isRunning }
    /// 安装期间的独立静音音频（轻松签式）：Playback 类别、
    /// AVAudioPlayer 循环播包内置真实静音文件，靠 audio 后台
    /// 模式无限时保活，不受 background task 到期限制。必须独立
    /// 起，不能只依赖全局 keepAlive——全局那只是 App 起动时起
    /// 一次（起动失败/路由变化/静态计数被别的实例耗到 0 都会
    /// 悄悄死掉，安装时早已不在跑，v59 仍弹的另一半原因就在这）。
    /// 这个 keeper 是实例私有的：start/stop 只动自己的 player，
    /// stop 时不动 AVAudioSession（不 setActive(false)、不改类别），
    /// 免得把全局 keepAlive 踩掉。
    private let installAudio = InstallAudioKeeper()
    private var installID = ""
    private var ipaURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var hardStopWork: DispatchWorkItem?
    /// v63 起无看门狗：服务活到 600 秒硬停、手动取消或下次安装，
    /// installd 慢连也不杀（见文件头注释，轻松签无此杀法）。
    private let queue = DispatchQueue(label: "czf.localhttp.install")

    /// 对一个已签好的记录拉起本地安装。completion 在主线程恰好
    /// 调一次：true = itms-services 已拉起（系统接管，进度回桌面
    /// 看）；false + 文案 = 服务没起来/链接没拉起，可重试。
    func install(record: SignedIPARecord, completion: ((Bool, String?) -> Void)? = nil) {
        lastError = nil
        guard !record.bundleID.isEmpty else {
            let msg = L("这个已签名记录没有 Bundle ID，装不了，先重签一次。")
            setStatus(msg)
            DispatchQueue.main.async { completion?(false, msg) }
            return
        }
        install(ipaURL: SignedIPAStore.url(for: record), appName: record.appName,
                bundleID: record.bundleID, version: record.version ?? "1.0",
                completion: completion)
    }

    /// 对一个刚签好的文件拉起本地安装（签名页「开始签名」用）。
    /// 必须在主线程调：状态/音频的启停都走主队列异步（见 stop()
    /// 的顺序注释），主线程调才能保证调用顺序就是执行顺序。
    /// completion 在主线程恰好调一次（见 install(record:) 注释）。
    func install(ipaURL: URL, appName: String, bundleID: String, version: String,
                 completion: ((Bool, String?) -> Void)? = nil) {
        // 结果只报一次：各失败 return 与 open() 回调互斥，但 stop()
        // 与 open() 回调万一都走到这里，flag 拦住第二下，不双报。
        var completionFired = false
        func finish(_ ok: Bool, _ msg: String?) {
            DispatchQueue.main.async {
                guard !completionFired else { return }
                completionFired = true
                completion?(ok, msg)
            }
        }
        // 防重入（v63 新增，见文件头）：已在跑就直接拒绝，不停旧
        // 服务、不起新口——旧清单 URL 必须一直有效，杀了就拒连。
        // 这里不碰 status/lastError（跑着的安装的状态要原样留着，
        // 原因只经 completion 回给调用方，由调用方页内显示）。
        // guard 看 installActive（同步）+ isRunning（异步置位，双保险）。
        guard !installActive && !isRunning else {
            finish(false, L("本地安装服务已在运行，先取消当前安装再试。"))
            return
        }
        stop()
        // 占位：从这里起、到 stop() 前，任何再进来的 install() 都
        // 被上面 guard 挡住（stop() 的异步清场块排在后面，不会
        // 把这个刚置的位清掉——清位只走 stop() 入口的同步行）。
        installActive = true
        lastError = nil
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            let msg = L("签好的文件找不到了，先重签一次。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            finish(false, msg)
            // 别漏 stop()：上面已置 installActive=true，不清掉，
            // 下次安装会被防重入 guard 永久挡住（直到杀 App）。
            stop()
            return
        }
        // 企业安装前先停内置隧道：企业安装走 localhost HTTP，不需要
        // 隧道；隧道是各步骤自动拉起后从不停（BuiltinTunnel 此前无
        // stop 调用点），若在跑可能干扰 installd 的回环连接（v65 前台
        // 仍弹 localhost 的头号嫌疑）。fire-and-forget：停隧道是系统
        // 异步操作，不阻塞起服；installd 取清单在用户点系统“安装”
        // 之后（数秒后），停隧道的时间足够。停失败不阻断安装（stop()
        // 内部已吞错），ID 操作需要时会自动再拉隧道。
        // 注意：上面那个 stop() 是本地服务停服，BuiltinTunnel.stop()
        // 是停系统 VPN 隧道，两者不同名不同物，别混。
        log("enterprise install: stopping built-in tunnel before local server")
        Task { await BuiltinTunnel.stop() }
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
            self?.log("GET \(manifestPath) \(self?.rangeDescription(for: request) ?? "range=none")")
            guard let data = manifestBox.data else {
                return GCDWebServerResponse(statusCode: 503)
            }
            return GCDWebServerDataResponse(data: data, contentType: "application/xml")
        }
        server.addHandler(forMethod: "GET", path: ipaRoutePath,
                          request: GCDWebServerRequest.self) { [weak self] request in
            self?.log("GET \(ipaRoutePath) \(self?.rangeDescription(for: request) ?? "range=none")")
            // 文件起服时已验过存在；装的过程中被删了就明给 404，
            // 不返回 nil（nil 在连接层行为未定义，别依赖它）。
            guard FileManager.default.fileExists(atPath: ipaPath) else {
                return GCDWebServerResponse(statusCode: 404)
            }
            // request.byteRange 直传：没 Range 就是全量 200，有
            // Range 就是 206 + Content-Range + Accept-Ranges，
            // 断点续传不用自己算（轻松签 FileResponse 同款）。
            // Accept-Ranges 再明写一遍：206 时库里自带，200 时也
            // 让 installd 知道能断点续传（轻松签定制 FileResponse
            // 同款显式头）。
            let response = GCDWebServerFileResponse(file: ipaPath, byteRange: request.byteRange)
            response?.setValue("bytes", forAdditionalHeader: "Accept-Ranges")
            return response
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
            finish(false, msg)
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
            finish(false, msg)
            stop()
            return
        }
        manifestBox.data = manifest
        hardStopWork = DispatchWorkItem { [weak self] in self?.stop() }
        if let hardStopWork {
            queue.asyncAfter(deadline: .now() + 600, execute: hardStopWork)
        }
        // v63 起无看门狗（见文件头）：服务活到 600 秒硬停、手动
        // 取消或下次安装；用户在系统安装确认上犹豫再久也不杀，
        // installd 慢连也不杀——杀服务正是 v61 仍弹的嫌疑之一。
        // 状态/音频一律走主队列异步（跟 stop() 里同一条纪律）：
        // 调用顺序就是执行顺序——stop() 的清场块先进队，音频起、
        // isRunning/status 后进队，绝不会出现“新音频起了又被旧
        // stop 块关掉”的倒序。音频起在 itms-services 拉起前排队，
        // 毫秒级就跑到，用户点系统“安装”时早已在播。
        // 取消竞态 guard（v63 新增）：install() 返回后、这两个异步
        // 块跑到之前，用户可能点了取消（stop() 已清 installID +
        // installActive）或起了新安装（installID 已换）。令牌对不上
        // 就什么都不做——不启动音频、不置 isRunning、不拉起安装、
        // 不报 completion（取消那路的页内 inFlight 由取消按钮自己
        // 清，不记成功也不记失败；新安装那路由新调用的 completion 管）。
        let installToken = installID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.installID == installToken, self.installActive else { return }
            // 音频起失败不再静默（以前 start() 内部 catch 后只置 false，
            // 页内看不到）：写 lastError，失败时用户知道后台可能挂起服务。
            // 注意：这时 isRunning 随即置 true，页内 isRunning 分支只显示
            // “取消安装”，这条 lastError 在停服后才露出（若随后看门狗
            // 触发，它的 lastError 会覆盖这条，以最近的为准）。
            let audioOK = self.installAudio.start()
            if audioOK == false {
                self.lastError = L("安装期静音保活启动失败，后台可能挂起服务，失败时点重试。")
            }
            self.isRunning = true
        }
        // 每次安装换一个随机路径，系统安装器不会吃到上次缓存的旧清单。
        let encoded = manifestURL.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? manifestURL
        guard let link = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
            let msg = L("安装链接生成失败，点安装重试。")
            setStatus(msg)
            DispatchQueue.main.async { self.lastError = msg }
            finish(false, msg)
            stop()
            return
        }
        setStatus(L("已拉起系统安装：点「安装」后服务保持到下载完成，装完自动停，进度回桌面看。"))
        DispatchQueue.main.async { [weak self] in
            // 同上：取消/新安装已发生时不开 itms-services（开了就
            // 停不下来，还会把 completion 的成功报给已取消的那次）。
            guard let self, self.installID == installToken, self.installActive else { return }
            UIApplication.shared.open(link, options: [:]) { [weak self] opened in
                if opened {
                    // 系统接管了：App 的活到此为止，服务继续跑着供
                    // installd 取包（600 秒硬停/手动取消才停），不
                    // 在这里 stop()——停了 installd 就拒连。
                    finish(true, nil)
                } else {
                    let msg = L("系统安装没拉起来，点安装重试。")
                    self?.setStatus(msg)
                    DispatchQueue.main.async { self?.lastError = msg }
                    finish(false, msg)
                    self?.stop()
                }
            }
        }
    }

    func stop() {
        // 同步清位（见 installActive 注释）：stop() 入口就清，不等
        // 后面主队列的清场块，这样下一次 install() 的 guard 立刻
        // 就能进，不会被上一次的异步块拖住。
        installActive = false
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

    /// 企业页步骤日志：签名/安装阶段行也进同一份 diagnosticLog
    ///（不另起一套日志系统，轻松签式一步步就在这份日志里看）。
    /// 只追加一行，不动安装流程；log() 本身走主队列追加，任何
    /// 线程调都安全。
    func appendStepLog(_ message: String) {
        log(message)
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

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    /// 安装期间的独立静音音频（v65 起换轻松签同款：AVAudioPlayer
    /// 循环播包内置真实静音文件 InstallSilence.wav，替代 v63 的
    /// AVAudioEngine 合成 1 秒静音——合成静音无渲染校验，中途停摆
    /// 无人知道，是 v58—v64 五代同弹窗的头号候选（第二阶段 installd
    /// 取包时后台死掉）；真实文件 + isPlaying 校验 + 前后台复核，
    /// 停了能发现、能重起。session 不再私有：start 成功时向全局
    /// KeepAlive 计数 +1（只动计数、不启动全局 engine），这样全局
    /// 最后一个 holder 停掉时不会误调 releaseSession() 把安装音频
    /// 的 session 一起杀掉；stop 时计数 -1，归零才释放。stop 时仍
    /// 不动 session 的类别/激活（除非计数归零走全局释放），互不踩。
    /// 调用纪律：start/stop 只在主队列上跑（install()/stop() 里
    /// 都已排主队列），不在后台队列直接碰 player；也因此这里用
    /// MainActor.assumeIsolated 调全局计数（KeepAlive 是 @MainActor
    /// 类），主队列上必成立。
    /// start() 返回 Bool：文件缺失、建 player 失败、play() 回 false、
    /// play 后 isPlaying 仍 false 都算失败，调用方（install()）据此
    /// 写 lastError，页内可见，不再静默。前后台/中断复核只是尽力
    /// 恢复（失败不写 lastError，下次复核或下次 install() 再起）。
    private final class InstallAudioKeeper {
        private var player: AVAudioPlayer?
        private var running = false
        private var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers {
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
                // 包内置真实静音文件（InstallSilence.wav，2 秒全零 PCM，
                // 循环无断点）：文件缺失就失败，不静默用合成顶替。
                guard let url = Bundle.main.url(forResource: "InstallSilence", withExtension: "wav") else {
                    return false
                }
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.numberOfLoops = -1
                _ = newPlayer.prepareToPlay()
                // 校验渲染：play() 回 false 或 play 后仍不在播，都算
                // 失败（v63 合成路子缺的正是这一校验——起了个寂寞，
                // 调用方还以为保活在跑）。
                guard newPlayer.play(), newPlayer.isPlaying else {
                    return false
                }
                player = newPlayer
                running = true
                // 复核监听：中断结束 + 前后台切换 + 音频路由变化时，
                // 停了就重起。v63 只有中断监听，且 engine 停摆（路由
                // 变化、媒体服务重置、其他音频会话干扰）除中断外无人
                // 重起；这里前后台切换与路由变化也复核——安装期 App
                // 在后台（用户在系统安装屏），只靠回前台复核不够，
                // 路由变化必须当场复核。observer 在 stop()/deinit 时
                // 移除。resumeIfNeeded 是幂等的：已在播就是空操作，
                // 多触发一次无害。
                let center = NotificationCenter.default
                observers.append(center.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: session, queue: .main) { [weak self] note in
                    self?.handleInterruption(note)
                })
                observers.append(center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil, queue: .main) { [weak self] _ in
                    self?.resumeIfNeeded()
                })
                observers.append(center.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil, queue: .main) { [weak self] _ in
                    self?.resumeIfNeeded()
                })
                observers.append(center.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: session, queue: .main) { [weak self] _ in
                    self?.resumeIfNeeded()
                })
                // 先占全局计数：此后全局 holder 停掉也不会释放 session。
                MainActor.assumeIsolated { KeepAlive.retainAudioSession() }
                return true
            } catch {
                player = nil
                running = false
                return false
            }
        }

        func stop() {
            guard running else { return }
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            player?.stop()
            player = nil
            running = false
            // 计数 -1：归零时全局释放 session；不归零时不动 session，
            // 全局 keepAlive 若在跑不受影响。
            MainActor.assumeIsolated { KeepAlive.releaseAudioSession() }
            // 故意不动 session 的类别/激活（除非上面计数归零已释放）：
            // 全局 keepAlive 若在跑，setActive(false) 或改类别会把它
            // 一起踩掉；若没在跑，App 挂起时系统自会收回。
        }

        /// 播放态复核：在播就不动；停了就重激活 session 再播。
        /// 尽力恢复：重起失败不抛、不写 lastError（start() 的失败
        /// 才写），下次复核或下次 install() 再起。
        private func resumeIfNeeded() {
            guard running, let current = player else { return }
            if !current.isPlaying {
                try? AVAudioSession.sharedInstance().setActive(true)
                _ = current.play()
            }
        }

        /// 中断结束才复核：中断类型不是 .ended 不管；running
        /// 已是 false（停服中）也不管。
        private func handleInterruption(_ note: Notification) {
            guard running else { return }
            guard let info = note.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
                  type == .ended else { return }
            resumeIfNeeded()
        }
    }

}
