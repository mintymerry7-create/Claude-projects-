import Foundation

/// Persists `UserData` as a versioned JSON document with atomic writes.
/// A corrupt file is moved aside (never silently deleted) and a fresh
/// document is started, so the app always launches.
public final class UserDataStore: @unchecked Sendable {
    public let url: URL
    public private(set) var data: UserData
    public private(set) var lastError: Error?
    /// Set when a corrupt file was moved aside during load.
    public private(set) var recoveredBackupURL: URL?
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        let fm = FileManager.default
        if let raw = try? Data(contentsOf: url) {
            do {
                data = try Self.decoder.decode(UserData.self, from: raw)
            } catch {
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("userdata-corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.moveItem(at: url, to: backup)
                recoveredBackupURL = backup
                lastError = error
                data = UserData()
            }
        } else {
            data = UserData()
        }
    }

    /// Default location: Application Support/KnightAcademy/userdata.json
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("KnightAcademy", isDirectory: true)
            .appendingPathComponent("userdata.json")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Mutates and immediately saves.
    public func update(_ body: (inout UserData) -> Void) {
        lock.lock()
        body(&data)
        let snapshot = data
        lock.unlock()
        do {
            try write(snapshot)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    public func save() throws {
        lock.lock()
        let snapshot = data
        lock.unlock()
        try write(snapshot)
    }

    private func write(_ snapshot: UserData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try Self.encoder.encode(snapshot)
        try raw.write(to: url, options: .atomic)
    }

    /// Erases all progress (used by "Reset progress" in Settings).
    public func reset(keepSettings: Bool = true) {
        let settings = data.settings
        update { d in
            d = UserData()
            if keepSettings { d.settings = settings; d.hasCompletedOnboarding = true }
        }
    }
}
