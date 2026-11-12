import Foundation
import HealthKit
import SwiftUI

struct HRSample: Identifiable, Codable, Hashable {
    var id = UUID()
    let date: Date
    let bpm: Double
}

struct HRSession: Identifiable, Codable, Hashable {
    var id = UUID()
    let start: Date
    let end: Date
    let samples: [HRSample]

    var avg: Double { samples.isEmpty ? 0 : samples.map(\.bpm).reduce(0, +) / Double(samples.count) }
    var maxBPM: Double { samples.map(\.bpm).max() ?? 0 }
    var minBPM: Double { samples.map(\.bpm).min() ?? 0 }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct PeriodStats {
    var avg: Double?
    var min: Double?
    var max: Double?
    var resting: Double?
    var buckets: [Bucket] = []

    struct Bucket: Identifiable {
        let id = UUID()
        let date: Date
        let avg: Double
        let min: Double
        let max: Double
    }
}

enum StatPeriod: String, CaseIterable, Identifiable {
    case hour = "1 h"
    case day = "24 h"
    case week = "7 j"
    case month = "30 j"
    case year = "1 an"
    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .year: return 365 * 86_400
        }
    }

    var bucket: DateComponents {
        switch self {
        case .hour: return DateComponents(minute: 5)
        case .day: return DateComponents(hour: 1)
        case .week: return DateComponents(day: 1)
        case .month: return DateComponents(day: 1)
        case .year: return DateComponents(month: 1)
        }
    }
}

@MainActor
final class HeartRateManager: NSObject, ObservableObject {
    let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private let restingType = HKQuantityType(.restingHeartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    @Published var authorized = false
    @Published var isRecording = false
    @Published var currentBPM: Double?
    @Published var lastUpdate: Date?
    @Published var sourceName: String?
    @Published var liveSamples: [HRSample] = []
    @Published var sessions: [HRSession] = []
    @Published var statusMessage: String?

    private var sessionStart: Date?
    private var anchoredQuery: HKAnchoredObjectQuery?
    private var workoutSession: AnyObject?
    private var workoutBuilder: AnyObject?

    override init() {
        super.init()
        loadSessions()
    }

    var sessionAvg: Double? {
        liveSamples.isEmpty ? nil : liveSamples.map(\.bpm).reduce(0, +) / Double(liveSamples.count)
    }
    var sessionMax: Double? { liveSamples.map(\.bpm).max() }
    var sessionMin: Double? { liveSamples.map(\.bpm).min() }

    func avg(lastSeconds s: TimeInterval) -> Double? {
        let cutoff = Date().addingTimeInterval(-s)
        let vals = liveSamples.filter { $0.date >= cutoff }.map(\.bpm)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "HealthKit indisponible sur cet appareil."
            return
        }
        do {
            try await store.requestAuthorization(
                toShare: [HKObjectType.workoutType(), hrType],
                read: [hrType, restingType, HKObjectType.workoutType()]
            )
            authorized = true
        } catch {
            statusMessage = "Autorisation refusée : \(error.localizedDescription)"
        }
    }

    // MARK: Live recording

    func start() {
        guard !isRecording else { return }
        liveSamples = []
        currentBPM = nil
        sessionStart = Date()
        isRecording = true
        statusMessage = "Mets tes AirPods… mesure en cours."
        startAnchoredQuery(from: sessionStart!)
        if #available(iOS 26.0, *) {
            startWorkout()
        } else {
            statusMessage = "iOS 26 requis pour activer le capteur AirPods. Lecture des données Santé uniquement."
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let q = anchoredQuery { store.stop(q) }
        anchoredQuery = nil
        if #available(iOS 26.0, *) { stopWorkout() }
        if let start = sessionStart, !liveSamples.isEmpty {
            sessions.insert(HRSession(start: start, end: Date(), samples: liveSamples), at: 0)
            saveSessions()
        }
        statusMessage = nil
    }

