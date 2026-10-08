// MARK: - SMC.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// A minimal client for the Apple System Management Controller (SMC) that
// reads and writes its keys.

import Foundation
import IOKit

import SMCParamStruct

internal typealias SMCKey = FourCharCode

internal extension SMCKey {
    init(fourCC string: StaticString) {
        precondition(string.utf8CodeUnitCount == 4)
        self = "\(string)".utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Minimal AppleSMC user client. All access happens on the main actor.
@MainActor
internal enum SMC: Loggable {
    nonisolated static let logTag = "[SMC]"

    enum KeyType {
        static let ui8 = SMCKey(fourCC: "ui8 ")
        static let ui32 = SMCKey(fourCC: "ui32")
    }

    private static var connect: io_connect_t = IO_OBJECT_NULL

    static func open() -> Bool {
        assert(self.connect == IO_OBJECT_NULL)

        // Apple can kiss my ass; I'll use the word "master" if I damn well please.
        let service = unsafe IOServiceGetMatchingService(
            kIOMasterPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else {
            log("AppleSMC service not found", level: .error)
            return false
        }
        defer { IOObjectRelease(service) }

        var connect: io_connect_t = IO_OBJECT_NULL
        let result = unsafe IOServiceOpen(service, mach_task_self_, 1, &connect)
        guard result == kIOReturnSuccess, connect != IO_OBJECT_NULL else {
            log("IOServiceOpen(AppleSMC) failed: \(self.describe(result))", level: .error)
            return false
        }

        self.connect = connect
        IOConnectCallMethod(
            connect, UInt32(kSMCUserClientOpen),
            nil, 0, nil, 0, nil, nil, nil, nil
        )
        log("AppleSMC opened")
        return true
    }

    static func close() {
        guard self.connect != IO_OBJECT_NULL else {
            return
        }

        IOConnectCallMethod(
            self.connect, UInt32(kSMCUserClientClose),
            nil, 0, nil, 0, nil, nil, nil, nil
        )
        IOServiceClose(self.connect)
        self.connect = IO_OBJECT_NULL
        log("AppleSMC closed")
    }

    /// What a key lookup found.
    enum KeyAvailability: Equatable {
        /// The key exists with the expected size and type.
        case available
        /// The key does not exist, or exists with a different layout.
        case absent
        /// The key may exist, but AppleSMC refused to touch it. Firmware from
        /// macOS 15.8 / 26.7 / 27 onward gates the charge-limit keys behind a
        /// private Apple entitlement, and refuses even root with
        /// kIOReturnNotPrivileged rather than answering "not found" (0x84).
        case blocked
    }

    /// Whether `key` exists with the given size and type.
    ///
    /// Battery Toolkit additionally required an exact attribute byte match.
    /// Attribute bits have no bearing on how we use a key and are free to
    /// change across firmware versions, so they are deliberately ignored.
    /// Writes are verified by read-back instead.
    static func availability(of key: SMCKey, size: UInt32, type: SMCKey) -> KeyAvailability {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = UInt8(kSMCGetKeyInfo)

        let (result, output) = self.rawCall(&input)
        if Self.isPrivilegeRefusal(result) {
            log("Key \(key.fourCC): access refused by AppleSMC (\(self.describe(result)))", level: .error)
            return .blocked
        }
        guard result == kIOReturnSuccess, output.result == UInt8(kSMCSuccess) else {
            log("Key \(key.fourCC): absent (IOReturn \(self.describe(result)), SMC result 0x\(output.result.hex(digits: 2)))")
            return .absent
        }

        let info = output.keyInfo
        guard info.dataSize == size, info.dataType == type else {
            log(
                "Key \(key.fourCC): unexpected layout size=\(info.dataSize) type=\(info.dataType.fourCC) attrs=0x\(info.dataAttributes.hex(digits: 2)); expected size=\(size) type=\(type.fourCC)",
                level: .warning
            )
            return .absent
        }

        log("Key \(key.fourCC): present size=\(size) type=\(type.fourCC) attrs=0x\(info.dataAttributes.hex(digits: 2))")
        return .available
    }

    /// The IOKit-level answers to a caller that lacks permission, as opposed
    /// to the SMC's own result byte (0x84 for a missing key).
    private static func isPrivilegeRefusal(_ result: kern_return_t) -> Bool {
        result == kIOReturnNotPrivileged || result == kIOReturnNotPermitted
    }

    static func read(_ key: SMCKey, size: Int) -> [UInt8]? {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(size)
        input.data8 = UInt8(kSMCReadKey)

        guard let output = self.call(&input) else {
            return nil
        }

        return unsafe withUnsafeBytes(of: output.bytes) { unsafe Array($0.prefix(size)) }
    }

    /// Writes `bytes` to `key` and verifies the result by reading it back.
    /// The SMC has been observed to report success while holding a value
    /// different from what was written.
    static func write(_ key: SMCKey, _ bytes: [UInt8]) -> Bool {
        var input = SMCParamStruct()
        precondition(bytes.count <= MemoryLayout.size(ofValue: input.bytes))
        input.key = key
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = UInt8(kSMCWriteKey)
        unsafe withUnsafeMutableBytes(of: &input.bytes) { buffer in
            unsafe buffer.copyBytes(from: bytes)
        }

        guard self.call(&input) != nil else {
            log("Write \(key.fourCC) <- \(Data(bytes).hex) failed", level: .error)
            return false
        }

        let readBack = self.read(key, size: bytes.count)
        guard readBack == bytes else {
            log(
                "Write \(key.fourCC) <- \(Data(bytes).hex) not retained; reads back \(readBack.map { Data($0).hex } ?? "nil")",
                level: .error
            )
            return false
        }

        log("Write \(key.fourCC) <- \(Data(bytes).hex) verified")
        return true
    }

    private static func call(
        _ input: inout SMCParamStruct,
        logErrors: Bool = true
    ) -> SMCParamStruct? {
        let (result, output) = self.rawCall(&input)
        guard result == kIOReturnSuccess, output.result == UInt8(kSMCSuccess)
        else {
            if logErrors {
                let key = input.key.fourCC
                log(
                    "Call for \(key) failed: IOReturn \(self.describe(result)), SMC result 0x\(output.result.hex(digits: 2))",
                    level: .error
                )
            }
            return nil
        }

        return output
    }

    private static func rawCall(
        _ input: inout SMCParamStruct
    ) -> (kern_return_t, SMCParamStruct) {
        assert(self.connect != IO_OBJECT_NULL)
        assert(MemoryLayout<SMCParamStruct>.stride == 80)

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = unsafe IOConnectCallStructMethod(
            self.connect,
            UInt32(kSMCHandleYPCEvent),
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        return (result, output)
    }

    private static func describe(_ result: kern_return_t) -> String {
        let hex = "0x" + UInt32(bitPattern: result).hex(digits: 8)
        guard let text = unsafe mach_error_string(result) else {
            return hex
        }
        return "\(hex) (\(unsafe String(cString: text)))"
    }
}
