import AVFAudio
import CoreLocation
import Foundation

/// Keeps the app running in the background with silent audio (and optionally
/// background location), e.g. while the user approves the pairing PIN in
/// Settings or while a location is being simulated.
@MainActor
final class KeepAlive: NSObject {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioRunning = false
    /// How many keep-alives play now. The pairing and a simulated location
    /// share the app's one audio session, so only the last to stop lets it go.
    private static var audioHolders = 0

    func startAudio() {
        guard !audioRunning else { return }
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
            audioRunning = true
            Self.audioHolders += 1
        } catch {
            audioRunning = false
            if Self.audioHolders == 0 { Self.releaseSession() }
        }
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

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        location.requestAlwaysAuthorization()
        if CLLocationManager.locationServicesEnabled() {
            location.allowsBackgroundLocationUpdates = true
            location.startUpdatingLocation()
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
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            MainActor.assumeIsolated {
                guard locationRunning else { return }
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }
}
