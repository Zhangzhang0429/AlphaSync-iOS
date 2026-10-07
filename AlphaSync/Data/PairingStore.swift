import Foundation

/// 已配对相机表 —— 手机端存一份，相机端另存一份，两侧互为镜像。
/// 存储：整表序列化成一条 JSON 数组字符串放 UserDefaults（与安卓端同构）。
final class PairingStore {

    static let shared = PairingStore()

    private let defaults = UserDefaults.standard
    private let tableKey = "pairing.pairedCameras"

    private(set) var cameras: [PairedCamera] = []

    private init() {
        cameras = Self.decode(defaults.string(forKey: tableKey))
    }

    // MARK: 查询

    func all() -> [PairedCamera] { cameras }

    func find(_ peerDeviceId: String) -> PairedCamera? {
        cameras.first { $0.peerDeviceId.caseInsensitiveCompare(peerDeviceId) == .orderedSame }
    }

    func contains(_ peerDeviceId: String) -> Bool { find(peerDeviceId) != nil }

    func mostRecent() -> PairedCamera? { cameras.first }

    // MARK: 变更

    /// 新增或覆盖（按 peerDeviceId）。已存在则保留原 pairedAt。
    func upsert(_ camera: PairedCamera) {
        let key = camera.peerDeviceId.lowercased()
        let existing = find(key)
        var next = cameras.filter { !$0.peerDeviceId.caseInsensitiveCompare(key).isOrderedSame }
        next.append(PairedCamera(
            peerDeviceId: key,
            peerName: camera.peerName,
            peerModel: camera.peerModel,
            peerSerial: camera.peerSerial,
            pairedAt: existing?.pairedAt ?? camera.pairedAt,
            lastSeenAt: camera.lastSeenAt,
            lastIp: camera.lastIp,
            lastPort: camera.lastPort,
            protoVersion: camera.protoVersion
        ))
        commit(next)
    }

    /// 解除配对（手机端主动）。返回是否真的删掉了。
    @discardableResult
    func remove(_ peerDeviceId: String) -> Bool {
        let next = cameras.filter { !$0.peerDeviceId.caseInsensitiveCompare(peerDeviceId).isOrderedSame }
        if next.count == cameras.count { return false }
        commit(next)
        return true
    }

    /// 连接成功后刷新“最近可见”信息。
    func touch(peerDeviceId: String, ip: String, port: Int, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guard let cur = find(peerDeviceId) else { return }
        upsert(PairedCamera(
            peerDeviceId: cur.peerDeviceId, peerName: cur.peerName, peerModel: cur.peerModel,
            peerSerial: cur.peerSerial, pairedAt: cur.pairedAt, lastSeenAt: now,
            lastIp: ip, lastPort: port, protoVersion: cur.protoVersion
        ))
    }

    func updateProtoVersion(_ peerDeviceId: String, _ v: Int) {
        guard let cur = find(peerDeviceId), cur.protoVersion != v else { return }
        upsert(PairedCamera(
            peerDeviceId: cur.peerDeviceId, peerName: cur.peerName, peerModel: cur.peerModel,
            peerSerial: cur.peerSerial, pairedAt: cur.pairedAt, lastSeenAt: cur.lastSeenAt,
            lastIp: cur.lastIp, lastPort: cur.lastPort, protoVersion: v
        ))
    }

    private func commit(_ next: [PairedCamera]) {
        cameras = next.sorted { $0.lastSeenAt > $1.lastSeenAt }
        defaults.set(Self.encode(cameras), forKey: tableKey)
    }

    // MARK: 序列化

    static func encode(_ list: [PairedCamera]) -> String {
        var arr: [[String: Any]] = []
        for c in list {
            arr.append([
                "id": c.peerDeviceId,
                "name": c.peerName,
                "model": c.peerModel,
                "serial": c.peerSerial,
                "pairedAt": c.pairedAt,
                "lastSeenAt": c.lastSeenAt,
                "lastIp": c.lastIp,
                "lastPort": c.lastPort,
                "proto": c.protoVersion,
            ])
        }
        return (try? JSONSerialization.data(withJSONObject: arr).base64EncodedString()) ?? ""
    }

    static func decode(_ raw: String?) -> [PairedCamera] {
        guard let raw = raw, !raw.isEmpty,
              let data = Data(base64Encoded: raw),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [PairedCamera] = []
        for o in arr {
            guard let id = o["id"] as? String, !id.isEmpty else { continue }
            out.append(PairedCamera(
                peerDeviceId: id.lowercased(),
                peerName: o["name"] as? String ?? "",
                peerModel: o["model"] as? String ?? "",
                peerSerial: o["serial"] as? String ?? "",
                pairedAt: (o["pairedAt"] as? NSNumber)?.int64Value ?? 0,
                lastSeenAt: (o["lastSeenAt"] as? NSNumber)?.int64Value ?? 0,
                lastIp: o["lastIp"] as? String ?? "",
                lastPort: (o["lastPort"] as? NSNumber)?.intValue ?? 0,
                protoVersion: (o["proto"] as? NSNumber)?.intValue ?? 0
            ))
        }
        return out.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
}
