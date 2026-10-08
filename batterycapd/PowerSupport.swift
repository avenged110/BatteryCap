// MARK: - PowerSupport.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// Battery state, power-source notifications, and sleep/wake events that tell
// the daemon when to re-check the limit.

import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import notify

// MARK: - Battery state

/// The internal battery's state, through the public IOPowerSources API.
/// Read only on events (power source change, wake, limit checks), so its
/// cost does not matter.
internal enum BatteryState: Loggable {
    static let logTag = "[BatteryState]"

    static func onExternalPower() -> Bool {
        guard let battery = self.internalBattery() else {
            //
            // Assume external power when unknown, so that an unreadable state
            // cannot end a charge to full.
            //
            return true
        }

        return InternalBattery.isOnAC(battery)
    }

    /// One-line summary for the log.
    static func summary() -> String {
        guard let battery = self.internalBattery() else {
            return "battery state unavailable"
        }

        let percent = (battery[kIOPSCurrentCapacityKey] as? Int).map { "\($0)%" } ?? "?%"
        let external = InternalBattery.isOnAC(battery) ? "external power" : "battery power"
        let charging = battery[kIOPSIsChargingKey] as? Bool == true ? "charging" : "not charging"
        // Read-only, for diagnosis: BatteryCap never changes Low Power Mode.
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode on" : "Low Power Mode off"
        return "\(percent), \(external), \(charging), \(lowPower)"
    }

    private static func internalBattery() -> [String: Any]? {
        guard let battery = InternalBattery.description() else {
            log("No internal battery information from IOPowerSources", level: .warning)
            return nil
        }

        return battery
    }
}

// MARK: - notify(3) subscriptions

@MainActor
internal final class NotifySubscription: Loggable {
    nonisolated static let logTag = "[Notify]"

    /// Kept for the daemon's lifetime, so never canceled.
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    init?(_ name: String, handler: @escaping @MainActor () -> Void) {
        let status = unsafe notify_register_dispatch(
            name,
            &self.token,
            DispatchQueue.main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        guard status == NOTIFY_STATUS_OK else {
            Self.log("Failed to register for \(name): \(status)", level: .error)
            return nil
        }

        Self.log("Subscribed to \(name)")
    }
}

// MARK: - Shutdown detection

/// Tells a SIGTERM sent because the Mac is shutting down or restarting apart
/// from every other one. launchd sends the same signal when the service is
/// turned off in Login Items (smd boots the job out, exactly as for an
/// unregister), so this is the only way to know which one we received.
@MainActor
internal enum ShutdownMonitor: Loggable {
    nonisolated static let logTag = "[Shutdown]"

    /// Posted by loginwindow when a shutdown or restart begins (Apple menu,
    /// power button dialog, an installer), and when one is canceled.
    private static let initiated = [
        "com.apple.system.loginwindow.shutdownInitiated",
        "com.apple.system.loginwindow.restartinitiated",
        "com.apple.system.install.shutdowninitiated",
        "com.apple.system.install.restartinitiated",
    ]
    private static let canceled = "com.apple.system.loginwindow.logoutcancelled"

    private static var pending: String?
    private static var subscriptions: [NotifySubscription] = []

    static func start() {
        for name in self.initiated {
            if let subscription = NotifySubscription(name, handler: {
                ShutdownMonitor.pending = name
                ShutdownMonitor.log("Shutdown or restart initiated (\(name))")
            }) {
                self.subscriptions.append(subscription)
            }
        }
        if let subscription = NotifySubscription(self.canceled, handler: {
            if ShutdownMonitor.pending != nil {
                ShutdownMonitor.pending = nil
                ShutdownMonitor.log("Shutdown or restart canceled")
            }
        }) {
            self.subscriptions.append(subscription)
        }
    }

    /// Why the system is going down, or nil if it is not.
    static func reason() -> String? {
        if let pending = self.pending {
            return pending
        }
        //
        // Covers shutdowns loginwindow does not announce (e.g., `shutdown`
        // from a shell): launchd sets these once it commits to one.
        //
        for name in ["kern.willshutdown", "kern.willuserspacereboot"] where self.sysctlFlag(name) {
            return name
        }
        return nil
    }

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return unsafe sysctlbyname(name, &value, &size, nil, 0) == 0 && value != 0
    }
}

// MARK: - System sleep/wake

@MainActor
internal enum SystemPower: Loggable {
    nonisolated static let logTag = "[SystemPower]"

    private static func iokitCommonMessage(_ message: UInt32) -> UInt32 {
        let sysIOKit: UInt32 = (0x38 & 0x3F) << 26
        return sysIOKit | message
    }

    private static let canSystemSleep = iokitCommonMessage(0x270)
    private static let systemWillSleep = iokitCommonMessage(0x280)
    private static let systemHasPoweredOn = iokitCommonMessage(0x300)

    private static var rootPort: io_connect_t = IO_OBJECT_NULL
    private static var notifyPort: IONotificationPortRef?
    private static var notifier: io_object_t = IO_OBJECT_NULL
    private static var wakeHandler: (@MainActor () -> Void)?

    static func register(onWake: @escaping @MainActor () -> Void) -> Bool {
        self.wakeHandler = onWake

        let callback: IOServiceInterestCallback = { _, _, messageType, argument in
            MainActor.assumeIsolated {
                if messageType == SystemPower.canSystemSleep {
                    //
                    // Registering for these messages obliges us to answer
                    // them, or sleep is delayed by 30 seconds.
                    //
                    IOAllowPowerChange(SystemPower.rootPort, Int(bitPattern: argument))
                } else if messageType == SystemPower.systemWillSleep {
                    SystemPower.log("System will sleep; battery \(BatteryState.summary())")
                    IOAllowPowerChange(SystemPower.rootPort, Int(bitPattern: argument))
                } else if messageType == SystemPower.systemHasPoweredOn {
                    SystemPower.log("System woke; battery \(BatteryState.summary())")
                    SystemPower.wakeHandler?()
                }
            }
        }

        self.rootPort = unsafe IORegisterForSystemPower(
            nil,
            &self.notifyPort,
            callback,
            &self.notifier
        )
        guard self.rootPort != IO_OBJECT_NULL, let notifyPort = unsafe self.notifyPort else {
            log("IORegisterForSystemPower failed", level: .error)
            return false
        }

        unsafe IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)
        log("Registered for system sleep/wake")
        return true
    }
}
