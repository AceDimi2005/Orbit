import Foundation

// What Orbit Companion 5 adds to its API. Every type decodes leniently: optional fields stay
// optional, so older or newer companions never break an app (older ones answer 404 instead).

/// `GET /api/capabilities` (HTTPS): what this companion can do and what this device may do.
struct OrbitCapabilities: Codable, Equatable {
    var apiVersion: Int
    var agentVersion: String
    var scopes: [String]
    var features: [String]
    var deviceID: String?
    var deviceName: String?

    func has(_ feature: String) -> Bool { features.contains(feature) }
    func may(_ scope: String) -> Bool { scopes.contains(scope) }
}

// MARK: - Devices

/// A device that may use the PC (`GET /api/devices`, admin scope).
struct OrbitDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var platform: String?
    var model: String?
    var scopes: [String]
    var createdAt: String?
    var lastSeenAt: String?
    var lastAddress: String?
    var legacy: Bool
    var current: Bool

    var lastSeen: Date? { lastSeenAt.flatMap(OrbitCompanionDates.parse) }

    /// "iPhone", "Mac", "Apple TV"…, or "Older Orbit apps" for the pre-5 shared token.
    var kind: String {
        if legacy { return "Apps paired before Orbit Companion 5" }
        switch platform?.lowercased() {
        case "ios": return model ?? "iPhone"
        case "ipados": return model ?? "iPad"
        case "macos": return model ?? "Mac"
        case "tvos": return "Apple TV"
        case "watchos": return "Apple Watch"
        default: return model ?? "Device"
        }
    }

    var symbol: String {
        if legacy { return "clock.arrow.circlepath" }
        switch platform?.lowercased() {
        case "ios": return "iphone"
        case "ipados": return "ipad"
        case "macos": return "laptopcomputer"
        case "tvos": return "appletv"
        case "watchos": return "applewatch"
        default: return "desktopcomputer"
        }
    }
}

struct OrbitDeviceList: Codable {
    var devices: [OrbitDevice]
    var scopes: [String]?
    var scopeDescriptions: [String: String]?
}

// MARK: - Power

/// `GET /api/power`: a pending timer or countdown, keep-awake, and the Windows power plans.
struct OrbitPowerState: Codable, Equatable {
    var timer: OrbitPowerTimer?
    var keepAwake: OrbitKeepAwake?
    var plans: [OrbitPowerPlan]
    var supports: Supports?

    struct Supports: Codable, Equatable {
        var hibernate: Bool?
        var displayOff: Bool?
    }

    var activePlan: OrbitPowerPlan? { plans.first(where: \.active) }
}

struct OrbitPowerTimer: Codable, Equatable, Identifiable {
    var id: String
    /// shutdown, restart, sleep, hibernate, signout or displayOff.
    var action: String
    /// "time" or "gameExits".
    var when: String
    /// scheduled, waitingForGame or countdown (Windows' own 30-second shutdown warning).
    var state: String
    var firesAt: String?
    var remainingSeconds: Int?
    var createdAt: String?
    var requestedBy: String?
    var game: String?

    var actionTitle: String {
        switch action {
        case "shutdown": return "Shut down"
        case "restart": return "Restart"
        case "sleep": return "Sleep"
        case "hibernate": return "Hibernate"
        case "signout": return "Sign out"
        case "displayOff": return "Turn off the display"
        default: return action.capitalized
        }
    }

    /// One line for banners and menus: "Shutting down in 0:27", "Sleep in 42 min",
    /// "Shut down when Cyberpunk 2077 closes".
    func summary(remaining: Int?) -> String {
        if when == "gameExits" || state == "waitingForGame" {
            return "\(actionTitle) when \(game ?? "the game") closes"
        }
        guard let remaining else { return "\(actionTitle) soon" }
        if state == "countdown" {
            let verb: String
            switch action {
            case "restart": verb = "Restarting"
            case "sleep": verb = "Going to sleep"
            default: verb = "Shutting down"
            }
            return "\(verb) in \(OrbitCompanionDates.clock(remaining))"
        }
        return "\(actionTitle) in \(OrbitCompanionDates.span(remaining))"
    }
}

/// Windows' own 30-second warning after Shut Down or Restart (Orbit Companion 5). The PC
/// doesn't list it in `GET /api/power`, so the app that asked counts it down itself.
struct OrbitLocalCountdown: Equatable {
    var action: String
    var until: Date

    var isRunning: Bool { until > Date() }

    func summary(at date: Date = Date()) -> String {
        let seconds = max(0, Int(until.timeIntervalSince(date).rounded(.up)))
        return "\(action == "restart" ? "Restarting" : "Shutting down") in \(OrbitCompanionDates.clock(seconds))"
    }
}

