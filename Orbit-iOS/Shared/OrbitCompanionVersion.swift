import Foundation

/// The Windows PC Companion's version as the apps show it.
///
/// The companion numbers its builds the PEP 440 way (see `orbit_updater.py`): "4.6.0" is a stable
/// build, and "4.6.0a1", "4.6.0b1" and "4.6.0rc1" are the first alpha, beta and release candidate of
/// 4.6.0. A PC gets those only with **Beta updates** turned on in the companion's tray menu; its
/// `/api/status` then reports `"updateChannel": "beta"`. The apps only show this: on Apple platforms
/// TestFlight is the beta channel, so there is no channel switch here.
enum OrbitCompanionVersion {
    struct Parts: Equatable {
        /// "4.6.0"
        let release: String
        /// "a", "b" or "rc"; nil for a stable build.
        let stage: String?
        let number: Int
    }

    /// Reads "4.6.0", "v4.6.0" or "4.6.0b1"; nil for anything else (demo text, an empty string).
    static func parts(_ raw: String?) -> Parts? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let stageStart = text.firstIndex(where: { $0.isLetter }) ?? text.endIndex
        let release = String(text[..<stageStart])
        let numbers = release.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count >= 2, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        let tail = text[stageStart...]
        if tail.isEmpty { return Parts(release: release, stage: nil, number: 0) }
        let stage = String(tail.prefix(while: { $0.isLetter })).lowercased()
        let digits = tail.dropFirst(stage.count)
        guard ["a", "b", "rc"].contains(stage), !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit),
              let number = Int(digits) else { return nil }
        return Parts(release: release, stage: stage, number: number)
    }

    /// True for alpha, beta and release-candidate builds.
    static func isPrerelease(_ raw: String?) -> Bool {
        parts(raw)?.stage != nil
    }

    /// "4.6.0b1" → "4.6.0 beta 1", "4.6.0rc2" → "4.6.0 RC 2"; anything else comes back unchanged.
    static func display(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let parts = parts(raw), let stage = parts.stage else { return raw }
        return "\(parts.release) \(stageName(stage)) \(parts.number)"
    }

    /// The short form for tight spaces: "4.6.0b1" → "4.6.0 β1", "4.6.0rc2" → "4.6.0 RC2".
    static func compact(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let parts = parts(raw), let stage = parts.stage else { return raw }
        let mark = stage == "a" ? "α" : stage == "b" ? "β" : "RC"
        return "\(parts.release) \(mark)\(parts.number)"
    }

    /// The `updateChannel` from `/api/status` or the update check: only "beta" is the beta channel.
    static func isBetaChannel(_ channel: String?) -> Bool {
        channel?.trimmingCharacters(in: .whitespaces).lowercased() == "beta"
    }

    private static func stageName(_ stage: String) -> String {
        switch stage {
        case "a": return "alpha"
        case "b": return "beta"
        default: return "RC"
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
