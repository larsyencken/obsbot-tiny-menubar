import CObsbotUSB
import Foundation

// Vendor protocol for the OBSBOT Tiny 2, as reverse-engineered and
// hardware-verified by lxman/obsbot-mcp (PROTOCOL.md, src/codec/commands.ts).
//
// Everything goes through UVC Extension Unit 2 as 60-byte payloads:
//   - selector 6: flat "uvcExt" commands like [tag, len, value...] (AI mode),
//     and GET_CUR returns a status block.
//   - selector 2: framed "V3" commands with a CRC (sleep/wake).

struct CameraError: Error, CustomStringConvertible {
    let code: Int32
    var description: String {
        switch UInt32(bitPattern: code) {
        case 0xE00002C0: return "camera not connected"  // kIOReturnNoDevice
        case 0xE00002C5: return "camera is in use by another app (e.g. OBSBOT Center)"  // kIOReturnExclusiveAccess
        case 0xE00002D6: return "camera didn't confirm the change in time"  // kIOReturnTimeout
        default: return String(format: "USB error 0x%08X", UInt32(bitPattern: code))
        }
    }
}

enum AIMode: Equatable {
    case off, normal, other(UInt8, UInt8)

    var label: String {
        switch self {
        case .off: return "Off"
        case .normal: return "Normal"
        case let .other(m, n): return "Other (\(m),\(n))"
        }
    }
}

struct CameraStatus {
    let awake: Bool
    let aiMode: AIMode

    init(block: [UInt8]) {
        awake = block[0x02] == 0
        let m = block[0x18], n = block[0x1C]
        switch (m, n) {
        case (0, 0): aiMode = .off
        case (2, 0): aiMode = .normal
        default: aiMode = .other(m, n)
        }
    }
}

final class Camera {
    static let vendorID: UInt16 = 0x3564
    static let productID: UInt16 = 0xFEF8  // Tiny 2
    private static let unit: UInt8 = 2
    private static let selStatus: UInt8 = 6
    private static let selFramed: UInt8 = 2
    private static let payloadSize = 60

    private var seq: UInt16 = 0

    var isPresent: Bool { obsbot_present(Self.vendorID, Self.productID) != 0 }

    func status() throws -> CameraStatus {
        var buf = [UInt8](repeating: 0, count: Self.payloadSize)
        let kr = obsbot_xu_get(Self.vendorID, Self.productID, Self.unit, Self.selStatus,
                               &buf, UInt16(buf.count))
        guard kr == 0 else { throw CameraError(code: kr) }
        return CameraStatus(block: buf)
    }

    func setAwake(_ awake: Bool) throws {
        // CAM_SET_DEV_STATUS (wire cmd 0xA0C2, receiver 0x02): wake=0, sleep=1.
        try send(Self.selFramed, frame(cmd: 0xA0C2, receiver: 0x02, payload: [awake ? 0 : 1, 0, 0, 0]))
    }

    /// Human tracking with the "normal" framing, or tracking off.
    func setTracking(_ on: Bool) throws {
        // [tag 0x16, len 2, work mode (2 = human, 0 = none), framing (0 = normal)]
        try send(Self.selStatus, [0x16, 0x02, on ? 0x02 : 0x00, 0x00])
    }

    /// Live gimbal pan/tilt in degrees (UVC CT_PANTILT_ABSOLUTE on the camera
    /// terminal, in arc-seconds). The firmware updates it as the gimbal moves,
    /// including moves made by AI tracking.
    func pose() throws -> (pan: Double, tilt: Double) {
        var buf = [UInt8](repeating: 0, count: 8)
        let kr = obsbot_xu_get(Self.vendorID, Self.productID, 1, 0x0D, &buf, 8)
        guard kr == 0 else { throw CameraError(code: kr) }
        let v = buf.withUnsafeBytes { (pan: Int32(littleEndian: $0.load(as: Int32.self)),
                                       tilt: Int32(littleEndian: $0.load(fromByteOffset: 4, as: Int32.self))) }
        return (Double(v.pan) / 3600, Double(v.tilt) / 3600)
    }