struct OrbitKeepAwake: Codable, Equatable {
    var since: String?
    var until: String?
    var display: Bool
    var requestedBy: String?
    var remainingSeconds: Int?

    func summary(remaining: Int?) -> String {
        guard let remaining else { return display ? "Kept awake with the display on" : "Kept awake" }
        return "Kept awake for \(OrbitCompanionDates.span(remaining))"
    }
}

struct OrbitPowerPlan: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var active: Bool
}

/// What the power menus offer.
enum OrbitPowerTimerChoice: CaseIterable, Identifiable {
    case minutes15, minutes30, hour1, hours2, gameExits

    var id: Self { self }
    var title: String {
        switch self {
        case .minutes15: return "In 15 Minutes"
        case .minutes30: return "In 30 Minutes"
        case .hour1: return "In 1 Hour"
        case .hours2: return "In 2 Hours"
        case .gameExits: return "When the Game Closes"
        }
    }
    var seconds: Int? {
        switch self {
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .hour1: return 3600
        case .hours2: return 7200
        case .gameExits: return nil
        }
    }

    /// The request body for `POST /api/power/timer`.
    func body(action: String) -> OrbitPowerTimerRequest {
        OrbitPowerTimerRequest(action: action, inSeconds: seconds, when: seconds == nil ? "gameExits" : nil)
    }
}

struct OrbitPowerTimerRequest: Encodable {
    var action: String
    var inSeconds: Int?
    var when: String?
}

struct OrbitKeepAwakeRequest: Encodable {
    var minutes: Int?
    var display: Bool
}

struct OrbitPowerPlanRequest: Encodable { var id: String }

// MARK: - Library

/// `GET /api/library`: games installed through Steam, Epic and GOG.
struct OrbitLibrary: Codable, Equatable {
    var scannedAt: String?
    var stores: [Store]
    var games: [OrbitLibraryGame]

    struct Store: Codable, Equatable {
        var store: String
        var available: Bool
        var count: Int
    }
}

struct OrbitLibraryGame: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var store: String
    var title: String
    var steamAppID: Int?
    var sizeBytes: Int64?
    var lastPlayedAt: String?
    var isRunning: Bool
    var coverID: String?
    var coverURL: String?
    var iconID: String?
    /// The Sunshine app that starts this game, when there is one: it can be streamed.
    var sunshineApp: String?
    var canLaunch: Bool

    var storeName: String {
        switch store {
        case "steam": return "Steam"
        case "epic": return "Epic Games"
        case "gog": return "GOG"
        default: return store.capitalized
        }
    }
    var lastPlayed: Date? { lastPlayedAt.flatMap(OrbitCompanionDates.parse) }
}

// MARK: - Activity

/// `GET /api/activity` (admin): what devices did on the PC, newest first.
struct OrbitActivityPage: Codable {
    var entries: [OrbitActivityEntry]
    var nextBefore: Int?
    var categories: [String]?
}

struct OrbitActivityEntry: Codable, Identifiable, Equatable {
    var id: Int
    var at: String
    var deviceID: String?
    var deviceName: String?
    var category: String
    var action: String
    var summary: String
    /// ok, denied or error.
    var result: String
    var status: Int?

    var date: Date? { OrbitCompanionDates.parse(at) }
}

// MARK: - Audio additions

/// `GET /api/audio/microphone`.
struct OrbitMicrophoneState: Codable, Equatable {
    var available: Bool
    var muted: Bool
    var devices: [Device]?

    struct Device: Codable, Equatable { var id: String; var name: String }
}

struct OrbitMicrophoneRequest: Encodable { var muted: Bool }
struct OrbitDefaultOutputRequest: Encodable { var deviceID: String }
struct OrbitDeviceRenameRequest: Encodable { var name: String }

// MARK: - Dates

enum OrbitCompanionDates {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    /// "0:27", "4:05".
    static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    /// "42 min", "1 h 5 min", "less than a minute".
    static func span(_ seconds: Int) -> String {
        let minutes = Int((Double(max(0, seconds)) / 60).rounded(.up))
        if seconds < 60 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// What this device tells the PC about itself when pairing, so the PC's device list and
/// its PIN dialog can say "Dimitrie's iPhone · iPhone" rather than a bare name.
enum OrbitDeviceIdentity {
    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return isPad ? "iPadOS" : "iOS"
        #endif
    }

    static var model: String {
        #if os(macOS)
        return "Mac"
        #elseif os(tvOS)
        return "Apple TV"
        #elseif os(watchOS)
        return "Apple Watch"
        #else
        return isPad ? "iPad" : "iPhone"
        #endif
    }

    #if os(iOS)
    /// From the hardware model ("iPad14,1"), so it works off the main thread.
    private static var isPad: Bool { machine.hasPrefix("iPad") }

    private static var machine: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
    #endif
}
