// MARK: - BCLogging.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Configures DebugLogKit for whichever process is running, the app or the
// daemon, and sets where each one's log file goes.

import Foundation
import os

/// Wires DebugLogKit up for whichever process this is.
///
/// - App:    ~/Library/Logs/BatteryCap/BatteryCap.log
/// - Daemon: /Library/Logs/BatteryCap/batterycapd.log (root-owned, world-readable)
///
/// Every line is mirrored to the unified log under subsystem `$(BC_APP_ID)`, so
/// `log stream --predicate 'subsystem == "com.BatteryCap"'` shows both processes
/// live.
///
/// One switch covers both processes, off by default:
/// `defaults write <app id> LoggingEnabled -bool YES`
/// The app owns it and passes it to the daemon on every connection and on
/// every change; the daemon keeps the last value it was given in its own
/// defaults, so it logs (or not) the same way before the app next connects.
internal enum BCLogging: Loggable {
    static let logTag = "[Logging]"
    static let enabledKey = "LoggingEnabled"
    static let daemonLogURL = URL(
        fileURLWithPath: "/Library/Logs/BatteryCap/batterycapd.log"
    )

    static func bootstrap() {
        let isDaemon = BCIdentity.isDaemon
        let destination: LogDestination = isDaemon ?
            .custom { BCLogging.daemonLogURL.deletingLastPathComponent() } :
            .userLibraryLogs(subdirectory: "BatteryCap")

        Logger.bootstrap(.init(
            fileName: isDaemon ? "batterycapd.log" : "BatteryCap.log",
            destination: destination,
            isEnabled: { BCLogging.isEnabled },
            maxFileSizeBytes: 2 * 1024 * 1024,
            // Lines unflushed at a crash are not lost: every line reaches the
            // unified log immediately through the sink below.
            timestampFormat: "yyyy-MM-dd'T'HH:mm:ss.SSS",
            // Off: the unified log sink already shows every line in Xcode's
            // console, so echoing to stdout would print each one twice.
            echoToConsole: false,
            includesLevelInOutput: true,
            sinks: [UnifiedLogSink(category: isDaemon ? "daemon" : "app")]
        ))
        Logger.prepareLogDirectory()
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Daemon: stores the value the app passed along. The app's own value
    /// is written by `defaults write`, so it only calls `announce`.
    static func store(_ enabled: Bool) {
        guard enabled != self.isEnabled else {
            return
        }
        if !enabled {
            self.announce(false)
        }
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            self.announce(true)
        }
    }

    /// Logs a change of the switch. The "off" line is forced through: in the
    /// app, the value is already off by the time this runs.
    static func announce(_ enabled: Bool) {
        if enabled {
            Logger.prepareLogDirectory()
            log("Logging on")
        } else {
            Logger.logForced("Logging off", cName: logTag)
        }
    }
}

/// Mirrors DebugLogKit lines into the unified log.
private struct UnifiedLogSink: LogSink {
    private let osLogger: os.Logger

    init(category: String) {
        self.osLogger = os.Logger(subsystem: BCIdentity.appID, category: category)
    }

    func receive(line: String, level: LogLevel, category _: String?, occurredAt _: Date) {
        let type: OSLogType = level >= .error ? .error : .default
        let message = line.trimmingCharacters(in: .newlines)
        self.osLogger.log(level: type, "\(message, privacy: .public)")
    }
}
