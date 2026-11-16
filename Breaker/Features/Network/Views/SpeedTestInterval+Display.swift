import Foundation

extension SpeedTestInterval {
    var title: String {
        switch self {
        case .manual:
            String(localized: "Manually", comment: "Choice of how often to measure internet speed: never automatically, only when the user asks")

        case .fifteenMinutes:
            String(localized: "Every 15 Minutes", comment: "Choice of how often to measure internet speed automatically")

        case .thirtyMinutes:
            String(localized: "Every 30 Minutes", comment: "Choice of how often to measure internet speed automatically")

        case .oneHour:
            String(localized: "Every Hour", comment: "Choice of how often to measure internet speed automatically")

        case .threeHours:
            String(localized: "Every 3 Hours", comment: "Choice of how often to measure internet speed automatically")

        case .sixHours:
            String(localized: "Every 6 Hours", comment: "Choice of how often to measure internet speed automatically")
        }
    }
}
