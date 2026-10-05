import CoreMotion
import Foundation
import MarginCore
@preconcurrency import WatchKit

/// Smart alarm: a watchOS alarm session scheduled for the wake window. While it
/// runs, wrist motion is summarised every 30 s and `SmartAlarmDetector`
/// decides when to wake; the latest wake time always fires. watchOS only lets
/// an app schedule the session while it is open, so it is re-armed every time
/// Margin comes to the foreground.
@MainActor
final class SmartAlarmManager: NSObject, ObservableObject {
    @Published private(set) var scheduledWake: Date?
    @Published private(set) var lastAlarm: String?

    private var session: WKExtendedRuntimeSession?
    /// The session currently running its wake window.
    private var running: WKExtendedRuntimeSession?
    private let motion = CMMotionManager()
    private var detector = SmartAlarmDetector()
    private var epoch: [Double] = []
    private var timer: Timer?
    private var deadline: Date?
    private var fired = false

    static let epochSeconds: TimeInterval = 30

    /// Cancels any scheduled session and schedules the next one if enabled.
    func reschedule(_ settings: SmartAlarmSettings) {
        session?.invalidate()
        session = nil
        scheduledWake = nil
        deadline = nil
        guard settings.enabled else { return }
        let window = settings.nextWindow(after: Date(), calendar: .current)
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        s.start(at: window.start)
        session = s
        scheduledWake = window.wake
        deadline = window.wake
        AppModel.shared.log(.lifecycle, .info,
                            "smart alarm scheduled: window \(window.start.formatted(date: .omitted, time: .shortened))–\(window.wake.formatted(date: .omitted, time: .shortened))")
    }

    /// Re-arms after the app returns to the foreground if nothing is scheduled.
    func ensureScheduled(_ settings: SmartAlarmSettings) {
        if settings.enabled, session == nil || scheduledWake.map({ $0 < Date() }) == true {
            reschedule(settings)
        } else if !settings.enabled, session != nil {
            reschedule(settings)
        }
    }

    private func begin(_ s: WKExtendedRuntimeSession) {
        detector = SmartAlarmDetector()
        epoch = []
        fired = false
        running = s
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                Task { @MainActor in self?.epoch.append(magnitude) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.epochSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        AppModel.shared.log(.lifecycle, .info, "smart alarm window started")
    }

    private func tick() {
        guard let s = running else { return }
        let samples = epoch
        epoch = []
        if detector.add(epoch: samples) {
            fire(s, reason: "movement after \(detector.epochs) epoch(s)")
        } else if let d = deadline, Date() >= d {
            fire(s, reason: "latest wake time")
        }
    }

    private func fire(_ s: WKExtendedRuntimeSession, reason: String) {
        guard !fired else { return }
        fired = true
        stopMonitoring()
        s.notifyUser(hapticType: .notification) { _ in 2.0 }
        let at = Date().formatted(date: .omitted, time: .shortened)
        lastAlarm = "Woke you at \(at) (\(reason))"
        AppModel.shared.log(.lifecycle, .info, "smart alarm fired at \(at): \(reason)")
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if motion.isAccelerometerActive { motion.stopAccelerometerUpdates() }
    }

    private func ended(_ reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        stopMonitoring()
        session = nil
        running = nil
        scheduledWake = nil
        if let error {
            AppModel.shared.log(.lifecycle, .warning, "smart alarm session ended: \(error.localizedDescription)")
        } else {
            AppModel.shared.log(.lifecycle, .info, "smart alarm session ended (reason \(reason.rawValue))")
        }
    }
}

extension SmartAlarmManager: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in self.begin(extendedRuntimeSession) }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in self.fire(extendedRuntimeSession, reason: "window ending") }
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in self.ended(reason, error: error) }
    }
}
