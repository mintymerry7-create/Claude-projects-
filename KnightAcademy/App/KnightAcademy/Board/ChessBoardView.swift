import SwiftUI
import ChessCore
import AppFeatures
import Learning

/// The reusable interactive chessboard used by lessons, puzzles, games and
/// analysis. It renders a `BoardDisplay` and reports legal moves via `onMove`.
struct ChessBoardView: View {
    let display: BoardDisplay
    var onMove: ((Move) -> Void)?

    @Environment(AppModel.self) private var model
    @State private var interaction = BoardInteraction()
    @State private var layout: PieceLayout
    @State private var drag: DragState?
    @State private var lastSeenMove: Move?

    struct DragState: Equatable {
        let from: Square
        var location: CGPoint
    }

    init(display: BoardDisplay, onMove: ((Move) -> Void)? = nil) {
        self.display = display
        self.onMove = onMove
        _layout = State(initialValue: PieceLayout(position: display.position))
        _lastSeenMove = State(initialValue: display.lastMove)
    }

    private var settings: AppSettings { model.settings }
    private var colors: BoardColors { BoardColors.forTheme(settings.boardTheme) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let sq = side / 8
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in drawBoard(ctx, squareSize: sq) }
                    .accessibilityHidden(true)
                ArrowsCanvas(arrows: display.arrows, orientation: display.orientation, squareSize: sq)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ForEach(layout.items) { item in
                    PieceImage(piece: item.piece)
                        .frame(width: sq, height: sq)
                        .position(point(for: item.square, sq))
                        .opacity(drag?.from == item.square ? 0.3 : 1)
                        .accessibilityHidden(true)
                }
                if let d = drag, let piece = display.position[d.from] {
                    PieceImage(piece: piece)
                        .frame(width: sq * 1.2, height: sq * 1.2)
                        .position(x: d.location.x, y: d.location.y - sq * 0.25)
                        .shadow(radius: 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .gesture(boardGesture(sq))
            .overlay {
                if let pending = interaction.pendingPromotion, let piece = display.position[pending.from] {
                    PromotionPicker(color: piece.color) { kind in
                        if let kind, let m = interaction.choosePromotion(kind) {
                            commit(m)
                        } else {
                            interaction.clear()
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chessboard")
            .accessibilityChildren { accessibilityGrid }
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: display.position) { _, newPosition in
            let candidates = [display.lastMove, lastSeenMove].compactMap { $0 }
            if settings.animateMoves {
                withAnimation(.easeInOut(duration: 0.22)) { layout.update(to: newPosition, candidates: candidates) }
            } else {
                layout.update(to: newPosition, candidates: candidates)
            }
            lastSeenMove = display.lastMove
            interaction.clear()
            drag = nil
        }
    }

    // MARK: Geometry

    private func point(for square: Square, _ sq: CGFloat) -> CGPoint {
        let col = display.orientation == .white ? square.file : 7 - square.file
        let row = display.orientation == .white ? 7 - square.rank : square.rank
        return CGPoint(x: (CGFloat(col) + 0.5) * sq, y: (CGFloat(row) + 0.5) * sq)
    }

    private func square(at p: CGPoint, _ sq: CGFloat) -> Square? {
        let col = Int(floor(p.x / sq)), row = Int(floor(p.y / sq))
        guard (0..<8).contains(col), (0..<8).contains(row) else { return nil }
        let file = display.orientation == .white ? col : 7 - col
        let rank = display.orientation == .white ? 7 - row : row
        return Square(file: file, rank: rank)
    }

    private func rect(for square: Square, _ sq: CGFloat) -> CGRect {
        let c = point(for: square, sq)
        return CGRect(x: c.x - sq / 2, y: c.y - sq / 2, width: sq, height: sq)
    }

    // MARK: Drawing

    private func drawBoard(_ ctx: GraphicsContext, squareSize sq: CGFloat) {
        for s in Square.all {
            let r = rect(for: s, sq)
            ctx.fill(Path(r), with: .color(s.isLight ? colors.light : colors.dark))
        }
        if let m = display.lastMove {
            for s in [m.from, m.to] { ctx.fill(Path(rect(for: s, sq)), with: .color(colors.lastMove)) }
        }
        for s in display.highlights {
            ctx.fill(Path(rect(for: s, sq)), with: .color(KA.Palette.accent.opacity(0.35)))
        }
        for s in display.hintSquares {
            ctx.fill(Path(rect(for: s, sq)), with: .color(colors.hint))
        }
        if let s = interaction.selected ?? drag?.from {
            ctx.fill(Path(rect(for: s, sq)), with: .color(colors.selection))
        }
        if let k = display.checkSquare {
            let r = rect(for: k, sq)
            ctx.fill(Path(ellipseIn: r.insetBy(dx: sq * 0.02, dy: sq * 0.02)),
                     with: .radialGradient(Gradient(colors: [Color.red.opacity(0.85), Color.red.opacity(0)]),
                                           center: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endRadius: sq * 0.55))
        }
        if settings.showLegalMoves {
            for t in interaction.targets {
                let r = rect(for: t, sq)
                if display.position[t] != nil {
                    ctx.stroke(Path(ellipseIn: r.insetBy(dx: sq * 0.06, dy: sq * 0.06)),
                               with: .color(Color.black.opacity(0.28)), lineWidth: sq * 0.08)
                } else {
                    ctx.fill(Path(ellipseIn: r.insetBy(dx: sq * 0.36, dy: sq * 0.36)), with: .color(Color.black.opacity(0.25)))
                }
            }
        }
        if settings.showCoordinates {
            let font = Font.system(size: max(8, sq * 0.2), weight: .semibold)
            for i in 0..<8 {
                let fileSquare = display.orientation == .white ? Square(file: i, rank: 0)! : Square(file: 7 - i, rank: 7)!
                let fr = rect(for: fileSquare, sq)
                ctx.draw(Text(String(fileSquare.fileLetter)).font(font).foregroundColor(fileSquare.isLight ? colors.dark : colors.light),
                         at: CGPoint(x: fr.maxX - sq * 0.1, y: fr.maxY - sq * 0.13), anchor: .center)
                let rankSquare = display.orientation == .white ? Square(file: 0, rank: i)! : Square(file: 7, rank: i)!
                let rr = rect(for: rankSquare, sq)
                ctx.draw(Text("\(rankSquare.rank + 1)").font(font).foregroundColor(rankSquare.isLight ? colors.dark : colors.light),
                         at: CGPoint(x: rr.minX + sq * 0.1, y: rr.minY + sq * 0.14), anchor: .center)
            }
        }
    }

    // MARK: Input

    private func boardGesture(_ sq: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                guard display.interactive, interaction.pendingPromotion == nil else { return }
                let distance = hypot(v.translation.width, v.translation.height)
                if drag == nil, distance > 6, let from = square(at: v.startLocation, sq),
                   let piece = display.position[from], piece.color == display.position.sideToMove {
                    if interaction.selected != from {
                        _ = interaction.tap(from, in: display.position, side: display.position.sideToMove)
                    }
                    drag = DragState(from: from, location: v.location)
                }
                if drag != nil { drag?.location = v.location }
            }
            .onEnded { v in
                guard display.interactive, interaction.pendingPromotion == nil else { drag = nil; return }
                if let d = drag {
                    drag = nil
                    guard let to = square(at: v.location, sq), to != d.from else { return }
                    handle(interaction.drag(from: d.from, to: to, in: display.position, side: display.position.sideToMove))
                } else if let s = square(at: v.location, sq) {
                    handle(interaction.tap(s, in: display.position, side: display.position.sideToMove))
                }
            }
    }

    private func handle(_ outcome: BoardInteraction.Outcome) {
        switch outcome {
        case .move(let m): commit(m)
        case .selected: Feedback.selection()
        case .needsPromotion, .none: break
        }
    }

    private func commit(_ m: Move) {
        Feedback.move(capture: display.position.isCapture(m))
        onMove?(m)
    }

    // MARK: Accessibility

    @ViewBuilder private var accessibilityGrid: some View {
        let rows: [Int] = display.orientation == .white ? Array((0..<8).reversed()) : Array(0..<8)
        let files: [Int] = display.orientation == .white ? Array(0..<8) : Array((0..<8).reversed())
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(files, id: \.self) { file in
                        let s = Square(file: file, rank: rank)!
                        Rectangle()
                            .accessibilityLabel(accessibilityLabel(for: s))
                            .accessibilityAddTraits(display.interactive ? .isButton : [])
                            .accessibilityAction {
                                guard display.interactive else { return }
                                handle(interaction.tap(s, in: display.position, side: display.position.sideToMove))
                            }
                    }
                }
            }
        }
    }

