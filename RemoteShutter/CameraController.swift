import AVFoundation

struct CapturedPhoto {
    let data: Data
    let width: Int
    let height: Int
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
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var configured = false

    private let lock = NSLock()
    private var _maxDimensions = CMVideoDimensions(width: 0, height: 0)

    /// どのスレッドから呼ばれてもよいログ出力
    var log: (String) -> Void = { _ in }
    /// セッションが動き始めた/止まったときに呼ばれる(任意のスレッド)
    var onRunningChange: ((Bool) -> Void)?

    var maxDimensions: CMVideoDimensions {
        lock.lock(); defer { lock.unlock() }
        return _maxDimensions
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
        session.commitConfiguration()

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
