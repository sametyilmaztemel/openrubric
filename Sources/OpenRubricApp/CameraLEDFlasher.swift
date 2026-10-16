#if os(macOS)
import AppKit
import AVFoundation
import IOKit
import OpenRubricCore

/// Minimal AppleSMC user-space client.
///
/// Talks to the `AppleSMC` kernel service through `IOConnectCallStructMethod`
/// using the kernel's `SMCParamStruct` layout (canonical 80 bytes — verified
/// byte-for-byte against the Apple pmconfigd C layout and the C compiler).
/// No entitlement, no privileged helper, no subprocess: `IOServiceGetMatchingService`
/// and `IOServiceOpen` are public.
///
/// Reads are two-step (`kSMCGetKeyInfo` for size/type, then `kSMCReadKey`);
/// a read that skips the info step is the classic SMC bug, so we never do it.
/// Every failure mode is surfaced as a distinct `SMCError` with a human-
/// readable description, so the diagnostic log tells us *exactly* why the
/// camera-LED key is unavailable on a given machine.
enum SMC {
    enum SMCError: Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case keyNotFound
        case smcResult(UInt8)
        case unexpectedLayout(Int)

        var description: String {
            switch self {
            case .serviceNotFound:
                return "AppleSMC service not found"
            case .openFailed(let kr):
                return "IOServiceOpen failed (kern \(kr))"
            case .callFailed(let kr):
                return "IOConnectCallStructMethod failed (kern \(kr))"
            case .keyNotFound:
                return "LSOO key not found on this machine (dataSize 0)"
            case .smcResult(let r):
                let hint = (r == 132) ? " — LSOO key not found" : ""
                return "SMC rejected (code \(r))\(hint)"
            case .unexpectedLayout(let s):
                return "SMC struct is \(s) bytes, expected 80"
            }
        }
    }

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        // Canonical C layout (informationsea/smc smc.h, Apple's original
        // pmconfigd): `dataSize` is a UInt32, NOT IOByteCount/UInt64. With
        // this type and no trailing padding field the whole struct is exactly
        // 80 bytes (dataSize@28, result@40, data8@42, data32@44, bytes@48) —
        // the beltex/SMCKit IOByteCount variant lays out at 96 bytes and
        // fails its own stride==80 assert (their issue #49).
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    // 80-byte layout, mirroring the kernel SMCParamStruct (canonical C above).
    // Order and types matter: the driver copies this struct by size, and the
    // whole struct must be exactly 80 bytes (asserted in `withConnection`).
    // `bytes` is the data payload; the SMC reports its real size via
    // keyInfo.dataSize, so we only read/write the first bytes.
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes = (
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        )
    }

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    /// `LSOO` — front camera LED on/off (1 = lit, 0 = off). Four-char SMC
    /// key built from its UTF-8 bytes, matching how the SMC addresses keys.
    private static let lsOOKey: UInt32 = fourCC("LSOO")

    private static func fourCC(_ code: String) -> UInt32 {
        precondition(code.utf8.count == 4, "SMC keys are 4 characters")
        return code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Runs `body` with an open SMC connection, closing it afterwards.
    static func withConnection<T>(_ body: (io_connect_t) throws -> T) throws -> T {
        guard MemoryLayout<SMCParamStruct>.stride == 80 else {
            throw SMCError.unexpectedLayout(MemoryLayout<SMCParamStruct>.stride)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
        defer { IOServiceClose(connection) }
        return try body(connection)
    }

    private static func call(_ connection: io_connect_t, _ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection, kSMCHandleYPCEvent, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outputSize
        )
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        guard output.result == 0 else { throw SMCError.smcResult(output.result) }
        return output
    }

    /// The key's payload size and data type. Throws `keyNotFound`/`smcResult`
    /// when the key is absent on this machine.
    static func keyInfo(connection: io_connect_t) throws -> (size: UInt32, type: UInt32) {
        var request = SMCParamStruct()
        request.key = lsOOKey
        request.data8 = kSMCGetKeyInfo
        let reply = try call(connection, request)
        guard reply.keyInfo.dataSize >= 1 else { throw SMCError.keyNotFound }
        return (reply.keyInfo.dataSize, reply.keyInfo.dataType)
    }

    /// Reads the current LED state (0/1) using an already-validated size.
    static func readValue(connection: io_connect_t, size: UInt32) throws -> Int {
        var request = SMCParamStruct()
        request.key = lsOOKey
        request.data8 = kSMCReadKey
        request.keyInfo.dataSize = size
        let reply = try call(connection, request)
        return Int(reply.bytes.0)
    }

    /// Writes the LED state (0/1) using an already-validated size. Throws when
    /// the SMC rejects the write (e.g. not privileged / read-only key).
    static func writeValue(connection: io_connect_t, size: UInt32, value: Int) throws {
        var request = SMCParamStruct()
        request.key = lsOOKey
        request.data8 = kSMCWriteKey
        request.keyInfo.dataSize = size
        request.bytes.0 = UInt8(min(max(value, 0), 1))
        _ = try call(connection, request)
    }
}

