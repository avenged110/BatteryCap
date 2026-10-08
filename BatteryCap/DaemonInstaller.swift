// MARK: - DaemonInstaller.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// Registers, updates, and removes the background daemon through SMAppService,
// including the user-approval flow.

import Foundation
import ServiceManagement

internal enum DaemonState {
    case checking
    case installing
    case needsApproval
    case running(BCStatus)
    case failed(String)
}

internal extension SMAppService.Status {
    var name: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(self.rawValue))"
        }
    }
}

/// Registers, updates, and removes the daemon via SMAppService.
///
/// Rebuilding needs no manual step: if the daemon changed, the app's XPC calls
/// fail with 4102 (signature no longer matches), so it unregisters and
/// registers the new one without re-approval. If only the app changed, the
/// running daemon refuses it (it pinned the app's signature at start), and the
/// app reinstalls the daemon the same way after about five seconds of retries.
/// The registration is tied to the app's location, so a copy moved to
/// /Applications must be launched once from there to re-register.
@MainActor
internal enum DaemonInstaller: Loggable {
    nonisolated static let logTag = "[DaemonInstaller]"

    /// The daemon executable shipped inside this app bundle.
    nonisolated static let bundledDaemonURL = Bundle.main.bundleURL.appending(
        path: BCIdentity.daemonBundlePath
    )

    private static var service: SMAppService {
        SMAppService.daemon(plistName: BCIdentity.daemonPlistName)
    }

    static var status: SMAppService.Status {
        self.service.status
    }

    /// Makes sure the daemon bundled with this app is registered and running,
    /// replacing a stale one (e.g., after rebuilding the app).
    /// `willInstall` is called before (re)registering, so the menu can say
    /// so instead of describing a plain connection attempt.
    static func ensureRunning(willInstall: () -> Void) async -> DaemonState {
        let initial = self.service.status
        log("ensureRunning: SMAppService(\(BCIdentity.daemonPlistName)) status \(initial.name)")

        switch initial {
        case .requiresApproval:
            return .needsApproval

        case .enabled:
            break

        default:
            //
            // .notRegistered or .notFound. Despite its name, .notFound is also
            // what SMAppService reports for a daemon that has simply never been
            // registered, so both mean "register it". A genuinely missing plist
            // is caught by IntegrityCheck before we get here.
            //
            // On first install, register() throws "Operation not permitted"
            // even though the status becomes requiresApproval, so the status
            // decides, not the error.
            //
            willInstall()
            if let error = await self.registerSettled() {
                return .failed("Registration failed: \(Self.describe(error))")
            }
            if self.service.status == .requiresApproval {
                return .needsApproval
            }
        }

        guard self.service.status == .enabled else {
            log("Daemon not enabled after registration; status \(self.service.status.name)", level: .error)
            return .failed("Background service not enabled (\(self.service.status.name))")
        }

        if let status = await self.currentDaemonStatus() {
            return .running(status)
        }

        log("Daemon is unreachable or stale; reinstalling", level: .warning)
        willInstall()
        await self.reinstall()
        if self.service.status == .requiresApproval {
            return .needsApproval
        }

        do {
            let status = try await self.retrying { try await DaemonClient.status() }
            log("Daemon running: supported \(status.supported), enforcing \(status.enforcing), \(status.detail)")
            return .running(status)
        } catch {
            return .failed("Not responding: \(DaemonClient.describe(error))")
        }
    }

    /// Opens Login Items settings, where the user approves the service.
    static func openApprovalSettings() {
        log("Opening Login Items settings for approval")
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Returns whether the daemon confirmed the limiter is off. If not (it
    /// was unreachable), unregistering still stops it, but the limiter stays
    /// armed in the SMC until the SMC is next reset (a restart).
    static func uninstall() async throws -> Bool {
        log("Uninstalling")
        let restored = (try? await DaemonClient.prepareUninstall()) ?? false
        log("Daemon restored stock charging: \(restored)", level: restored ? .info : .warning)

        DaemonClient.disconnect()
        do {
            try await self.unregisterService()
            log("Unregistered; status \(self.service.status.name)")
        } catch {
            log("Unregister failed: \(error)", level: .error)
            throw error
        }
        return restored
    }

    /// SMAppService is not Sendable; create it where it is awaited.
    private nonisolated static func unregisterService() async throws {
        try await SMAppService.daemon(
            plistName: BCIdentity.daemonPlistName
        ).unregister()
    }

    /// Returns the error, or nil on success.
    ///
    /// register() also throws when approval is pending, which is not a
    /// failure for our purposes; callers inspect the status afterwards.
    @discardableResult
    private static func register() -> NSError? {
        do {
            try self.service.register()
            log("Registered; status \(self.service.status.name)")
            return nil
        } catch {
            let nsError = error as NSError
            log("register() threw \(self.describe(nsError)); status now \(self.service.status.name)",
                level: self.service.status == .requiresApproval ? .info : .error)
            return nsError
        }
    }

    private static func reinstall() async {
        DaemonClient.disconnect()
        do {
            try await self.unregisterService()
            log("Unregistered stale daemon")
        } catch {
            log("Unregistering stale daemon failed: \(error)", level: .warning)
        }
        //
        // Registering right after unregistering can fail briefly.
        //
        if await self.registerSettled() != nil {
            log("Re-registration did not take; status \(self.service.status.name)", level: .error)
        }
    }

    /// Registers and waits for the status to settle on enabled or
    /// requiresApproval. register() can throw, and the status can lag,
    /// for a moment after a first install or an unregister. Returns the
    /// last error if it never settles, or nil once it has.
    private static func registerSettled() async -> NSError? {
        var lastError: NSError?
        for attempt in 1...6 {
            lastError = self.register()
            for _ in 1...5 {
                let status = self.service.status
                if status == .enabled || status == .requiresApproval {
                    log("Registration settled on attempt \(attempt); status \(status.name)")
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return lastError ?? NSError(
            domain: "BatteryCap", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "status \(self.service.status.name)"]
        )
    }

    private static func describe(_ error: NSError) -> String {
        "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// The running daemon's status, or nil if it is unreachable or is not
    /// the daemon bundled with this app.
    private static func currentDaemonStatus() async -> BCStatus? {
        guard let bundled = CodeSigning.info(url: self.bundledDaemonURL)?.cdhash else {
            log("Cannot read the bundled daemon's signature", level: .error)
            return nil
        }

        let status: BCStatus
        do {
            status = try await self.retrying { try await DaemonClient.status() }
        } catch {
            log("Running daemon unreachable: \(DaemonClient.describe(error))", level: .warning)
            return nil
        }

        guard status.uniqueID == bundled else {
            log("Running daemon cdhash \(status.uniqueID?.hex ?? "nil") != bundled \(bundled.hex)", level: .warning)
            return nil
        }

        log("Running daemon matches the bundled one (\(bundled.hex)): supported \(status.supported), enforcing \(status.enforcing), \(status.detail)")
        return status
    }

    /// The daemon may take a moment to come up after (re)registration. A code
    /// signing mismatch is not transient, so it is not retried.
    private static func retrying<T: Sendable>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?
        for attempt in 1...5 {
            do {
                return try await operation()
            } catch {
                lastError = error
                DaemonClient.disconnect()
                if DaemonClient.isSignatureMismatch(error) {
                    break
                }
                if attempt < 5 {
                    log("Attempt \(attempt) failed; retrying in 1 s")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        throw lastError!
    }
}
