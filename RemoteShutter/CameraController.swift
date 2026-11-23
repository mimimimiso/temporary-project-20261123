import AVFoundation
import CoreGraphics

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

enum CameraPosition: String, CaseIterable {
    case back
    case front

    var av: AVCaptureDevice.Position { self == .back ? .back : .front }
    var label: String { self == .back ? "背面カメラ" : "前面カメラ" }
}

enum FlashSetting: String, CaseIterable {
    case off
    case auto
    case on

    var av: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    var label: String {
        switch self {
        case .off: return "オフ"
        case .auto: return "自動"
        case .on: return "オン"
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
        case .noDevice: return "カメラが見つかりません"
        case .configurationFailed(let why): return "カメラの設定に失敗しました: \(why)"
        case .noData: return "写真データを取り出せませんでした"
        }
    }
}

/// AVCaptureSession を管理し、フル解像度の JPEG を撮る。ライブ映像のフレームも流す。
/// セッション操作はすべて sessionQueue 上で行う。
final class CameraController: NSObject {
    let session = AVCaptureSession()
    /// カメラを切り替えるときは作り直す(前のカメラの最大解像度が残らないように)
    private var photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var configured = false

    // 他のスレッドからも読む値
    private let lock = NSLock()
    private var _maxDimensions = CMVideoDimensions(width: 0, height: 0)
    private var _orientation: CaptureOrientation = .portrait
    private var _position: CameraPosition = .back
    private var _flash: FlashSetting = .off
    private var _flashSupported = false

    /// どのスレッドから呼ばれてもよいログ出力
    var log: (String) -> Void = { _ in }
    /// セッションが動き始めた/止まった、またはカメラが切り替わったときに呼ばれる(任意のスレッド)
    var onRunningChange: ((Bool) -> Void)?
    /// ライブ映像の1フレームごとに videoQueue 上で呼ばれる。起動前に1回だけ設定する
    var onVideoFrame: ((CMSampleBuffer) -> Void)?