    private func accessibilityLabel(for s: Square) -> String {
        var label = s.name
        if let p = display.position[s] { label += ", \(p.description)" }
        if interaction.selected == s { label += ", selected" }
        if interaction.targets.contains(s) { label += ", legal destination" }
        if display.lastMove?.to == s { label += ", last move" }
        return label
    }
}

/// A piece rendered from the bundled cburnett vector images.
struct PieceImage: View {
    let piece: Piece

    var body: some View {
        Image(piece.assetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityLabel(piece.description)
    }
}

/// Arrows drawn over the board.
struct ArrowsCanvas: View {
    let arrows: [Arrow]
    let orientation: PieceColor
    let squareSize: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for a in arrows {
                let from = center(a.from), to = center(a.to)
                let dx = to.x - from.x, dy = to.y - from.y
                let len = max(1, hypot(dx, dy))
                let ux = dx / len, uy = dy / len
                let head = squareSize * 0.38
                let width = squareSize * 0.15
                let end = CGPoint(x: to.x - ux * squareSize * 0.18, y: to.y - uy * squareSize * 0.18)
                let shaftEnd = CGPoint(x: end.x - ux * head * 0.8, y: end.y - uy * head * 0.8)
                var shaft = Path()
                shaft.move(to: CGPoint(x: from.x + ux * squareSize * 0.2, y: from.y + uy * squareSize * 0.2))
                shaft.addLine(to: shaftEnd)
                let color = tint(a.kind)
                ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                var tip = Path()
                tip.move(to: end)
                tip.addLine(to: CGPoint(x: end.x - ux * head - uy * head * 0.6, y: end.y - uy * head + ux * head * 0.6))
                tip.addLine(to: CGPoint(x: end.x - ux * head + uy * head * 0.6, y: end.y - uy * head - ux * head * 0.6))
                tip.closeSubpath()
                ctx.fill(tip, with: .color(color))
            }
        }
    }

    private func center(_ s: Square) -> CGPoint {
        let col = orientation == .white ? s.file : 7 - s.file
        let row = orientation == .white ? 7 - s.rank : s.rank
        return CGPoint(x: (CGFloat(col) + 0.5) * squareSize, y: (CGFloat(row) + 0.5) * squareSize)
    }

    private func tint(_ kind: Arrow.Kind) -> Color {
        switch kind {
        case .suggestion: return Color(red: 0.18, green: 0.62, blue: 0.38).opacity(0.82)
        case .threat: return Color(red: 0.85, green: 0.25, blue: 0.2).opacity(0.8)
        case .engine: return Color(red: 0.2, green: 0.45, blue: 0.85).opacity(0.8)
        case .plan: return Color(red: 0.95, green: 0.6, blue: 0.1).opacity(0.8)
        }
    }
}

