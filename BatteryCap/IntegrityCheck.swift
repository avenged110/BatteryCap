// MARK: - IntegrityCheck.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Verifies at launch that bundle identifiers, the launchd plist, and code
// signatures agree, so a mismatched daemon is never registered.

import Foundation
import ServiceManagement

/// Verifies, at every launch, each link the app ⇄ daemon handshake depends on.
///
/// Every one of these was, at some point, the silent cause of "background
/// service not responding": a bundle identifier changed in the project but
/// not in the launchd plist, a Mach service name left behind, ad-hoc signing
/// meeting code that expected a team. Each check logs ✓ or ✗ with the actual
/// values, so a single look at the log says which link is broken.
@MainActor
internal enum IntegrityCheck: Loggable {
    nonisolated static let logTag = "[Integrity]"

    /// Returns the problems found; empty means every check passed.
    static func run() -> [String] {
        var problems: [String] = []
        func fail(_ message: String) {
            problems.append(message)
            log("✗ \(message)", level: .error)
        }
        func pass(_ message: String) {
            log("✓ \(message)")
        }

        let bundleURL = Bundle.main.bundleURL
        let info = Bundle.main.infoDictionary ?? [:]
        log("──── BatteryCap \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) starting, pid \(getpid()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ────")
        log("Bundle: \(bundleURL.path)")

        // Identity
        if BCIdentity.ownID.isEmpty {
            fail("App has no bundle identifier")
        } else if BCIdentity.isDaemon {
            fail("App bundle identifier \(BCIdentity.ownID) ends in \(BCIdentity.daemonSuffix)")
        } else {
            pass("Identity: app=\(BCIdentity.appID) daemon=\(BCIdentity.daemonID) plist=\(BCIdentity.daemonPlistName)")
        }

        // App signature
        let app = CodeSigning.selfInfo()
        if let app, app.teamID != nil || app.isAdhoc {
            pass("App signature: \(app)")
        } else {
            fail("App is not signed (\(app?.description ?? "no signature"))")
        }
        if let error = CodeSigning.validationError(url: bundleURL) {
            fail("App bundle signature does not validate: \(error)")
        } else {
            pass("App bundle signature validates (including nested code)")
        }

        // Embedded daemon
        let daemonURL = DaemonInstaller.bundledDaemonURL
        if !FileManager.default.isExecutableFile(atPath: daemonURL.path) {
            fail("Daemon executable missing at \(BCIdentity.daemonBundlePath)")
        } else if let daemon = CodeSigning.info(url: daemonURL) {
            if daemon.identifier != BCIdentity.daemonID {
                fail("Daemon identifier is \(daemon.identifier ?? "nil"), expected \(BCIdentity.daemonID)")
            } else if daemon.teamID != app?.teamID || daemon.isAdhoc != app?.isAdhoc {
                fail("Daemon signing (\(daemon)) does not match the app's (\(app?.description ?? "nil"))")
            } else {
                pass("Daemon signature: \(daemon)")
            }
        } else {
            fail("Daemon signature unreadable at \(BCIdentity.daemonBundlePath)")
        }

        // launchd plist
        let plistURL = bundleURL.appending(path: BCIdentity.daemonPlistBundlePath)
        if let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] {
            var plistOK = true
            func expect(_ key: String, _ actual: Any?, _ ok: Bool, _ expected: String) {
                guard !ok else { return }
                plistOK = false
                fail("launchd plist \(key) is \(actual.map { "\($0)" } ?? "missing"), expected \(expected)")
            }

            let label = plist["Label"] as? String
            expect("Label", label, label == BCIdentity.daemonID, BCIdentity.daemonID)

            let program = plist["BundleProgram"] as? String
            expect("BundleProgram", program, program == BCIdentity.daemonBundlePath, BCIdentity.daemonBundlePath)

            let machServices = plist["MachServices"] as? [String: Any]
            expect(
                "MachServices", machServices.map { Array($0.keys) },
                machServices?[BCIdentity.daemonMachService] as? Bool == true,
                "[\(BCIdentity.daemonMachService)]"
            )

            let associated = plist["AssociatedBundleIdentifiers"]
            let associatedIDs = (associated as? [String]) ?? (associated as? String).map { [$0] } ?? []
            expect(
                "AssociatedBundleIdentifiers", associated,
                associatedIDs.contains(BCIdentity.appID), BCIdentity.appID
            )

            if plistOK {
                pass("launchd plist consistent (\(BCIdentity.daemonPlistBundlePath))")
            }
        } else {
            fail("launchd plist missing or unreadable at \(BCIdentity.daemonPlistBundlePath)")
        }

        // Peer pinning
        if let requirement = CodeSigning.peerRequirement(
            identifier: BCIdentity.daemonID,
            counterpart: daemonURL
        ) {
            pass("Daemon peer requirement: \(requirement)")
        } else {
            fail("Cannot build a code signing requirement for the daemon")
        }

        // Informational
        if !bundleURL.path.hasPrefix("/Applications/") {
            log("Note: running from outside /Applications; the background service is tied to this location")
        }
        log("SMAppService status: \(DaemonInstaller.status.name)")
        log(problems.isEmpty ?
            "Integrity check passed" :
            "Integrity check found \(problems.count) problem(s)")

        return problems
    }
}
