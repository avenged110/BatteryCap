// MARK: - BatteryCapDaemon.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// The privileged daemon's entry point and XPC server, which enforces the charge
// limit independently of the app.

import Foundation
import IOKit.ps

@main
@MainActor
internal enum BatteryCapDaemon: Loggable {
    nonisolated static let logTag = "[Daemon]"

    /// Whether this Mac's SMC has the firmware charge limiter.
    private(set) static var supported = false
    /// The limiter keys exist but AppleSMC refuses access to them.
    private(set) static var blocked = false
    /// Cached at launch: the on-disk binary may be replaced while we run.
    private(set) static var uniqueID: Data?

    private static var uninstalling = false
    private static var powerSourceSubscription: NotifySubscription?
    private static var termSource: DispatchSourceSignal?
    private static var lowPowerObserver: (any NSObjectProtocol)?

    /// The app bundle this daemon was launched from:
    /// <app>/Contents/Library/LaunchServices/batterycapd → <app>
    nonisolated static let appBundleURL: URL? = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }

        let bundle = executable
            .deletingLastPathComponent() // LaunchServices
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // <app>
        return bundle.pathExtension == "app" ? bundle : nil
    }()

    static func main() {
        BCLogging.bootstrap()
        self.uniqueID = CodeSigning.selfInfo()?.cdhash
        self.logStartupReport()

        self.start()
        self.installTermHandler()
        //
        // Serve XPC even when unsupported, so the app can report the
        // situation and uninstall us cleanly.
        //
        DaemonXPCServer.shared.start()

        dispatchMain()
    }

    static func status() -> BCStatus {
        let current = self.supported ? FirmwareLimiter.read() : nil
        return BCStatus(
            uniqueID: self.uniqueID,
            supported: self.supported,
            blocked: self.blocked,
            enforcing: !self.uninstalling && LimitEnforcer.isSatisfied(by: current),
            chargeToFull: ChargeToFull.isActive,
            detail: self.supported ?
                "limiter \(current?.description ?? "unreadable")" :
                self.blocked ?
                "firmware charge limiter access refused (bfF0/bfD0/bfE0)" :
                "no firmware charge limiter (bfF0/bfD0/bfE0)"
        )
    }

    static func setChargeToFull(_ enabled: Bool) -> Bool {
        guard !self.uninstalling, self.supported else {
            return false
        }

        ChargeToFull.set(enabled)
        LimitEnforcer.enforce(reason: "charge to full \(enabled ? "on" : "off")")
        return true
    }

    static func prepareUninstall() -> Bool {
        log("Preparing for uninstall")
        self.uninstalling = true
        self.uninstallAttempt += 1
        ChargeToFull.set(false)
        //
        // The app unregisters us next, and launchd's SIGTERM follows within
        // moments. If it never comes (the unregister failed, or the app died
        // in between), resume enforcing rather than stay disarmed until the
        // next reboot. A later attempt supersedes this one's timer.
        //
        let attempt = self.uninstallAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + self.uninstallGrace) {
            MainActor.assumeIsolated {
                BatteryCapDaemon.resumeAfterAbandonedUninstall(attempt)
            }
        }

        return !self.supported || FirmwareLimiter.disable()
    }

    private static let uninstallGrace: TimeInterval = 60
    private static var uninstallAttempt = 0

    private static func resumeAfterAbandonedUninstall(_ attempt: Int) {
        guard self.uninstalling, attempt == self.uninstallAttempt else {
            return
        }

        log("Still running \(Int(self.uninstallGrace)) s after prepareUninstall; uninstall was abandoned, resuming", level: .warning)
        self.uninstalling = false
        if self.supported {
            LimitEnforcer.enforce(reason: "abandoned uninstall")
        }
    }

    /// Everything needed to diagnose a daemon that the app cannot reach or
    /// that is not enforcing, in one place at the top of each run.
    private static func logStartupReport() {
        let info = ProcessInfo.processInfo
        log("──── batterycapd starting (pid \(info.processIdentifier), uid \(getuid())) ────")
        log("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")), macOS \(info.operatingSystemVersionString)")
        log("Identity: own=\(BCIdentity.ownID) app=\(BCIdentity.appID) machService=\(BCIdentity.daemonMachService)")
        log("Executable: \(Bundle.main.executableURL?.path ?? "unknown")")
        log("Signature: \(CodeSigning.selfInfo()?.description ?? "unavailable")")

        if BCIdentity.ownID.isEmpty || !BCIdentity.isDaemon {
            log("Bundle identifier '\(BCIdentity.ownID)' does not end in '\(BCIdentity.daemonSuffix)'; the embedded Info.plist is missing or wrong", level: .error)
        }

        guard let appBundleURL = self.appBundleURL else {
            log("Not running from inside an app bundle; XPC clients will be refused", level: .error)
            return
        }
        log("App bundle: \(appBundleURL.path)")
        if let app = CodeSigning.info(url: appBundleURL) {
            log("App signature: \(app.description)")
            if app.identifier != BCIdentity.appID {
                log("App identifier \(app.identifier ?? "nil") != expected \(BCIdentity.appID)", level: .error)
            }
        } else {
            log("App signature unreadable", level: .error)
        }
    }

    private static func start() {
        guard SMC.open() else {
            log("Cannot open the SMC; running unsupported", level: .error)
            return
        }
        switch FirmwareLimiter.availability {
        case .available:
            break
        case .blocked:
            log("Firmware charge limiter (bfF0/bfD0/bfE0) present but access refused; running unsupported", level: .error)
            self.blocked = true
            SMC.close()
            return
        case .absent:
            log("No firmware charge limiter (bfF0/bfD0/bfE0); running unsupported", level: .error)
            SMC.close()
            return
        }

        self.supported = true
        LimitEnforcer.enforce(reason: "startup")

        self.powerSourceSubscription = NotifySubscription(
            kIOPSNotifyPowerSource
        ) {
            BatteryCapDaemon.powerSourceChanged()
        }
        if !SystemPower.register(onWake: { BatteryCapDaemon.wokeFromSleep() }) {
            log("Failed to register for system power events", level: .error)
        }
        //
        // Observation only, so the log can show whether Low Power Mode ever
        // changes around our own events. Nothing here writes it.
        //
        self.lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BatteryCapDaemon.log("Low Power Mode changed (by macOS or the user); battery \(BatteryState.summary())")
            }
        }
    }

    private static func powerSourceChanged() {
        guard !self.uninstalling else {
            return
        }

        log("Power source changed; battery \(BatteryState.summary())")
        ChargeToFull.powerSourceChanged()
        LimitEnforcer.enforce(reason: "power source change")
    }

    private static func wokeFromSleep() {
        guard !self.uninstalling else {
            return
        }

        LimitEnforcer.enforce(reason: "wake")
    }

    /// launchd sends SIGTERM when the service is turned off in Login Items,
    /// on uninstall, when the app replaces a stale daemon, and at shutdown.
    ///
    /// Stopping the service means stopping the limit, so every case but a
    /// shutdown or restart returns charging to stock. At shutdown the limit
    /// is simply left as it is: it is a no-op there, because the SMC resets
    /// the limiter at power-off, so a Mac charging while shut down charges
    /// to 100% regardless. It matters across a restart only until we re-arm
    /// it at boot. A replaced daemon's successor re-arms it within a second.
    private static func installTermHandler() {
        ShutdownMonitor.start()
        signal(SIGTERM, SIG_IGN)

        let source = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated {
                if let reason = ShutdownMonitor.reason() {
                    BatteryCapDaemon.log("SIGTERM during shutdown/restart (\(reason)); exiting with the charge limit left in place")
                } else if BatteryCapDaemon.supported {
                    BatteryCapDaemon.log("SIGTERM: service stopped (turned off, uninstalled, or being replaced); restoring stock charging")
                    if !FirmwareLimiter.disable() {
                        BatteryCapDaemon.log("Failed to restore stock charging on exit", level: .error)
                    }
                } else {
                    BatteryCapDaemon.log("SIGTERM received; exiting")
                }
                SMC.close()
                Logger.shutdownLoggingBlocking()
                exit(0)
            }
        }
        source.resume()
        self.termSource = source
    }
}