/// Chooses the promotion piece.
struct PromotionPicker: View {
    let color: PieceColor
    let onChoose: (PieceKind?) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture { onChoose(nil) }
            VStack(spacing: 10) {
                Text("Promote to").font(.headline)
                HStack(spacing: 12) {
                    ForEach(PieceKind.promotionChoices, id: \.self) { kind in
                        Button { onChoose(kind) } label: {
                            PieceImage(piece: Piece(color, kind))
                                .frame(width: 52, height: 52)
                                .padding(6)
                                .background(KA.Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel(kind.name.capitalized)
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// A small, non-interactive board for previews and lists.
struct BoardThumbnail: View {
    let position: Position
    var orientation: PieceColor = .white
    var lastMove: Move?
    var theme: BoardTheme = .forest

    var body: some View {
        GeometryReader { geo in
            let sq = min(geo.size.width, geo.size.height) / 8
            let colors = BoardColors.forTheme(theme)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for s in Square.all {
                        let r = rect(s, sq)
                        var c = s.isLight ? colors.light : colors.dark
                        if let m = lastMove, m.from == s || m.to == s { c = c.opacity(0.75) }
                        ctx.fill(Path(r), with: .color(c))
                        if let m = lastMove, m.from == s || m.to == s { ctx.fill(Path(r), with: .color(colors.lastMove)) }
                    }
                }
                ForEach(Square.all.filter { position[$0] != nil }, id: \.self) { s in
                    PieceImage(piece: position[s]!)
                        .frame(width: sq, height: sq)
                        .position(x: rect(s, sq).midX, y: rect(s, sq).midY)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Board position")
    }

    private func rect(_ s: Square, _ sq: CGFloat) -> CGRect {
        let col = orientation == .white ? s.file : 7 - s.file
        let row = orientation == .white ? 7 - s.rank : s.rank
        return CGRect(x: CGFloat(col) * sq, y: CGFloat(row) * sq, width: sq, height: sq)
    }
}
