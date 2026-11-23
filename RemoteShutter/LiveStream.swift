import AVFoundation
import CoreImage
import ImageIO
import QuartzCore

/// カメラのフレームを低解像度の JPEG にして、つながっているブラウザへ MJPEG で配る。
/// 見ている人がいないときはエンコードしない。送信が終わっていない相手にはフレームを飛ばす(遅延をためない)。
final class LiveStream {
    static let boundary = "frame"

    var maxFPS: Double = 15
    var maxWidth: CGFloat = 960
    var quality: CGFloat = 0.5

    var log: (String) -> Void = { _ in }
    /// 視聴者数が変わったときに呼ばれる(任意のスレッド)
    var onClientCountChange: ((Int) -> Void)?

    private final class Client {
        let connection: HTTPConnection
        var busy = false
        init(_ connection: HTTPConnection) { self.connection = connection }
    }

    private let lock = NSLock()
    private var clients: [UUID: Client] = [:]
    private var lastEncode: CFTimeInterval = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clients.count
    }

    func add(_ connection: HTTPConnection) {
        connection.beginStream(headers: [
            "Content-Type": "multipart/x-mixed-replace; boundary=\(Self.boundary)",
        ])
        lock.lock()
        clients[connection.id] = Client(connection)
        let count = clients.count
        lock.unlock()
        log("ライブ映像: 接続(\(connection.remote))視聴 \(count)")
        onClientCountChange?(count)
    }

    /// camera の videoQueue から呼ばれる
    func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let hasIdleClient = clients.values.contains { !$0.busy }
        lock.unlock()
        guard hasIdleClient else { return }

        let now = CACurrentMediaTime()
        guard now - lastEncode >= 1.0 / maxFPS else { return }
        lastEncode = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = image.extent.width
        if width > maxWidth {
            let scale = maxWidth / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [qualityKey: quality]) else {
            return
        }
        broadcast(jpeg)
    }

    private func broadcast(_ jpeg: Data) {
        var part = Data("--\(Self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        part.append(jpeg)
        part.append(Data("\r\n".utf8))

        lock.lock()
        let targets = clients.values.filter { !$0.busy }
        targets.forEach { $0.busy = true }
        lock.unlock()

        for client in targets {
            client.connection.sendChunk(part) { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    self.lock.lock()
                    client.busy = false
                    self.lock.unlock()
                } else {
                    self.remove(client)
                }
            }
        }
    }

    private func remove(_ client: Client) {
        lock.lock()
        let existed = clients.removeValue(forKey: client.connection.id) != nil
        let count = clients.count
        lock.unlock()
        client.connection.close()
        if existed {
            log("ライブ映像: 切断 視聴 \(count)")
            onClientCountChange?(count)
        }
    }
}
