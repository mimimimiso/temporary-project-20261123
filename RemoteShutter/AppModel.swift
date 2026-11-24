import Combine
import CoreGraphics
import Foundation
import UIKit

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
}

/// アプリ全体の状態。画面用の @Published 値はメインスレッドでだけ更新する。
/// HTTP サーバーのスレッドから読む値(トークン、ログ、撮影回数、保存設定)は lock で守る。
final class AppModel: ObservableObject {
    static let port: UInt16 = 8080
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static let hasFrontCamera = CameraController.hasFrontCamera

    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var serverState = "停止中"
    @Published private(set) var cameraState = "未確認"
    @Published private(set) var ipAddress: String?
    @Published private(set) var token: String
    @Published private(set) var captureCount = 0
    @Published private(set) var maxPhotoSize = "-"
    @Published private(set) var streamClients = 0
    @Published private(set) var orientation: CaptureOrientation
    @Published private(set) var cameraPosition: CameraPosition
    @Published private(set) var flash: FlashSetting
    @Published private(set) var flashSupported = false
    @Published private(set) var saveToPhotos: Bool
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var zoomOptions: [CGFloat] = [1]

    let camera = CameraController()
    private let stream = LiveStream()
    private let server = HTTPServer(port: AppModel.port)

    private let lock = NSLock()
    private var sharedToken: String
    private var sharedLog: [String] = []
    private var sharedCaptureCount = 0
    private var sharedSaveToPhotos: Bool

    private enum Key {
        static let token = "token"
        static let orientation = "orientation"
        static let position = "cameraPosition"
        static let flash = "flash"
        static let saveToPhotos = "saveToPhotos"
        static let zoom = "zoom"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f
    }()

