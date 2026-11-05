import Foundation
import Observation

@MainActor @Observable final class SettingsViewModel {
    @ObservationIgnored private let defaults: UserDefaults
    var largeGB: Double { didSet { defaults.set(largeGB, forKey: "largeGB") } }
    var cacheAgeDays: Int { didSet { defaults.set(cacheAgeDays, forKey: "cacheAgeDays") } }
    var ageDays: Int { didSet { defaults.set(ageDays, forKey: "ageDays") } }
    /// Keep folder sizes of finished scans (never contents) to show growth later.
    var keepScanHistory: Bool { didSet { defaults.set(keepScanHistory, forKey: "keepScanHistory") } }
    @ObservationIgnored let history: ScanHistoryStore
    private(set) var historyCleared = false

    init(defaults: UserDefaults = .standard, history: ScanHistoryStore = ScanHistoryStore()) {
        self.defaults = defaults
        self.history = history
        keepScanHistory = defaults.object(forKey: "keepScanHistory") as? Bool ?? true
        cacheAgeDays = defaults.object(forKey: "cacheAgeDays") as? Int ?? 30
        largeGB = defaults.object(forKey: "largeGB") as? Double ?? 1
        ageDays = defaults.object(forKey: "ageDays") as? Int ?? 180
    }

    func clearHistory() { history.clear(); historyCleared = true }
}
