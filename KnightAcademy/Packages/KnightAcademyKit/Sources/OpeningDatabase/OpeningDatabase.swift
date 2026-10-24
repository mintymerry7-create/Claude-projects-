import Foundation
import ChessCore

public enum OpeningDatabaseError: Error, LocalizedError {
    case resourceMissing
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing: return "The opening database is missing from the app bundle."
        case .corrupt(let s): return "The opening database could not be read: \(s)"
        }
    }
}

/// Filters for the opening explorer.
public struct OpeningFilter: Hashable, Sendable {
    public var query: String = ""
    public var difficulty: Difficulty?
    public var side: PieceColor?
    public var family: String?

    public init(query: String = "", difficulty: Difficulty? = nil, side: PieceColor? = nil, family: String? = nil) {
        self.query = query
        self.difficulty = difficulty
        self.side = side
        self.family = family
    }

    public var isEmpty: Bool { query.isEmpty && difficulty == nil && side == nil && family == nil }
}

/// The bundled, read-only opening library.
public final class OpeningDatabase: @unchecked Sendable {
    public let openings: [Opening]
    private let byID: [String: Opening]

    public init(openings: [Opening]) {
        self.openings = openings
        var map: [String: Opening] = [:]
        for o in openings { map[o.id] = o }
        byID = map
    }

    public static func loadBundled() throws -> OpeningDatabase {
        guard let url = Bundle.module.url(forResource: "openings", withExtension: "json") else {
            throw OpeningDatabaseError.resourceMissing
        }
        return try load(from: Data(contentsOf: url))
    }

    public static func load(from data: Data) throws -> OpeningDatabase {
        do {
            let file = try JSONDecoder().decode(OpeningFile.self, from: data)
            return OpeningDatabase(openings: file.openings)
        } catch {
            throw OpeningDatabaseError.corrupt(error.localizedDescription)
        }
    }

    /// Shared instance loaded lazily from the bundle.
    public static let shared: OpeningDatabase = {
        (try? loadBundled()) ?? OpeningDatabase(openings: [])
    }()

    public func opening(id: String) -> Opening? { byID[id] }

    public var families: [String] {
        var seen: [String] = []
        for o in openings where !seen.contains(o.family) { seen.append(o.family) }
        return seen
    }

    public func openings(inFamily family: String) -> [Opening] {
        openings.filter { $0.family == family }
    }

    public func search(_ filter: OpeningFilter) -> [Opening] {
        let q = Self.fold(filter.query.trimmingCharacters(in: .whitespaces))
        let terms = q.split(separator: " ").map(String.init)
        let matches = openings.filter { o in
            if let d = filter.difficulty, o.difficulty != d { return false }
            if let s = filter.side, o.side != s { return false }
            if let f = filter.family, o.family != f { return false }
            if terms.isEmpty { return true }
            let blob = o.searchBlob
            return terms.allSatisfy { blob.contains($0) }
        }
        guard !terms.isEmpty else { return matches }
        // Stable ranking: ECO / name matches before matches in variation names.
        func score(_ o: Opening) -> Int {
            let name = Self.fold(o.name)
            if Self.fold(o.eco) == q { return 4 }
            if name.hasPrefix(q) { return 3 }
            if terms.allSatisfy({ name.contains($0) }) { return 2 }
            if o.aliases.contains(where: { Self.fold($0).contains(q) }) { return 1 }
            return 0
        }
        return matches.enumerated()
            .sorted { a, b in
                let sa = score(a.element), sb = score(b.element)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Openings whose lines pass through `position` (repetition-key match),
    /// deepest named opening first. Used to name positions in games.
    public func identify(moves: [Move], from start: Position = .start) -> Opening? {
        guard start == .start || start.fen == Position.startFEN else { return nil }
        var p = start
        var keys: [String] = []
        for m in moves {
            guard p.isLegal(m) else { break }
            p.make(m)
            keys.append(p.repetitionKey)
        }
        let reached = Set(keys)
        var best: Opening?
        for o in openings {
            guard let canon = try? Position(fen: o.fen), reached.contains(canon.repetitionKey) else { continue }
            if best == nil || o.canonicalPly > best!.canonicalPly { best = o }
        }
        return best
    }
}
