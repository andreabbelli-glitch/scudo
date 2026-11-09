import Foundation
import ScudoKit
#if os(iOS)
import BackgroundTasks
#endif

/// The engine shared by the UI and the background refresh, so that their
/// operations are serialized by the same actor.
enum AppServices {
    static let engine: Result<ProtectionEngine, any Error> = Result {
        ProtectionEngine(store: try ScudoStore.shared()) { kind in
            try await SafariBridge.reload(kind)
        }
    }
}

/// Periodic update of the filter lists while the app is not in use.
///
/// iOS decides when to run it (usually overnight, while charging); the
/// request only sets the earliest date. Conditional downloads keep it cheap
/// when nothing changed.
enum BackgroundRefresh {
    /// Must be listed in `BGTaskSchedulerPermittedIdentifiers` (Info.plist).
    static var identifier: String {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return permitted?.first ?? "\(Bundle.main.bundleIdentifier ?? "scudo").refresh"
    }

    static let interval: TimeInterval = 12 * 60 * 60

    static func schedule() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not available in the simulator or when Background App Refresh
            // is off: the lists are then updated when the app is opened.
        }
        #endif
    }

    static func cancel() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        #endif
    }

    /// Body of the background task.
    static func run() async {
        guard case .success(let engine) = AppServices.engine else { return }
        guard await engine.settings().automaticUpdates else { return }
        // Queue the next run first: if iOS stops this one midway, the chain
        // of refreshes is not broken.
        schedule()
        _ = await engine.update()
    }
}
