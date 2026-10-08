// MARK: - DaemonClient.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// The app's XPC client for the privileged daemon, with signature pinning and
// timeouts on every request.

import Foundation

internal enum DaemonClientError: Error, CustomStringConvertible {
    case noPeerRequirement
    case timeout
    case malformedReply

    var description: String {
        switch self {
        case .noPeerRequirement:
            "cannot build a code signing requirement for the daemon (see [CodeSigning] lines)"
        case .timeout:
            "no reply within the timeout"
        case .malformedReply:
            "reply could not be decoded"
        }
    }
}

/// XPC client for the privileged daemon.
@MainActor
internal enum DaemonClient: Loggable {
    nonisolated static let logTag = "[DaemonClient]"

    private static let timeout: TimeInterval = 5

    private static var connection: NSXPCConnection?

    /// Called on the main actor when the daemon exits under an open
    /// connection (turned off, replaced, or crashed). XPC reports this at
    /// once, so the app learns of it without polling.
    static var onInterruption: (@MainActor () -> Void)?

    static func status() async throws -> BCStatus {
        let data: Data? = try await self.call("getStatus") { daemon, reply in
            daemon.getStatus(reply: reply)
        }
        guard
            let data,
            let status = try? JSONDecoder().decode(BCStatus.self, from: data)
        else {
            log("getStatus: undecodable reply (\(data?.count ?? 0) bytes)", level: .error)
            throw DaemonClientError.malformedReply
        }

        return status
    }

    static func setChargeToFull(_ enabled: Bool) async throws -> Bool {
        try await self.call("setChargeToFull") { daemon, reply in
            daemon.setChargeToFull(enabled, reply: reply)
        }
    }

    static func prepareUninstall() async throws -> Bool {
        try await self.call("prepareUninstall") { daemon, reply in
            daemon.prepareUninstall(reply: reply)
        }
    }

    /// One-way: logging is not worth failing or retrying anything over.
    static func sendLoggingEnabled() {
        guard let connection = try? self.connect() else {
            return
        }
        let proxy = connection.remoteObjectProxy as? any BCDaemonProtocol
        proxy?.setLoggingEnabled(BCLogging.isEnabled)
    }

    static func disconnect() {
        guard let connection = self.connection else {
            return
        }

        self.connection = nil
        connection.invalidate()
        log("Disconnected")
    }

    /// Whether `error` means the daemon answered but is not the one bundled
    /// with this app (e.g., a stale daemon after a rebuild). Retrying cannot
    /// help; only reinstalling can.
    static func isSignatureMismatch(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSXPCConnectionCodeSigningRequirementFailure
    }

    /// Describes an XPC failure precisely enough to tell the cases apart:
    /// NSCocoaErrorDomain 4102 = the daemon failed our code signing
    /// requirement (stale or foreign daemon); 4099 = the Mach service could
    /// not be looked up (daemon not loaded); 4097 = the daemon exited mid-call.
    static func describe(_ error: any Error) -> String {
        if let clientError = error as? DaemonClientError {
            return clientError.description
        }

        let nsError = error as NSError
        var text = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let debug = nsError.userInfo["NSDebugDescription"] as? String {
            text += " — \(debug)"
        }
        return text
    }

    private static func connect() throws -> NSXPCConnection {
        if let connection = self.connection {
            return connection
        }
        //
        // Only talk to the daemon shipped inside this app bundle. Without this,
        // anything able to register the Mach service name could impersonate it.
        //
        guard
            let requirement = CodeSigning.peerRequirement(
                identifier: BCIdentity.daemonID,
                counterpart: DaemonInstaller.bundledDaemonURL
            )
        else {
            log("Not connecting: \(DaemonClientError.noPeerRequirement)", level: .error)
            throw DaemonClientError.noPeerRequirement
        }

        let connection = NSXPCConnection(
            machServiceName: BCIdentity.daemonMachService,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: (any BCDaemonProtocol).self
        )
        connection.setCodeSigningRequirement(requirement)
        //
        // XPC invokes these handlers on its own queues. They must be @Sendable:
        // a closure written inside this @MainActor type is otherwise inferred
        // to be main-actor isolated, and Swift traps when XPC calls it from a
        // background queue.
        //
        connection.interruptionHandler = { @Sendable in
            DaemonClient.log("Connection interrupted (daemon exited or crashed)", level: .warning)
            Task { @MainActor in
                DaemonClient.onInterruption?()
            }
        }
        //
        // Clear only this connection: by the time the hop lands, disconnect()
        // may already have replaced it with a new one that must survive.
        //
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable in
            DaemonClient.log("Connection invalidated")
            Task { @MainActor in
                if let current = DaemonClient.connection, ObjectIdentifier(current) == id {
                    DaemonClient.connection = nil
                }
            }
        }
        connection.resume()
        // Each new connection may be a freshly started daemon.
        (connection.remoteObjectProxy as? any BCDaemonProtocol)?
            .setLoggingEnabled(BCLogging.isEnabled)

        log("Connecting to \(BCIdentity.daemonMachService); requiring: \(requirement)")
        self.connection = connection
        return connection
    }

    private static func call<T: Sendable>(
        _ name: String,
        _ body: (any BCDaemonProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let connection = try self.connect()
        let started = Date()

        do {
            let value: T = try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)

                // @Sendable for the same reason as the connection handlers.
                // This one fires whenever the daemon fails our code signing
                // requirement, e.g. a stale daemon after a rebuild.
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                    once.resume(throwing: error)
                } as! any BCDaemonProtocol

                body(proxy) { value in
                    once.resume(returning: value)
                }

                DispatchQueue.global().asyncAfter(
                    deadline: .now() + self.timeout
                ) { @Sendable in
                    once.resume(throwing: DaemonClientError.timeout)
                }
            }

            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("\(name) OK (\(ms) ms)")
            return value
        } catch {
            log("\(name) failed: \(self.describe(error))", level: .error)
            throw error
        }
    }
}

/// Resumes a continuation at most once; reply, error, and timeout race.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        self.take()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        self.take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        self.lock.lock()
        defer { self.lock.unlock() }

        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}
