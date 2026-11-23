import Combine
import Foundation
import UIKit

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
}

/// アプリ全体の状態。画面用の @Published 値はメインスレッドでだけ更新する。
/// HTTP サーバーのスレッドから読む値(トークン、ログ、撮影回数)は lock で守る。
final class AppModel: ObservableObject {
    static let port: UInt16 = 8080
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var serverState = "停止中"
    @Published private(set) var cameraState = "未確認"
    @Published private(set) var ipAddress: String?
    @Published private(set) var token: String
    @Published private(set) var captureCount = 0
    @Published private(set) var maxPhotoSize = "-"
    @Published private(set) var streamClients = 0
    @Published private(set) var orientation: CaptureOrientation

    let camera = CameraController()
    private let stream = LiveStream()
    private let server = HTTPServer(port: AppModel.port)

    private let lock = NSLock()
    private var sharedToken: String
    private var sharedLog: [String] = []
    private var sharedCaptureCount = 0

    private static let tokenKey = "token"
    private static let orientationKey = "orientation"

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
        let saved = UserDefaults.standard.string(forKey: Self.tokenKey)
        let initial = saved ?? Self.makeToken()
        if saved == nil { UserDefaults.standard.set(initial, forKey: Self.tokenKey) }
        _token = Published(initialValue: initial)
        sharedToken = initial

        let savedOrientation = UserDefaults.standard.string(forKey: Self.orientationKey)
            .flatMap(CaptureOrientation.init(rawValue:)) ?? .portrait
        _orientation = Published(initialValue: savedOrientation)
        camera.setOrientation(savedOrientation)

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
            DispatchQueue.main.async {
                self.cameraState = running ? "動作中" : "停止"
                if dims.width > 0 { self.maxPhotoSize = "\(dims.width) × \(dims.height)" }
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

    func regenerateToken() {
        let newToken = Self.makeToken()
        UserDefaults.standard.set(newToken, forKey: Self.tokenKey)
        lock.lock(); sharedToken = newToken; lock.unlock()
        token = newToken
        log("トークンを作り直しました")
    }

    /// どのスレッドから呼んでもよい
    func setOrientation(_ value: CaptureOrientation) {
        camera.setOrientation(value)
        UserDefaults.standard.set(value.rawValue, forKey: Self.orientationKey)
        DispatchQueue.main.async { self.orientation = value }
        log("向きを変更: \(value.label)")
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
            if let raw = request.query["orientation"] {
                guard let value = CaptureOrientation(rawValue: raw) else {
                    let allowed = CaptureOrientation.allCases.map(\.rawValue).joined(separator: ", ")
                    connection.respond(.text("orientation は \(allowed) のどれかを指定してください", status: 400))
                    return
                }
                setOrientation(value)
            }
            connection.respond(.json(statusJSON()))
        case ("POST", "/capture"):
            capture(from: request, connection)
        case (_, "/capture"):
            connection.respond(.text("POST で呼んでください", status: 405))
        default:
            connection.respond(.text("Not Found", status: 404))
        }
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
            "orientation": camera.orientation.rawValue,
            "orientations": CaptureOrientation.allCases.map { ["value": $0.rawValue, "label": $0.label] },
            "streamClients": stream.clientCount,
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
