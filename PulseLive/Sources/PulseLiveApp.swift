// PulseLive — fréquence cardiaque live depuis AirPods Pro 3 / Powerbeats Pro 2
// iOS 26+ (HKWorkoutSession sur iPhone). Aucun workout sauvegardé.

import SwiftUI
import HealthKit
import Charts
import Observation

// MARK: - App

@main
struct PulseLiveApp: App {
    @State private var hr = HeartRateManager()
    var body: some Scene {
        WindowGroup { ContentView().environment(hr) }
    }
}

// MARK: - Modèle

struct HRPoint: Identifiable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

@MainActor
@Observable
final class HeartRateManager: NSObject {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let hrType = HKQuantityType(.heartRate)

    var isRunning = false
    var current: Double?
    var points: [HRPoint] = []
    var startDate: Date?
    var errorMessage: String?

    var average: Double? { points.isEmpty ? nil : points.map(\.bpm).reduce(0, +) / Double(points.count) }
    var minBPM: Double? { points.map(\.bpm).min() }
    var maxBPM: Double? { points.map(\.bpm).max() }

    func requestAuth() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit indisponible."
            return
        }
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [hrType]
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start() async {
        await requestAuth()
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            points.removeAll()
            current = nil
            let now = Date()
            startDate = now
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard let s = session, let b = builder else { return }
        s.end()
        do {
            try await b.endCollection(at: .now)
        } catch {}
        b.discardWorkout() // rien écrit dans Santé, anneaux intacts
        session = nil
        builder = nil
        isRunning = false
    }

    fileprivate func add(_ bpm: Double, at date: Date) {
        current = bpm
        points.append(HRPoint(date: date, bpm: bpm))
        if points.count > 3600 { points.removeFirst(points.count - 3600) }
    }
}

// MARK: - Délégués HealthKit

extension HeartRateManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.errorMessage = msg
            self.isRunning = false
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              let q = workoutBuilder.statistics(for: type)?.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: .count().unitDivided(by: .minute()))
        let date = Date()
        Task { @MainActor in self.add(bpm, at: date) }
    }
}

// MARK: - UI

struct ContentView: View {
    @Environment(HeartRateManager.self) private var hr

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    bigNumber
                    stats
                    chart
                    button
                    if let e = hr.errorMessage {
                        Text(e).font(.footnote).foregroundStyle(.red)
                    }
                    Text("Porte tes AirPods. Lance un peu d'audio si pas de valeur.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("PulseLive")
        }
        .task { await hr.requestAuth() }
    }

    private var bigNumber: some View {
        VStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: hr.isRunning)
            Text(hr.current.map { "\(Int($0.rounded()))" } ?? "--")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: hr.current)
            Text("BPM").font(.headline).foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        HStack {
            stat("Moy", hr.average)
            stat("Min", hr.minBPM)
            stat("Max", hr.maxBPM)
            VStack {
                Text("Durée").font(.caption).foregroundStyle(.secondary)
                if let s = hr.startDate, hr.isRunning {
                    Text(s, style: .timer).font(.title3.bold()).monospacedDigit()
                } else {
                    Text("--").font(.title3.bold())
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private func stat(_ label: String, _ v: Double?) -> some View {
        VStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(v.map { "\(Int($0.rounded()))" } ?? "--")
                .font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var chart: some View {
        Chart(hr.points) { p in
            LineMark(x: .value("Heure", p.date), y: .value("BPM", p.bpm))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.red)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 200)
        .padding()
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var button: some View {
        Button {
            Task { hr.isRunning ? await hr.stop() : await hr.start() }
        } label: {
            Text(hr.isRunning ? "Stop" : "Démarrer")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding()
        }
        .buttonStyle(.borderedProminent)
        .tint(hr.isRunning ? .gray : .red)
    }
}
