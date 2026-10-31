import Foundation
import Observation

@MainActor @Observable final class SettingsViewModel {
    @ObservationIgnored private let defaults: UserDefaults
    var largeGB: Double { didSet { defaults.set(largeGB, forKey: "largeGB") } }
    var cacheAgeDays: Int { didSet { defaults.set(cacheAgeDays, forKey: "cacheAgeDays") } }
    var ageDays: Int { didSet { defaults.set(ageDays, forKey: "ageDays") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cacheAgeDays = defaults.object(forKey: "cacheAgeDays") as? Int ?? 30
        largeGB = defaults.object(forKey: "largeGB") as? Double ?? 1
        ageDays = defaults.object(forKey: "ageDays") as? Int ?? 180
    }
}
