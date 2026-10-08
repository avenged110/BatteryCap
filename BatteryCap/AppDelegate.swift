// MARK: - AppDelegate.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The app's entry point and menu bar UI: refuses to run on Macs without a battery
// starts the background service, and reports the charge limit's status.

import Cocoa
import IOKit.ps
import notify
import ServiceManagement

/// BatteryCap's only UI: a status item whose menu reports the battery and
/// the daemon, and offers uninstall. Quitting the app leaves the daemon
/// running; the charge limit does not depend on the app.
@main
@MainActor
internal final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, Loggable {
    nonisolated static let logTag = "[App]"

    private var statusItem: NSStatusItem!
    private var menuItems: [NSMenuItem] = []

    private let batteryItem = AppDelegate.infoItem()
    private let limitItem = AppDelegate.infoItem()
    private let bandItem = AppDelegate.infoItem()
    private let detailItem = AppDelegate.infoItem()
    private let chargeToFullHeaderItem = AppDelegate.infoItem()
    private let approveItem = NSMenuItem(
        title: "Allow BatteryCap in Login Items…",
        action: #selector(approve),
        keyEquivalent: ""
    )
    private let retryItem = NSMenuItem(
        title: "Retry Background Service",
        action: #selector(retry),
        keyEquivalent: ""
    )
    private let chargeToFullItem = NSMenuItem(
        title: "Charge to Full Now",
        action: #selector(toggleChargeToFull),
        keyEquivalent: "f"
    )
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private let logsItem = NSMenuItem(
        title: "Reveal Logs in Finder",
        action: #selector(showLogs),
        keyEquivalent: ""
    )

    private var state = DaemonState.checking
    private var isStarting = false
    /// Set for the whole uninstall, so nothing re-registers the daemon
    /// behind it (a menu opening, a failed refresh, the approval poll).
    private var isUninstalling = false
    private var lastLoggedState = ""
    private var powerSourceToken: Int32 = NOTIFY_TOKEN_INVALID
    private var interruptionRecheck: Task<Void, Never>?
    private var approvalPoll: Task<Void, Never>?
    private let loggingObserver = LoggingSwitchObserver()

    static func main() {
        BCLogging.bootstrap()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_: Notification) {
        //
        // Desktops have nothing to limit. Refuse before touching the daemon,
        // login item or menu bar so nothing is left installed behind us.
        //
        guard BatteryInfo.hasInternalBattery() else {
            log("No internal battery found; quitting", level: .error)
            let alert = NSAlert()
            alert.messageText = "BatteryCap requires a Mac with a battery."
            alert.informativeText =
                "BatteryCap limits charging on MacBook models only. This " +
                "Mac has no battery, so there is nothing for it to do."
            alert.addButton(withTitle: "Quit")
            _ = self.runAlert(alert)
            NSApp.terminate(nil)
            return
        }

        self.buildMenu()
        self.observePowerSource()
        self.loggingObserver.start()
        DaemonClient.onInterruption = { [weak self] in
            self?.daemonInterrupted()
        }
        self.render()

        Task {
            await self.startDaemon(promptForApproval: true)
        }
    }

    func applicationWillTerminate(_: Notification) {
        log("Quitting (the background service keeps running)")
        if self.powerSourceToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(self.powerSourceToken)
        }
        DaemonClient.disconnect()
        Logger.shutdownLoggingBlocking()
    }

    // MARK: - Daemon lifecycle

    private func startDaemon(promptForApproval: Bool) async {
        //
        // Launch, a failed refresh, the approval flow and Retry can each
        // ask for this while a run is suspended mid-flight. Two overlapping
        // runs would race each other's unregister/register.
        //
        guard !self.isStarting, !self.isUninstalling else {
            log("Background service check or uninstall already in progress")
            return
        }

        self.isStarting = true
        self.state = .checking
        self.render()
        self.state = await Self.checkDaemon { [weak self] in
            self?.state = .installing
            self?.render()
        }
        self.isStarting = false
        self.render()

        //
        // The approval poll notices the switch being turned on and starts
        // the daemon from there.
        //
        if case .needsApproval = self.state, promptForApproval, !self.isUninstalling,
           self.promptForApproval() {
            DaemonInstaller.openApprovalSettings()
        }
    }

    private static func checkDaemon(willInstall: () -> Void) async -> DaemonState {
        let problems = IntegrityCheck.run()
        if let first = problems.first {
            //
            // Registering a daemon whose plist, identifiers or signatures
            // disagree only produces a service that cannot be reached.
            //
            return .failed("Integrity check failed: \(first)")
        }

        return await DaemonInstaller.ensureRunning(willInstall: willInstall)
    }

    private func refreshDaemonStatus() async {
        switch self.state {
        case .running:
            do {
                let status = try await DaemonClient.status()
                //
                // A check or uninstall that began while this reply was in
                // flight owns the state now; do not overwrite its result.
                //
                guard !self.isStarting, !self.isUninstalling else {
                    return
                }
                self.state = .running(status)
            } catch {
                //
                // The daemon may have been switched off under "Allow in the
                // Background", or restarted. Check it again from the top,
                // which also recognizes a pending approval, rather than
                // settling on "not responding".
                //
                log("Status refresh failed; re-checking the background service", level: .warning)
                await self.startDaemon(promptForApproval: false)
                return
            }
        case .needsApproval:
            //
            // Wait for the switch to be turned on. The status may read
            // notRegistered rather than requiresApproval meanwhile, and
            // re-registering on that would repeat every poll.
            //
            if DaemonInstaller.status == .enabled {
                await self.startDaemon(promptForApproval: false)
                return
            }
        case .checking, .installing, .failed:
            //
            // Failures are retried explicitly via "Retry Background
            // Service", so the reason stays visible until then.
            //
            break
        }

        self.render()
    }

    /// The daemon exited under our connection: turned off in Login Items,
    /// replaced, or crashed. Re-check after a moment, so a replacement has
    /// time to come up; a burst of interruptions yields one check.
    private func daemonInterrupted() {
        self.interruptionRecheck?.cancel()
        self.interruptionRecheck = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }
            self.interruptionRecheck = nil
            await self.refreshDaemonStatus()
        }
    }

    /// While approval is pending there is no daemon to hear from, so the
    /// only way to notice it being turned back on is to look. The check is
    /// a cheap SMAppService status query, made only in this state, with a
    /// generous tolerance so the system can coalesce the wakeups.
    private func updateApprovalPoll() {
        guard case .needsApproval = self.state else {
            self.approvalPoll?.cancel()
            self.approvalPoll = nil
            return
        }
        guard self.approvalPoll == nil else {
            return
        }

        self.approvalPoll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(2))
                guard !Task.isCancelled, case .needsApproval = self.state else {
                    return
                }
                await self.refreshDaemonStatus()
            }
        }
    }

    // MARK: - Actions

    @objc private func approve() {
        log("Menu: Allow in Login Items")
        DaemonInstaller.openApprovalSettings()
    }

    @objc private func retry() {
        log("Menu: Retry Background Service")
        Task {
            await self.startDaemon(promptForApproval: true)
        }
    }

    @objc private func toggleChargeToFull() {
        guard case let .running(status) = self.state else {
            return
        }

        let enable = !status.chargeToFull
        log("Menu: \(self.chargeToFullItem.title) → \(enable)")
        Task {
            do {
                if try await !DaemonClient.setChargeToFull(enable) {
                    log("Daemon declined charge to full", level: .warning)
                }
            } catch {
                log("Charge to full failed: \(DaemonClient.describe(error))", level: .error)
            }
            await self.refreshDaemonStatus()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !LoginItemManager.isEnabled
        log("Menu: Launch at Login → \(enable)")
        LoginItemManager.setEnabled(enable)
    }

    @objc private func showAbout() {
        log("Menu: About")
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showLogs() {
        log("Menu: Show Logs")
        Task {
            // Writes out the buffered lines, so the file shown is current.
            await Logger.shutdownLoggingAwaiting()
            let files = [Logger.safeLogFileURL, BCLogging.daemonLogURL].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    @objc private func uninstall() {
        log("Menu: Uninstall")
        guard !self.isUninstalling else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall BatteryCap?"
        alert.informativeText =
            "This removes the background service and returns charging to " +
            "macOS defaults. Afterwards, move BatteryCap to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard self.runAlert(alert) == .alertFirstButtonReturn else {
            log("Uninstall canceled")
            return
        }

        self.isUninstalling = true
        Task {
            //
            // A check already under way (launch, Retry, the approval
            // poll, or one that began while the alert was up) may still
            // register the daemon. Let it finish first, or it could bring
            // the daemon back right after we unregister it. No new one can
            // start now that isUninstalling is set.
            //
            while self.isStarting {
                try? await Task.sleep(for: .milliseconds(100))
            }
            do {
                let restored = try await DaemonInstaller.uninstall()
                LoginItemManager.setEnabled(false)
                let done = NSAlert()
                done.messageText = "BatteryCap Was Uninstalled"
                done.informativeText = restored ?
                    "Charging is back to macOS defaults. You can now move " +
                    "BatteryCap to the Trash." :
                    "The background service did not confirm it turned the " +
                    "charge limit off, so it may stay in effect until you " +
                    "restart your Mac. You can now move BatteryCap to the Trash."
                _ = self.runAlert(done)
                NSApp.terminate(nil)
            } catch {
                self.isUninstalling = false
                let failed = NSAlert(error: error)
                failed.messageText = "BatteryCap could not be uninstalled."
                _ = self.runAlert(failed)
            }
        }
    }

    // MARK: - Menu

    /// Runs before AppKit measures the menu, so the width fits the titles
    /// shown now. (menuWillOpen comes after the measuring.)
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.statusItem.menu else {
            return
        }
        self.render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.statusItem.menu else {
            return
        }
        Task {
            await self.refreshDaemonStatus()
        }
    }

    /// An NSMenu keeps the width it was last laid out at when its titles
    /// get shorter, so a menu once opened with a long error line would stay
    /// wide. Each opening therefore gets a fresh NSMenu, laid out from
    /// scratch. Deferred to the default run loop mode, which resumes only
    /// once menu tracking has ended and the chosen item's action was sent.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.statusItem.menu else {
            return
        }
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.installFreshMenu()
            }
        }
    }

    private func installFreshMenu() {
        self.statusItem.menu?.removeAllItems()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in self.menuItems {
            menu.addItem(item)
        }
        menu.delegate = self
        self.statusItem.menu = menu
    }

    private func buildMenu() {
        let uninstallItem = NSMenuItem(
            title: "Uninstall BatteryCap…",
            action: #selector(uninstall),
            keyEquivalent: ""
        )
        let aboutItem = NSMenuItem(
            title: "About BatteryCap…",
            action: #selector(showAbout),
            keyEquivalent: "?"
        )
        let quitItem = NSMenuItem(
            title: "Quit BatteryCap",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        for item in [
            self.approveItem, self.retryItem, self.chargeToFullItem,
            self.launchAtLoginItem, self.logsItem, uninstallItem, aboutItem,
        ] {
            item.target = self
        }

        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false
        for item in [self.launchAtLoginItem, .separator(), self.logsItem, uninstallItem] {
            settingsMenu.addItem(item)
        }
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu

        self.menuItems = [
            self.batteryItem,
            self.limitItem,
            self.bandItem,
            self.detailItem,
            self.approveItem,
            self.retryItem,
            .separator(),
            self.chargeToFullHeaderItem,
            self.chargeToFullItem,
            .separator(),
            settingsItem,
            .separator(),
            aboutItem,
            .separator(),
            quitItem,
        ]

        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        self.installFreshMenu()
    }

    /// Re-renders on every power source change, including while the menu is
    /// open (the main queue also runs during menu tracking), so the Charge
    /// to Full item always describes what choosing it will do right now.
    private func observePowerSource() {
        let status = unsafe notify_register_dispatch(
            kIOPSNotifyPowerSource,
            &self.powerSourceToken,
            DispatchQueue.main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        if status != NOTIFY_STATUS_OK {
            log("notify_register_dispatch(power source) failed: \(status)", level: .warning)
        }
    }

    /// Whether System Integrity Protection is enabled, read once from
    /// `csrutil status` (SIP cannot change without a reboot). Only consulted
    /// when the daemon reports the limiter keys as blocked: firmware from
    /// macOS 15.8 onward refuses those keys to processes without a private
    /// Apple entitlement, a gate that SIP being disabled lifts. Anything other
    /// than an explicit "disabled" counts as enabled, including a partially
    /// disabled configuration, which csrutil reports as "enabled (Custom
    /// Configuration)".
    private static let isSIPEnabled: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("csrutil status could not be run: \(error.localizedDescription)", level: .warning)
            return true
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let enabled = !output.contains("status: disabled")
        log("SIP: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        return enabled
    }()

    private func render() {
        Self.setInfo(self.batteryItem, BatteryInfo.summary() ?? "Battery status unavailable")

        var limit: String
        var band: String? = "Hysteresis band: \(BCLimits.lower)–\(BCLimits.upper)%"
        var healthy = false
        var detail: String?
        var chargeToFull: Bool?
        self.approveItem.isHidden = true
        self.retryItem.isHidden = true

        switch self.state {
        case .checking:
            limit = "Connecting to background service…"
            band = nil
            healthy = true

        case .installing:
            limit = "Installing background service…"
            band = nil
            healthy = true

        case .needsApproval:
            limit = "Not active: background service needs approval"
            band = nil
            self.approveItem.isHidden = false

        case let .running(status):
            if !status.supported, status.blocked == true {
                limit = Self.isSIPEnabled ?
                    "SMC key access is blocked. Disable SIP to restore access." :
                    "SMC key access is blocked."
                band = nil
            } else if !status.supported {
                limit = "This Mac's firmware is not supported"
                band = nil
            } else if status.chargeToFull {
                limit = "Charge limit: 100% until unplugged"
                healthy = status.enforcing
                chargeToFull = true
            } else {
                limit = status.enforcing ?
                    "Charge limit: \(BCLimits.upper)%" :
                    "Charge limit: not applied"
                healthy = status.enforcing
                chargeToFull = false
            }
            if !healthy, detail == nil {
                detail = status.detail
            }

        case let .failed(message):
            limit = "Background service unavailable"
            band = nil
            detail = message
            self.retryItem.isHidden = false
        }

        Self.setInfo(self.limitItem, limit)
        Self.setInfo(self.bandItem, band ?? "")
        self.bandItem.isHidden = band == nil
        Self.setInfo(self.detailItem, detail ?? "")
        self.detailItem.isHidden = detail == nil
        self.detailItem.toolTip = detail

        let onPower = BatteryInfo.isOnExternalPower()
        Self.setInfo(self.chargeToFullHeaderItem, "When Connected to Power:")
        self.chargeToFullHeaderItem.isHidden = onPower
        self.chargeToFullItem.title = onPower ? "Charge to Full Now" : "Charge to Full"
        self.chargeToFullItem.isEnabled = chargeToFull != nil
        self.chargeToFullItem.state = chargeToFull == true ? .on : .off
        self.launchAtLoginItem.state = LoginItemManager.isEnabled ? .on : .off
        self.logsItem.isHidden = !BCLogging.isEnabled

        let image = healthy ?
            NSImage(named: "MenuBarIcon") :
            NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "BatteryCap"
            )
        image?.isTemplate = true
        self.statusItem.button?.image = image

        self.updateApprovalPoll()

        let summary = "\(limit)\(detail.map { " — \($0)" } ?? "")"
        if summary != self.lastLoggedState {
            self.lastLoggedState = summary
            log("Menu state: \(summary)", level: healthy ? .info : .warning)
        }
    }

    private static func infoItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Informational rows are drawn in the secondary label color.
    private static func setInfo(_ item: NSMenuItem, _ text: String) {
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    // MARK: - Prompts

    private func promptForApproval() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow BatteryCap Background Service"
        alert.informativeText =
            "BatteryCap needs to run in the background to limit charging. In " +
            "System Settings, enable BatteryCap under \"Allow in the " +
            "Background\"."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        let accepted = self.runAlert(alert) == .alertFirstButtonReturn
        log("Approval prompt: \(accepted ? "Open Settings" : "Later")")
        return accepted
    }

    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}

