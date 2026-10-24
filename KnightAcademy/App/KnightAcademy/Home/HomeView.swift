import SwiftUI
import Charts
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
import AppFeatures

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.l) {
                header
                continueCard
                HStack(spacing: KA.Spacing.m) {
                    reviewsTile
                    quickPlayTile
                }
                dailyPuzzleCard
                openingProgress
                weeklyChart
                recentGames
                recentActivity
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(AppInfo.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.greeting()).font(.title2.bold())
                Text("\(model.practisedToday) of \(model.settings.dailyGoal) moves practised today")
                    .font(.subheadline)
                    .foregroundStyle(KA.Palette.textSecondary)
            }
            Spacer()
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(model.streak > 0 ? Color.orange : KA.Palette.textSecondary)
                    Text("\(model.streak)").font(.headline.monospacedDigit())
                }
                Text("day streak").font(.caption2).foregroundStyle(KA.Palette.textSecondary)
            }
            .padding(10)
            .background(KA.Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(model.streak) day learning streak")
        }
    }

    // MARK: Continue learning

    private var continueCard: some View {
        let step = model.nextStep
        let resume = model.data.resume
        return VStack(alignment: .leading, spacing: KA.Spacing.m) {
            Label(resume == nil ? "Recommended next" : "Continue learning", systemImage: "play.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(resume?.title ?? step.title).font(.title3.bold()).foregroundStyle(.white)
            Text(resume?.subtitle ?? step.reason).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            Button {
                if let r = resume, let route = route(for: r) {
                    router.push(route)
                } else {
                    open(step.target)
                }
            } label: {
                Text(resume == nil ? "Start" : "Continue")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(.white, in: Capsule())
                    .foregroundStyle(KA.Palette.accent)
            }
            if resume != nil, step.target != .reviews || model.dueReviews().isEmpty {
                Button { open(step.target) } label: {
                    Text("Up next · \(step.title)").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .padding(KA.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [KA.Palette.accent, KA.Palette.accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: KA.Radius.card, style: .continuous)
        )
    }

    private var reviewsTile: some View {
        let due = model.dueReviews().count
        return Button { router.push(.reviews) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(KA.Palette.accent).font(.headline)
                Text("\(due)").font(.title.bold().monospacedDigit())
                Text(due == 1 ? "review due" : "reviews due").font(.caption).foregroundStyle(KA.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: KA.Spacing.m)
        }
        .buttonStyle(.plain)
        .disabled(due == 0)
        .accessibilityLabel("\(due) reviews due today")
    }

    private var quickPlayTile: some View {
        Button {
            let bot: BotProfile = model.settings.level == .beginner ? .beginner : model.settings.level == .intermediate ? .intermediate : .advanced
            router.push(.game(GameSetup(bot: bot, playerColor: Bool.random() ? .white : .black)))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(KA.Palette.gold).font(.headline)
                Text("Quick play").font(.title3.bold())
                Text("vs bot at your level").font(.caption).foregroundStyle(KA.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: KA.Spacing.m)
        }
        .buttonStyle(.plain)
    }

    // MARK: Daily puzzle

    @ViewBuilder private var dailyPuzzleCard: some View {
        if let p = model.dailyPuzzle {
            Button { router.push(.puzzles(theme: nil, puzzleID: p.id)) } label: {
                HStack(spacing: KA.Spacing.l) {
                    BoardThumbnail(position: p.position, orientation: p.learnerColor,
                                   lastMove: p.lastMove.flatMap(Move.init(uci:)), theme: model.settings.boardTheme)
                        .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Daily puzzle").font(.headline)
                        Text("\(p.learnerColor.displayName) to move · level \(p.level)")
                            .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                        if model.data.puzzles[p.id]?.solved == true {
                            Tag(text: "Solved", tint: KA.Palette.accent)
                        } else {
                            Tag(text: "Solve now", tint: KA.Palette.info)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(KA.Palette.textSecondary)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Opening progress

    @ViewBuilder private var openingProgress: some View {
        let courses = model.courses
        VStack(alignment: .leading, spacing: KA.Spacing.m) {
            SectionHeader(title: "Your openings", subtitle: "Mastery \(Int((model.overallMastery * 100).rounded()))%",
                          actionTitle: "Browse", action: { router.tab = .openings })
            if courses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You haven't started an opening yet.").font(.subheadline)
                    ForEach(model.recommendedOpenings.prefix(2), id: \.title) { rec in
                        Button { open(rec.target) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rec.title).font(.headline)
                                    Text(rec.reason).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(KA.Palette.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card()
            } else {
                ForEach(courses.prefix(3)) { c in
                    Button { router.push(.opening(c.opening.id)) } label: {
                        HStack(spacing: KA.Spacing.m) {
                            ProgressRing(progress: c.mastery).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.opening.name).font(.headline).lineLimit(1)
                                Text("\(c.progress.settings.preset.displayName) · \(c.counts.total) moves · \(c.dueCount) due")
                                    .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(KA.Palette.textSecondary)
                        }
                        .card(padding: KA.Spacing.m)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Weekly chart

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: KA.Spacing.m) {
            SectionHeader(title: "This week")
            Chart(model.weekly) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Items", day.count))
                    .foregroundStyle(Calendar.current.isDateInToday(day.date) ? KA.Palette.accent : KA.Palette.accent.opacity(0.45))
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
            .card()
            .accessibilityLabel("Items practised over the last seven days")
        }
    }

    // MARK: Recent games & activity

    @ViewBuilder private var recentGames: some View {
        let games = model.recentGames
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                SectionHeader(title: "Recent games", actionTitle: "All", action: { router.push(.gameHistory) })
                VStack(spacing: 0) {
                    ForEach(games.prefix(3)) { g in
                        Button { router.push(.savedGame(g.id)) } label: { GameRow(game: g) }
                            .buttonStyle(.plain)
                        if g.id != games.prefix(3).last?.id { Divider() }
                    }
                }
                .card(padding: KA.Spacing.m)
            }
        }
    }

    @ViewBuilder private var recentActivity: some View {
        let events = model.recentActivity.filter { $0.count > 0 }
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                SectionHeader(title: "Recent activity")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(events.prefix(5)) { e in
                        HStack(spacing: 10) {
                            Image(systemName: e.kind.symbol).foregroundStyle(KA.Palette.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.subheadline.weight(.medium))
                                Text("\(e.detail.isEmpty ? "" : e.detail + " · ")\(e.count) item\(e.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                            }
                            Spacer()
                            Text(e.date, style: .relative).font(.caption2).foregroundStyle(KA.Palette.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .card()
            }
        }
    }

    // MARK: Navigation helpers

    private func open(_ target: Recommendation.Target) {
        switch target {
        case .opening(let id): router.push(.opening(id))
        case .lesson(let id): router.push(.lesson(id))
        case .reviews: router.push(.reviews)
        case .puzzles(let theme): router.push(.puzzles(theme: theme, puzzleID: nil))
        }
    }

    private func route(for resume: ResumePoint) -> Route? {
        switch resume.kind {
        case .opening:
            guard let course = model.course(for: resume.targetID), let plan = model.plan(for: resume.targetID) else {
                return .opening(resume.targetID)
            }
            var node = MoveTree.rootID
            for san in course.resumePath {
                guard let next = try? plan.tree.position(at: node).move(fromSAN: san),
                      let child = plan.tree.child(of: node, playing: next) else { break }
                node = child
            }
            // Resume at the learner's last decision point inside the plan.
            if plan.nodeLines[node] == nil { node = MoveTree.rootID }
            let mode = course.lastMode.flatMap(TrainerMode.init(rawValue:)) ?? .learn
            return .trainer(openingID: resume.targetID, mode: mode, side: course.side, startNode: node)
        case .lesson: return .lesson(resume.targetID)
        case .puzzle: return .puzzles(theme: nil, puzzleID: nil)
        case .repertoire: return UUID(uuidString: resume.targetID).map { .repertoire($0) }
        }
    }
}

struct GameRow: View {
    let game: SavedGame

    var body: some View {
        HStack(spacing: 12) {
            resultBadge
            VStack(alignment: .leading, spacing: 2) {
                Text("vs \(game.opponent)").font(.subheadline.weight(.semibold))
                Text([game.openingName, game.reason].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(KA.Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            Text(game.date, format: .dateTime.month(.abbreviated).day())
                .font(.caption).foregroundStyle(KA.Palette.textSecondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(KA.Palette.textSecondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var resultBadge: some View {
        let score = game.playerScore
        let (text, tint): (String, Color) = score == 1 ? ("W", KA.Palette.accent) : score == 0 ? ("L", KA.Palette.danger) : score == 0.5 ? ("D", KA.Palette.info) : ("–", KA.Palette.textSecondary)
        return Text(text)
            .font(.headline)
            .frame(width: 32, height: 32)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityLabel(score == 1 ? "Win" : score == 0 ? "Loss" : score == 0.5 ? "Draw" : "Unfinished")
    }
}