    init() {
        let defaults = UserDefaults.standard
        let savedToken = defaults.string(forKey: Key.token)
        let initialToken = savedToken ?? Self.makeToken()
        if savedToken == nil { defaults.set(initialToken, forKey: Key.token) }
        _token = Published(initialValue: initialToken)
        sharedToken = initialToken

        let savedOrientation = defaults.string(forKey: Key.orientation).flatMap(CaptureOrientation.init(rawValue:)) ?? .portrait
        var savedPosition = defaults.string(forKey: Key.position).flatMap(CameraPosition.init(rawValue:)) ?? .back
        if savedPosition == .front && !Self.hasFrontCamera { savedPosition = .back }
        let savedFlash = defaults.string(forKey: Key.flash).flatMap(FlashSetting.init(rawValue:)) ?? .off
        let savedSave = defaults.bool(forKey: Key.saveToPhotos)
        _orientation = Published(initialValue: savedOrientation)
        _cameraPosition = Published(initialValue: savedPosition)
        _flash = Published(initialValue: savedFlash)
        _saveToPhotos = Published(initialValue: savedSave)
        sharedSaveToPhotos = savedSave
        let savedZoom = defaults.object(forKey: Key.zoom) as? Double ?? 1

        camera.setOrientation(savedOrientation)
        camera.setPosition(savedPosition)
        camera.setFlash(savedFlash)
        zoom = camera.setZoom(CGFloat(savedZoom))
        zoomOptions = camera.zoomOptions

        stream.log = { [weak self] in self?.log($0) }
        stream.onClientCountChange = { [weak self] count in
            DispatchQueue.main.async { self?.streamClients = count }
        }
        let stream = self.stream
        camera.onVideoFrame = { sampleBuffer in
            stream.handle(sampleBuffer)
        }

        server.log = { [weak self] in self?.log($0) }
        server.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.serverState = state }
        }
        server.handler = { [weak self] request, connection in
            guard let self = self else {
                connection.respond(.text("unavailable", status: 503))
                return
            }
            self.route(request, connection)
        }

        camera.log = { [weak self] in self?.log($0) }
        camera.onRunningChange = { [weak self] running in
            guard let self = self else { return }
            let dims = self.camera.maxDimensions
            let flashOK = self.camera.flashSupported
            // カメラが変わると倍率の上限も変わる
            let zoom = self.camera.zoom
            let zoomOptions = self.camera.zoomOptions
            DispatchQueue.main.async {
                self.cameraState = running ? "動作中" : "停止"
                if dims.width > 0 { self.maxPhotoSize = "\(dims.width) × \(dims.height)" }
                self.flashSupported = flashOK
                self.zoom = zoom
                self.zoomOptions = zoomOptions
            }
        }

        log("RemoteShutter v\(Self.appVersion) (build \(Self.buildNumber)) / iOS \(UIDevice.current.systemVersion)")
    }

    var urlString: String {
        "http://\(ipAddress ?? "<IP不明>"):\(Self.port)/?token=\(token)"
    }

    // MARK: - 起動

    /// 画面が前面に来るたびに呼ぶ。何度呼んでもよい。
    func start() {
        refreshIP()
        server.start()
        camera.requestAccessAndStart { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                self.log("カメラが許可されていません。設定 > RemoteShutter でカメラをオンにしてください")
                DispatchQueue.main.async { self.cameraState = "許可なし" }
            }
        }
    }

    func refreshIP() {
        let ip = NetworkInfo.localIPv4()
        if ip != ipAddress {
            ipAddress = ip
            log(ip.map { "IPアドレス: \($0)" } ?? "IPアドレスが見つかりません(Wi-Fiにつないでください)")
        }
    }

    // MARK: - 設定(どのスレッドから呼んでもよい)

    func regenerateToken() {
        let newToken = Self.makeToken()
        UserDefaults.standard.set(newToken, forKey: Key.token)
        lock.lock(); sharedToken = newToken; lock.unlock()
        DispatchQueue.main.async { self.token = newToken }
        log("トークンを作り直しました")
    }

    func setOrientation(_ value: CaptureOrientation) {
        camera.setOrientation(value)
        UserDefaults.standard.set(value.rawValue, forKey: Key.orientation)
        DispatchQueue.main.async { self.orientation = value }
        log("向きを変更: \(value.label)")
    }

    func setCameraPosition(_ value: CameraPosition) {
        guard value == .back || Self.hasFrontCamera else {
            log("前面カメラが見つかりません")
            return
        }
        camera.setPosition(value)
        UserDefaults.standard.set(value.rawValue, forKey: Key.position)
        DispatchQueue.main.async { self.cameraPosition = value }
    }

    func setFlash(_ value: FlashSetting) {
        camera.setFlash(value)
        UserDefaults.standard.set(value.rawValue, forKey: Key.flash)
        DispatchQueue.main.async { self.flash = value }
        log("フラッシュ: \(value.label)")
    }

    func setZoom(_ value: CGFloat) {
        let applied = camera.setZoom(value)
        UserDefaults.standard.set(Double(applied), forKey: Key.zoom)
        DispatchQueue.main.async { self.zoom = applied }
        log("倍率: \(CameraController.zoomLabel(applied))")
    }

    func setSaveToPhotos(_ value: Bool) {
        lock.lock(); sharedSaveToPhotos = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: Key.saveToPhotos)
        DispatchQueue.main.async { self.saveToPhotos = value }
        log("iPhoneの写真アプリにも保存: \(value ? "オン" : "オフ")")
        if value {
            // 先に許可ダイアログを出しておく(撮影の瞬間に出ると困るので)
            PhotoLibrary.requestAccess { [weak self] granted in
                if !granted {
                    self?.log("写真アプリへの保存が許可されていません(設定 > RemoteShutter > 写真)")
                }
            }
        }
    }

    // MARK: - ログ

    /// どのスレッドから呼んでもよい
    func log(_ message: String) {
        let line = "\(Self.timeFormatter.string(from: Date())) \(message)"
        lock.lock()
        sharedLog.append(line)
        if sharedLog.count > 300 { sharedLog.removeFirst(sharedLog.count - 300) }
        lock.unlock()
        DispatchQueue.main.async {
            self.logs.append(LogLine(text: line))
            if self.logs.count > 100 { self.logs.removeFirst(self.logs.count - 100) }
        }
    }

    private func logText() -> String {
        lock.lock(); defer { lock.unlock() }
        return sharedLog.joined(separator: "\n")
    }

    // MARK: - HTTP

    private func route(_ request: HTTPRequest, _ connection: HTTPConnection) {
        if request.path == "/favicon.ico" {
            connection.respond(HTTPResponse(status: 404))
            return
        }
        guard isAuthorized(request) else {
            log("認証失敗: \(request.method) \(request.path)(\(request.remote))")
            connection.respond(.text("401 Unauthorized: URLの末尾に ?token=... を付けてください(iPhoneの画面に表示されています)", status: 401))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            connection.respond(.html(WebPage.html))
        case ("GET", "/status"):
            connection.respond(.json(statusJSON()))
        case ("GET", "/log"):
            connection.respond(.text(logText()))
        case ("GET", "/stream"):
            stream.add(connection)
        case ("POST", "/settings"):
            if let error = applySettings(request.query) {
                connection.respond(.text(error, status: 400))
            } else {
                connection.respond(.json(statusJSON()))
            }
        case ("POST", "/focus"):
            if request.query["reset"] != nil {
                camera.resetFocus()
            } else if let x = request.query["x"].flatMap({ Double($0) }), let y = request.query["y"].flatMap({ Double($0) }) {
                camera.focus(atDisplayPoint: CGPoint(x: x, y: y))
            } else {
                connection.respond(.text("x と y(0〜1)を指定してください。自動に戻すときは reset=1", status: 400))
                return
            }
            connection.respond(HTTPResponse(status: 204))
        case ("POST", "/capture"):
            capture(from: request, connection)
        case (_, "/capture"):
            connection.respond(.text("POST で呼んでください", status: 405))
        default:
            connection.respond(.text("Not Found", status: 404))
        }
    }

    /// /settings のクエリを反映する。おかしな値があればエラーメッセージを返す(何も変えない)
    private struct SettingsError: Error {
        let message: String
    }

    private func applySettings(_ query: [String: String]) -> String? {
        func parse<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
            guard let raw = query[key] else { return nil }
            guard let value = T(rawValue: raw) else {
                let allowed = T.allCases.map { $0.rawValue }.joined(separator: ", ")
                throw SettingsError(message: "\(key) は \(allowed) のどれかを指定してください")
            }
            return value
        }

        let orientation: CaptureOrientation?
        let position: CameraPosition?
        let flash: FlashSetting?
        var save: Bool?
        var zoom: CGFloat?
        do {
            if let raw = query["zoom"] {
                guard let z = Double(raw), z.isFinite, z >= 1 else {
                    throw SettingsError(message: "zoom は 1 以上の数(例: 1.5)を指定してください")
                }
                zoom = CGFloat(z)
            }
            orientation = try parse("orientation", CaptureOrientation.self)
            position = try parse("camera", CameraPosition.self)
            flash = try parse("flash", FlashSetting.self)
            if let raw = query["saveToPhotos"] {
                switch raw.lowercased() {
                case "1", "true", "on": save = true
                case "0", "false", "off": save = false
                default: throw SettingsError(message: "saveToPhotos は 1 か 0 を指定してください")
                }
            }
        } catch let error as SettingsError {
            return error.message
        } catch {
            return error.localizedDescription
        }

        if let v = orientation { setOrientation(v) }
        if let v = position { setCameraPosition(v) }
        if let v = flash { setFlash(v) }
        if let v = save { setSaveToPhotos(v) }
        if let v = zoom { setZoom(v) }
        return nil
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        lock.lock()
        let current = sharedToken
        lock.unlock()
        if request.query["token"] == current { return true }
        if request.headers["x-token"] == current { return true }
        if request.headers["authorization"] == "Bearer \(current)" { return true }
        return false
    }

    private func statusJSON() -> [String: Any] {
        let dims = camera.maxDimensions
        lock.lock()
        let count = sharedCaptureCount
        let save = sharedSaveToPhotos
        lock.unlock()
        return [
            "ok": true,
            "app": "RemoteShutter",
            "version": Self.appVersion,
            "build": Self.buildNumber,
            "ios": UIDevice.current.systemVersion,
            "camera": [
                "running": camera.isRunning,
                "maxPhotoWidth": Int(dims.width),
                "maxPhotoHeight": Int(dims.height),
            ] as [String: Any],
            "captures": count,
            "streamClients": stream.clientCount,
            "orientation": camera.orientation.rawValue,
            "orientations": CaptureOrientation.allCases.map { ["value": $0.rawValue, "label": $0.label] },
            "position": camera.position.rawValue,
            "positions": CameraPosition.allCases
                .filter { $0 == .back || Self.hasFrontCamera }
                .map { ["value": $0.rawValue, "label": $0.label] },
            "flash": camera.flash.rawValue,
            "flashModes": FlashSetting.allCases.map { ["value": $0.rawValue, "label": $0.label] },
            "flashSupported": camera.flashSupported,
            "saveToPhotos": save,
            "zoom": CameraController.zoomString(camera.zoom),
            "zoomOptions": camera.zoomOptions.map {
                ["value": CameraController.zoomString($0), "label": CameraController.zoomLabel($0)]
            },
        ]
    }

    private func capture(from request: HTTPRequest, _ connection: HTTPConnection) {
        let started = Date()
        log("撮影リクエスト(\(request.remote))")
        camera.capture { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let photo):
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let name = "IMG_\(Self.fileFormatter.string(from: Date())).jpg"
                self.lock.lock()
                self.sharedCaptureCount += 1
                let count = self.sharedCaptureCount
                let save = self.sharedSaveToPhotos
                self.lock.unlock()
                DispatchQueue.main.async { self.captureCount = count }
                self.log("撮影成功: \(photo.width)x\(photo.height) / \(Self.megabytes(photo.data.count)) / \(ms)ms")
                connection.respond(HTTPResponse(status: 200, headers: [
                    "Content-Type": "image/jpeg",
                    "Content-Disposition": "inline; filename=\"\(name)\"",
                    "X-Filename": name,
                    "X-Photo-Width": String(photo.width),
                    "X-Photo-Height": String(photo.height),
                ], body: photo.data))
                if save {
                    PhotoLibrary.save(photo.data) { [weak self] in self?.log($0) }
                }
            case .failure(let error):
                self.log("撮影失敗: \(error.localizedDescription)")
                connection.respond(.text("撮影失敗: \(error.localizedDescription)", status: 500))
            }
        }
    }

    // MARK: - 補助

    private static func makeToken() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_000_000)
    }
}
