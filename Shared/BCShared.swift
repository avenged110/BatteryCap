// MARK: - BCShared.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// Identity, charge limits, the internal battery lookup, and the XPC protocol
// and status types shared by the app and the daemon.

import Foundation
import IOKit.ps

/// Identity shared by the app and the daemon.
///
/// There is exactly one source of truth: the `BC_APP_ID` build setting. The
/// app's bundle identifier is `$(BC_APP_ID)`, the daemon's is
/// `$(BC_APP_ID).daemon`, and the launchd plist is generated from the same
/// setting at build time (the "Generate Daemon Plist" build phase, which also
/// fails the build if the embedded daemon is not signed with the identifier the
/// plist expects). Each process derives everything else from its own
/// bundle identifier, so nothing here can drift out of sync with the project.
internal enum BCIdentity {
    static let daemonSuffix = ".daemon"

    /// This process's own bundle identifier (the daemon's comes from the
    /// Info.plist embedded in its binary).
    static let ownID = Bundle.main.bundleIdentifier ?? ""
    static let isDaemon = ownID.hasSuffix(daemonSuffix)

    static let appID = isDaemon ? String(ownID.dropLast(daemonSuffix.count)) : ownID
    static let daemonID = appID + daemonSuffix
    static let daemonMachService = daemonID
    static let daemonPlistName = daemonID + ".plist"

    /// Locations inside the app bundle.
    static let daemonBundlePath = "Contents/Library/LaunchServices/batterycapd"
    static let daemonPlistBundlePath = "Contents/Library/LaunchDaemons/" + daemonPlistName
}

/// Percentages of the true state of charge, which is lower than the figure
/// macOS displays (see `FirmwareLimiter`).
internal enum BCLimits {
    /// Charging resumes only once the battery falls below this percentage.
    static let lower: UInt8 = 70
    /// Charging stops once the battery reaches this percentage.
    static let upper: UInt8 = 80
}

/// The internal battery, through the public IOPowerSources API.
internal enum InternalBattery {
    /// The battery's power source description, or nil when the Mac reports
    /// no internal battery (a desktop) or no power source information.
    static func description() -> [String: Any]? {
        guard
            let info = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = unsafe IOPSCopyPowerSourcesList(info)?
            .takeRetainedValue() as? [CFTypeRef]
        else {
            return nil
        }

        for source in sources {
            if let description = unsafe IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return description
            }
        }

        return nil
    }

    /// Whether the battery reports it is on AC power.
    static func isOnAC(_ description: [String: Any]) -> Bool {
        description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    }
}

internal struct BCStatus: Codable, Sendable {
    /// The daemon's code signature unique ID (cdhash); used to detect a stale
    /// daemon after the app has been rebuilt or updated.
    let uniqueID: Data?
    /// This Mac's SMC has the firmware charge limiter (bfF0/bfD0/bfE0).
    let supported: Bool
    /// The limiter exists but this Mac refuses access to it (believed to be
    /// the firmware's entitlement gate, which SIP being disabled lifts).
    /// Optional so a status from an older daemon still decodes.
    let blocked: Bool?
    /// The limiter holds the state we want: armed with our band, or off
    /// during a charge to full.
    let enforcing: Bool
    /// The limit is lifted until the Mac is next disconnected from power.
    let chargeToFull: Bool
    /// Human-readable limiter state as read from the SMC, for diagnostics.
    let detail: String
}

@objc internal protocol BCDaemonProtocol {
    /// JSON-encoded `BCStatus`.
    func getStatus(reply: @escaping @Sendable (Data?) -> Void)

    /// Lifts the limit until the Mac is next disconnected from power (true),
    /// or restores it now (false). Replies false if nothing is being enforced.
    func setChargeToFull(_ enabled: Bool, reply: @escaping @Sendable (Bool) -> Void)

    /// Returns the platform to stock charging behavior and stops enforcing,
    /// ahead of the app unregistering the daemon.
    func prepareUninstall(reply: @escaping @Sendable (Bool) -> Void)

    /// The app's logging switch, which the daemon follows and remembers.
    func setLoggingEnabled(_ enabled: Bool)
}
