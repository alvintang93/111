import Foundation
import MarginCore
import WatchConnectivity

/// Sends the latest brief and logs to the iPhone app as a file transfer
/// (queued by watchOS and delivered even when the phone app isn't running).
/// Only the newest payload matters, so older pending transfers are cancelled.
@MainActor
final class PhoneSync: NSObject, ObservableObject {
    static let shared = PhoneSync()

    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastError: String?
    /// Set by the phone asking for fresh data.
    var onRefreshRequest: (() -> Void)?

    private var session: WCSession? { WCSession.isSupported() ? .default : nil }
    private var lastPayloadAt: Date?
    static let minimumInterval: TimeInterval = 5 * 60

    func activate() {
        guard let s = session else { return }
        s.delegate = self
        s.activate()
    }

    /// Sends unless a payload went out less than 5 minutes ago (`force` skips that check).
    func send(_ payload: PhonePayload, force: Bool = false) {
        guard let s = session, s.activationState == .activated, s.isCompanionAppInstalled else { return }
        if !force, let last = lastPayloadAt, Date().timeIntervalSince(last) < Self.minimumInterval { return }
        do {
            let data = try JSONEncoder().encode(payload)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-payload-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            for t in s.outstandingFileTransfers where t.file.metadata?["kind"] as? String == "payload" { t.cancel() }
            s.transferFile(url, metadata: ["kind": "payload", "version": PhonePayload.version])
            lastPayloadAt = Date()
        } catch {
            lastError = error.localizedDescription
            AppModel.shared.log(.persist, .error, "phone payload failed: \(error.localizedDescription)")
        }
    }

    fileprivate func finished(errorMessage: String?) {
        if let errorMessage {
            lastError = errorMessage
            AppModel.shared.log(.persist, .warning, "phone transfer failed: \(errorMessage)")
        } else {
            lastSentAt = Date()
            lastError = nil
        }
    }
}

extension PhoneSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { AppModel.shared.log(.lifecycle, .warning, "phone link activation failed: \(message)") }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // Transfers cancelled in favour of a newer payload are not failures.
        let message = (error as NSError?)?.code == NSUserCancelledError ? nil : error?.localizedDescription
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        Task { @MainActor in self.finished(errorMessage: message) }
    }

    /// Routine edits made on iPhone.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["routines"] as? Data, let lib = try? JSONDecoder().decode(RoutineLibrary.self, from: data) else { return }
        Task { @MainActor in AppModel.shared.mergeRoutines(lib) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["request"] as? String == "refresh" else { return }
        Task { @MainActor in self.onRefreshRequest?() }
    }
}
