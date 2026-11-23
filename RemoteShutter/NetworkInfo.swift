import Darwin
import Foundation

enum NetworkInfo {
    /// Wi-Fi(en0)の IPv4 アドレス。なければ、モバイル通信以外で見つかった IPv4 を返す。
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var found: [String: String] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            if name == "lo0" || name.hasPrefix("pdp_ip") || name.hasPrefix("utun") { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if rc == 0 {
                found[name] = String(cString: host)
            }
        }
        if let wifi = found["en0"] { return wifi }
        return found.sorted { $0.key < $1.key }.first?.value
    }
}
