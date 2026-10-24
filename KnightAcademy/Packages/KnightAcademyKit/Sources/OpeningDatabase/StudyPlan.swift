import Foundation
import ChessCore

public enum DepthPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case beginner, intermediate, advanced, custom

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    public var blurb: String {
        switch self {
        case .beginner: return "Main line only, first moves, with the basic principles explained."
        case .intermediate: return "Main line plus the important replies, common traps and typical positions."
        case .advanced: return "Deep theory: many branches, move-order nuances, rare sidelines and traps."
        case .custom: return "Choose the depth, number of variations and what to include."
        }
    }
}

/// How deeply to study an opening. A ply is one move by either side.
public struct DepthSettings: Codable, Hashable, Sendable {
    public var preset: DepthPreset
    public var maxPly: Int
    /// Total number of lines in the plan, including the main line.
    public var maxVariations: Int
    public var includeRareSidelines: Bool
    public var prioritizeTraps: Bool
    public var includeEngineAnalysis: Bool

    public init(preset: DepthPreset, maxPly: Int, maxVariations: Int, includeRareSidelines: Bool,
                prioritizeTraps: Bool, includeEngineAnalysis: Bool) {
        self.preset = preset
        self.maxPly = max(2, min(60, maxPly))
        self.maxVariations = max(1, min(60, maxVariations))
        self.includeRareSidelines = includeRareSidelines
        self.prioritizeTraps = prioritizeTraps
        self.includeEngineAnalysis = includeEngineAnalysis
    }

    public static let beginner = DepthSettings(preset: .beginner, maxPly: 8, maxVariations: 1,
                                               includeRareSidelines: false, prioritizeTraps: false, includeEngineAnalysis: false)
    public static let intermediate = DepthSettings(preset: .intermediate, maxPly: 16, maxVariations: 5,
                                                   includeRareSidelines: false, prioritizeTraps: true, includeEngineAnalysis: false)
    public static let advanced = DepthSettings(preset: .advanced, maxPly: 30, maxVariations: 14,
                                               includeRareSidelines: true, prioritizeTraps: true, includeEngineAnalysis: true)

    public static func forPreset(_ p: DepthPreset) -> DepthSettings {
        switch p {
        case .beginner: return .beginner
        case .intermediate: return .intermediate
        case .advanced: return .advanced
        case .custom: var s = DepthSettings.intermediate; s.preset = .custom; return s
        }
    }
}

/// A move the learner must produce: in the position before `nodeID`, the
/// learner's side plays the node's move.
public struct StudyCard: Hashable, Sendable, Identifiable {
    /// Stable key independent of the plan: position + move.
    public let id: String
    public let nodeID: Int
    public let move: Move
    public let san: String
    public let positionKey: String
    public let lineIDs: [String]
}

/// A line selected for study, truncated to the chosen depth.
public struct StudyLine: Hashable, Sendable, Identifiable {
    public let line: OpeningLine
    public let moves: [String]
    public let leafNodeID: Int
    public var id: String { line.id }
}

/// The study tree generated from an opening and depth settings. Different
/// settings produce genuinely different trees (lines and depth).
public struct StudyPlan: Sendable {
    public let opening: Opening
    public let settings: DepthSettings
    public let learnerSide: PieceColor
    public let tree: MoveTree
    public let lines: [StudyLine]
    /// node id -> annotation
    public let notes: [Int: String]
    /// node id -> ids of lines passing through it
    public let nodeLines: [Int: [String]]

    /// Moves the learner must know, in tree order (main line first).
    public let cards: [StudyCard]