/// Drives the front camera LED, `count` times, via two mechanisms:
///
/// 1. **SMC `LSOO`** (fast, ~250ms/blink) — the clean path, used when the key
///    is present and writable on this machine.
/// 2. **AVCaptureSession open/close** (fallback, ~4s/blink) — on Intel Macs
///    the LED is hardware-interlocked to the camera sensor, so powering the
///    sensor on/off reliably lights it. The PMIC enforces a ~3s minimum on-
///    time, so capture blinks are slower.
///
/// The SMC path is tried first; on any failure (service missing, key unknown,
/// write rejected) the capture fallback takes over so the LED still blinks.
/// Both are best-effort and log their outcome; neither can crash the app.
final class CameraLEDFlasher: @unchecked Sendable {
    /// Serial queue so overlapping answer cycles cannot interleave LED writes.
    private let queue = DispatchQueue(label: "openrubric.camera-led")
    /// SMC path: seconds each on/off phase lasts.
    private let pulseGap: Double
    /// Capture path: sensor-on time (must clear the ~3s PMIC minimum on-time).
    private let captureOn: Double
    /// Capture path: sensor-off time.
    private let captureOff: Double

    init(pulseGap: Double = 0.25) {
        self.pulseGap = pulseGap
        // Capture-fallback timing: the camera PMIC enforces a ~3s minimum LED
        // on-time after the sensor powers down (hardware interlock), so the
        // off-phase must exceed that for the blink to be *visible* as on-then-
        // off. 3.5s on covers hardware where the minimum is slightly above
        // 3s; 4.0s off lets the LED fully decay. Slower than the SMC path but
        // reliable on hardware where LSOO is absent.
        self.captureOn = 3.5
        self.captureOff = 4.0
    }

    /// Blinks the front camera LED `count` times (SMC first, capture fallback).
    func flash(count: Int) {
        queue.async {
            do {
                try self.flashViaSMC(count: count)
                return
            } catch {
                FlashDiagnostics.note("flash: cameraLED SMC unavailable (\(error)) — trying capture fallback")
            }
            self.flashViaCapture(count: count)
        }
    }

    /// Fast path: read the resting state once, then pulse its inverse `count`
    /// times on a single SMC connection, always ending at the resting state.
    private func flashViaSMC(count: Int) throws {
        try SMC.withConnection { connection in
            let info = try SMC.keyInfo(connection: connection)
            let resting = try SMC.readValue(connection: connection, size: info.size)
            FlashDiagnostics.note("flash: cameraLED [SMC] resting=\(resting) count=\(count)")
            let levels = FlashMath.cameraLEDPulse(resting: resting)
            for _ in 0..<count {
                try SMC.writeValue(connection: connection, size: info.size, value: levels.set)
                Thread.sleep(forTimeInterval: self.pulseGap)
                try SMC.writeValue(connection: connection, size: info.size, value: levels.restore)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
            FlashDiagnostics.note("flash: cameraLED [SMC] done — \(count) blink(s)")
        }
    }

    /// Fallback path: power the camera sensor on/off `count` times; the
    /// hardware-interlocked LED follows. Requires camera permission (prompted
    /// once). Slower than SMC because of the sensor's minimum on-time.
    private func flashViaCapture(count: Int) {
        guard cameraAuthorized() else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            FlashDiagnostics.note("flash: cameraLED [capture] UNAVAILABLE (no video device) — skipped")
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .low
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            FlashDiagnostics.note("flash: cameraLED [capture] UNAVAILABLE (cannot create input) — skipped")
            return
        }
        session.addInput(input)
        FlashDiagnostics.note("flash: cameraLED [capture] count=\(count) (LED follows sensor power)")
        for cycle in 0..<count {
            session.startRunning()
            Thread.sleep(forTimeInterval: self.captureOn)
            session.stopRunning()
            Thread.sleep(forTimeInterval: self.captureOff)
        }
        FlashDiagnostics.note("flash: cameraLED [capture] done — \(count) blink(s)")
    }

    /// Ensures camera permission, prompting once when not yet decided.
    private func cameraAuthorized() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
            let ok = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            FlashDiagnostics.note("flash: cameraLED [capture] permission granted=\(ok)")
            return ok
        default:
            FlashDiagnostics.note("flash: cameraLED [capture] UNAVAILABLE (no camera permission) — skipped")
            return false
        }
    }
}
#endif
