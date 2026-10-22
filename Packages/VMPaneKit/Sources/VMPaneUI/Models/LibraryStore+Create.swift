import Foundation
import SwiftUI
import VMPaneCore
import VMPaneHost

/// VMs being created in the background: the sheet closes on Create, and the library lists each one with its stage
/// (Download · Verify · Prepare disk) until it becomes a VM, which then starts and shows its helper's install stages.
extension LibraryStore {
    public struct Creation: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let os: GuestOS
        /// Its bundle, once the downloads are done and it is being prepared.
        public var bundle: URL?
        public var progress: VMCreator.Progress = .creating
        /// Why it failed (Retry runs the create again; a download goes on where it stopped).
        public var failure: String?
        /// Cancel was pressed; the create ends at its next step.
        public var stopping = false

        public var stage: String {
            if stopping { return "Stopping" }
            return switch progress {
            case .creating: "Starting"
            case .downloading(let received, let total?) where received >= total: "Verifying the download"
            case .downloading: "Downloading"
            case .verifying: "Verifying the download"
            case .preparing: "Preparing the disk"
            }
        }

        /// Done so far, when known.
        public var fraction: Double? {
            guard case .downloading(let received, let total?) = progress, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }
    }

    /// Creates VMs in this library (the wizard).
    public func makeCreator() -> VMCreator {
        VMCreator(ops: LibraryOps(library: library, identity: .ui))
    }

    /// A VM the wizard just made: listed, selected, and started (which begins its install).
    public func didCreate(_ bundle: VMBundle) async {
        await reload()
        guard let id = rows.first(where: { $0.bundleURL.standardizedFileURL == bundle.url.standardizedFileURL })?.id else { return }
        selection = id
        await perform(.start(headless: false), on: id)
    }

    /// Creates the VM `request` describes, in the background (`creations` follows it).
    public func create(_ request: VMCreator.Request) {
        let creation = Creation(id: UUID(), name: request.name, os: request.os)
        creations.append(creation)
        run(creation.id, request)
    }

    /// Stops a create; what it made is removed (a download's partial file stays for the next try).
    public func cancelCreation(_ id: UUID) {
        if let task = creationTasks[id] {
            // A checksum or the disk's preparation ends on its own first: the row says it is stopping meanwhile.
            if let index = creations.firstIndex(where: { $0.id == id }) { creations[index].stopping = true }
            task.cancel()
        } else {
            forgetCreation(id)
        }
    }

    public func retryCreation(_ id: UUID) {
        guard creationTasks[id] == nil, let request = creationRequests[id], let index = creations.firstIndex(where: { $0.id == id })
        else { return }
        creations[index].failure = nil
        creations[index].progress = .creating
        run(id, request)
    }

    /// Takes a failed create off the list.
    public func forgetCreation(_ id: UUID) {
        creations.removeAll { $0.id == id }
        creationRequests[id] = nil
        creationTasks[id] = nil
    }

    private func run(_ id: UUID, _ request: VMCreator.Request) {
        creationRequests[id] = request
        let creator = makeCreator()
        let throttle = ProgressThrottle()
        let ops = LibraryOps(library: library, identity: .ui)
        creationTasks[id] = Task { [weak self] in
            do {
                let bundle = try await creator.create(
                    request,
                    progress: { update in
                        guard throttle.passes(update) else { return }
                        Task { @MainActor in self?.show(update, for: id) }
                    },
                    made: { url in Task { @MainActor in self?.made(url, for: id) } })
                // Cancel pressed as it finished: what it made goes, as for any cancel.
                if Task.isCancelled {
                    try? await Blocking.run { try ops.delete(bundle) }
                    throw CancellationError()
                }
                self?.forgetCreation(id)
                await self?.didCreate(bundle)
            } catch {
                guard let self else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    forgetCreation(id)
                } else {
                    creationTasks[id] = nil
                    fail(id, ErrorText.readable(error))
                }
            }
        }
    }

    private func show(_ progress: VMCreator.Progress, for id: UUID) {
        guard let index = creations.firstIndex(where: { $0.id == id }), creations[index].failure == nil else { return }
        let before = creations[index].stage
        creations[index].progress = progress
        if creations[index].stage != before {
            AccessibilityNotification.Announcement("\(creations[index].name): \(creations[index].stage)").post()
        }
    }

    private func made(_ bundle: URL, for id: UUID) {
        guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
        creations[index].bundle = bundle
    }

    private func fail(_ id: UUID, _ reason: String) {
        guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
        creations[index].failure = reason
        AccessibilityNotification.Announcement("\(creations[index].name) could not be created").post()
    }
}

/// Download progress at most four times a second (a chunk arrives far more often), other stages always.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now - .seconds(1)

    func passes(_ progress: VMCreator.Progress) -> Bool {
        guard case .downloading(let received, let total) = progress, received < (total ?? .max) else { return true }
        return lock.withLock {
            guard ContinuousClock.now - last >= .milliseconds(250) else { return false }
            last = ContinuousClock.now
            return true
        }
    }
}
