import AVFAudio
import CoreLocation
import Foundation

/// Keeps the app running in the background with silent audio (and optionally
/// background location), e.g. while the user approves the pairing PIN in
/// Settings or while a location is being simulated.
@MainActor
final class KeepAlive: NSObject {

    // var 而非 let：媒体服务重置后旧 engine 已死，必须换新的再起
    //（中断自恢复重建时也直接换新，免得残留已 attach 的节点报错）。
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var audioRunning = false
    /// 音频会话通知的观察者（中断/路由变更/媒体服务丢失/重置）：
    /// 只注册一次，KeepAlive 与 App 同寿，不用摘。
    private var audioObservers: [NSObjectProtocol] = []
    /// How many keep-alives play now. The pairing and a simulated location
    /// share the app's one audio session, so only the last to stop lets it go.
    private static var audioHolders = 0

    func startAudio() {
        guard !audioRunning else { return }
        registerAudioObservers()
        // 每次都换新 engine/player：上一轮若在半路失败（如 attach 后
        // start 抛错），残留节点会让下次重试直接报错。
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        do {
            try startEngine()
            audioRunning = true
            Self.audioHolders += 1
        } catch {
            audioRunning = false
            if Self.audioHolders == 0 { Self.releaseSession() }
        }
    }

    /// 建会话、挂节点、起无声循环。startAudio 与中断自恢复共用。
    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "KeepAlive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate silent buffer"])
        }
        buffer.frameLength = frames

        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    /// 音频中断自恢复（Seal 同款）：中断结束、耳机拔掉/接上、媒体
    /// 服务重置后重建播放器续播。不然锁屏后一次来电或语音就把
    /// 保活永久掐了，巡检再也没人跑。
    private func restartAudioEngine() {
        guard audioRunning else { return }
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        do {
            try startEngine()
            Engine.shared.log("Keep-alive audio restarted after interruption.")
        } catch {
            audioRunning = false
            if Self.audioHolders == 0 { Self.releaseSession() }
            Engine.shared.log("Keep-alive audio restart failed: \(error.localizedDescription)")
        }
    }

    private func registerAudioObservers() {
        guard audioObservers.isEmpty else { return }
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioInterruption(note) }
        })
        audioObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioRouteChange(note) }
        })
        audioObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesLost() }
        })
        audioObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // 开始中断时系统已替我们停了播放，等结束信号再重建；
        // 结束时不管有没有 shouldResume 都重建（无声音频 +
        // mixWithOthers，重建无害）。
        if type == .ended { restartAudioEngine() }
    }

    private func handleAudioRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            restartAudioEngine()
        default:
            break
        }
    }

    private func handleMediaServicesLost() {
        // 媒体服务丢了，engine 已死：先停，避免残留节点报错；
        // audioRunning 留着，等重置通知来再重建。
        guard audioRunning else { return }
        player.stop()
        engine.stop()
    }

    private func handleMediaServicesReset() {
        restartAudioEngine()
    }

    func stopAudio() {
        guard audioRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        audioRunning = false
        Self.audioHolders -= 1
        if Self.audioHolders == 0 { Self.releaseSession() }
    }

    /// 外部静音音频持有 session 的计数（v62 起停用：企业安装改走
    /// Engine，安装期的 InstallAudioKeeper 留着不用，不再有外部
    /// holder 调这里；计数 API 留着不删，免得以后外部音频 holder
    /// 又要重写）：只动计数、不启动全局 engine；调用方须成对
    /// 调用（start 成功时 retain、stop 时 release）。归零时才释放
    /// session，避免全局最后一个 holder 停掉时误杀正在跑的音频。
    static func retainAudioSession() {
        audioHolders += 1
    }

    static func releaseAudioSession() {
        audioHolders -= 1
        if audioHolders == 0 { releaseSession() }
    }

    /// Deactivates the session and puts it back in a category that Silent
    /// Mode mutes: `.playback` would let `SoundEffects` play through it.
    private static func releaseSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try? session.setCategory(.ambient)
    }

    private lazy var location: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        m.distanceFilter = kCLDistanceFilterNone
        m.pausesLocationUpdatesAutomatically = false
        return m
    }()
    private var locationRunning = false

    /// 定位不可用时为真（被拒/受限/系统定位总开关关了）：这时只有
    /// 音频保活在撑，锁屏续签可能被挂起。AutoRefreshService 记日志、
    /// 设置页明示（Seal 被拒降级同款，只是它还多一句提醒）。
    var locationUnavailable = false

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        location.requestAlwaysAuthorization()
        // 已经明确被拒/受限时不等回调，直接标降级；系统定位总开关
        // 关了也一样（下面 locationServicesEnabled 为假）。
        switch location.authorizationStatus {
        case .denied, .restricted:
            locationUnavailable = true
        default:
            break
        }
        if CLLocationManager.locationServicesEnabled() {
            location.allowsBackgroundLocationUpdates = true
            location.startUpdatingLocation()
        } else {
            locationUnavailable = true
        }
    }

    func stopLocation() {
        guard locationRunning else { return }
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        locationRunning = false
    }

    func stopAll() {
        stopAudio()
        stopLocation()
    }
}

extension KeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard locationRunning else { return }
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                locationUnavailable = false
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
            case .denied, .restricted:
                // 定位被拒：降级为仅音频保活，并明说锁屏续签可能
                // 被挂起（Seal 同款降级 + 明示）。
                locationUnavailable = true
                Engine.shared.log("Keep-alive: location denied — audio-only keep-alive; lock-screen renewal may be suspended.")
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}
