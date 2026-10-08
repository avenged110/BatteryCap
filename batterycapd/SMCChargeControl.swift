// MARK: - SMCChargeControl.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// Controls the SMC's built-in firmware charge limiter (the bf* keys) that
// enforces the 70–80% band.

import Foundation

/// The SMC firmware charge limiter found on newer Apple Silicon firmware.
/// The keys were first published by ashwinr64
/// (https://github.com/actuallymentor/battery/pull/469, 2026-07-10).
///
/// - bfF0 (ui8): 0x00 = inactive, 0x02 = active
/// - bfD0 (ui32, LE): upper bound; charging stops at this percentage
/// - bfE0 (ui32, LE): lower bound; charging resumes below this percentage
///
/// The SMC enforces this band on its own, including during sleep, so the
/// daemon only arms it and re-verifies it. Observed on
/// an M3 Max: the setting survives the controlling process exiting, and with
/// the battery above the upper bound on AC, it discharges down to it.
///
/// The bounds apply to the fuel gauge's true state of charge (`StateOfCharge`
/// in `ioreg -rn AppleSmartBattery`: raw mAh over full-charge mAh), not to the
/// percentage macOS displays, which is remapped and reads higher near the top
/// (held at a true 80%, an M3 Max displays 84%).
///
/// Why this and not Battery Toolkit's method: newer SMC firmware (seen on
/// `mBoot-20457`, M3 Max, macOS 15.8) removed the legacy `CHTE`/`CH0C`
/// charge-inhibit keys that Battery Toolkit uses, and added this limiter. Its
/// own MCL API reports unsupported on macOS 15.x (`isMCLSupported = 0`), so
/// the bf* keys are the only backend and the legacy keys are not kept as a
/// fallback. Firmware, not the macOS version, decides support; the macOS 15.8
/// deployment target is only the release that ships this firmware.
///
/// Any other tool that limits charging (Battery Toolkit, batt, AlDente)
/// writes the same SMC keys and will fight this one.
@MainActor
internal enum FirmwareLimiter: Loggable {
    nonisolated static let logTag = "[FirmwareLimiter]"

    struct State: Equatable, CustomStringConvertible {
        let active: Bool
        let lower: UInt8
        let upper: UInt8

        var description: String {
            "\(self.active ? "active" : "inactive") \(self.lower)-\(self.upper)"
        }
    }

    private static let activationKey = SMCKey(fourCC: "bfF0")
    private static let upperKey = SMCKey(fourCC: "bfD0")
    private static let lowerKey = SMCKey(fourCC: "bfE0")

    private static let inactive: UInt8 = 0x00
    private static let active: UInt8 = 0x02

    /// Available only if all three keys are; blocked if AppleSMC refused
    /// any of them, since that refusal is the one thing a user can act on.
    static var availability: SMC.KeyAvailability {
        let keys = [
            SMC.availability(of: self.activationKey, size: 1, type: SMC.KeyType.ui8),
            SMC.availability(of: self.upperKey, size: 4, type: SMC.KeyType.ui32),
            SMC.availability(of: self.lowerKey, size: 4, type: SMC.KeyType.ui32),
        ]
        if keys.contains(.blocked) {
            return .blocked
        }
        return keys.allSatisfy { $0 == .available } ? .available : .absent
    }

    /// Returns nil if the keys cannot be read or hold values we do not
    /// understand; callers treat that as "not in the desired state".
    static func read() -> State? {
        guard
            let activation = SMC.read(self.activationKey, size: 1)?.first,
            let upperBytes = SMC.read(self.upperKey, size: 4),
            let lowerBytes = SMC.read(self.lowerKey, size: 4)
        else {
            log("Limiter keys unreadable", level: .warning)
            return nil
        }
        guard
            activation == self.inactive || activation == self.active,
            let upper = self.percent(upperBytes),
            let lower = self.percent(lowerBytes)
        else {
            log(
                "Limiter holds values we do not understand: bfF0=\(Data([activation]).hex) bfD0=\(Data(upperBytes).hex) bfE0=\(Data(lowerBytes).hex)",
                level: .warning
            )
            return nil
        }

        return State(
            active: activation == self.active,
            lower: lower,
            upper: upper
        )
    }

    static func apply(lower: UInt8, upper: UInt8) -> Bool {
        precondition(lower < upper && upper <= 100)

        let desired = State(active: true, lower: lower, upper: upper)
        //
        // Deactivate while the bounds are rewritten so the SMC never acts on
        // a half-updated band.
        //
        log("Applying \(desired)")
        guard
            SMC.write(self.activationKey, [self.inactive]),
            SMC.write(self.upperKey, self.percentBytes(upper)),
            SMC.write(self.lowerKey, self.percentBytes(lower)),
            SMC.write(self.activationKey, [self.active])
        else {
            log("Applying \(desired) failed part-way; limiter may be inactive", level: .error)
            return false
        }

        let result = self.read()
        guard result == desired else {
            log("After apply, limiter reads \(result?.description ?? "nil"), expected \(desired)", level: .error)
            return false
        }

        log("Limiter armed: \(desired)")
        return true
    }

    /// Checks only the activation byte, so bounds we do not understand
    /// cannot make a successful disable look like a failure.
    static func disable() -> Bool {
        if SMC.read(self.activationKey, size: 1)?.first == self.inactive {
            log("Limiter already inactive")
            return true
        }
        // SMC.write verifies the byte by reading it back.
        guard SMC.write(self.activationKey, [self.inactive]) else {
            log("Limiter did not report inactive after disable", level: .error)
            return false
        }

        log("Limiter disabled")
        return true
    }

    private static func percentBytes(_ value: UInt8) -> [UInt8] {
        [value, 0x00, 0x00, 0x00]
    }

    private static func percent(_ bytes: [UInt8]) -> UInt8? {
        guard bytes.count == 4, bytes[1...].allSatisfy({ $0 == 0 }), bytes[0] <= 100 else {
            return nil
        }

        return bytes[0]
    }
}
