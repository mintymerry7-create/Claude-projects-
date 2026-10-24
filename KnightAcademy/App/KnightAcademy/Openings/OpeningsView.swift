import SwiftUI
import ChessCore
import OpeningDatabase
import Learning
import AppFeatures

/// The opening explorer: search, filters and the library grouped by family.
struct OpeningsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var difficulty: Difficulty?
    @State private var side: PieceColor?
    @State private var family: String?
    @State private var status: CardStatus?

    private var filter: OpeningFilter {
        OpeningFilter(query: query, difficulty: difficulty, side: side, family: family)
    }

    private var results: [Opening] {
        let base = model.db.search(filter)
        guard let status else { return base }
        return base.filter { ProgressStats.learningStatus(of: $0, in: model.data) == status }
    }

    private var isFiltered: Bool {
        !query.isEmpty || difficulty != nil || side != nil || family != nil || status != nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: KA.Spacing.m) {
                HStack(spacing: 8) {
                    filterMenu
                    Spacer()
                    Text("\(results.count)/\(model.db.openings.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(KA.Palette.textSecondary)
                }
                if !isFiltered { recommendations }
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(results) { o in
                    OpeningCard(opening: o)
                }
            }
            .padding(.horizontal, KA.Spacing.l)
            .padding(.bottom, KA.Spacing.xl)
        }
        .screenBackground()
        .navigationTitle("Openings")
        .searchable(text: $query, prompt: "Search openings, aliases, ECO")
    }

    @ViewBuilder private var recommendations: some View {
        let recs = model.recommendedOpenings
        if !recs.isEmpty {
            Text("Recommended for you").font(.headline).padding(.top, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recs, id: \.title) { rec in
                        if case .opening(let id) = rec.target, let o = model.db.opening(id: id) {
                            NavigationLink(value: Route.opening(id)) {
                                HStack(spacing: 10) {
                                    BoardThumbnail(position: o.thumbnailPosition, orientation: o.side, theme: model.settings.boardTheme)
                                        .frame(width: 54, height: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(o.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(rec.reason).font(.caption).foregroundStyle(KA.Palette.textSecondary).lineLimit(2)
                                    }
                                    .frame(width: 170, alignment: .leading)
                                }
                                .padding(10)
                                .background(KA.Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("All openings").font(.headline).padding(.top, 4)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Side", selection: $side) {
                Text("Any side").tag(PieceColor?.none)
                Text("White").tag(PieceColor?.some(.white))
                Text("Black").tag(PieceColor?.some(.black))
            }
            Picker("Difficulty", selection: $difficulty) {
                Text("Any level").tag(Difficulty?.none)
                ForEach(Difficulty.allCases) { d in Text(d.displayName).tag(Difficulty?.some(d)) }
            }
            Picker("Family", selection: $family) {
                Text("All families").tag(String?.none)
                ForEach(model.db.families, id: \.self) { f in Text(f).tag(String?.some(f)) }
            }
            Picker("Status", selection: $status) {
                Text("Any status").tag(CardStatus?.none)
                ForEach(CardStatus.allCases, id: \.self) { s in Text(s == .new ? "Not started" : s.displayName).tag(CardStatus?.some(s)) }
            }
            if isFiltered {
                Button("Clear filters", role: .destructive) { query = ""; difficulty = nil; side = nil; family = nil; status = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(activeFilterSummary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isFiltered ? Color.white : Color.primary)
            .background(isFiltered ? KA.Palette.progress : KA.Palette.surfaceElevated, in: Capsule())
        }
        .accessibilityLabel("Filters")
    }

    private var activeFilterSummary: String {
        let parts = [side?.displayName, difficulty?.displayName, family, status.map { $0 == .new ? "Not started" : $0.displayName }].compactMap { $0 }
        return parts.isEmpty ? "Filters" : parts.joined(separator: " · ")
    }
}

struct OpeningRow: View {
    let opening: Opening
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let course = model.course(for: opening.id), let plan = model.plan(for: opening.id) {
                ProgressRing(progress: ProgressStats.mastery(cardIDs: plan.cards.map(\.id), in: model.data),
                             lineWidth: 4, showsLabel: false)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(course.openingID.isEmpty)
            } else {
                SideBadge(isWhite: opening.side == .white).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(opening.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(opening.eco).font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary)
                    Tag(text: opening.difficulty.displayName, tint: opening.difficulty.tint)
                    Text("for \(opening.side.displayName)").font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Course card in the style of a course store: thumbnail, title, summary,
/// stats, segmented progress and a shortcut into the first line.
struct OpeningCard: View {
    let opening: Opening
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let plan = model.plan(for: opening.id)
        let cardIDs = plan?.cards.map(\.id) ?? []
        let counts = ProgressStats.statusCounts(cardIDs: cardIDs, in: model.data)
        let learned = counts.total - counts.new
        let mastery = ProgressStats.mastery(cardIDs: cardIDs, in: model.data)

        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.opening(opening.id)) {
                HStack(alignment: .top, spacing: 12) {
                    BoardThumbnail(position: opening.thumbnailPosition, orientation: opening.side, theme: model.settings.boardTheme)
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(opening.name).font(.headline).multilineTextAlignment(.leading)
                        Text(opening.summary).font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                            .lineLimit(3).multilineTextAlignment(.leading)
                        Text("\(opening.eco) · \(opening.difficulty.displayName) · for \(opening.side.displayName)")
                            .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            HStack(spacing: 14) {
                stat("Learned", "\(learned)/\(counts.total)")
                stat("Lines", "\(opening.lines.count) total")
                stat("Mastery", "\(Int(mastery * 100))%", tint: KA.Palette.score)
            }
            SegmentedProgress(value: mastery, segments: max(1, min(12, plan?.lines.count ?? opening.lines.count)))
            HStack {
                Button {
                    router.push(.trainer(openingID: opening.id, mode: .learn, side: nil, startNode: MoveTree.rootID))
                } label: {
                    HStack(spacing: 4) {
                        Text(learned == 0 ? "Try the first line" : "Continue learning")
                        Image(systemName: "arrow.right")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                if model.course(for: opening.id) != nil {
                    Image(systemName: "bookmark.fill").foregroundStyle(KA.Palette.progress)
                        .accessibilityLabel("In your courses")
                }
            }
        }
        .padding(14)
        .background(KA.Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KA.Palette.stroke, lineWidth: 1))
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(KA.Palette.textSecondary)
            Text(value).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Progress drawn as small rounded segments.
struct SegmentedProgress: View {
    let value: Double
    var segments: Int = 10

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                let fill = min(1, max(0, value * Double(segments) - Double(i)))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(KA.Palette.surfaceElevated)
                        Capsule().fill(KA.Palette.progress).frame(width: geo.size.width * fill)
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

extension Opening {
    /// The position after the moves that define the opening.
    var thumbnailPosition: Position {
        (try? Position(fen: fen)) ?? .start
    }
}