    private func startAnchoredQuery(from start: Date) {
        let pred = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-5), end: nil, options: .strictStartDate)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
            Task { @MainActor in self?.ingest(samples) }
        }
        let q = HKAnchoredObjectQuery(type: hrType, predicate: pred, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        anchoredQuery = q
        store.execute(q)
    }

    private func ingest(_ samples: [HKQuantitySample]) {
        for s in samples.sorted(by: { $0.endDate < $1.endDate }) {
            let bpm = s.quantity.doubleValue(for: bpmUnit)
            add(bpm: bpm, date: s.endDate, source: s.sourceRevision.source.name)
        }
    }

    fileprivate func add(bpm: Double, date: Date, source: String?) {
        guard isRecording, bpm > 20, bpm < 250 else { return }
        if liveSamples.contains(where: { abs($0.date.timeIntervalSince(date)) < 1 && abs($0.bpm - bpm) < 0.5 }) { return }
        liveSamples.append(HRSample(date: date, bpm: bpm))
        liveSamples.sort { $0.date < $1.date }
        if lastUpdate == nil || date >= lastUpdate! {
            currentBPM = bpm
            lastUpdate = date
            if let source { sourceName = source }
        }
        statusMessage = nil
    }

    @available(iOS 26.0, *)
    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder
            let now = Date()
            session.startActivity(with: now)
            builder.beginCollection(withStart: now) { _, error in
                if let error {
                    Task { @MainActor in self.statusMessage = "Séance : \(error.localizedDescription)" }
                }
            }
        } catch {
            statusMessage = "Impossible de lancer la séance : \(error.localizedDescription)"
        }
    }

    @available(iOS 26.0, *)
    private func stopWorkout() {
        guard let session = workoutSession as? HKWorkoutSession,
              let builder = workoutBuilder as? HKLiveWorkoutBuilder else { return }
        session.end()
        builder.endCollection(withEnd: Date()) { _, _ in
            // On ne sauvegarde pas la séance comme entraînement : on la jette.
            builder.discardWorkout()
        }
        workoutSession = nil
        workoutBuilder = nil
    }

    // MARK: Period statistics (from Health app data)

    func stats(for period: StatPeriod) async -> PeriodStats {
        let end = Date()
        let start = end.addingTimeInterval(-period.interval)
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        var result = PeriodStats()

        let summary: HKStatistics? = await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: hrType, quantitySamplePredicate: pred,
                                      options: [.discreteAverage, .discreteMin, .discreteMax]) { _, stats, _ in
                cont.resume(returning: stats)
            }
            store.execute(q)
        }
        result.avg = summary?.averageQuantity()?.doubleValue(for: bpmUnit)
        result.min = summary?.minimumQuantity()?.doubleValue(for: bpmUnit)
        result.max = summary?.maximumQuantity()?.doubleValue(for: bpmUnit)

        let resting: HKStatistics? = await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: restingType, quantitySamplePredicate: pred,
                                      options: [.discreteAverage]) { _, stats, _ in
                cont.resume(returning: stats)
            }
            store.execute(q)
        }
        result.resting = resting?.averageQuantity()?.doubleValue(for: bpmUnit)

        let anchor = Calendar.current.startOfDay(for: start)
        let collection: HKStatisticsCollection? = await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: hrType, quantitySamplePredicate: pred,
                                                options: [.discreteAverage, .discreteMin, .discreteMax],
                                                anchorDate: anchor, intervalComponents: period.bucket)
            q.initialResultsHandler = { _, coll, _ in cont.resume(returning: coll) }
            store.execute(q)
        }
        let unit = bpmUnit
        collection?.enumerateStatistics(from: start, to: end) { s, _ in
            if let a = s.averageQuantity()?.doubleValue(for: unit) {
                result.buckets.append(.init(
                    date: s.startDate, avg: a,
                    min: s.minimumQuantity()?.doubleValue(for: unit) ?? a,
                    max: s.maximumQuantity()?.doubleValue(for: unit) ?? a))
            }
        }
        return result
    }

    // MARK: Persistence

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sessions.json")
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func loadSessions() {
        if let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode([HRSession].self, from: data) { sessions = s }
    }

    func deleteSessions(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        saveSessions()
    }
}

// MARK: - Workout delegates

extension HeartRateManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.statusMessage = "Erreur séance : \(error.localizedDescription)" }
    }
}

extension HeartRateManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              let q = workoutBuilder.statistics(for: type)?.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let date = workoutBuilder.statistics(for: type)?.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor in self.add(bpm: bpm, date: date, source: "AirPods") }
    }
}
