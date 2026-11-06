import ChiakiModels
import Foundation

/// A developer preview console card, configured in the developer preview settings.
public struct SampleConsole: Codable, Equatable, Sendable {
    /// The console generation a preview card shows.
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// A PlayStation 5.
        case ps5
        /// A PlayStation 4.
        case ps4

        /// The short name used in the card's sample name and the settings.
        public var title: String {
            switch self {
            case .ps5:
                "PS5"
            case .ps4:
                "PS4"
            }
        }

        /// The console kind the card shows.
        public var kind: RegistrationFlow.ConsoleKind {
            switch self {
            case .ps5:
                .ps5
            case .ps4:
                .ps4
            }
        }
    }

    /// Whether and how a preview card shows a last played title.
    public enum RecentlyPlayed: String, Codable, CaseIterable, Sendable {
        /// The card shows no last played title.
        case none
        /// The card shows the title's plain tile.
        case withoutLayeredArt
        /// The card shows made-up layered key art.
        case withLayeredArt

        /// The setting's label.
        public var title: String {
            switch self {
            case .none:
                "None"
            case .withoutLayeredArt:
                "Without layered art"
            case .withLayeredArt:
                "With layered art"
            }
        }
    }

    /// The generation the card shows.
    public var model = Model.ps5
    /// How the card shows its last played title.
    public var recentlyPlayed = RecentlyPlayed.withLayeredArt

    /// How the card shows its last played title; a PS4 card never shows one.
    public var shownRecentlyPlayed: RecentlyPlayed {
        model == .ps5
            ? recentlyPlayed
            : .none
    }
}

/// The developer preview console cards, stored in user defaults as JSON.
public struct SampleConsoleList: Equatable, RawRepresentable, Sendable {
    /// The most preview cards there can be.
    public static let limit = DeveloperPreviewSetting.mostSampleConsoles
    /// The room names the preview cards are named after, in order.
    public static let rooms = [
        "Bedroom", "Office", "Den", "Loft", "Basement", "Garage",
        "Guest Room", "Kitchen", "Attic", "Workshop", "Library", "Cabin"
    ]
    /// The made-up game names the preview cards show as last played, in order.
    public static let games = [
        "Starfall Run", "Harbor Lights", "Iron Meridian", "Paper Kingdoms", "Low Tide", "Signal North",
        "Glass Orchard", "Ninth Lantern", "Copper Sky", "Quiet Engines", "Salt and Ember", "Hollow Crown"
    ]

    /// The configured cards, at most ``limit``.
    public private(set) var consoles: [SampleConsole]

    /// Creates a list, keeping only the first ``limit`` cards.
    ///
    /// - Parameter consoles: The cards.
    public init(_ consoles: [SampleConsole] = []) {
        self.consoles = Array(consoles.prefix(Self.limit))
    }

    /// Decodes a list from its stored JSON, or an empty list when the JSON is invalid.
    ///
    /// - Parameter rawValue: The stored JSON.
    public init(rawValue: String) {
        let decoded = try? JSONDecoder().decode([SampleConsole].self, from: Data(rawValue.utf8))
        self.init(decoded ?? [])
    }

    /// The list as JSON with sorted keys.
    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(consoles)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Compares the configured cards.
    public static func == (lhs: SampleConsoleList, rhs: SampleConsoleList) -> Bool {
        lhs.consoles == rhs.consoles
    }

    /// Whether no more cards can be added.
    public var isFull: Bool {
        consoles.count >= Self.limit
    }

    /// The list stored in user defaults.
    ///
    /// - Parameter defaults: The defaults to read.
    /// - Returns: The stored list, or an empty one.
    public static func stored(in defaults: UserDefaults) -> SampleConsoleList {
        SampleConsoleList(rawValue: defaults.string(forKey: DeveloperPreviewSetting.sampleConsoles) ?? "")
    }

    /// Stores the list in user defaults.
    ///
    /// - Parameter defaults: The defaults to write.
    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: DeveloperPreviewSetting.sampleConsoles)
    }

    /// The sample name of a card: a room and its generation.
    ///
    /// - Parameter index: The card's index.
    /// - Returns: The name.
    public func name(at index: Int) -> String {
        let room = Self.rooms[index % Self.rooms.count]
        return "\(chiakiLocalized("Sample console room: \(room)")) \(consoles[index].model.title)"
    }

    /// Adds a PS5 card with layered art, unless the list is full.
    public mutating func add() {
        guard !isFull else {
            return
        }
        consoles.append(SampleConsole())
    }

    /// Removes a card; an index out of range does nothing.
    ///
    /// - Parameter index: The card's index.
    public mutating func remove(at index: Int) {
        guard consoles.indices.contains(index) else {
            return
        }
        consoles.remove(at: index)
    }

    /// Changes a card's generation; an index out of range does nothing.
    ///
    /// - Parameters:
    ///   - model: The generation.
    ///   - index: The card's index.
    public mutating func setModel(_ model: SampleConsole.Model, at index: Int) {
        guard consoles.indices.contains(index) else {
            return
        }
        consoles[index].model = model
    }

    /// Changes how a card shows its last played title; an index out of range does nothing.
    ///
    /// - Parameters:
    ///   - recentlyPlayed: How the title is shown.
    ///   - index: The card's index.
    public mutating func setRecentlyPlayed(_ recentlyPlayed: SampleConsole.RecentlyPlayed, at index: Int) {
        guard consoles.indices.contains(index) else {
            return
        }
        consoles[index].recentlyPlayed = recentlyPlayed
    }

    /// The made-up last played title of a card, played a few hours before now for each step down the list.
    ///
    /// - Parameters:
    ///   - index: The card's index.
    ///   - now: The current time.
    /// - Returns: The title, or `nil` when the card shows none.
    public func title(at index: Int, now: Date) -> RecentTitle? {
        guard consoles[index].shownRecentlyPlayed != .none else {
            return nil
        }
        let played = now.addingTimeInterval(-TimeInterval(index + 1) * 3 * 3600)
        return RecentTitle(
            titleID: "SAMPLE\(index)_00", launchID: "", name: Self.games[index % Self.games.count],
            imageURL: "", lastPlayedMs: Timestamp.milliseconds(of: played), recent: true
        )
    }

    /// The shelf cards of the list, in debug builds only.
    ///
    /// - Parameter now: The current time, which dates the made-up titles.
    /// - Returns: Preview cards that start nothing, or none in release builds.
    public func displayed(now: Date = Date()) -> [DisplayedConsole] {
        #if DEBUG
            consoles.indices.map { index in
                DisplayedConsole(
                    target: RegistrationFlow.ConsoleTarget(
                        address: "Developer preview",
                        kind: consoles[index].model.kind,
                        remoteDeviceID: Data([UInt8(index + 2)]),
                        name: name(at: index)
                    ),
                    preview: true,
                    sampleTitle: title(at: index, now: now),
                    sampleRecentlyPlayed: consoles[index].shownRecentlyPlayed
                )
            }
        #else
            []
        #endif
    }
}
