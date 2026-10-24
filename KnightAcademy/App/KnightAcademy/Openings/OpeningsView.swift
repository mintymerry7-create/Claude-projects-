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

    var body: some View {
        List {
            if query.isEmpty && difficulty == nil && side == nil && family == nil && status == nil {
                recommendations
            }
            filters
            let grouped = Dictionary(grouping: results, by: \.family)
            let families = model.db.families.filter { grouped[$0] != nil }
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
            ForEach(families, id: \.self) { fam in
                Section {
                    ForEach(grouped[fam] ?? []) { o in
                        NavigationLink(value: Route.opening(o.id)) { OpeningRow(opening: o) }
                    }
                } header: {
                    Text("\(fam) · \(grouped[fam]?.count ?? 0)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Openings")
        .searchable(text: $query, prompt: "Name, alias or ECO code")
    }

    @ViewBuilder private var recommendations: some View {
        let recs = model.recommendedOpenings
        if !recs.isEmpty {
            Section("Recommended for you") {
                ForEach(recs, id: \.title) { rec in
                    if case .opening(let id) = rec.target, let o = model.db.opening(id: id) {
                        NavigationLink(value: Route.opening(id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                OpeningRow(opening: o)
                                Text(rec.reason).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filters: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Any side") { side = nil }
                        Button("White") { side = .white }
                        Button("Black") { side = .black }
                    } label: { filterLabel(side?.displayName ?? "Side", active: side != nil) }
                    Menu {
                        Button("Any level") { difficulty = nil }
                        ForEach(Difficulty.allCases) { d in Button(d.displayName) { difficulty = d } }
                    } label: { filterLabel(difficulty?.displayName ?? "Difficulty", active: difficulty != nil) }
                    Menu {
                        Button("All families") { family = nil }
                        ForEach(model.db.families, id: \.self) { f in Button(f) { family = f } }
                    } label: { filterLabel(family ?? "Family", active: family != nil) }
                    Menu {
                        Button("Any status") { status = nil }
                        ForEach(CardStatus.allCases, id: \.self) { s in Button(s == .new ? "Not started" : s.displayName) { status = s } }
                    } label: { filterLabel(status.map { $0 == .new ? "Not started" : $0.displayName } ?? "Status", active: status != nil) }
                    if difficulty != nil || side != nil || family != nil || status != nil {
                        Button("Clear") { difficulty = nil; side = nil; family = nil; status = nil }
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(Color.clear)
        }
    }

    private func filterLabel(_ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? KA.Palette.accent : KA.Palette.surfaceElevated, in: Capsule())
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