// MARK: - XPC

internal final class DaemonXPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable, Loggable {
    static let logTag = "[XPCServer]"
    static let shared = DaemonXPCServer()

    private let listener = NSXPCListener(
        machServiceName: BCIdentity.daemonMachService
    )
    private let service = DaemonService()

    /// Only the BatteryCap app that shipped this daemon may talk to us.
    ///
    /// Computed once, at launch: for an ad-hoc build it pins the app's cdhash,
    /// and reading that from disk per connection would let an app binary
    /// swapped in while we run pass as ours. The app reinstalls (and so
    /// relaunches) the daemon whenever it is rebuilt, which re-pins it.
    private let peerRequirement: String? = BatteryCapDaemon.appBundleURL.flatMap {
        CodeSigning.peerRequirement(identifier: BCIdentity.appID, counterpart: $0)
    }

    func start() {
        log("Peer requirement: \(self.peerRequirement ?? "none; every connection will be refused")")
        self.listener.delegate = self
        self.listener.resume()
        log("Listening on \(BCIdentity.daemonMachService)")
    }

    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let pid = connection.processIdentifier
        //
        // The system enforces the requirement against the peer's audit token
        // for every message, not just at connection time; a peer that fails
        // it has its connection invalidated before any call reaches us.
        //
        guard let requirement = self.peerRequirement else {
            log("Rejected connection from pid \(pid): no peer requirement", level: .error)
            return false
        }

        log("Connection from pid \(pid); requiring: \(requirement)")
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(
            with: BCDaemonProtocol.self
        )
        connection.exportedObject = self.service
        connection.invalidationHandler = { @Sendable in
            DaemonXPCServer.log("Connection from pid \(pid) closed")
        }
        connection.resume()
        return true
    }
}

private final class DaemonService: NSObject, BCDaemonProtocol, Sendable, Loggable {
    static let logTag = "[XPCService]"

    func getStatus(reply: @escaping @Sendable (Data?) -> Void) {
        Task { @MainActor in
            let status = BatteryCapDaemon.status()
            DaemonService.log("getStatus → supported=\(status.supported), enforcing=\(status.enforcing), \(status.detail)")
            reply(try? JSONEncoder().encode(status))
        }
    }

    func setChargeToFull(_ enabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in
            let success = BatteryCapDaemon.setChargeToFull(enabled)
            DaemonService.log("setChargeToFull(\(enabled)) → \(success)", level: success ? .info : .error)
            reply(success)
        }
    }

    func prepareUninstall(reply: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in
            let success = BatteryCapDaemon.prepareUninstall()
            DaemonService.log("prepareUninstall → \(success)", level: success ? .info : .error)
            reply(success)
        }
    }

    func setLoggingEnabled(_ enabled: Bool) {
        Task { @MainActor in
            BCLogging.store(enabled)
        }
    }
}
