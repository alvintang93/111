import SwiftUI
import WatchKit

@main
struct MarginApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}

final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        BackgroundRefresh.schedule()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await AppModel.shared.refresh()
                    BackgroundRefresh.schedule()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

enum BackgroundRefresh {
    /// The preferred date is a request: watchOS budgets background refreshes
    /// and may run them later or less often.
    static func schedule(after interval: TimeInterval = 45 * 60) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }
}
