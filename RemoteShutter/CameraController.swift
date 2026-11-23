import AVFoundation

struct CapturedPhoto {
    let data: Data
    let width: Int
    let height: Int
}

/// 写真とライブ映像の向き。iPhone をどう構えているか(三脚に横向きで付けるなど)に合わせる
enum CaptureOrientation: String, CaseIterable {
    case portrait
    case landscapeRight
    case landscapeLeft
    case portraitUpsideDown

    var av: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .landscapeRight: return .landscapeRight
        case .landscapeLeft: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        }
    }

    var label: String {
        switch self {
        case .portrait: return "縦向き"
        case .landscapeRight: return "横向き(画面の下端が右)"
        case .landscapeLeft: return "横向き(画面の下端が左)"
        case .portraitUpsideDown: return "逆さま"
        }
    }
}

enum CameraError: LocalizedError {
    case notAuthorized
    case notRunning
    case noDevice
    case configurationFailed(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "カメラの使用が許可されていません(設定アプリで許可してください)"
        case .notRunning: return "カメラが動いていません"
        case .noDevice: return "背面カメラが見つかりません"
        case .configurationFailed(let why): return "カメラの設定に失敗しました: \(why)"
        case .noData: return "写真データを取り出せませんでした"
        }
    }
}

/// AVCaptureSession を管理し、フル解像度の JPEG を撮る。
/// セッション操作はすべて sessionQueue 上で行う。
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var configured = false

    private let lock = NSLock()
    private var _maxDimensions = CMVideoDimensions(width: 0, height: 0)
    private var _orientation: CaptureOrientation = .portrait

    /// どのスレッドから呼ばれてもよいログ出力
    var log: (String) -> Void = { _ in }
    /// セッションが動き始めた/止まったときに呼ばれる(任意のスレッド)
    var onRunningChange: ((Bool) -> Void)?
    /// ライブ映像の1フレームごとに videoQueue 上で呼ばれる。起動前に1回だけ設定する
    var onVideoFrame: ((CMSampleBuffer) -> Void)?

    var maxDimensions: CMVideoDimensions {
        lock.lock(); defer { lock.unlock() }
        return _maxDimensions
    }

    var orientation: CaptureOrientation {
        lock.lock(); defer { lock.unlock() }
        return _orientation
    }

    func setOrientation(_ value: CaptureOrientation) {
        lock.lock(); _orientation = value; lock.unlock()
        sessionQueue.async { self.applyOrientation() }
    }

    /// 写真とライブ映像の両方の接続に向きを反映する(sessionQueue 上で呼ぶ)
    private func applyOrientation() {
        let value = orientation.av
        for output in [photoOutput, videoOutput] as [AVCaptureOutput] {
            if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = value
            }
        }
    }

    var isRunning: Bool { session.isRunning }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didStartRunning(_:)), name: .AVCaptureSessionDidStartRunning, object: session)
        nc.addObserver(self, selector: #selector(didStopRunning(_:)), name: .AVCaptureSessionDidStopRunning, object: session)
        nc.addObserver(self, selector: #selector(runtimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        nc.addObserver(self, selector: #selector(wasInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(interruptionEnded(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    // MARK: - 起動

    func requestAccessAndStart(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.startSession() }
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func startSession() {
        sessionQueue.async {
            if !self.configured {
                do {
                    try self.configure()
                } catch {
                    self.log("カメラ設定エラー: \(error.localizedDescription)")
                    return
                }
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noDevice
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CameraError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed("入力を追加できません")
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed("写真出力を追加できません")
        }
        session.addOutput(photoOutput)

        // ライブ映像用。遅れたフレームは捨てて、常に最新だけを配信する
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            log("ライブ映像の出力を追加できません(撮影だけは使えます)")
        }
        session.commitConfiguration()
        applyOrientation()

        // commit 後に activeFormat が確定するので、ここで最大解像度を選ぶ
        let candidates = device.activeFormat.supportedMaxPhotoDimensions
        if let best = candidates.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = best
            lock.lock(); _maxDimensions = best; lock.unlock()
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        let list = candidates.map { "\($0.width)x\($0.height)" }.joined(separator: ", ")
        log("カメラ準備完了: \(device.localizedName) / 対応する最大解像度 [\(list)]")
        configured = true
    }

    // MARK: - 撮影

    func capture(_ completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        sessionQueue.async {
            guard self.configured, self.session.isRunning else {
                let auth = AVCaptureDevice.authorizationStatus(for: .video)
                completion(.failure(auth == .authorized ? CameraError.notRunning : CameraError.notAuthorized))
                return
            }

            self.applyOrientation()
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            if self.photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor { [weak self] result in
                self?.sessionQueue.async { self?.inFlight[id] = nil }
                completion(result)
            }
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    // MARK: - 通知

    @objc private func didStartRunning(_ n: Notification) {
        onRunningChange?(true)
    }

    @objc private func didStopRunning(_ n: Notification) {
        onRunningChange?(false)
    }

    @objc private func runtimeError(_ n: Notification) {
        let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
        log("カメラの実行時エラー: \(err?.localizedDescription ?? "不明")。再開を試みます")
        sessionQueue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    @objc private func wasInterrupted(_ n: Notification) {
        let raw = n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        log("カメラが中断されました(理由コード \(raw))")
    }

    @objc private func interruptionEnded(_ n: Notification) {
        log("カメラの中断が終わりました")
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onVideoFrame?(sampleBuffer)
    }
}

/// 1回の撮影ごとに作るデリゲート
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var result: Result<CapturedPhoto, Error>?

    init(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            result = .failure(error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            result = .failure(CameraError.noData)
            return
        }
        let dims = photo.resolvedSettings.photoDimensions
        result = .success(CapturedPhoto(data: data, width: Int(dims.width), height: Int(dims.height)))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let final: Result<CapturedPhoto, Error>
        if let result = result {
            final = result
        } else if let error = error {
            final = .failure(error)
        } else {
            final = .failure(CameraError.noData)
        }
        completion(final)
    }
}
