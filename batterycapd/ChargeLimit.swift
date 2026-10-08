// MARK: - ChargeLimit.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// Arms and re-verifies the firmware charge limit, and handles the one-time
// "Charge to Full" override.

import Foundation

// MARK: - Charge to full

/// A one-time lift of the limit, as Battery Toolkit's "Charge to Full Now":
/// the battery charges to 100%, and the limit returns once the Mac is next
/// disconnected from power. Held in memory only, so a daemon restart (or a
/// reboot) also ends it.
///
/// It ends on unplugging rather than on reaching 100% because the firmware
/// limiter, re-armed above its upper bound, discharges the battery down to it
/// even on AC — so ending at 100% would immediately undo the charge.
@MainActor
internal enum ChargeToFull: Loggable {
    nonisolated static let logTag = "[ChargeToFull]"

    private(set) static var isActive = false
    /// Whether external power has been seen since activation. Turning this on
    /// while on battery waits for the Mac to be plugged in and then unplugged.
    private static var sawExternalPower = false

    static func set(_ active: Bool) {
        guard active != self.isActive else {
            return
        }

        self.isActive = active
        self.sawExternalPower = active && BatteryState.onExternalPower()
        log(active ?
            "Started; battery \(BatteryState.summary())" :
            "Canceled; battery \(BatteryState.summary())")
    }

    /// Called on every power source change, before the limit is re-verified.
    static func powerSourceChanged() {
        guard self.isActive else {
            return
        }

        if BatteryState.onExternalPower() {
            self.sawExternalPower = true
        } else if self.sawExternalPower {
            self.isActive = false
            self.sawExternalPower = false
            log("Disconnected from power; limit restored; battery \(BatteryState.summary())")
        }
    }
}

// MARK: - Enforcement

/// Arms the SMC firmware limiter with our band, then re-verifies it whenever
/// something could plausibly have changed it: power source changes and wake
/// from sleep. Nothing else to do: the SMC enforces the band itself, and keeps
/// it until it is reset (at boot, when launchd starts us again).
@MainActor
internal enum LimitEnforcer: Loggable {
    nonisolated static let logTag = "[LimitEnforcer]"

    /// Charge to full deactivates the limiter; its bounds are left as they are.
    static var desired: FirmwareLimiter.State {
        FirmwareLimiter.State(
            active: !ChargeToFull.isActive,
            lower: BCLimits.lower,
            upper: BCLimits.upper
        )
    }

    /// During a charge to full only the activation byte matters; the bounds
    /// disable() leaves behind are irrelevant while the limiter is off.
    static func isSatisfied(by current: FirmwareLimiter.State?) -> Bool {
        guard let current else {
            return false
        }
        return ChargeToFull.isActive ? !current.active : current == self.desired
    }

    static func enforce(reason: String) {
        let current = FirmwareLimiter.read()
        guard !self.isSatisfied(by: current) else {
            log("\(reason): limiter OK (\(self.desired)); battery \(BatteryState.summary())")
            return
        }

        log(
            "\(reason): limiter is \(current?.description ?? "unreadable"), want \(self.desired); battery \(BatteryState.summary())",
            level: .warning
        )
        if ChargeToFull.isActive {
            if !FirmwareLimiter.disable() {
                log("\(reason): failed to deactivate the limiter for charge to full", level: .error)
            }
        } else if !FirmwareLimiter.apply(lower: BCLimits.lower, upper: BCLimits.upper) {
            log("\(reason): failed to apply firmware charge limit", level: .error)
        }
    }
}
