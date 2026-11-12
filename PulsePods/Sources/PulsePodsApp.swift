import SwiftUI
import Charts

@main
struct PulsePodsApp: App {
    @StateObject private var hr = HeartRateManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                LiveView().tabItem { Label("Direct", systemImage: "heart.fill") }
                StatsView().tabItem { Label("Stats", systemImage: "chart.xyaxis.line") }
                HistoryView().tabItem { Label("Séances", systemImage: "list.bullet") }
            }
            .tint(.red)
            .environmentObject(hr)
            .task { await hr.requestAuthorization() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { hr.appBecameActive() }
            }
        }
    }
}

func fmt(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

struct StatTile: View {
    let title: String
    let value: Double?
    var color: Color = .primary
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(fmt(value)).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            Text("BPM").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var hr: HeartRateManager
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.12)).frame(width: 220, height: 220)
                            .scaleEffect(pulse ? 1.08 : 1)
                        VStack(spacing: 2) {
                            Image(systemName: "heart.fill").font(.system(size: 34)).foregroundStyle(.red)
                                .scaleEffect(pulse ? 1.2 : 1)
                            Text(fmt(hr.currentBPM))
                                .font(.system(size: 72, weight: .bold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())
                            Text("BPM").font(.headline).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: hr.currentBPM) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) { pulse = true }
                        withAnimation(.easeIn(duration: 0.35).delay(0.15)) { pulse = false }
                    }

                    if let src = hr.sourceName, let t = hr.lastUpdate {
                        Text("\(src) · \(t.formatted(date: .omitted, time: .standard))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let msg = hr.statusMessage {
                        Text(msg).font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(.orange).padding(.horizontal)
                    }

                    Button {
                        hr.isRecording ? hr.stop() : hr.start()
                    } label: {
                        Label(hr.isRecording ? "Arrêter" : "Démarrer la mesure",
                              systemImage: hr.isRecording ? "stop.fill" : "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(hr.isRecording ? .gray : .red)
                    .padding(.horizontal)

                    if !hr.liveSamples.isEmpty {
                        Chart(hr.liveSamples) {
                            LineMark(x: .value("Heure", $0.date), y: .value("BPM", $0.bpm))
                                .interpolationMethod(.catmullRom).foregroundStyle(.red)
                            if let avg = hr.sessionAvg {
                                RuleMark(y: .value("Moyenne", avg))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 200).padding(.horizontal)

                        HStack {
                            StatTile(title: "Moyenne", value: hr.sessionAvg)
                            StatTile(title: "Pic max", value: hr.sessionMax, color: .red)
                            StatTile(title: "Min", value: hr.sessionMin, color: .blue)
                        }.padding(.horizontal)

                        HStack {
                            StatTile(title: "Moy. 1 min", value: hr.avg(lastSeconds: 60))
                            StatTile(title: "Moy. 5 min", value: hr.avg(lastSeconds: 300))
                            StatTile(title: "Moy. 15 min", value: hr.avg(lastSeconds: 900))
                        }.padding(.horizontal)

                        Text("\(hr.liveSamples.count) mesures").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("PulsePods")
        }
    }
}

// MARK: - Stats

struct StatsView: View {
    @EnvironmentObject var hr: HeartRateManager
    @State private var period: StatPeriod = .day
    @State private var stats = PeriodStats()
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Période", selection: $period) {
                        ForEach(StatPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)

                    HStack {
                        StatTile(title: "Moyenne", value: stats.avg)
                        StatTile(title: "Pic max", value: stats.max, color: .red)
                        StatTile(title: "Min", value: stats.min, color: .blue)
                    }
                    StatTile(title: "Fréquence au repos (moy.)", value: stats.resting, color: .green)

                    if stats.buckets.isEmpty {
                        ContentUnavailableView(loading ? "Chargement…" : "Pas de données",
                                               systemImage: "heart.text.square",
                                               description: Text("Données lues depuis l'app Santé (AirPods, Apple Watch…)."))
                    } else {
                        Chart(stats.buckets) { b in
                            RuleMark(x: .value("Date", b.date),
                                     yStart: .value("Min", b.min), yEnd: .value("Max", b.max))
                                .foregroundStyle(.red.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                            PointMark(x: .value("Date", b.date), y: .value("Moyenne", b.avg))
                                .foregroundStyle(.red).symbolSize(20)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 260)
                        Text("Barre = min→max · point = moyenne").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Statistiques")
            .refreshable { await load() }
            .task(id: period) { await load() }
        }
    }

    private func load() async {
        loading = true
        stats = await hr.stats(for: period)
        loading = false
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var hr: HeartRateManager

    var body: some View {
        NavigationStack {
            List {
                if hr.sessions.isEmpty {
                    Text("Aucune séance enregistrée.").foregroundStyle(.secondary)
                }
                ForEach(hr.sessions) { s in
                    NavigationLink(value: s) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(Duration.seconds(s.duration).formatted(.time(pattern: .hourMinuteSecond))) · moy \(fmt(s.avg)) · max \(fmt(s.maxBPM)) · min \(fmt(s.minBPM))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { hr.deleteSessions(at: $0) }
            }
            .navigationTitle("Séances")
            .navigationDestination(for: HRSession.self) { SessionDetail(session: $0) }
        }
    }
}

struct SessionDetail: View {
    let session: HRSession
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Chart(session.samples) {
                    LineMark(x: .value("Heure", $0.date), y: .value("BPM", $0.bpm))
                        .interpolationMethod(.catmullRom).foregroundStyle(.red)
                    RuleMark(y: .value("Moyenne", session.avg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 260)
                HStack {
                    StatTile(title: "Moyenne", value: session.avg)
                    StatTile(title: "Pic max", value: session.maxBPM, color: .red)
                    StatTile(title: "Min", value: session.minBPM, color: .blue)
                }
                Text("\(session.samples.count) mesures").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(session.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}
