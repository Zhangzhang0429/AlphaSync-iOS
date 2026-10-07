import Foundation
import Darwin

/// 相机发现（UDP Probe）—— 镜像安卓端 `Discovery.kt`。
///
/// 扫描策略（三段，都在毫秒级）：
/// 1. 已知地址快扫：配对表里记过的相机 IP + 本机 IP
/// 2. 广播补扫：子网广播 + 受限广播（255.255.255.255）+ 热点常见网段
/// 3. 整段 /24 单播兜底（广播被 AP 过滤时）
enum Discovery {

    static let candidatePorts = [15740]

    private static let sweepTimeoutMs = 420
    private static let fastTimeoutMs = 260
    private static let quietMs = 150
    private static let recvSliceMs = 50

    struct DiscoveredCamera: Hashable {
        let host: String
        let protoPort: Int
        let filePort: Int
        let cameraGuid16: [UInt8]
        let name: String
        let pairingMode: Bool

        var guidHex: String { PtpCodec.hex(cameraGuid16) }
    }

    /// 扫描子网内所有处于 AlphaSync 相机状态的设备。
    static func scan(preferredHosts: [String], thorough: Bool = false, sweep: Bool = true,
                     timeoutMs: Int = 6000) -> [DiscoveredCamera] {
        let myGuid = IdentityStore.shared.guid16
        let myName = IdentityStore.shared.friendlyName + " " + PtpCodec.vendorTag
        var foundByGuid: [String: DiscoveredCamera] = [:]
        let request = PtpCodec.probe(request: true, guid: myGuid, friendlyName: myName,
                                     protoPort: 0, filePort: 0, pairingMode: false, paired: false)

        let localIp = localIPv4()

        // ① 已知地址快扫
        var known = Set<String>()
        for h in preferredHosts where !h.isEmpty { known.insert(h) }
        if let ip = localIp { known.insert(ip) }
        if !known.isEmpty {
            let sock = makeSocket()
            sendTo(sock, Array(known), request)
            collect(sock, &foundByGuid, fastTimeoutMs, stopOnFirst: !thorough)
            closeSocket(sock)
        }

        // ② 广播补扫（thorough 时无论快扫是否命中都广播）
        if sweep && (thorough || foundByGuid.isEmpty) {
            let targets = broadcastTargets(localIp: localIp)
            if !targets.isEmpty {
                let sock = makeSocket()
                sendTo(sock, targets, request)
                collect(sock, &foundByGuid, sweepTimeoutMs, stopOnFirst: false)
                closeSocket(sock)
            }
        }

        // ③ 整段 /24 单播兜底
        if sweep && foundByGuid.isEmpty, let ip = localIp {
            let rest = subnetOf(ip).filter { !known.contains($0) }
            if !rest.isEmpty {
                let sock = makeSocket()
                sendTo(sock, rest, request)
                collect(sock, &foundByGuid, sweepTimeoutMs, stopOnFirst: false)
                closeSocket(sock)
            }
        }

        return foundByGuid.values.sorted { $0.pairingMode && !$1.pairingMode }
    }

    // MARK: 内部

    private static func makeSocket() -> Int32 {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        if s >= 0 {
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: recvSliceMs / 1000, tv_usec: (recvSliceMs % 1000) * 1000)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        return s
    }

    private static func closeSocket(_ s: Int32) {
        if s >= 0 { Darwin.close(s) }
    }

    private static func sendTo(_ sock: Int32, _ hosts: [String], _ request: [UInt8]) {
        for h in hosts {
            for port in candidatePorts {
                guard let ip = resolveIPv4(h) else { continue }
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr = ip
                _ = request.withUnsafeBytes { ptr in
                    withUnsafePointer(to: &addr) { ap in
                        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(sock, ptr.baseAddress, request.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private static func collect(_ sock: Int32, _ found: inout [String: DiscoveredCamera],
                                _ windowMs: Int, stopOnFirst: Bool) {
        let deadline = Date().addingTimeInterval(TimeInterval(windowMs) / 1000.0)
        var lastHit = Date(timeIntervalSince1970: 0)
        var buf = [UInt8](repeating: 0, count: 1500)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { ptr in
                withUnsafePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sock, ptr.baseAddress, 1500, 0, sa, &fromLen)
                    }
                }
            }
            if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK {
                    // 超时切片：静默判定
                    if lastHit.timeIntervalSince1970 > 0 &&
                        Date().timeIntervalSince(lastHit) >= TimeInterval(quietMs) / 1000.0 {
                        return
                    }
                    continue
                }
                if e == EINTR { continue }
                return
            }
            if n <= 0 { continue }
            let host = hostString(from.sin_addr)
            let raw = Array(buf[0..<n])
            guard let cam = parse(raw, fromHost: host) else { continue }
            found[cam.guidHex] = cam
            lastHit = Date()
            if stopOnFirst { return }
        }
    }

    private static func parse(_ raw: [UInt8], fromHost: String) -> DiscoveredCamera? {
        guard let m = try? PtpCodec.read(StreamBytes(raw)) else { return nil }
        guard m.type == PtpCodec.tProbeResp else { return nil }
        guard let pr = try? PtpCodec.parseProbe(m.body) else { return nil }
        // 必须带厂商标记才算我们的相机（防误报）
        guard PtpCodec.hasVendorTag(pr.name) else { return nil }
        return DiscoveredCamera(
            host: fromHost,
            protoPort: pr.protoPort > 0 ? pr.protoPort : candidatePorts[0],
            filePort: pr.filePort,
            cameraGuid16: pr.guid,
            name: pr.name.hasSuffix(" " + PtpCodec.vendorTag)
                ? String(pr.name.dropLast(PtpCodec.vendorTag.count + 1)).trimmingCharacters(in: .whitespaces)
                : pr.name,
            pairingMode: pr.pairingMode
        )
    }

    // MARK: 网络小件

    /// 本机 Wi-Fi IPv4（getifaddrs，跳过 loopback/link-local）。
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while ptr != nil {
            let ifa = ptr!.pointee
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp") || name.hasPrefix("ap") {
                    let sa = ifa.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let s = hostString(sa.sin_addr)
                    if !s.isEmpty && !s.hasPrefix("169.254") && !s.hasPrefix("0.") {
                        return s
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    private static func hostString(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private static func resolveIPv4(_ host: String) -> in_addr? {
        if let a = inet_addr(host), a != INADDR_NONE {
            return in_addr(s_addr: a)
        }
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    private static func subnetOf(_ ip: String) -> [String] {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let b = Int(parts[2]), (0...254).contains(b) else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(b)."
        return (1...254).map { prefix + String($0) }
    }

    private static func broadcastTargets(localIp: String?) -> [String] {
        var targets = Set<String>()
        if let ip = localIp {
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                targets.insert("\(parts[0]).\(parts[1]).\(parts[2]).255")
            }
        }
        targets.insert("255.255.255.255")
        // 手机自己做热点时的常见热点网段
        for b in ["192.168.43.255", "192.168.42.255", "192.168.44.255",
                  "192.168.0.255", "192.168.1.255", "192.168.2.255", "10.0.0.255"] {
            targets.insert(b)
        }
        return Array(targets)
    }
}

/// 内存字节流，用于解析探测包等已收齐的字节。
private struct StreamBytes: InputStreamLike {
    let data: [UInt8]
    var offset = 0
    init(_ data: [UInt8]) { self.data = data }

    mutating func readFully(_ count: Int) throws -> [UInt8]? {
        if offset + count > data.count {
            throw PtpError.badFrame("流截断")
        }
        let out = Array(data[offset..<offset + count])
        offset += count
        return out
    }
}