// MARK: - Battery

internal enum BatteryInfo {
    /// Whether the Mac is drawing from a power adapter. Desktops, which
    /// report no power sources at all, count as on external power.
    static func isOnExternalPower() -> Bool {
        guard let info = unsafe IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = unsafe IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else {
            return true
        }
        return type as String != kIOPSBatteryPowerValue
    }

    static func hasInternalBattery() -> Bool {
        InternalBattery.description() != nil
    }

    /// The charge state line, or nil when the Mac reports no internal battery.
    static func summary() -> String? {
        guard let description = InternalBattery.description() else {
            return nil
        }

        if !InternalBattery.isOnAC(description) {
            return "On battery"
        }
        return description[kIOPSIsChargingKey] as? Bool == true ?
            "Charging" : "On power, not charging"
    }
}

/// Follows the logging switch, which `defaults write` changes from outside
/// the app: UserDefaults' KVO reports those changes, unlike its
/// didChangeNotification. KVO calls in on the writing thread; `lastValue`
/// is only touched on the main actor.
private final class LoggingSwitchObserver: NSObject, @unchecked Sendable {
    private var lastValue = BCLogging.isEnabled
    private var observation: NSKeyValueObservation?

    func start() {
        self.observation = UserDefaults.standard.observe(\.loggingEnabled, options: []) { [self] _, _ in
            self.switchChanged()
        }
    }

    private func switchChanged() {
        Task { @MainActor in
            let enabled = BCLogging.isEnabled
            guard enabled != self.lastValue else {
                return
            }
            self.lastValue = enabled
            BCLogging.announce(enabled)
            DaemonClient.sendLoggingEnabled()
        }
    }
}

private extension UserDefaults {
    /// KVO-observable alias for `BCLogging.enabledKey`; the Objective-C name
    /// must match the defaults key exactly.
    @objc(LoggingEnabled) dynamic var loggingEnabled: Bool {
        self.bool(forKey: BCLogging.enabledKey)
    }
}