    func aim(pan: Double, tilt: Double) throws {
        var p = Int32(pan * 3600).littleEndian, t = Int32(tilt * 3600).littleEndian
        var buf = [UInt8](repeating: 0, count: 8)
        withUnsafeBytes(of: &p) { buf.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: &t) { buf.replaceSubrange(4..<8, with: $0) }
        let kr = obsbot_xu_set(Self.vendorID, Self.productID, 1, 0x0D, buf, 8)
        guard kr == 0 else { throw CameraError(code: kr) }
    }

    private func send(_ selector: UInt8, _ bytes: [UInt8]) throws {
        var buf = [UInt8](repeating: 0, count: Self.payloadSize)
        buf.replaceSubrange(0..<bytes.count, with: bytes)
        let kr = obsbot_xu_set(Self.vendorID, Self.productID, Self.unit, selector,
                               buf, UInt16(buf.count))
        guard kr == 0 else { throw CameraError(code: kr) }
    }

    private func frame(cmd: UInt16, receiver: UInt8, payload: [UInt8]) -> [UInt8] {
        seq &+= 1
        var f = [UInt8](repeating: 0, count: Self.payloadSize)
        f[0] = 0xAA
        f[1] = 0x25
        f[2] = UInt8(seq & 0xFF); f[3] = UInt8(seq >> 8)
        f[4] = 12; f[5] = 0
        f[8] = 0x0A  // sender
        f[9] = receiver
        f[10] = UInt8(cmd & 0xFF); f[11] = UInt8(cmd >> 8)
        let hdr = crc16usb(f[0..<12])
        f[6] = UInt8(hdr & 0xFF); f[7] = UInt8(hdr >> 8)
        // Nested payload segment: len2 @12, token2 @14, data @16.
        f[12] = UInt8(payload.count); f[13] = 0
        f.replaceSubrange(16..<(16 + payload.count), with: payload)
        let seg = crc16usb(f[12..<(16 + payload.count)])
        f[14] = UInt8(seg & 0xFF); f[15] = UInt8(seg >> 8)
        return f
    }
}

/// CRC-16/USB: poly 0xA001 (reflected), init 0xFFFF, xorout 0xFFFF.
func crc16usb(_ data: ArraySlice<UInt8>) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in data {
        crc ^= UInt16(b)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
    }
    return crc ^ 0xFFFF
}

extension Camera {
    static let timeout = Int32(bitPattern: 0xE00002D6)  // kIOReturnTimeout

    /// Wake, wait until the camera reports awake, then turn on normal tracking
    /// and wait for the status to confirm it. Blocking; call off the main thread.
    func wakeAndTrack() throws {
        try setAwake(true)
        try waitFor(timeout: 5) { $0.awake }
        Thread.sleep(forTimeInterval: 0.5)  // let the gimbal finish rising
        try enableTracking()
    }

    func enableTracking() throws {
        // A switch passes through a transient mode for ~200ms, so poll, and resend
        // once in case the first write landed while the camera was still busy.
        for _ in 0..<2 {
            try setTracking(true)
            do {
                try waitFor(timeout: 2) { $0.aiMode == .normal }
                return
            } catch let e as CameraError where e.code == Self.timeout {
                continue
            }
        }
        throw CameraError(code: Self.timeout)
    }

    func disableTracking() throws {
        try setTracking(false)
        try waitFor(timeout: 2) { $0.aiMode == .off }
    }

    func sleepAndWait() throws {
        try setAwake(false)
        try waitFor(timeout: 5) { !$0.awake }
    }

    private func waitFor(timeout: TimeInterval, _ pred: (CameraStatus) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if pred(try status()) { return }
            if Date() > deadline { throw CameraError(code: Self.timeout) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
