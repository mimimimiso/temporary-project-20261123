import Foundation
import Network

// 依存ライブラリなしの最小 HTTP/1.1 サーバー(Network.framework の NWListener)。
// 1接続につき1リクエストを受けて応答し、接続を閉じる(Connection: close)。

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// ヘッダー名は小文字
    let headers: [String: String]
    let body: Data
    let remote: String
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    static func html(_ html: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// 1本の TCP 接続。リクエストの受信と応答の送信を担う。
/// すべての処理はサーバーの queue 上で行う。
final class HTTPConnection {
    let id = UUID()
    let remote: String
    private let nw: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var responded = false

    var onRequest: ((HTTPRequest, HTTPConnection) -> Void)?
    var onClose: ((HTTPConnection) -> Void)?

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1_000_000

    init(_ nw: NWConnection, queue: DispatchQueue) {
        self.nw = nw
        self.queue = queue
        switch nw.endpoint {
        case .hostPort(let host, _):
            remote = "\(host)"
        default:
            remote = "\(nw.endpoint)"
        }
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    /// 応答を送って接続を閉じる。どのスレッドから呼んでもよい。2回目以降は無視する。
    func respond(_ response: HTTPResponse) {
        queue.async {
            guard !self.responded else { return }
            self.responded = true

            var headers = response.headers
            headers["Content-Length"] = String(response.body.count)
            headers["Connection"] = "close"
            if headers["Cache-Control"] == nil { headers["Cache-Control"] = "no-store" }

            var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasonPhrase(response.status))\r\n"
            for (name, value) in headers {
                head += "\(name): \(value)\r\n"
            }
            head += "\r\n"

            var data = Data(head.utf8)
            data.append(response.body)
            self.nw.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    func close() {
        nw.cancel()
    }

    private func finish() {
        let callback = onClose
        onClose = nil
        onRequest = nil
        callback?(self)
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
            }
            if error != nil {
                self.close()
                return
            }
            switch self.parse() {
            case .needMore:
                if isComplete { self.close() } else { self.receive() }
            case .request(let request):
                self.onRequest?(request, self)
            case .bad(let status, let message):
                self.respond(.text(message, status: status))
            }
        }
    }

    private enum ParseResult {
        case needMore
        case request(HTTPRequest)
        case bad(Int, String)
    }

    private func parse() -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeaderBytes ? .bad(431, "header too large") : .needMore
        }

        let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .bad(400, "bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maxBodyBytes else { return .bad(413, "body too large") }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])

        let target = String(parts[1])
        let components = URLComponents(string: target)
        var path = components?.path ?? target
        if path.isEmpty { path = "/" }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        return .request(HTTPRequest(
            method: String(parts[0]).uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: body,
            remote: remote
        ))
    }
}

final class HTTPServer {
    let port: UInt16
    private let queue = DispatchQueue(label: "http.server")
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private var restartScheduled = false

    /// リクエストごとに server queue 上で呼ばれる。必ず connection.respond を1回呼ぶこと。
    var handler: ((HTTPRequest, HTTPConnection) -> Void)?
    var onStateChange: ((String) -> Void)?
    var log: ((String) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    /// まだ動いていなければ起動する(何度呼んでもよい)
    func start() {
        queue.async { self.startIfNeeded() }
    }

    private func startIfNeeded() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            // Bonjour で広告する。ローカルネットワークの許可ダイアログを確実に出すためでもある
            listener.service = NWListener.Service(name: "RemoteShutter", type: "_remoteshutter._tcp")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self = self, let listener = listener else { return }
                self.handleState(state, of: listener)
            }
            listener.newConnectionHandler = { [weak self] nw in
                self?.accept(nw)
            }
            self.listener = listener
            onStateChange?("起動中")
            listener.start(queue: queue)
        } catch {
            log?("サーバーを起動できません: \(error)")
            onStateChange?("起動失敗")
            scheduleRestart()
        }
    }

    private func handleState(_ state: NWListener.State, of listener: NWListener) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            onStateChange?("待受中(ポート \(port))")
            log?("サーバー待受開始: ポート \(port)")
        case .waiting(let error):
            onStateChange?("待機中")
            log?("サーバー待機中: \(error)(ローカルネットワークの許可を確認してください)")
        case .failed(let error):
            log?("サーバーが停止しました: \(error)。作り直します")
            onStateChange?("エラー")
            listener.cancel()
            self.listener = nil
            scheduleRestart()
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        queue.asyncAfter(deadline: .now() + 2) {
            self.restartScheduled = false
            self.startIfNeeded()
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection = HTTPConnection(nw, queue: queue)
        connections[connection.id] = connection
        connection.onClose = { [weak self] closed in
            self?.connections[closed.id] = nil
        }
        connection.onRequest = { [weak self] request, conn in
            guard let handler = self?.handler else {
                conn.respond(.text("server not ready", status: 503))
                return
            }
            handler(request, conn)
        }
        connection.start()
    }
}
