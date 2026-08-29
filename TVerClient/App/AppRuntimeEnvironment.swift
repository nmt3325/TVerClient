import Foundation

enum AppRuntimeEnvironment {
    static var isLiveContainer: Bool {
        isLiveContainer(
            environment: ProcessInfo.processInfo.environment,
            bundlePath: Bundle.main.bundlePath
        )
    }

    static var label: String {
        isLiveContainer ? "LiveContainer detected" : "standard/unknown container"
    }

    static func isLiveContainer(
        environment: [String: String],
        bundlePath: String
    ) -> Bool {
        environment["LC_HOME_PATH"] != nil
            || environment["LP_HOME_PATH"] != nil
            || bundlePath.localizedCaseInsensitiveContains("LiveContainer")
    }
}