    init(opening: Opening, settings: DepthSettings, learnerSide: PieceColor, tree: MoveTree,
         lines: [StudyLine], notes: [Int: String], nodeLines: [Int: [String]]) {
        self.opening = opening
        self.settings = settings
        self.learnerSide = learnerSide
        self.tree = tree
        self.lines = lines
        self.notes = notes
        self.nodeLines = nodeLines
        var out: [StudyCard] = []
        var seen = Set<String>()
        func walk(_ id: Int, _ pos: Position) {
            for c in tree[id].children {
                guard let m = tree[c].move else { continue }
                if pos.sideToMove == learnerSide {
                    let key = StudyPlan.cardKey(position: pos, move: m)
                    if seen.insert(key).inserted {
                        out.append(StudyCard(id: key, nodeID: c, move: m, san: tree[c].san,
                                             positionKey: pos.repetitionKey, lineIDs: nodeLines[c] ?? []))
                    }
                }
                var next = pos
                next.make(m)
                walk(c, next)
            }
        }
        walk(MoveTree.rootID, tree.startPosition)
        cards = out
    }

    public static func cardKey(position: Position, move: Move) -> String {
        "\(position.repetitionKey)|\(move.uci)"
    }

    /// Cards that belong to one line.
    public func cards(forLine lineID: String) -> [StudyCard] {
        cards.filter { $0.lineIDs.contains(lineID) }
    }

    /// Expected moves for the learner from a node (all branches in the plan are accepted).
    public func expectedMoves(after nodeID: Int) -> [Move] {
        tree[nodeID].children.compactMap { tree[$0].move }
    }

    /// Learning-time estimate derived from the number of moves to memorise:
    /// about 25 seconds per new move on the first pass.
    public var estimatedMinutes: Int {
        max(1, Int((Double(cards.count) * 25.0 / 60.0).rounded(.up)))
    }

    public var maxDepthPlies: Int { tree.maxPly }
}

public enum StudyPlanBuilder {

    /// Builds the study tree:
    /// 1. the main line is always included first;
    /// 2. traps come next when prioritised (kept whole so the punchline is shown),
    ///    otherwise after key variations and only if they fit the depth;
    /// 3. key variations, then — if enabled — rare sidelines, preferring those
    ///    that branch late from the main line;
    /// 4. at most `maxVariations` lines, each truncated to `maxPly`.
    public static func build(opening: Opening, settings: DepthSettings, side: PieceColor? = nil) -> StudyPlan {
        let main = opening.mainLine
        var ordered: [OpeningLine] = [main]
        let traps = opening.traps
        let keys = opening.keyVariations
        if settings.prioritizeTraps { ordered += traps }
        ordered += keys
        if !settings.prioritizeTraps && settings.maxVariations > 1 {
            ordered += traps.filter { $0.plyCount <= settings.maxPly }
        }
        if settings.includeRareSidelines {
            let mainMoves = main.moves
            ordered += opening.sidelines.sorted { a, b in
                let pa = commonPrefix(a.moves, mainMoves), pb = commonPrefix(b.moves, mainMoves)
                if pa != pb { return pa > pb }
                if a.plyCount != b.plyCount { return a.plyCount > b.plyCount }
                return a.id < b.id
            }
        }

        var tree = MoveTree()
        var lines: [StudyLine] = []
        var notes: [Int: String] = [:]
        var nodeLines: [Int: [String]] = [:]
        var usedSequences = Set<[String]>()

        for line in ordered {
            guard lines.count < settings.maxVariations else { break }
            let keepWhole = line.kind == .trap && settings.prioritizeTraps
            let moves = keepWhole ? line.moves : Array(line.moves.prefix(settings.maxPly))
            guard !moves.isEmpty, !usedSequences.contains(moves) else { continue }
            // A truncated line fully contained in an existing one adds nothing.
            if lines.contains(where: { Array($0.moves.prefix(moves.count)) == moves }) { continue }
            var cur = MoveTree.rootID
            var ok = true
            for (i, san) in moves.enumerated() {
                guard let id = try? tree.add(san: san, after: cur) else { ok = false; break }
                cur = id
                nodeLines[id, default: []].append(line.id)
                if notes[id] == nil, let n = line.note(atPly: i + 1) { notes[id] = n }
            }
            guard ok else { continue }
            usedSequences.insert(moves)
            lines.append(StudyLine(line: line, moves: moves, leafNodeID: cur))
        }

        return StudyPlan(opening: opening, settings: settings, learnerSide: side ?? opening.side,
                         tree: tree, lines: lines, notes: notes, nodeLines: nodeLines)
    }

    static func commonPrefix(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }
}
