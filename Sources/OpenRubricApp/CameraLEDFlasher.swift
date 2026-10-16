#if os(macOS)
import AppKit
import IOKit
import OpenRubricCore

/// Minimal AppleSMC user-space client.
///
/// Talks to the `AppleSMC` kernel service through `IOConnectCallStructMethod`
/// using the kernel's `SMCParamStruct` layout (80 bytes) — the same technique
/// used by `xline`/`SMCKit` for the front camera LED. No entitlement, no
/// privileged helper, no subprocess: `IOServiceGetMatchingService` and
/// `IOServiceOpen` are public, and the front LED is driven by a single-byte
/// key (`LSOO`).
///
/// The SMC key set is not a documented Apple interface — it is observed
/// behaviour. Reads are two-step (`kSMCGetKeyInfo` for size/type, then
/// `kSMCReadKey`); a read that skips the info step and assumes a type is the
/// classic SMC bug, so we never do that.
enum SMC {
    enum SMCError: Error {
        case serviceNotFound
        case openFailed(kern_return_t)
        case callFailed(kern_return_t)
        case smcResult(UInt8)
        case unexpectedLayout(Int)
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
        // pmconfigd): `dataSize` is a UInt32 here, NOT IOByteCount/UInt64.
        // The beltex/SMCKit variant (IOByteCount + a trailing `padding` field)
        // lays out at 96 bytes and fails its own stride==80 assert on modern
        // Swift (beltex/SMCKit issue #49); with the UInt32 layout and no
        // padding field the whole struct is exactly 80 bytes with the
        // canonical offsets (dataSize@28, result@40, data8@42, data32@44,
        // bytes@48), which is what the AppleSMC driver expects.
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    // 80-byte layout, mirroring the kernel SMCParamStruct (canonical C above).
    // Order and types matter: the driver copies this struct by size, and the
    // whole struct must be exactly 80 bytes (asserted in `withConnection`).
    // There is no explicit padding field — the 1-byte `dataAttributes` leaves
    // the alignment to the compiler, reproducing the C layout exactly.
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
    private static func withConnection<T>(_ body: (io_connect_t) throws -> T) throws -> T {
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

    /// The key's payload size and whether it is present on this machine.
    /// `nil` when the `AppleSMC` service is missing or the key is unknown.
    /// Typed as `UInt32` to match `SMCParamStruct.keyInfo.dataSize`.
    static func cameraLEDKeyInfo() -> UInt32? {
        do {
            return try withConnection { connection in
                var request = SMCParamStruct()
                request.key = lsOOKey
                request.data8 = kSMCGetKeyInfo
                let reply = try call(connection, request)
                return reply.keyInfo.dataSize
            }
        } catch {
            return nil
        }
    }

    /// Reads the front camera LED's current on/off state, or `nil` when it
    /// cannot be read (service missing, key unknown, or not privileged).
    static func readCameraLED() -> Int? {
        guard let size = cameraLEDKeyInfo() else { return nil }
        do {
            return try withConnection { connection -> Int in
                var request = SMCParamStruct()
                request.key = lsOOKey
                request.data8 = kSMCReadKey
                request.keyInfo.dataSize = size
                let reply = try call(connection, request)
                return Int(reply.bytes.0)
            }
        } catch {
            return nil
        }
    }

    /// Writes the front camera LED on/off state. Returns `true` when the SMC
    /// accepted the write. Best-effort: a `nil`/`false` means the channel is
    /// unavailable (logged by the caller), never a crash.
    @discardableResult
    static func writeCameraLED(_ on: Int) -> Bool {
        guard let size = cameraLEDKeyInfo() else { return false }
        do {
            _ = try withConnection { connection in
                var request = SMCParamStruct()
                request.key = lsOOKey
                request.data8 = kSMCWriteKey
                request.keyInfo.dataSize = size
                request.bytes.0 = UInt8(min(max(on, 0), 1))
                return try call(connection, request)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Drives the front camera LED through the SMC `LSOO` key, `count` times.
///
/// The LED is an on/off byte, so "flash N times" is an inverse pulse, exactly
/// like the Caps Lock LED: the resting state is read once, then each cycle
/// writes its inverse and back to the resting state, so a cycle ends where it
/// started and never leaves the LED on the wrong side. Best-effort: when the
/// `AppleSMC` service or the `LSOO` key is unavailable (or the write is not
/// privileged) the channel no-ops and the diagnostic log records why.
///
/// On modern Macs the camera LED is hardware-interlocked to the sensor, so
/// while the camera is genuinely active the SMC write may be overridden — the
/// same best-effort posture as the keyboard backlight.
final class CameraLEDFlasher: @unchecked Sendable {
    /// Serial queue so overlapping answer cycles cannot interleave SMC writes.
    private let queue = DispatchQueue(label: "openrubric.camera-led")
    /// Seconds each on/off phase lasts before returning.
    private let pulseGap: Double

    init(pulseGap: Double = 0.25) {
        self.pulseGap = pulseGap
    }

    /// Blinks the front camera LED `count` times.
    func flash(count: Int) {
        queue.async {
            guard let resting = SMC.readCameraLED() else {
                FlashDiagnostics.note("flash: cameraLED NOT AVAILABLE (AppleSMC/LSOO missing or not privileged) — skipped")
                return
            }
            FlashDiagnostics.note("flash: cameraLED resting=\(resting) count=\(count)")
            let levels = FlashMath.cameraLEDPulse(resting: resting)
            for cycle in 0..<count {
                let ok = SMC.writeCameraLED(levels.set)
                if cycle == 0 {
                    FlashDiagnostics.note("flash: cameraLED first write=\(ok ? "success" : "rejected") (set=\(levels.set))")
                }
                Thread.sleep(forTimeInterval: self.pulseGap)
                _ = SMC.writeCameraLED(levels.restore)
                Thread.sleep(forTimeInterval: self.pulseGap)
            }
            FlashDiagnostics.note("flash: cameraLED done — \(count) blink(s) sent")
        }
    }
}
#endif
