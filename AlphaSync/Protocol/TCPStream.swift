import Foundation
import Darwin

/// 一条 TCP 连接（POSIX socket 封装）：组帧/解帧/收发，镜像安卓端 `PtpIpClient.Link`。
/// 读在独立 DispatchQueue 上进行，`readFully` 可安全跨线程调用（socket 读由内核保证原子性，
/// 本工程用法：一个读线程 + 多个写线程，写端用锁串行化）。
final class TCPStream: InputStreamLike {

    private var fd: Int32 = -1
    private let sendLock = NSLock()
    private var alive = false
    private var onDisconnected: (() -> Void)?
    private var readerQueue: DispatchQueue?

    init(fd: Int32) {
        self.fd = fd
        self.alive = true
    }

    deinit {
        closeQuietly()
    }

    var isAlive: Bool { alive && fd >= 0 }

    // MARK: 建连

    /// 带超时的 TCP 连接（IPv4）。
    static func connect(host: String, port: Int, timeoutMs: Int, receiveBuffer: Int = 1024 * 1024) throws -> TCPStream {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { throw PtpError.io("socket: \(String(cString: strerror(errno)))") }

        var noDelay: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
        var rcv: Int32 = Int32(receiveBuffer)
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))

        guard let ip = resolveIPv4(host) else {
            closeRaw(s)
            throw PtpError.io("无法解析主机: \(host)")
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = ip

        // 非阻塞 connect + poll 超时
        let flags = fcntl(s, F_GETFL, 0)
        fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int32 in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc < 0 && errno == EINPROGRESS {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, Int32(timeoutMs))
            if pr <= 0 {
                closeRaw(s)
                throw PtpError.timeout("连接超时（\(host):\(port)）")
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                closeRaw(s)
                throw PtpError.io("连接失败（\(host):\(port)）：\(String(cString: strerror(err)))")
            }
        } else if rc < 0 {
            let e = errno
            closeRaw(s)
            throw PtpError.io("连接失败（\(host):\(port)）：\(String(cString: strerror(e)))")
        }
        fcntl(s, F_SETFL, flags)
        return TCPStream(fd: s)
    }

    private static func resolveIPv4(_ host: String) -> in_addr? {
        let a = inet_addr(host)
        if a != INADDR_NONE {
            return in_addr(s_addr: a)
        }
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        let addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return addr
    }

    // MARK: 读 / 写

    func setReceiveTimeout(_ ms: Int) {
        guard fd >= 0 else { return }
        var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func readFully(_ count: Int) throws -> [UInt8]? {
        guard fd >= 0 else { throw PtpError.closed }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress!.advanced(by: got), count - got)
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK {
                    throw PtpError.timeout("读取超时")
                }
                throw PtpError.io("read: \(String(cString: strerror(e)))")
            }
            if n == 0 {
                if got == 0 { return nil }
                throw PtpError.badFrame("流截断：还差 \(count - got) 字节")
            }
            got += n
        }
        return buf
    }

    func write(_ data: [UInt8]) throws {
        guard fd >= 0 else { throw PtpError.closed }
        sendLock.lock()
        defer { sendLock.unlock() }
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { ptr -> Int in
                unistd.write(fd, ptr.baseAddress!.advanced(by: off), data.count - off)
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw PtpError.io("write: \(String(cString: strerror(e)))")
            }
            if n == 0 { throw PtpError.io("write: 连接已关闭") }
            off += n
        }
    }

    /// 启动读线程：逐包读取并回调；连接断开/出错时回调 onDisconnected。
    func startReader(onDisconnected: (() -> Void)? = nil, onMsg: @escaping (PtpCodec.Msg) -> Void) {
        guard alive else { return }
        self.onDisconnected = onDisconnected
        let q = DispatchQueue(label: "alphasync.ptpip.reader")
        readerQueue = q
        q.async { [weak self] in
            guard let self = self else { return }
            do {
                while self.alive && self.fd >= 0 {
                    guard let msg = try PtpCodec.read(self) else { break }
                    onMsg(msg)
                }
            } catch {
                // 连接关闭 / 超时：静默收敛
            }
            let wasAlive = self.alive
            self.alive = false
            if wasAlive && !self.isClosedByUser {
                self.onDisconnected?()
            }
        }
    }

    private var isClosedByUser = false

    func closeQuietly() {
        sendLock.lock()
        isClosedByUser = true
        alive = false
        let s = fd
        fd = -1
        sendLock.unlock()
        if s >= 0 { Self.closeRaw(s) }
    }

    private static func closeRaw(_ s: Int32) {
        _ = Darwin.close(s)
    }
}
