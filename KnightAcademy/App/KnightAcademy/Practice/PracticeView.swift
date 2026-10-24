import SwiftUI
import ChessCore
import Learning
import AppFeatures

/// Reviews, puzzles and the fundamentals curriculum.
struct PracticeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.l) {
                reviewCard
                puzzleSection
                curriculumSection
                forgottenSection
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle("Practice")
    }

    private var reviewCard: some View {
        let due = model.dueReviews().count
        let total = model.data.reviews.count
        return VStack(alignment: .leading, spacing: KA.Spacing.m) {
            SectionHeader(title: "Spaced repetition", subtitle: "\(total) moves tracked")
            HStack(spacing: KA.Spacing.m) {
                StatTile(value: "\(due)", label: "due now", symbol: "clock.badge.exclamationmark", tint: due > 0 ? KA.Palette.warning : KA.Palette.accent)
                StatTile(value: "\(model.data.reviews.values.filter { $0.status == .mastered }.count)", label: "mastered", symbol: "checkmark.seal")
            }
            Button(due > 0 ? "Review \(due) move\(due == 1 ? "" : "s")" : "No reviews due") { router.push(.reviews) }
                .buttonStyle(.primary)
                .disabled(due == 0)
            Text("Moves are scheduled with the SM-2 algorithm: answers you know well come back after longer intervals, mistakes come back soon.")
                .font(.caption).foregroundStyle(KA.Palette.textSecondary)
        }
    }

    private var puzzleSection: some View {
        let stats = model.puzzleStats
        let accuracy = ProgressStats.puzzleAccuracyByTheme(model.data)
        return VStack(alignment: .leading, spacing: KA.Spacing.m) {
            SectionHeader(title: "Tactics puzzles", subtitle: "\(stats.solved) solved · \(model.puzzles.count) available")
            Button("Next puzzle at your level") { router.push(.puzzles(theme: nil, puzzleID: nil)) }
                .buttonStyle(.primary)
                .disabled(model.puzzles.isEmpty)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(PuzzleLibrary.allThemes, id: \.self) { theme in
                    Button { router.push(.puzzles(theme: theme, puzzleID: nil)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Puzzle.displayName(forTheme: theme)).font(.subheadline.weight(.semibold))
                            let count = model.puzzles.filter { $0.themes.contains(theme) }.count
                            if let a = accuracy[theme] {
                                Text("\(a.solved)/\(a.attempted) first try · \(count) total").font(.caption2).foregroundStyle(KA.Palette.textSecondary)
                            } else {
                                Text("\(count) puzzles").font(.caption2).foregroundStyle(KA.Palette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var curriculumSection: some View {
        VStack(alignment: .leading, spacing: KA.Spacing.m) {
            SectionHeader(title: "Chess fundamentals", subtitle: "\(model.curriculum.allLessons.count) lessons",
                          actionTitle: "All lessons", action: { router.push(.curriculum) })
            if let rec = model.recommendedLesson, case .lesson(let id) = rec.target {
                Button { router.push(.lesson(id)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(KA.Palette.gold).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recommended: \(rec.title)").font(.headline)
                            Text(rec.reason).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(KA.Palette.textSecondary)
                    }
                    .card()
                }
                .buttonStyle(.plain)
            }
            ForEach(model.curriculum.modules.prefix(4)) { module in
                ModuleRow(module: module)
            }
        }
    }

    @ViewBuilder private var forgottenSection: some View {
        let forgotten = model.data.frequentlyForgotten.prefix(5)
        if !forgotten.isEmpty {
            VStack(alignment: .leading, spacing: KA.Spacing.s) {
                SectionHeader(title: "Frequently forgotten")
                ForEach(Array(forgotten)) { r in
                    HStack {
                        Text(r.san ?? "?").font(.headline.monospaced())
                        Text(r.context ?? "").font(.caption).foregroundStyle(KA.Palette.textSecondary).lineLimit(1)
                        Spacer()
                        Text("\(r.lapses)× missed · \(Int(r.accuracy * 100))%").font(.caption).foregroundStyle(KA.Palette.warning)
                    }
                }
                .card(padding: 12)
            }
        }
    }
}

struct ModuleRow: View {
    let module: LessonModule
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let done = module.lessons.filter { model.lessonProgress($0) >= 1 }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: module.symbol).foregroundStyle(KA.Palette.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.headline)
                    Text(module.summary).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
                Spacer()
                Text("\(done)/\(module.lessons.count)").font(.caption.monospacedDigit()).foregroundStyle(KA.Palette.textSecondary)
            }
            ForEach(module.lessons) { lesson in
                Button { router.push(.lesson(lesson.id)) } label: {
                    HStack {
                        let progress = model.lessonProgress(lesson)
                        Image(systemName: progress >= 1 ? "checkmark.circle.fill" : progress > 0 ? "circle.lefthalf.filled" : "circle")
                            .foregroundStyle(progress >= 1 ? KA.Palette.accent : KA.Palette.textSecondary)
                        Text(lesson.title).font(.subheadline)
                        Spacer()
                        Tag(text: lesson.difficulty.displayName, tint: lesson.difficulty.tint)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}

struct CurriculumView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                ForEach(model.curriculum.modules) { ModuleRow(module: $0) }
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle("Fundamentals")
    }
}
