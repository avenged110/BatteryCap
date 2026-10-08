// MARK: - CodeSigning.swift
// Copyright © 2026 avenged110.
// Portions Copyright (C) 2022–2025 Marvin Häuser (Battery Toolkit, https://github.com/mhaeuser/Battery-Toolkit).
// SPDX-License-Identifier: GPL-3.0-only AND BSD-3-Clause
// Adapted from Battery Toolkit and modified by avenged110, 2026. The BSD-3-Clause portions
// are subject to the notice in NOTICES/Battery-Toolkit-BSD-3-Clause.txt.
// Reads code-signing information and builds the requirements the app and
// daemon use to trust each other over XPC.

import Foundation
import Security

/// Signature facts about a piece of code, for peer pinning and diagnostics.
internal struct SignatureInfo: CustomStringConvertible {
    let identifier: String?
    let teamID: String?
    /// The CodeDirectory hash; unique to this exact build.
    let cdhash: Data?
    let isAdhoc: Bool

    var description: String {
        let mode = self.teamID.map { "team \($0)" } ?? (self.isAdhoc ? "ad-hoc" : "unsigned")
        return "id=\(self.identifier ?? "nil") \(mode) cdhash=\(self.cdhash?.hex ?? "nil")"
    }
}

internal enum CodeSigning: Loggable {
    static let logTag = "[CodeSigning]"

    /// Requirement the peer (app or daemon) must satisfy, computed by each side
    /// for the other.
    ///
    /// - Team-signed: the peer must carry `identifier` and be signed by an
    ///   Apple-issued certificate for our own team. The team comes from our own
    ///   signature, so there is nothing to keep in sync by hand.
    /// - Ad-hoc ("Sign to Run Locally"): there is no team to pin, so the peer
    ///   must be the exact binary shipped alongside us in the same app bundle,
    ///   matched by cdhash. Weaker than team pinning (anyone who can rewrite the
    ///   bundle can rewrite both halves), but still rejects every other process.
    ///
    /// Battery Toolkit pins its author's own team ID here instead.
    /// A copy built by anyone else can never pass, so the app reports the
    /// service as not responding while the root daemon runs fine and keeps
    /// writing the SMC.
    ///
    /// Returns nil, failing closed, if we are unsigned or the counterpart cannot
    /// be read.
    static func peerRequirement(identifier: String, counterpart: URL) -> String? {
        let own = self.selfInfo()
        if let teamID = own?.teamID {
            return "anchor apple generic" +
                " and identifier \"\(identifier)\"" +
                " and certificate leaf[subject.OU] = \"\(teamID)\""
        }

        guard own?.isAdhoc == true else {
            log("Refusing peer: own code is not signed (\(own?.description ?? "no signature"))", level: .error)
            return nil
        }
        guard let peer = self.info(url: counterpart), let cdhash = peer.cdhash else {
            log("Refusing peer: cannot read counterpart signature at \(counterpart.path)", level: .error)
            return nil
        }
        guard peer.identifier == identifier else {
            log("Refusing peer: counterpart at \(counterpart.path) is \(peer.description), expected id=\(identifier)", level: .error)
            return nil
        }

        return "cdhash H\"\(cdhash.hex)\""
    }

    static func selfInfo() -> SignatureInfo? {
        var code: SecCode?
        guard unsafe SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard
            unsafe SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            return nil
        }

        return self.info(staticCode: staticCode)
    }

    static func info(url: URL) -> SignatureInfo? {
        var staticCode: SecStaticCode?
        let status = unsafe SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            log("Cannot open code at \(url.path): OSStatus \(status)", level: .warning)
            return nil
        }

        return self.info(staticCode: staticCode)
    }

    /// Verifies the on-disk signature of the code at `url` (and, for a bundle,
    /// everything nested in it). Returns nil when valid, else the reason.
    static func validationError(url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard
            unsafe SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            return "cannot open code"
        }

        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = unsafe SecStaticCodeCheckValidityWithErrors(staticCode, flags, nil, &error)
        guard status == errSecSuccess else {
            let reason = unsafe error?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
            return reason
        }

        return nil
    }

    private static func info(staticCode: SecStaticCode) -> SignatureInfo? {
        var info: CFDictionary?
        let status = unsafe SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess, let info = info as? [String: AnyObject] else {
            log("Failed to retrieve signing information: OSStatus \(status)", level: .warning)
            return nil
        }

        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return SignatureInfo(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            cdhash: info[kSecCodeInfoUnique as String] as? Data,
            isAdhoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        )
    }
}

internal extension Data {
    var hex: String {
        self.map { $0.hex(digits: 2, uppercase: false) }.joined()
    }
}

internal extension FixedWidthInteger where Self: UnsignedInteger {
    /// Zero-padded hex, without `String(format:)` and its C varargs.
    func hex(digits: Int, uppercase: Bool = true) -> String {
        let text = String(self, radix: 16, uppercase: uppercase)
        return String(repeating: "0", count: Swift.max(0, digits - text.count)) + text
    }
}