    static var hasFrontCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    var maxDimensions: CMVideoDimensions { locked { _maxDimensions } }
    var orientation: CaptureOrientation { locked { _orientation } }
    var position: CameraPosition { locked { _position } }
    var flash: FlashSetting { locked { _flash } }
    var flashSupported: Bool { locked { _flashSupported } }
    var isRunning: Bool { session.isRunning }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didStartRunning(_:)), name: .AVCaptureSessionDidStartRunning, object: session)
        nc.addObserver(self, selector: #selector(didStopRunning(_:)), name: .AVCaptureSessionDidStopRunning, object: session)
        nc.addObserver(self, selector: #selector(runtimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        nc.addObserver(self, selector: #selector(wasInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(interruptionEnded(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
        nc.addObserver(self, selector: #selector(subjectAreaDidChange(_:)), name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }

    // MARK: - 設定

    func setOrientation(_ value: CaptureOrientation) {
        lock.lock(); _orientation = value; lock.unlock()
        sessionQueue.async { self.applyConnections() }
    }

    func setFlash(_ value: FlashSetting) {
        lock.lock(); _flash = value; lock.unlock()
    }

    /// カメラを切り替える。起動前なら次の起動時に使う
    func setPosition(_ value: CameraPosition) {
        sessionQueue.async {
            guard value != self.position else { return }
            guard self.configured else {
                self.lock.lock(); self._position = value; self.lock.unlock()
                return
            }
            // 左右反転の判定に使うので、切り替えの前に新しい値にしておく
            let previous = self.position
            self.lock.lock(); self._position = value; self.lock.unlock()
            do {
                try self.switchCamera(to: value)
                self.log("\(value.label)に切り替えました")
                self.onRunningChange?(self.session.isRunning)
            } catch {
                self.lock.lock(); self._position = previous; self.lock.unlock()
                self.applyConnections()
                self.log("カメラを切り替えられません: \(error.localizedDescription)")
            }
        }
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

    private static func device(for position: CameraPosition) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position.av)
    }

    private func configure() throws {
        guard let device = Self.device(for: position) else { throw CameraError.noDevice }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.configurationFailed(error.localizedDescription)
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed("入力を追加できません")
        }
        session.addInput(newInput)
        input = newInput

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

        afterDeviceChange(device)
        configured = true
    }

    private func switchCamera(to value: CameraPosition) throws {
        guard let device = Self.device(for: value) else { throw CameraError.noDevice }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.configurationFailed(error.localizedDescription)
        }

        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        session.removeOutput(photoOutput)

        guard session.canAddInput(newInput) else {
            if let old = input, session.canAddInput(old) { session.addInput(old) }
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            session.commitConfiguration()
            throw CameraError.configurationFailed("入力を追加できません")
        }
        session.addInput(newInput)
        input = newInput

        let newPhotoOutput = AVCapturePhotoOutput()
        if session.canAddOutput(newPhotoOutput) {
            session.addOutput(newPhotoOutput)
            photoOutput = newPhotoOutput
        } else if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()

        afterDeviceChange(device)
    }

    /// 入力のカメラが決まった(変わった)あとの共通処理。commit 後に呼ぶ
    private func afterDeviceChange(_ device: AVCaptureDevice) {
        // commit 後に activeFormat が確定するので、ここで最大解像度を選ぶ
        let candidates = device.activeFormat.supportedMaxPhotoDimensions
        var best = CMVideoDimensions(width: 0, height: 0)
        if let largest = candidates.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
            best = largest
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        lock.lock()
        _maxDimensions = best
        _flashSupported = photoOutput.supportedFlashModes.contains(.on)
        lock.unlock()

        applyConnections()
        resetFocus(device)

        let list = candidates.map { "\($0.width)x\($0.height)" }.joined(separator: ", ")
        log("カメラ準備完了: \(device.localizedName) / 対応する最大解像度 [\(list)]")
    }

    /// 写真とライブ映像の接続に向きと左右反転を反映する(sessionQueue 上で呼ぶ)
    private func applyConnections() {
        let value = orientation.av
        let mirror = position == .front
        for output in [photoOutput, videoOutput] as [AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = value
            }
            // 前面カメラのときは、ライブ映像だけ鏡のように左右反転する(写真はそのまま)
            if output === videoOutput, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirror
            }
        }
    }

    // MARK: - ピント

    /// ライブ映像上の位置(左上 0,0 〜 右下 1,1)にピントと明るさを合わせる
    func focus(atDisplayPoint point: CGPoint) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            var u = min(max(point.x, 0), 1)
            let v = min(max(point.y, 0), 1)
            if self.position == .front { u = 1 - u } // ライブ映像は左右反転している

            // 表示上の座標を、センサー基準(横向き・画面の下端が右)の座標に戻す
            let devicePoint: CGPoint
            switch self.orientation {
            case .landscapeRight: devicePoint = CGPoint(x: u, y: v)
            case .portrait: devicePoint = CGPoint(x: v, y: 1 - u)
            case .landscapeLeft: devicePoint = CGPoint(x: 1 - u, y: 1 - v)
            case .portraitUpsideDown: devicePoint = CGPoint(x: 1 - v, y: u)
            }

            do {
                try device.lockForConfiguration()
                var did: [String] = []
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                    did.append("ピント")
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                    did.append("明るさ")
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
                if did.isEmpty {
                    self.log("このカメラは位置を指定したピント合わせに対応していません")
                } else {
                    self.log("\(did.joined(separator: "と"))を合わせました(\(String(format: "%.2f, %.2f", point.x, point.y)))")
                }
            } catch {
                self.log("ピントを設定できません: \(error.localizedDescription)")
            }
        }
    }

    /// ピントと明るさを、画面中央の自動に戻す
    func resetFocus() {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            self.resetFocus(device)
            self.log("ピントを自動に戻しました")
        }
    }

    private func resetFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
        } catch {
            log("ピントを戻せません: \(error.localizedDescription)")
        }
    }

    // MARK: - 撮影

    func capture(_ completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        sessionQueue.async {
            guard self.configured, self.session.isRunning else {
                let auth = AVCaptureDevice.authorizationStatus(for: .video)
                completion(.failure(auth == .authorized ? CameraError.notRunning : CameraError.notAuthorized))
                return
            }

            self.applyConnections()
            let output = self.photoOutput
            let settings: AVCapturePhotoSettings
            if output.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            let flashMode = self.flash.av
            if output.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor { [weak self] result in
                self?.sessionQueue.async { self?.inFlight[id] = nil }
                completion(result)
            }
            self.inFlight[id] = processor
            output.capturePhoto(with: settings, delegate: processor)
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

    /// タップでピントを合わせたあと、構図が大きく変わったら自動に戻す
    @objc private func subjectAreaDidChange(_ n: Notification) {
        sessionQueue.async {
            guard let device = self.input?.device, (n.object as? AVCaptureDevice) === device else { return }
            self.resetFocus(device)
        }
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
