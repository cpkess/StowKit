import Foundation
import CloudKit

@MainActor final class CloudSyncCoordinator {
    private let repository: ArchiveRepository
    private let storage: DocumentStorageManager
    private let reader: TextSearchService
    private let transport: any ArchiveCloudTransport
    private let onStatus: (String, Bool) -> Void
    private let onUpdate: () -> Void
    private let onAccess: (Bool) -> Void
    private let onSuspended: () -> Void
    private var worker: Task<Void, Never>?
    private var rerun = false
    private var stopped = false
    private var writable = false
    init(repository: ArchiveRepository, storage: DocumentStorageManager, reader: TextSearchService,
         transport: any ArchiveCloudTransport, onStatus: @escaping (String, Bool) -> Void, onUpdate: @escaping () -> Void, onAccess: @escaping (Bool) -> Void = { _ in }, onSuspended: @escaping () -> Void = {}) {
        self.repository = repository; self.storage = storage; self.reader = reader; self.transport = transport
        self.onStatus = onStatus; self.onUpdate = onUpdate; self.onAccess = onAccess; self.onSuspended = onSuspended
    }
    func schedule() {
        guard !stopped else { return }
        if let date = try? repository.cloudRetryDate(), date > Date() { return }
        guard worker == nil else { rerun = true; return }
        worker = Task {
            repeat {
                rerun = false
                do {
                    try await sync(); try repository.setCloudRetryDate(nil)
                    let conflicts = try repository.syncConflicts().count
                    let pending = try repository.pendingSyncOperations().count
                    let textPending = try repository.hasPendingCloudText(writable: writable)
                    onStatus(conflicts > 0 ? "\(conflicts) changes need review" : ((writable && pending > 0) || textPending ? "Changes are waiting to sync" : "Up to date"), false)
                }
                catch is CancellationError { break }
                catch {
                    #if STOWKIT_LIVE_VERIFICATION
                    print("STOWKIT_LIVE_ERROR: \(String(reflecting: error))")
                    #endif
                    onStatus(error.localizedDescription, true)
                    let code = (error as? CKError)?.code
                    if code == .permissionFailure || code == .zoneNotFound || code == .userDeletedZone || code == .notAuthenticated || (error as? CloudArchiveError) == .accountChanged {
                        stopped = true; await storage.setCloudTransport(nil); onAccess(false); onSuspended()
                    } else {
                        let delay = ((error as? CKError)?.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? 60
                        try? repository.setCloudRetryDate(Date().addingTimeInterval(max(1, delay)))
                    }
                    break
                }
            } while rerun && !Task.isCancelled
            worker = nil
        }
    }
    func stop() async {
        stopped = true; worker?.cancel(); await worker?.value; worker = nil
        await storage.setCloudTransport(nil)
    }
    func waitUntilIdle() async { await worker?.value }
    private func sync() async throws {
        try await transport.verifyAccount()
        writable = try await transport.canWrite(); onAccess(writable)
        onStatus("Preparing archive…", false)
        while try writable && !repository.backfillSyncBatch() { try Task.checkCancellation(); await Task.yield() }
        onStatus("Receiving changes…", false)
        try await receive()
        onUpdate()
        while writable && !Task.isCancelled {
            let operations = try repository.pendingSyncOperations()
            guard !operations.isEmpty else { break }
            var progressed = false
            for operation in operations {
                try Task.checkCancellation()
                if operation.metadata.recordKey.hasPrefix("document:"),
                   let id = UUID(uuidString: String(operation.metadata.recordKey.dropFirst(9))), let doc = try repository.document(id) {
                    if try repository.originalCloudState(id)?.cloudVerified != true && repository.originalCloudState(id)?.remote != true {
                        onStatus("Uploading original…", false)
                        let original = try await storage.localOriginal(for: doc)
                        try await transport.uploadOriginal(doc, url: original)
                        try await storage.verifyCloudOriginal(doc, transport: transport)
                        try repository.markOriginalVerified(id)
                    }
                }
                let request = try repository.cloudRequest(operation)
                let result = try await transport.save(request)
                try repository.acceptCloudSave(result, sent: operation)
                progressed = progressed || result.saved != nil
                onUpdate()
            }
            // Avoid spinning against repeated concurrent writes; the next catch-up retries.
            if !progressed { break }
        }
        var uploadOffset = 0
        while writable {
            let batch = try repository.pendingTextUploads(offset: uploadOffset)
            guard !batch.isEmpty else { break }
            for (id, operationID) in batch {
                try Task.checkCancellation()
                guard let document = try repository.document(id), try repository.processingJob(id)?.state == "complete" else {
                    uploadOffset += 1; continue
                }
                let pages = try await reader.pages(for: id).map { CloudTextPage(index: $0.index, text: $0.text, method: $0.method) }
                try await transport.uploadText(document, pages: pages)
                try repository.acknowledgeTextUpload(operationID)
            }
            await Task.yield()
        }
        try await receive()
        var downloadOffset = 0
        while true {
            let batch = try repository.pendingTextDownloads(offset: downloadOffset)
            guard !batch.isEmpty else { break }
            for head in batch {
                try Task.checkCancellation()
                guard try repository.canApplyCloudText(head) else { downloadOffset += 1; continue }
                let pages = try await transport.downloadText(head)
                try repository.applyCloudText(pages, head: head)
                // A local extraction or newer incoming head may have won while awaiting I/O.
                if try repository.pendingTextDownloads(offset: downloadOffset).contains(where: { $0.originalHash == head.originalHash }) {
                    downloadOffset += 1
                }
            }
            await Task.yield()
        }
        try Task.checkCancellation(); onUpdate()
    }
    private func receive() async throws {
        var resetHistory = false
        repeat {
            try Task.checkCancellation()
            var token = try repository.incomingSyncToken()
            let page: CloudChangePage
            do { page = try await transport.fetchChanges(after: token) }
            catch let error as CKError where error.code == .changeTokenExpired && !resetHistory {
                resetHistory = true
                try repository.resetIncomingCloudToken(); token = ""
                page = try await transport.fetchChanges(after: token)
            }
            if page.token != token { try repository.applyCloudPage(page, after: token) }
            else if !page.records.isEmpty || !page.textHeads.isEmpty { throw SyncRecoveryError.stalePage }
            if !page.moreComing { break }
        } while !Task.isCancelled
    }
}
