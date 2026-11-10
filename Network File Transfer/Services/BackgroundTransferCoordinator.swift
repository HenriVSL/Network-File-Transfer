//
//  BackgroundTransferCoordinator.swift
//  Network File Transfer
//

import BackgroundTasks
import Foundation

/// Keeps transfers running after the app leaves the foreground, using iOS 26's
/// `BGContinuedProcessingTask`. One task covers the current batch of transfers: iOS shows its
/// progress in the system UI and may expire it (for example when the user stops it there),
/// in which case the active transfers are cancelled.
final class BackgroundTransferCoordinator {
    /// Must match the wildcard in `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    private static let identifierPrefix = "henril.Network-File-Transfer.transfers."
    /// Progress units per transfer, so the system progress can mix known and unknown sizes.
    private static let unitsPerItem: Int64 = 1000

    private var task: BGContinuedProcessingTask?
    private var requestPending = false
    private var batch: [TransferItem] = []
    private var shownText = ""

    /// Called when iOS expires the task; should cancel the active transfers.
    var onExpiration: (() -> Void)?

    func transferStarted(_ item: TransferItem) {
        if task == nil && !requestPending {
            // Start a fresh batch; anything left over finished without a background task.
            batch.removeAll { !$0.isActive }
            batch.append(item)
            submitRequest()
        } else {
            batch.append(item)
        }
        update()
    }

    /// Call whenever an item's progress or state changes.
    func update() {
        guard let task else { return }
        let progress = task.progress
        progress.totalUnitCount = Int64(batch.count) * Self.unitsPerItem
        progress.completedUnitCount = batch.reduce(0) { sum, item in
            sum + (item.isActive ? Int64((item.fractionCompleted ?? 0) * Double(Self.unitsPerItem)) : Self.unitsPerItem)
        }

        let active = batch.filter(\.isActive)
        if active.isEmpty {
            finish()
        } else {
            let title = active.count == 1 ? active[0].verb + " " + active[0].fileName : "Transferring \(active.count) files"
            let subtitle = "\(Int(progress.fractionCompleted * 100))% · \(Set(active.map(\.serverName)).sorted().joined(separator: ", "))"
            // Progress arrives per chunk; only message the system when the visible text changes.
            if title + subtitle != shownText {
                shownText = title + subtitle
                task.updateTitle(title, subtitle: subtitle)
            }
        }
    }

    private func submitRequest() {
        let identifier = Self.identifierPrefix + UUID().uuidString
        let first = batch.first
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: first.map { $0.verb + " " + $0.fileName } ?? "Transferring files",
            subtitle: first?.serverName ?? ""
        )
        // Fail rather than queue: a queued request would only start later, after the transfer may be done.
        request.strategy = .fail

        // Continued-processing handlers may be registered at runtime, right before submitting.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in self?.began(task) }
        }
        guard registered else { return }

        do {
            try BGTaskScheduler.shared.submit(request)
            requestPending = true
        } catch {
            // Not allowed right now (e.g. system load); transfers still get the short
            // background time from `beginBackgroundTask`.
        }
    }

    private func began(_ task: BGContinuedProcessingTask) {
        requestPending = false
        guard batch.contains(where: \.isActive) else {
            batch.removeAll()
            task.setTaskCompleted(success: true)
            return
        }
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.onExpiration?()
                self?.finish()
            }
        }
        update()
    }

    private func finish() {
        guard let task else { return }
        let success = !batch.contains { if case .failed = $0.state { true } else { false } }
        self.task = nil
        shownText = ""
        batch.removeAll()
        task.setTaskCompleted(success: success)
    }
}

private extension TransferItem {
    var verb: String { direction == .download ? "Downloading" : "Uploading" }
}
