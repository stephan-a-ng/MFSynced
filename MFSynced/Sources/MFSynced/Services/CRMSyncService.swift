import Foundation
import OSLog

private let crmLogger = Logger(subsystem: "tech.moonfive.MFSynced", category: "CRMSync")

/// A one-shot synchronous-to-async start barrier. Tracked tasks wait here
/// until their owner has inserted them into its cancellation registry,
/// eliminating the finish-before-register and stop-between-create/insert
/// races without running work under an NSLock.
final class TrackedTaskStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else { lock.unlock(); return }
        isOpen = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

enum SensitiveDiagnostics {
    private static let lock = NSLock()
    private static let ioQueue = DispatchQueue(label: "tech.moonfive.MFSynced.sensitive-diagnostics")
    private static var logsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs", isDirectory: true)
    private static var enabled = false
    private static var generation: UInt64 = 0

    static func configure(logsDirectory: URL) {
        lock.lock()
        self.logsDirectory = logsDirectory
        generation &+= 1
        lock.unlock()
        ioQueue.sync {
            try? FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    static func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        if !value { generation &+= 1 }
        lock.unlock()
    }

    @discardableResult
    static func record(_ message: String, bufferForFleet: Bool) -> Bool {
        lock.lock()
        guard enabled else { lock.unlock(); return false }
        let directory = logsDirectory
        let recordGeneration = generation
        if bufferForFleet {
            FleetLogBuffer.shared.append(line: message)
        }
        lock.unlock()

        let path = directory.appendingPathComponent("mfsynced_crm.log")
        let line = "\(Date()): \(message)\n"
        guard let data = line.data(using: .utf8) else { return true }
        ioQueue.async {
            // A disable/purge or directory reconfiguration invalidates every
            // queued write from the previous generation. purge() also runs
            // its deletion on this queue, so a write already in progress is
            // guaranteed to finish before the file is removed.
            lock.lock()
            let shouldWrite = enabled
                && generation == recordGeneration
                && logsDirectory == directory
            lock.unlock()
            guard shouldWrite else { return }
            if let handle = try? FileHandle(forWritingTo: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: path)
            }
        }
        return true
    }

    static func purge() {
        lock.lock()
        enabled = false
        generation &+= 1
        let directory = logsDirectory
        FleetLogBuffer.shared.purge()
        lock.unlock()
        ioQueue.sync {
            for filename in [
                "mfsynced_messages.txt",
                "mfsynced_conversations.txt",
                "mfsynced_crm.log",
            ] {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(filename)
                )
            }
        }
    }

    /// Returns a failed upload batch to the in-memory queue only while
    /// sensitive diagnostics are still enabled. Sign-out disables and
    /// purges under this same lock, so an in-flight upload can never put
    /// drained identifiers or message metadata back after the privacy gate
    /// closes.
    static func requeue(_ batch: [FleetLogBuffer.Entry]) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        FleetLogBuffer.shared.requeue(batch)
    }
}

private func crmLog(_ message: String) {
    guard SensitiveDiagnostics.record(message, bufferForFleet: true) else { return }
    crmLogger.info("\(message, privacy: .public)")
}

struct OutboundResult {
    let commandID: String
    let phone: String
    let text: String
    let success: Bool
    let error: String?
    let timestamp: Date
}

@Observable
final class CRMSyncService {
    var isConnected: Bool = false
    var lastSyncTime: Date?
    var pendingInbound: Int = 0
    var pendingOutbound: Int = 0
    var recentOutboundResults: [OutboundResult] = []

    // Config is read from the poll task and written by the gate wire and
    // the settings UI — a plain var would be a cross-task data race on the
    // Set inside. Every access goes through the lock; reads take a value
    // snapshot (CRMConfig is a struct), writers use mutateConfig so the
    // save + change notification can never be forgotten.
    private let configLock = NSLock()
    private var _config: CRMConfig
    private var config: CRMConfig {
        configLock.lock()
        defer { configLock.unlock() }
        return _config
    }

    /// The one channel back to the UI: AppState holds its own copy of the
    /// config (value type), so every service-side change — a gate pull, a
    /// server add, the 409 rollback on the next pull — must be pushed to it
    /// or the sidebar's sync flags lie. Called on the main queue.
    var onConfigChanged: ((CRMConfig) -> Void)?

    private func mutateConfig(_ transform: (inout CRMConfig) -> Void) {
        configLock.lock()
        transform(&_config)
        let snapshot = _config
        configLock.unlock()
        snapshot.save()
        DispatchQueue.main.async { [weak self] in
            self?.onConfigChanged?(snapshot)
        }
    }

    private let syncQueue: SyncQueueDatabase
    /// Looks up a chat's Messages service ("iMessage"/"SMS"/...) so outbound
    /// sends target the right account. Injected (ChatDatabase-backed) so the
    /// sync service stays testable without a live chat.db.
    var chatServiceHint: (@Sendable (String) -> String?)?
    /// CNContactStore name + JPEG for a phone; injected like chatServiceHint.
    var contactInfoProvider: (@MainActor @Sendable (String) -> (name: String?, photoJPEG: Data?))?
    /// Test seam for `pushContactInfo()`'s `/contacts` POST: when set, the
    /// request is routed through this closure instead of a real `URLSession`
    /// call, returning the HTTP status code to react to (nil simulates a
    /// network failure / no response). Same closure-override DI (dependency
    /// injection) convention as `chatServiceHint`/`contactInfoProvider` — nil in production, so the
    /// real network path always runs there; tests set it to exercise the
    /// 200/404/5xx branches without a live endpoint. Internal (not private)
    /// for test visibility.
    var contactPushStatusOverride: ((URLRequest) -> Int?)?
    /// Applies one console-side contact NAME/PHOTO edit to this Mac's
    /// Address Book (S5 write-back); production wires
    /// ContactStore.applyContactUpdate in ContentView. Injected like
    /// contactInfoProvider so the sync service stays testable without live
    /// Contacts access. Returns whether anything was actually written —
    /// `false` (no local match, or nothing changed) still counts as a
    /// successfully-applied update for cursor-advance purposes; only a
    /// thrown network/parse error withholds the advance.
    var contactUpdateApplier: (@MainActor @Sendable ([String], String?, Data?) -> Bool)?
    /// Test seam for `pullContactUpdates()`'s GET `/contact-updates`: when
    /// set, the request is routed through this closure instead of a real
    /// `URLSession` call, returning (status code, response body) to react
    /// to (nil simulates a network failure / no response). Same
    /// closure-override DI convention as `contactPushStatusOverride` — nil
    /// in production, so the real network path always runs there; tests
    /// set it to exercise the 200/404/error branches without a live
    /// endpoint. Internal (not private) for test visibility.
    var contactUpdatesFetchOverride: ((URLRequest) -> (status: Int, body: Data)?)?
    /// Enumerates every 1:1 conversation (metadata only) for the candidate
    /// catalog upload; injected (ChatDatabase.fetchCatalog()-backed in
    /// production) so the sync service stays testable without a live chat.db.
    var catalogChatsProvider: (@Sendable () throws -> [ChatCatalogEntry])?
    /// Fetches one chat's messages for staged upload — the `StagedFetchMode`
    /// says which of ChatDatabase's three fetch shapes to use: `.backfill`
    /// → newest `limit` (fetchMessages(forChat:limit:)); `.continueBackfill`
    /// → newest `limit` older than `beforeRowID` (fetchMessages(forChat:
    /// limit:beforeRowID:)); `.incremental` → ROWID > afterRowID
    /// (fetchMessages(forChat:afterRowID:limit:)). Injected like
    /// catalogChatsProvider so the sync service stays testable without a
    /// live chat.db.
    var stagedMessagesProvider: (@Sendable (_ chatIdentifier: String, _ mode: StagedFetchMode) throws -> [Message])?
    // Internal (not private) for test visibility of retry semantics.
    var pushedContactPhones = Set<String>()
    /// Catalog gating state — in-memory only (telemetry-like: a relaunch
    /// re-uploading is fine and intended). Internal for test visibility.
    var lastCatalogUploadAt: TimeInterval?
    var lastCatalogFingerprint: Int?
    var lastCatalogSuccessAt: TimeInterval?
    /// Overridable by tests so the gating math can run on fake clocks instead
    /// of waiting on real wall-clock seconds.
    var catalogMinIntervalSeconds: TimeInterval = 60
    var catalogFloorIntervalSeconds: TimeInterval = 600
    /// contact-updates poll gating — in-memory only (a relaunch re-polling
    /// from the persisted cursor is fine and intended, same rationale as
    /// `lastCatalogUploadAt`). Internal for test visibility.
    var lastContactUpdatesPollAt: TimeInterval?
    /// Overridable by tests, same rationale as `catalogMinIntervalSeconds`.
    var contactUpdatesMinIntervalSeconds: TimeInterval = 60
    /// Best-guess "phone number/handle used on this Mac", for the
    /// heartbeat's `send_handle` — production wires
    /// ChatDatabase.selfHandle() (sqlite-backed, so DI like
    /// catalogChatsProvider/chatServiceHint keeps this testable without a
    /// live chat.db). nil (unset, or the provider itself returning nil)
    /// just omits `send_handle` from the heartbeat, same degrade as a
    /// blank owner_email.
    var selfHandleProvider: (@Sendable () -> String?)?
    /// `currentSendHandle()`'s cache — in-memory only, same rationale as
    /// `lastCatalogUploadAt`/`lastCatalogFingerprint`: a relaunch
    /// re-querying is fine and intended. UNLIKE most of this class's other
    /// poll-gating vars, this pair IS lock-protected (`sendHandleLock`):
    /// `poll()` is NOT actually serialized end-to-end despite
    /// `pollInFlight` — `ControlServer.handlePoll()` calls
    /// `syncService.poll()` directly from its own `Task` for its
    /// localhost e2e-testing control API, with no `pollInFlight` check at
    /// all, so a timer-driven `poll()` and a ControlServer-driven one can
    /// run concurrently against the same instance and both reach
    /// `sendHeartbeat()` at once. (That gap pre-exists this change and
    /// also affects `lastCatalogUploadAt`/`lastContactUpdatesPollAt` —
    /// out of scope here, but not repeated for this new state.) Internal
    /// for test visibility; mutate only through `currentSendHandle()` so
    /// the lock is never bypassed.
    var cachedSendHandle: String?
    var lastSendHandleQueryAt: TimeInterval?
    /// Overridable by tests, same rationale as `catalogMinIntervalSeconds`.
    var sendHandleCacheIntervalSeconds: TimeInterval = 600
    private let sendHandleLock = NSLock()
    /// chat.db's current max message ROWID — watermark taken just before a
    /// send so the verifier can find the row that send created.
    var chatMaxRowID: (@Sendable () -> Int64)?
    /// Delivery state (receipt + error code) of the first outgoing message
    /// after a watermark; nil until Messages writes the row.
    var deliveryProbe: (@Sendable (String, Int64) -> (delivered: Bool, errorCode: Int)?)?
    /// Fires once for each identifier `pullGate()` finds newly added to the
    /// server-desired gate (see `gateBackfillTargets`) — the completeness
    /// backstop beyond the ~2000 staged rows the server already promoted:
    /// the Mac backfills that conversation's FULL history via the same
    /// syncHistory path the forward/manual-add flows use. Injected
    /// (AppState-backed, driving AppState.syncHistoryToCRM(forChatIdentifier:))
    /// so the sync service stays testable without a live chat.db — same DI
    /// pattern as catalogChatsProvider/stagedMessagesProvider. The service
    /// launches each callback in its tracked background-task registry so a
    /// long backfill never stalls heartbeat/outbound delivery and sign-out
    /// can still cancel it.
    var historyBackfillRequest: (@MainActor @Sendable (String) async -> Void)?
    /// Identifiers already sent through `historyBackfillRequest` this
    /// process launch — in-memory only (telemetry-like: a relaunch
    /// re-running a backfill is acceptable, same rationale as
    /// `lastCatalogUploadAt`). Deliberately never cleared, including when a
    /// number leaves the gate: a number that flickers gated/un-gated/gated
    /// again already has its full history from the first backfill, so
    /// re-fetching it from scratch again would be redundant work, not a
    /// correctness fix. Internal (not private) for test visibility.
    var backfilledThisSession = Set<String>()
    private var pollTimer: Timer?
    private let taskLock = NSLock()
    private var pollTask: Task<Void, Never>?
    /// All work intentionally detached from the serial poll (delivery
    /// receipt checks and gate-triggered history backfills). Registration
    /// and stop use the same lock so nothing can escape sign-out cleanup.
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    /// Main-thread only (timer closure + main-actor reset).
    private var pollInFlight = false
    /// Best-effort re-entrancy guard for uploadStaged() — NOT a mutex, and
    /// unlike pollInFlight it isn't actually needed for correctness today:
    /// poll() is the sole caller, and poll() is itself already serialized by
    /// pollInFlight, so two uploadStaged() calls can never overlap in
    /// practice. This only protects against a future direct call racing an
    /// in-flight one. No lock — same plain-Bool style as its siblings.
    private var stagedUploadInFlight = false
    private let session = URLSession.shared
    /// App-process start, for the heartbeat's uptime_seconds.
    private let launchedAt = Date()
    private let authService: AuthService
    /// Sent as X-Agent-Name on every request — same value sendHeartbeat()
    /// already reports as `hostname`.
    private static let agentHostname: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    init(
        config: CRMConfig,
        syncQueue: SyncQueueDatabase = SyncQueueDatabase(),
        // Explicit by design. Production wires AuthService.shared
        // (Keychain-backed) at its one call site (AppState.startPolling).
        // Compatibility tests inject a legacy-enabled in-memory fixture, so
        // a new production call site can never inherit fallback by default.
        authService: AuthService
    ) {
        self._config = config
        self.syncQueue = syncQueue
        self.authService = authService
        crmLog("[CRM] init — isEnabled=\(config.isEnabled) endpoint='\(config.apiEndpoint)' synced=\(config.syncedPhoneNumbers.count)")
    }

    /// Legacy per-endpoint config predates `targets`: a manually-configured
    /// endpoint (pre-migration installs) still wins so those setups keep
    /// working exactly as before. A fresh sign-in-only install never
    /// populates `apiEndpoint` at all, so this falls back to the first
    /// configured sync target — the same URL basis pushInbound/syncHistory
    /// already use via `config.targets`.
    private var agentEndpoint: String {
        config.apiEndpoint.isEmpty ? (config.targets.first?.url.absoluteString ?? "") : config.apiEndpoint
    }

    /// Resolves the Authorization header value for an outbound request:
    /// Delegates every credential decision to AuthService. Production uses
    /// the shared OIDC-required instance; isolated compatibility tests opt
    /// into the legacy key path explicitly.
    private func authorizationHeaderValue() async -> String? {
        await authService.authorizationHeaderValue(legacyKey: config.apiKey)
    }

    /// Builds one outbound request with the standard auth + agent-identity
    /// headers every wire call now carries (Authorization, X-Agent-Id,
    /// X-Agent-Name), plus Content-Type when there's a JSON body.
    private func makeRequest(url: URL, method: String, body: Data?, authorization: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(config.agentID, forHTTPHeaderField: "X-Agent-Id")
        request.setValue(Self.agentHostname, forHTTPHeaderField: "X-Agent-Name")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Appends `path` onto one sync target's base URL — same string-concat
    /// convention this file already uses for `config.apiEndpoint`.
    private func targetURL(_ target: SyncTarget, path: String) -> URL? {
        URL(string: target.url.absoluteString + path)
    }

    func updateConfig(_ config: CRMConfig) {
        configLock.lock()
        _config = config
        configLock.unlock()
    }

    func startPolling() {
        // `stopped` blocks every tracked background operation, including a
        // user-requested history sync. Clear it before the automatic-polling
        // configuration guard: CRM can be disabled while manual forwarding
        // and history sync remain valid authenticated actions.
        taskLock.lock()
        stopped = false
        taskLock.unlock()
        // Endpoint availability checks agentEndpoint (not the raw legacy
        // apiEndpoint field): a sign-in-only install never populates
        // apiEndpoint at all, but always has a non-empty sync target to
        // fall back to.
        guard config.isEnabled, !agentEndpoint.isEmpty else {
            crmLog("[CRM] startPolling: skipped — isEnabled=\(config.isEnabled) endpoint='\(agentEndpoint)'")
            return
        }
        crmLog("[CRM] startPolling: starting timer every \(config.pollIntervalSeconds)s → \(agentEndpoint)")
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.pollIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            // One tick at a time: the timer fires on the main run loop, and
            // pollInFlight is only touched here and in the main-actor reset
            // below, so a slow network can delay ticks but never overlap
            // two poll() tasks racing the same state.
            guard !self.pollInFlight else {
                crmLog("[CRM] timer fired — previous poll still running, skipping tick")
                return
            }
            self.pollInFlight = true
            crmLog("[CRM] timer fired")
            let task = Task {
                await self.poll()
                await MainActor.run { self.pollInFlight = false }
            }
            self.taskLock.lock()
            self.pollTask = task
            self.taskLock.unlock()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
        taskLock.lock()
        stopped = true
        let pollTask = self.pollTask
        self.pollTask = nil
        let backgroundTasks = Array(self.backgroundTasks.values)
        self.backgroundTasks.removeAll()
        taskLock.unlock()
        pollTask?.cancel()
        backgroundTasks.forEach { $0.cancel() }
    }

    func queueInbound(message: Message, contactName: String? = nil) {
        guard config.syncedPhoneNumbers.contains(message.chatIdentifier ?? "") else { return }
        var payload: [String: Any] = [
            "id": message.guid,
            "phone": message.senderID ?? message.chatIdentifier ?? "",
            "text": message.displayText ?? "",
            "timestamp": ISO8601DateFormatter().string(from: message.date),
            "is_from_me": message.isFromMe,
            "service": message.service,
        ]
        if let name = contactName { payload["contact_name"] = name }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        try? syncQueue.enqueue(direction: "inbound", messageGuid: message.guid, phone: message.chatIdentifier ?? "", payload: jsonString)
    }

    /// True once the backend has answered GET /gate — from then on the
    /// server-desired allowlist is authoritative and local removal is a
    /// console action, not a Mac action. Stays false against the legacy
    /// backend (404), which keeps every pre-nexus behavior intact.
    private(set) var serverGateActive = false

    func poll() async {
        guard !Task.isCancelled, !isStopped else { return }
        crmLog("[CRM] poll() called")
        await pullGate()
        guard !Task.isCancelled, !isStopped else { return }
        await pullContactUpdates()
        guard !Task.isCancelled, !isStopped else { return }
        await sendHeartbeat()
        guard !Task.isCancelled, !isStopped else { return }
        await pushInbound()
        guard !Task.isCancelled, !isStopped else { return }
        await pullOutbound()
        guard !Task.isCancelled, !isStopped else { return }
        await pushContactInfo()
        guard !Task.isCancelled, !isStopped else { return }
        await updateCounts()
        guard !Task.isCancelled, !isStopped else { return }
        // Last on purpose: logs describe the tick that just happened, and a
        // slow/failed upload must never delay the messaging work above.
        await uploadLogs()
        guard !Task.isCancelled, !isStopped else { return }
        // After logs, never blocking messaging: candidate catalog is
        // telemetry for the console review tab, not part of the send/receive
        // path.
        await uploadCatalog()
        guard !Task.isCancelled, !isStopped else { return }
        // Last of all: staged content upload is background console-review
        // material for non-gated chats, never part of the send/receive path.
        await uploadStaged()
    }

    private var isStopped: Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return stopped
    }

    /// Drain one batch of buffered crmLog lines to the nexus
    /// (POST {apiEndpoint}/logs). Failure re-buffers the batch (drop-oldest
    /// cap applies); a legacy backend (404) discards it — there is nowhere
    /// for those lines to go, and hoarding them would only evict newer ones.
    func uploadLogs() async {
        let batch = FleetLogBuffer.shared.drain(max: 200)
        guard !batch.isEmpty else { return }
        guard let url = URL(string: "\(agentEndpoint)/logs") else { return }
        guard let authorization = await authorizationHeaderValue() else {
            SensitiveDiagnostics.requeue(batch)
            return
        }

        let iso = ISO8601DateFormatter()
        let lines: [[String: Any]] = batch.map { entry in
            [
                "ts": iso.string(from: entry.ts),
                "level": entry.level,
                "category": entry.category,
                "line": entry.line,
            ]
        }
        let bodyData = try? JSONSerialization.data(
            withJSONObject: ["agent_id": config.agentID, "lines": lines]
        )
        let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                SensitiveDiagnostics.requeue(batch)
                return
            }
            switch http.statusCode {
            case 200:
                break
            case 404:
                break  // Legacy backend: no log wire; drop the batch.
            default:
                SensitiveDiagnostics.requeue(batch)
            }
        } catch {
            SensitiveDiagnostics.requeue(batch)
        }
    }

    /// Pure diff: which of `desired`'s identifiers should get an automatic
    /// history backfill triggered right now. An identifier qualifies when
    /// it is newly present — in `desired` but not `previouslyApplied`, i.e.
    /// the gate just gained it — AND has not already been backfilled this
    /// session (`alreadyBackfilled`, see `backfilledThisSession`). Sorted
    /// for deterministic test/log output (the inputs are Sets). Static and
    /// pure so the diff + dedup logic is testable without network or
    /// chat.db (mirrors `catalogUploadDecision`/`stagedRowsPlan`) — the
    /// caller (`pullGate`) supplies the real Sets and fires
    /// `historyBackfillRequest` for each result.
    static func gateBackfillTargets(
        previouslyApplied: Set<String>,
        desired: Set<String>,
        alreadyBackfilled: Set<String>
    ) -> [String] {
        let newlyAdded = desired.subtracting(previouslyApplied)
        return newlyAdded.subtracting(alreadyBackfilled).sorted()
    }

    /// Pull the server-desired allowlist and APPLY it (config-sync pattern:
    /// desired → applied → reported back via the next heartbeat).
    ///
    /// Removal is enforced all the way down: a number that left the gate is
    /// dropped from the local set AND its already-queued rows are purged, so
    /// nothing captured earlier keeps uploading after the owner revoked it.
    ///
    /// A number newly added to the gate also gets its full history
    /// backfilled (see `gateBackfillTargets`) — the completeness backstop
    /// beyond the ~2000 staged rows the server already promoted when the
    /// conversation was shared in the console. A number added FROM the Mac
    /// side (`requestGateAdd`, e.g. the sidebar's right-click add, or
    /// `pullOutbound`'s auto-enable-on-send) never appears here as "newly
    /// added": `requestGateAdd` applies the server's confirmed set via
    /// `mutateConfig` as soon as its own HTTP round trip completes, which
    /// happens well before the next timer-driven `pullGate()` tick, so
    /// `current` below already contains it by the time this diff runs. That
    /// path also never called `syncHistory` before this change, so this is
    /// a no-op for it either way, not a suppressed duplicate.
    func pullGate() async {
        guard let url = URL(string: "\(agentEndpoint)/gate") else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        let request = makeRequest(url: url, method: "GET", body: nil, authorization: authorization)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                // Legacy backend: no gate wire. Local list stays
                // authoritative — but STICKY the other way: once the gate
                // wire has answered 200 once, a lone 404 (proxy hiccup,
                // mid-deploy route gap) must not reopen local-only edits
                // the console believes it owns. Deployed routes do not
                // disappear.
                return
            }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let phones = json["phones"] as? [String] else { return }
            serverGateActive = true
            let desired = Set(phones)
            let current = config.syncedPhoneNumbers
            guard desired != current else { return }

            let removed = current.subtracting(desired)
            for phone in removed {
                try? syncQueue.removeAll(phone: phone)
            }
            let added = desired.subtracting(current)
            mutateConfig { $0.syncedPhoneNumbers = desired }
            crmLog(
                "[CRM] gate applied: \(desired.count) number(s) "
                + "(+\(added.count) -\(removed.count))"
            )

            // Completeness backstop: backfill full history for every number
            // that just entered the gate, at most once per identifier per
            // session (see `backfilledThisSession`'s doc comment).
            let backfillTargets = Self.gateBackfillTargets(
                previouslyApplied: current, desired: desired, alreadyBackfilled: backfilledThisSession
            )
            for phone in backfillTargets {
                backfilledThisSession.insert(phone)
                crmLog("[CRM] gate backfill: triggering history sync for \(phone)")
                guard let historyBackfillRequest else { continue }
                launchBackgroundTask { [weak self] in
                    guard let self, !Task.isCancelled, !self.isStopped else { return }
                    await historyBackfillRequest(phone)
                }
            }
        } catch {
            // Offline or transient — keep the last applied list.
        }
    }

    /// Put a number through the gate via the server (audited, owner-rooted).
    /// Returns true when the number is synced after the call. Against the
    /// legacy backend (404) it falls back to the old local-only add.
    @discardableResult
    func requestGateAdd(_ phone: String) async -> Bool {
        guard let url = URL(string: "\(agentEndpoint)/gate/entries") else { return false }
        guard let authorization = await authorizationHeaderValue() else { return false }
        let bodyData = try? JSONSerialization.data(withJSONObject: ["phone": phone])
        let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            switch http.statusCode {
            case 200:
                serverGateActive = true
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let phones = json["phones"] as? [String] {
                    let desired = Set(phones)
                    mutateConfig { $0.syncedPhoneNumbers = desired }
                }
                return true
            case 404:
                // Legacy backend: keep the pre-nexus local behavior.
                mutateConfig { $0.syncedPhoneNumbers.insert(phone) }
                return true
            case 409:
                // No owner assigned yet — the structural onboarding rule.
                crmLog("[CRM] gate add \(phone) refused: agent has no owner (assign one in the console)")
                return false
            default:
                crmLog("[CRM] gate add \(phone): HTTP \(http.statusCode)")
                return false
            }
        } catch {
            crmLog("[CRM] gate add \(phone) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Contact write-back (S5)

    /// One console-side contact edit (NAME and/or PHOTO). `phones` may
    /// carry more than one number for the same person — the server has
    /// already deduped to latest-state-per-person — and ContactStore
    /// matches against the FIRST local CNContact ANY of them resolves to.
    struct ContactUpdate: Equatable {
        let phones: [String]
        let displayName: String?
        let photoJPEG: Data?
    }

    /// The `kv_state` key the contact-updates poll cursor is persisted
    /// under (see `SyncQueueDatabase.getState`/`setState`).
    static let contactUpdatesCursorKey = "contact_updates_cursor"

    /// Parses one GET `/contact-updates` 200 response body
    /// (`{"cursor": <int>, "updates": [{"phones": [...], "display_name":
    /// ..., "photo_thumb": "<base64 JPEG>"|null}, ...]}`). Pure — no
    /// network — so the happy-path and missing-field shapes are directly
    /// testable. A row missing `phones` is dropped (nothing to match it
    /// against); `display_name` is nil when absent or not a string; a
    /// present-but-invalid-base64 `photo_thumb` degrades to nil (name-only
    /// update) rather than failing the whole row. Returns nil for a
    /// malformed body (no top-level `cursor`) — `pullContactUpdates`
    /// treats that like a network error: cursor left untouched, retried
    /// next tick.
    static func parseContactUpdates(json data: Data) -> (cursor: Int, updates: [ContactUpdate])? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursor = obj["cursor"] as? Int else { return nil }
        let rawUpdates = obj["updates"] as? [[String: Any]] ?? []
        let updates: [ContactUpdate] = rawUpdates.compactMap { row in
            guard let phones = row["phones"] as? [String], !phones.isEmpty else { return nil }
            let displayName = row["display_name"] as? String
            let photoJPEG = (row["photo_thumb"] as? String).flatMap { Data(base64Encoded: $0) }
            return ContactUpdate(phones: phones, displayName: displayName, photoJPEG: photoJPEG)
        }
        return (cursor, updates)
    }

    /// Pulls console-side NAME/PHOTO edits down to this Mac's Address Book
    /// (GET `{apiEndpoint}/contact-updates?after=<cursor>`). Applies to ANY
    /// matching local contact, not just ones already shared to the CRM
    /// (Stephan's call) — see `ContactStore.applyContactUpdate`. Gated to
    /// once per `contactUpdatesMinIntervalSeconds`, the same cheap
    /// time-gate-first pattern `uploadCatalog` uses, since a full tick
    /// enumerates every local CNContact per matched update.
    ///
    /// Cursor persistence: `SyncQueueDatabase`'s `kv_state` table (key
    /// `contactUpdatesCursorKey`). The new cursor only advances after the
    /// WHOLE batch has been run through `contactUpdateApplier` — an
    /// applier returning `false` (no local match, or nothing changed) is a
    /// legitimate outcome and still advances; a thrown network error or a
    /// malformed response body does not, so the same batch is re-fetched
    /// next tick rather than silently skipped. A 404 (legacy backend, no
    /// contact-updates wire) degrades silently, same convention as
    /// `pullGate`/`uploadCatalog`/`uploadStaged`.
    func pullContactUpdates() async {
        guard let applier = contactUpdateApplier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Cheap time gate FIRST, before touching the sync queue or network.
        if let last = lastContactUpdatesPollAt, now - last < contactUpdatesMinIntervalSeconds {
            return
        }
        lastContactUpdatesPollAt = now

        let storedCursor = (try? syncQueue.getState(key: Self.contactUpdatesCursorKey)) ?? nil
        let cursor = storedCursor.flatMap(Int.init) ?? 0
        guard let url = URL(string: "\(agentEndpoint)/contact-updates?after=\(cursor)") else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        let request = makeRequest(url: url, method: "GET", body: nil, authorization: authorization)

        let result: (status: Int, body: Data)?
        if let override = contactUpdatesFetchOverride {
            result = override(request)
        } else {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                result = (http.statusCode, data)
            } catch {
                crmLog("[CRM] pullContactUpdates: network error: \(error.localizedDescription)")
                return
            }
        }
        guard let (status, body) = result else {
            crmLog("[CRM] pullContactUpdates: network error (no response)")
            return
        }

        switch status {
        case 200:
            guard let (newCursor, updates) = Self.parseContactUpdates(json: body) else {
                crmLog("[CRM] pullContactUpdates: malformed response, cursor left untouched")
                return
            }
            for update in updates {
                _ = await applier(update.phones, update.displayName, update.photoJPEG)
            }
            do {
                try syncQueue.setState(key: Self.contactUpdatesCursorKey, value: String(newCursor))
            } catch {
                // Reprocessing the batch next tick is idempotent — but a real
                // persistence fault must not be invisible.
                crmLog("[contactUpdates] cursor persist failed: \(error)")
            }
        case 404:
            // Legacy backend: no contact-updates wire. Silent skip, same
            // convention as pullGate's 404 handling.
            return
        default:
            crmLog("[CRM] pullContactUpdates: HTTP \(status)")
        }
    }

    /// Fleet telemetry for the nexus (POST {apiEndpoint}/heartbeat).
    ///
    /// Fire-and-forget on purpose: a heartbeat must never block or fail
    /// message sync, and an old backend that 404s the route costs nothing.
    /// Every field is optional on the wire; the server samples what it
    /// forwards to the datalake, so sending each poll tick is fine.
    /// Builds the heartbeat JSON body from config + live process values.
    /// Pure and static on purpose: sendHeartbeat() supplies the real
    /// hostname/uptime/etc, tests supply fixed values and assert on the
    /// dict directly, without a network call in the loop.
    static func heartbeatBody(
        config: CRMConfig,
        hostname: String,
        osVersion: String,
        uptimeSeconds: Int,
        appVersion: String?,
        sendHandle: String? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "agent_id": config.agentID,
            "hostname": hostname,
            "os_version": osVersion,
            "poll_interval_seconds": max(1, Int(config.pollIntervalSeconds)),
            "uptime_seconds": max(0, uptimeSeconds),
            "gate_applied": Array(config.syncedPhoneNumbers).sorted(),
        ]
        if let appVersion {
            body["app_version"] = appVersion
        }
        // Omitted (not sent as empty) when unset: an absent key is a no-op
        // for the backend's first-claim-wins owner assignment, while an
        // empty string could be mistaken for an explicit clear.
        let trimmedOwnerEmail = config.ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOwnerEmail.isEmpty {
            body["owner_email"] = trimmedOwnerEmail
        }
        // Same omit-when-blank convention as owner_email above. The nexus
        // contract caps this at 255 chars; ChatDatabase.selfHandle() (via
        // selectSelfHandle) only ever returns a chat.db handle string,
        // which is nowhere near that length in practice, so no truncation
        // is applied here.
        if let trimmedSendHandle = sendHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedSendHandle.isEmpty {
            body["send_handle"] = trimmedSendHandle
        }
        return body
    }

    /// Returns the cached self-handle, re-querying `selfHandleProvider` only
    /// when the cache is empty or older than `sendHandleCacheIntervalSeconds`
    /// — chat.db's `selfHandle()` opens a sqlite connection and scans every
    /// chat row, far more than a 5s poll tick should pay for a value that
    /// essentially never changes mid-session. The timestamp is updated on
    /// every re-query, including a nil result, so a chat.db read error
    /// doesn't turn into a retry-every-tick loop.
    ///
    /// Lock-protected (`sendHandleLock`), NOT relying on `poll()`
    /// serialization: `ControlServer`'s localhost `/poll` endpoint can call
    /// `syncService.poll()` (→ `sendHeartbeat()` → this method) concurrently
    /// with the timer-driven poll — see the doc comment on
    /// `cachedSendHandle`. The provider itself runs OUTSIDE the lock: it
    /// opens its own sqlite connection per call (`ChatDatabase.selfHandle()`
    /// makes no shared-state assumption), so a concurrent provider call from
    /// a losing thread is redundant work, not a correctness problem — only
    /// the cache fields themselves need mutual exclusion. Internal (not
    /// private) for direct test access without going through the async
    /// network path in `sendHeartbeat()`.
    func currentSendHandle() async -> String? {
        guard let provider = selfHandleProvider else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        let freshCache: (isFresh: Bool, value: String?) = sendHandleLock.withLock {
            guard let last = lastSendHandleQueryAt,
                  now - last < sendHandleCacheIntervalSeconds else {
                return (false, nil)
            }
            return (true, cachedSendHandle)
        }
        if freshCache.isFresh { return freshCache.value }

        // Provider call happens outside the lock (see doc comment) — two
        // threads can race into here and both call the provider, but each
        // then re-takes the lock to publish, so the cache never observes a
        // half-written state and always ends up with SOME valid result
        // (whichever thread writes last), never a torn value.
        let result = provider()

        sendHandleLock.withLock {
            lastSendHandleQueryAt = now
            cachedSendHandle = result
        }

        return result
    }

    func sendHeartbeat() async {
        guard let url = URL(string: "\(agentEndpoint)/heartbeat") else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        let body = Self.heartbeatBody(
            config: config,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            uptimeSeconds: Int(Date().timeIntervalSince(launchedAt)),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sendHandle: await currentSendHandle()
        )
        let bodyData = try? JSONSerialization.data(withJSONObject: body)
        let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 404 = old backend without the fleet wire; anything else is
                // worth one line per tick in the local log, nothing more.
                if http.statusCode != 404 {
                    crmLog("[CRM] heartbeat: HTTP \(http.statusCode)")
                }
            }
        } catch {
            crmLog("[CRM] heartbeat failed: \(error.localizedDescription)")
        }
    }

    /// Push CNContactStore name+photo for synced phones the backend hasn't
    /// been given yet this app session. Once per phone per launch: uploads
    /// are ephemeral on the backend, so each launch re-heals the avatars.
    ///
    /// Wire reality: the legacy CRM backend implements POST
    /// {apiEndpoint}/contacts and still needs this push during the
    /// transition. The nexus does NOT implement it —
    /// contact_name + photo_thumb already ride along on every chat in the
    /// S2 candidate-catalog upload (`uploadCatalog`, POST /catalog), and the
    /// server copies the photo onto the org-side Person at SHARE time, so a
    /// per-phone push is redundant on that wire. A 404 here means "this
    /// backend doesn't have the route" — same convention as
    /// `pullGate`/`uploadLogs`/`uploadCatalog` — so the phone is marked
    /// pushed (permanent-for-this-launch skip) instead of retried every poll
    /// tick forever. Any other failure (5xx/network) is presumed transient
    /// on a backend that DOES implement the route, so it still retries, same
    /// as before.
    func pushContactInfo() async {
        guard let provider = contactInfoProvider else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        for phone in config.syncedPhoneNumbers where !pushedContactPhones.contains(phone) {
            let (name, photoJPEG) = await provider(phone)
            // Not marked pushed yet: an unresolved contact (ContactStore may
            // still be building its phone map, or waiting on the permission
            // dialog) must be retried on a later poll, not skipped for the
            // whole session. The provider call is an in-memory lookup, so
            // retrying costs no HTTP.
            guard name != nil || photoJPEG != nil else { continue }
            pushedContactPhones.insert(phone)

            var payload: [String: Any] = ["phone": phone]
            if let name { payload["name"] = name }
            if let photoJPEG { payload["photo_base64"] = photoJPEG.base64EncodedString() }

            guard let url = URL(string: "\(agentEndpoint)/contacts"),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let request = makeRequest(url: url, method: "POST", body: body, authorization: authorization)

            switch await contactPushStatusCode(for: request) {
            case 200:
                crmLog("[CRM] pushContactInfo: sent \(phone) photo=\(photoJPEG != nil)")
            case 404:
                // No /contacts route on this backend (the nexus — catalog +
                // share-time copy already covers it). Stay marked pushed:
                // retrying a route that will never appear is pure noise.
                crmLog("[CRM] pushContactInfo: \(phone) — no /contacts route, not retrying this launch")
            default:
                // Retry on a later poll. Deliberate for transient failures
                // (offline, or a real legacy-backend outage); a
                // permanently-failing backend costs one small POST per
                // synced phone per poll, accepted.
                pushedContactPhones.remove(phone)
            }
        }
    }

    /// Performs the `/contacts` POST and returns its HTTP status code (nil
    /// for a network failure or non-HTTP response). Routes through
    /// `contactPushStatusOverride` when a test has set one; otherwise runs
    /// the real `URLSession` call.
    private func contactPushStatusCode(for request: URLRequest) async -> Int? {
        if let override = contactPushStatusOverride {
            return override(request)
        }
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// One 1:1 conversation's enriched metadata, ready for `catalogBody`.
    /// Pure input struct: production builds it from ChatCatalogEntry +
    /// contactInfoProvider, tests build it by hand.
    struct CatalogChatInput {
        let chatIdentifier: String
        let displayName: String
        let contactName: String?
        let photoJPEG: Data?
        let lastActivityAt: Date?
        let messageCount: Int
    }

    /// A base64 JPEG this long or longer is dropped from the row rather than
    /// sent — 100KB (binary) already exceeds anything a contact thumbnail
    /// should encode to, and a partial/oversized blob helps the console less
    /// than a row with no photo at all.
    static let catalogMaxPhotoBase64Length = 100 * 1024

    /// Chats per POST — kept well under typical body-size limits; larger
    /// catalogs go out as multiple sequential POSTs (see `catalogBodies`).
    static let catalogChunkSize = 500

    /// Builds one POST body ({"agent_id", "chats": [...]}) for a chunk of
    /// chats. Pure and static like `heartbeatBody`: production supplies real
    /// chat.db + Contacts data, tests assert on the dict directly.
    static func catalogBody(agentID: String, chats: [CatalogChatInput]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let chatDicts: [[String: Any]] = chats.map { chat in
            var dict: [String: Any] = [
                "chat_identifier": chat.chatIdentifier,
                "display_name": chat.displayName,
                "message_count": chat.messageCount,
            ]
            if let contactName = chat.contactName, !contactName.isEmpty {
                dict["contact_name"] = contactName
            }
            if let photoJPEG = chat.photoJPEG {
                let base64 = photoJPEG.base64EncodedString()
                if base64.utf8.count <= catalogMaxPhotoBase64Length {
                    dict["photo_thumb"] = base64
                }
            }
            if let lastActivityAt = chat.lastActivityAt {
                dict["last_activity_at"] = iso.string(from: lastActivityAt)
            }
            return dict
        }
        return ["agent_id": agentID, "chats": chatDicts]
    }

    /// Splits `chats` into `catalogChunkSize`-sized POST bodies, in the same
    /// order every time (the caller sorts/orders `chats` beforehand). Pure:
    /// exercised directly by the chunking test without any network I/O.
    static func catalogBodies(
        agentID: String, chats: [CatalogChatInput], chunkSize: Int = catalogChunkSize
    ) -> [[String: Any]] {
        guard !chats.isEmpty else { return [] }
        return stride(from: 0, to: chats.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, chats.count)
            return catalogBody(agentID: agentID, chats: Array(chats[start..<end]))
        }
    }

    /// A stable-within-process identity for "the same catalog contents":
    /// combines sorted "chat_identifier|last_activity|message_count" triples
    /// so unrelated field changes (contact name/photo) don't force a resend,
    /// but a new/changed/removed chat or a new message does. Process-lifetime
    /// only (Hasher's seed is randomized per launch) — fine, since the
    /// fingerprint itself is in-memory-only state (see lastCatalogFingerprint).
    static func catalogFingerprint(chats: [CatalogChatInput]) -> Int {
        let iso = ISO8601DateFormatter()
        let lines = chats.map { chat -> String in
            let activity = chat.lastActivityAt.map { iso.string(from: $0) } ?? ""
            return "\(chat.chatIdentifier)|\(activity)|\(chat.messageCount)"
        }.sorted()
        var hasher = Hasher()
        for line in lines { hasher.combine(line) }
        return hasher.finalize()
    }

    enum CatalogUploadDecision: Equatable {
        /// Inside the 60s floor since the last attempt (success or not) —
        /// don't touch the network at all this tick.
        case tooSoon
        /// Fingerprint unchanged and still within the 10-minute floor since
        /// the last SUCCESSFUL upload — nothing new to report yet.
        case skipUnchanged
        /// Either the catalog changed, or it's been long enough that a lost
        /// server-side row shouldn't go stale forever.
        case upload
    }

    /// Pure gating decision — no network, no wall-clock sleep, so the skip
    /// and floor-resend tests run instantly on fake clock values. Mirrors the
    /// two rules from the S2 spec: at most once per `minIntervalSeconds`, and
    /// (independently) a forced resend at least every `floorIntervalSeconds`
    /// even when nothing changed.
    static func catalogUploadDecision(
        now: TimeInterval,
        lastUploadAt: TimeInterval?,
        minIntervalSeconds: TimeInterval,
        fingerprint: Int,
        lastFingerprint: Int?,
        lastSuccessAt: TimeInterval?,
        floorIntervalSeconds: TimeInterval
    ) -> CatalogUploadDecision {
        if let lastUploadAt, now - lastUploadAt < minIntervalSeconds {
            return .tooSoon
        }
        if fingerprint == lastFingerprint {
            let sinceSuccess = lastSuccessAt.map { now - $0 } ?? .infinity
            if sinceSuccess < floorIntervalSeconds {
                return .skipUnchanged
            }
        }
        return .upload
    }

    /// Uploads the candidate catalog (POST {apiEndpoint}/catalog, chunked at
    /// `catalogChunkSize`) so the console review tab can list every 1:1
    /// conversation — metadata only, never message bodies. Gated to at most
    /// once per `catalogMinIntervalSeconds`, and skipped when the fingerprint
    /// is unchanged within `catalogFloorIntervalSeconds` of the last success.
    /// Fire-and-forget like the heartbeat/log uploads: never blocks
    /// messaging, and a legacy backend (404) degrades silently — same
    /// handling as pullGate, see `catalogUploadDecision`'s 404 case below.
    func uploadCatalog() async {
        guard let provider = catalogChatsProvider else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Cheap time gate FIRST: the chat.db scan and per-chat contact/photo
        // enrichment below are far more expensive than the POST they feed, so
        // they must sit behind the same 60s floor — not run every poll tick.
        if let last = lastCatalogUploadAt, now - last < catalogMinIntervalSeconds {
            return
        }

        guard let rawChats = try? provider() else { return }
        var chats: [CatalogChatInput] = []
        chats.reserveCapacity(rawChats.count)
        for entry in rawChats {
            guard !Task.isCancelled, !isStopped else { return }
            let contact = await contactInfoProvider?(entry.chatIdentifier)
            guard !Task.isCancelled, !isStopped else { return }
            // chat.db stores EMPTY STRING (not NULL) for nearly every 1:1
            // chat's display_name — `??` alone never fires, and the nexus
            // requires a non-empty display_name, so "" would 422 the whole
            // catalog chunk. Empty means absent here.
            let rawName = entry.displayName ?? ""
            chats.append(CatalogChatInput(
                chatIdentifier: entry.chatIdentifier,
                displayName: rawName.isEmpty ? entry.chatIdentifier : rawName,
                contactName: contact?.name,
                photoJPEG: contact?.photoJPEG,
                lastActivityAt: entry.lastActivityAt,
                messageCount: entry.messageCount
            ))
        }
        let fingerprint = Self.catalogFingerprint(chats: chats)

        let decision = Self.catalogUploadDecision(
            now: now,
            lastUploadAt: lastCatalogUploadAt,
            minIntervalSeconds: catalogMinIntervalSeconds,
            fingerprint: fingerprint,
            lastFingerprint: lastCatalogFingerprint,
            lastSuccessAt: lastCatalogSuccessAt,
            floorIntervalSeconds: catalogFloorIntervalSeconds
        )
        switch decision {
        case .tooSoon:
            return
        case .skipUnchanged:
            // The full database/enrichment pass itself is an attempt worth
            // throttling. Without advancing this timestamp an unchanged
            // catalog would repeat every poll tick until the forced-resend
            // floor, including one MainActor contact lookup per chat.
            lastCatalogUploadAt = now
            return
        case .upload:
            break
        }
        // Set BEFORE the network call: the 60s floor limits attempt
        // frequency regardless of outcome, so a persistently failing
        // endpoint can't be hammered every poll tick.
        lastCatalogUploadAt = now

        guard let url = URL(string: "\(agentEndpoint)/catalog") else { return }
        let bodies = Self.catalogBodies(agentID: config.agentID, chats: chats)
        guard !bodies.isEmpty else {
            // Nothing to report (no 1:1 chats yet) is still a real, uploadable
            // state — but with no chats there's nothing to POST or persist
            // against; leave fingerprint/successAt untouched so a chat that
            // appears later is picked up on the very next tick.
            return
        }
        // Not authenticated (signed out, no legacy key): the 60s floor above
        // was already touched, but nothing here can be marked successful.
        guard let authorization = await authorizationHeaderValue() else { return }

        var succeeded = true
        for body in bodies {
            let bodyData = try? JSONSerialization.data(withJSONObject: body)
            let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { succeeded = false; continue }
                switch http.statusCode {
                case 200:
                    continue
                case 404:
                    // Legacy backend: no catalog wire. Silent degrade, same
                    // as pullGate's 404 handling — no log, no state update
                    // (fingerprint/successAt stay nil/stale), so the 60s
                    // floor alone brings us back to try again next tick,
                    // forever, without ever spamming the log.
                    return
                default:
                    crmLog("[CRM] uploadCatalog: HTTP \(http.statusCode)")
                    succeeded = false
                }
            } catch {
                succeeded = false
            }
        }
        if succeeded {
            lastCatalogFingerprint = fingerprint
            lastCatalogSuccessAt = now
        }
    }

    // MARK: - Staged content upload (S3)

    /// Rows per POST for uploadStaged, and the total per-tick fetch budget
    /// spent across all chats — kept equal since this service does exactly
    /// one POST per poll tick and the wire caps a POST at 200 rows.
    static let stagedBatchLimit = 200

    /// One wire-ready staged message row. `rowID` is bookkeeping only (chat.db
    /// ROWID, for cursor advancement) — it is never sent on the wire, only
    /// the guid identifies a row to the server.
    struct StagedMessageRow: Equatable {
        let chatIdentifier: String
        let guid: String
        let sender: String?
        let isFromMe: Bool
        let body: String
        let sentAt: Date
        let rowID: Int64
    }

    /// Whether a chat's fetch this tick is an initial backfill (no cursor
    /// row yet), a continuation of an in-progress backfill (cursor row with
    /// `backfillDone == false`), or incremental (cursor row with
    /// `backfillDone == true`, resuming after `afterRowID`) — and the
    /// request size/paging boundary to use in each case.
    enum StagedFetchMode: Equatable {
        case backfill(limit: Int)
        case continueBackfill(beforeRowID: Int64, limit: Int)
        case incremental(afterRowID: Int64, limit: Int)
    }

    struct StagedFetchPlan: Equatable {
        let chatIdentifier: String
        let mode: StagedFetchMode
    }

    /// The per-chat backfill target: the newest `stagedBackfillWindow`
    /// messages per chat are staged before a chat ever goes incremental;
    /// older history is out of scope by design. Equal to `stagedBatchLimit`
    /// today (both 200), but conceptually distinct — one bounds a single
    /// POST, the other bounds a chat's total backfill — so they're named
    /// separately rather than sharing a constant.
    static let stagedBackfillWindow = 200

    /// Which catalog chats get a staged-upload fetch this tick, backfill vs
    /// backfill-continuation vs incremental, and the request limit for each
    /// — decided purely from cursor presence/state (no cursor row ⇒ initial
    /// backfill; cursor row with backfillDone == false ⇒ continue backfill
    /// from where it left off; cursor row with backfillDone == true ⇒
    /// incremental) and a shared `budget` spent in `chats` order. Gated
    /// (already-live-synced) chats are excluded entirely: their content
    /// already flows through pushInbound, so staging it too would be
    /// redundant.
    ///
    /// A backfill (initial or continuation) chat's request is capped by how
    /// much of its `stagedBackfillWindow` remains — for an initial backfill
    /// that's `chat.messageCount` (already known from the catalog, no extra
    /// chat.db round trip); for a continuation it's `stagedBackfillWindow -
    /// cursor.backfilledCount`. Capping either way means the budget spent on
    /// a chat reflects what will actually come back, letting a second chat
    /// pick up the leftover in the same tick — e.g. two 150-message chats
    /// against a 200 budget split 150/50, not 200/0. An incremental chat's
    /// true row count isn't cheaply knowable ahead of the fetch, so it
    /// conservatively claims the rest of the tick's budget; any budget it
    /// doesn't actually use is simply picked up again next tick (fairness
    /// across ticks is fine — see the module doc).
    static func stagedRowsPlan(
        chats: [ChatCatalogEntry],
        cursors: [String: StagedCursor],
        gated: Set<String>,
        budget: Int
    ) -> [StagedFetchPlan] {
        var plans: [StagedFetchPlan] = []
        var remaining = budget
        for chat in chats {
            guard remaining > 0 else { break }
            guard !gated.contains(chat.chatIdentifier) else { continue }
            if let cursor = cursors[chat.chatIdentifier] {
                if cursor.backfillDone {
                    // Incremental probes do NOT consume plan budget: a done,
                    // quiet chat fetches zero rows, and charging it the
                    // remaining budget starved every later chat forever
                    // (observed live: 2 of 1518 chats processed, then a
                    // permanent zero-row tick loop). The real row budget is
                    // enforced at POST assembly — rows beyond the batch cap
                    // are dropped unsent, stay unconfirmed, and re-offer
                    // next tick.
                    plans.append(StagedFetchPlan(
                        chatIdentifier: chat.chatIdentifier,
                        mode: .incremental(afterRowID: cursor.lastRowID, limit: stagedBatchLimit)
                    ))
                } else {
                    let windowRemaining = max(0, stagedBackfillWindow - cursor.backfilledCount)
                    let limit = min(remaining, windowRemaining)
                    guard limit > 0 else { continue }
                    plans.append(StagedFetchPlan(
                        chatIdentifier: chat.chatIdentifier,
                        mode: .continueBackfill(beforeRowID: cursor.oldestRowID, limit: limit)
                    ))
                    remaining -= limit
                }
            } else {
                let limit = min(stagedBackfillWindow, remaining, chat.messageCount)
                guard limit > 0 else { continue }
                plans.append(StagedFetchPlan(chatIdentifier: chat.chatIdentifier, mode: .backfill(limit: limit)))
                remaining -= limit
            }
        }
        return plans
    }

    /// Converts one chat's already-fetched chat.db messages into wire rows,
    /// skipping messages with no displayable body (tapbacks, empty/whitespace
    /// text with no attributedBody fallback) — a row with nothing to show the
    /// owner in the console isn't worth a slot in the 200-row budget. Pure:
    /// takes already-fetched Message values, no chat.db access.
    static func stagedRows(chatIdentifier: String, messages: [Message]) -> [StagedMessageRow] {
        messages.compactMap { msg in
            guard let body = msg.displayText, !body.isEmpty else { return nil }
            return StagedMessageRow(
                chatIdentifier: chatIdentifier,
                guid: msg.guid,
                sender: msg.senderID,
                isFromMe: msg.isFromMe,
                body: body,
                sentAt: msg.date,
                rowID: msg.id
            )
        }
    }

    /// Builds the POST body ({"agent_id", "messages": [...]}) for `rows`.
    /// Pure and static like `catalogBody`/`heartbeatBody`: production
    /// supplies real chat.db rows, tests assert on the dict directly.
    static func stagedBody(agentID: String, rows: [StagedMessageRow]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let messages: [[String: Any]] = rows.map { row in
            var dict: [String: Any] = [
                "chat_identifier": row.chatIdentifier,
                "guid": row.guid,
                "is_from_me": row.isFromMe,
                "body": row.body,
                "sent_at": iso.string(from: row.sentAt),
            ]
            if let sender = row.sender {
                dict["sender"] = sender
            }
            return dict
        }
        return ["agent_id": agentID, "messages": messages]
    }

    /// Per-chat new cursor state after a staged-upload tick, from the mode
    /// each chat was fetched under this tick (from `plan`), which chats'
    /// CONFIRMED rows advance their progress, and which chats' backfill
    /// fetch came back with nothing left to page (`exhaustedChats`). Pure —
    /// no network, no chat.db — so it stays exercisable without a live
    /// server or database, including the exhausted-chat branch (which
    /// `uploadStaged` must apply independent of whether its POST even runs,
    /// since there's nothing to confirm for an exhausted chat).
    ///
    /// A chat with none of its rows confirmed this tick, and not exhausted,
    /// gets no entry here at all — its cursor (or lack of one) stays exactly
    /// where it was, so every row is re-offered next tick rather than
    /// silently dropped.
    ///
    /// - `exhaustedChats` (continuation fetch returned zero rows — history
    ///   for that chat is used up before reaching the newest-
    ///   `stagedBackfillWindow` target): `backfillDone` forced true,
    ///   `lastRowID`/`oldestRowID`/`backfilledCount` carried over from
    ///   `existingCursors` unchanged (nothing new was confirmed).
    /// - `.backfill` (first-ever confirmed batch): `lastRowID`/`oldestRowID`
    ///   span this tick's confirmed rows, `backfilledCount` = confirmed
    ///   count, `backfillDone` once that count already reaches
    ///   `stagedBackfillWindow` or the chat's whole catalog `messageCount`
    ///   (whichever is known — a chat with fewer than `stagedBackfillWindow`
    ///   messages total finishes backfill in one batch).
    /// - `.continueBackfill`: `lastRowID` is left as whatever the initial
    ///   batch set it to (continuation only pages OLDER messages, so it can
    ///   never be the newest-seen boundary), `oldestRowID` moves down to
    ///   this tick's minimum confirmed rowID, `backfilledCount` accumulates
    ///   onto the prior total, `backfillDone` once the running total reaches
    ///   `stagedBackfillWindow`.
    /// - `.incremental`: `lastRowID` advances to this tick's max confirmed
    ///   rowID (as before this cursor shape existed); `oldestRowID`/
    ///   `backfilledCount` are irrelevant once `backfillDone` and are simply
    ///   carried over unchanged.
    static func cursorUpdates(
        plan: [StagedFetchPlan],
        confirmedGuids: Set<String>,
        rows: [StagedMessageRow],
        exhaustedChats: Set<String>,
        existingCursors: [String: StagedCursor],
        messageCounts: [String: Int]
    ) -> [String: StagedCursor] {
        var updates: [String: StagedCursor] = [:]

        for chatIdentifier in exhaustedChats {
            let existing = existingCursors[chatIdentifier]
            updates[chatIdentifier] = StagedCursor(
                lastRowID: existing?.lastRowID ?? 0,
                oldestRowID: existing?.oldestRowID ?? 0,
                backfilledCount: existing?.backfilledCount ?? 0,
                backfillDone: true
            )
        }

        let modeByChat = Dictionary(uniqueKeysWithValues: plan.map { ($0.chatIdentifier, $0.mode) })
        var confirmedByChat: [String: [StagedMessageRow]] = [:]
        for row in rows where confirmedGuids.contains(row.guid) {
            confirmedByChat[row.chatIdentifier, default: []].append(row)
        }

        for (chatIdentifier, confirmed) in confirmedByChat {
            guard let mode = modeByChat[chatIdentifier] else { continue }
            let confirmedRowIDs = confirmed.map(\.rowID)
            guard let maxRowID = confirmedRowIDs.max(), let minRowID = confirmedRowIDs.min() else { continue }
            let existing = existingCursors[chatIdentifier]

            switch mode {
            case .backfill:
                let count = confirmed.count
                let done = count >= stagedBackfillWindow
                    || (messageCounts[chatIdentifier].map { count >= $0 } ?? false)
                updates[chatIdentifier] = StagedCursor(
                    lastRowID: maxRowID,
                    oldestRowID: minRowID,
                    backfilledCount: count,
                    backfillDone: done
                )
            case .continueBackfill:
                let newCount = (existing?.backfilledCount ?? 0) + confirmed.count
                updates[chatIdentifier] = StagedCursor(
                    lastRowID: existing?.lastRowID ?? maxRowID,
                    oldestRowID: minRowID,
                    backfilledCount: newCount,
                    backfillDone: newCount >= stagedBackfillWindow
                )
            case .incremental:
                updates[chatIdentifier] = StagedCursor(
                    lastRowID: maxRowID,
                    oldestRowID: existing?.oldestRowID ?? maxRowID,
                    backfilledCount: existing?.backfilledCount ?? 0,
                    backfillDone: true
                )
            }
        }
        return updates
    }

    /// Continuously uploads conversation content for every non-gated 1:1 chat
    /// to the nexus staging store (POST {apiEndpoint}/staged) so the owner
    /// can review it in the console before opting the number into the live
    /// gate. One POST per tick, bounded to `stagedBatchLimit` rows total —
    /// see `stagedRowsPlan` for the per-chat backfill/continuation/
    /// incremental split. Cursors only advance for CONFIRMED guids (see
    /// `cursorUpdates`); a 404 (legacy backend) degrades silently like
    /// pullGate, and any other failure leaves every cursor untouched so
    /// nothing is lost, only re-offered. A backfill-continuation chat whose
    /// fetch comes back empty (history exhausted before reaching the
    /// newest-`stagedBackfillWindow` target) is marked done immediately,
    /// independent of the POST outcome — there is nothing to confirm for it.
    func uploadStaged() async {
        guard !stagedUploadInFlight else { return }
        stagedUploadInFlight = true
        defer { stagedUploadInFlight = false }

        guard let catalogProvider = catalogChatsProvider,
              let messagesProvider = stagedMessagesProvider else { return }
        guard let chats = try? catalogProvider(), !chats.isEmpty else { return }

        let cursors = (try? syncQueue.allStagedCursors()) ?? [:]
        let plan = Self.stagedRowsPlan(
            chats: chats,
            cursors: cursors,
            gated: config.syncedPhoneNumbers,
            budget: Self.stagedBatchLimit
        )
        guard !plan.isEmpty else { return }

        var allRows: [StagedMessageRow] = []
        var exhaustedChats: Set<String> = []
        for entry in plan {
            guard !Task.isCancelled, !isStopped else { return }
            // The POST-side row budget: incremental plan entries are
            // budget-free probes, so the total is enforced here instead.
            // Rows beyond the cap are never fetched/sent; unconfirmed means
            // their cursors don't advance, so they re-offer next tick.
            if allRows.count >= Self.stagedBatchLimit { break }
            let messages = (try? messagesProvider(entry.chatIdentifier, entry.mode)) ?? []
            guard !Task.isCancelled, !isStopped else { return }
            if case .continueBackfill = entry.mode, messages.isEmpty {
                exhaustedChats.insert(entry.chatIdentifier)
            }
            let rows = Self.stagedRows(chatIdentifier: entry.chatIdentifier, messages: messages)
            let room = Self.stagedBatchLimit - allRows.count
            allRows.append(contentsOf: rows.prefix(room))
        }

        // History exhausted: nothing to POST or confirm for this chat, so it
        // must not wait on (or be skipped by) the network call below.
        if !exhaustedChats.isEmpty {
            let exhaustedUpdates = Self.cursorUpdates(
                plan: plan, confirmedGuids: [], rows: [],
                exhaustedChats: exhaustedChats, existingCursors: cursors, messageCounts: [:]
            )
            for (chatIdentifier, cursor) in exhaustedUpdates {
                try? syncQueue.setStagedCursor(
                    chatIdentifier: chatIdentifier,
                    lastRowID: cursor.lastRowID,
                    oldestRowID: cursor.oldestRowID,
                    backfilledCount: cursor.backfilledCount,
                    backfillDone: cursor.backfillDone
                )
            }
        }

        guard !allRows.isEmpty else { return }
        // Defensive: the plan bounds per-chat requests to the shared budget,
        // but never exceed the wire's hard per-POST cap.
        let rows = Array(allRows.prefix(Self.stagedBatchLimit))

        guard let url = URL(string: "\(agentEndpoint)/staged") else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        let bodyData = try? JSONSerialization.data(
            withJSONObject: Self.stagedBody(agentID: config.agentID, rows: rows)
        )
        let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let confirmed = json["confirmed"] as? [String] else { return }
                let messageCounts = Dictionary(
                    chats.map { ($0.chatIdentifier, $0.messageCount) }, uniquingKeysWith: { first, _ in first }
                )
                let updates = Self.cursorUpdates(
                    plan: plan,
                    confirmedGuids: Set(confirmed),
                    rows: rows,
                    exhaustedChats: [],
                    existingCursors: cursors,
                    messageCounts: messageCounts
                )
                for (chatIdentifier, cursor) in updates {
                    try? syncQueue.setStagedCursor(
                        chatIdentifier: chatIdentifier,
                        lastRowID: cursor.lastRowID,
                        oldestRowID: cursor.oldestRowID,
                        backfilledCount: cursor.backfilledCount,
                        backfillDone: cursor.backfillDone
                    )
                }
            case 404:
                // Legacy backend: no staged wire. Silent skip, like pullGate.
                return
            default:
                crmLog("[CRM] uploadStaged: HTTP \(http.statusCode)")
            }
        } catch {
            crmLog("[CRM] uploadStaged: network error: \(error.localizedDescription)")
        }
    }

    /// Watch chat.db for the just-sent message's delivery receipt or error
    /// and upgrade the ack accordingly. No verdict within the window leaves
    /// the command at "sent" — honest for plain SMS, which may never produce
    /// a receipt; a receipt upgrades to "delivered"; a Messages error code
    /// acks "failed" so the portal finally SHOWS undelivered sends.
    private func verifyDeliveryAndAck(commandID: String, phone: String, afterRowID: Int64) {
        guard let probe = deliveryProbe else { return }
        launchBackgroundTask { [weak self] in
            for _ in 0..<15 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                guard !Task.isCancelled, !self.isStopped else { return }
                guard let state = probe(phone, afterRowID) else { continue }
                if let verdict = MessageSender.deliveryAckStatus(
                    errorCode: state.errorCode, delivered: state.delivered
                ) {
                    await self.acknowledge(commandID: commandID, status: verdict)
                    crmLog("[CRM] deliveryVerify: cmd=\(commandID) → \(verdict)")
                    return
                }
            }
            crmLog("[CRM] deliveryVerify: cmd=\(commandID) no receipt in 30s — left as sent")
        }
    }

    private func launchBackgroundTask(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        let taskID = UUID()
        let startGate = TrackedTaskStartGate()
        let task = Task { [weak self] in
            await startGate.wait()
            guard !Task.isCancelled else { return }
            defer { self?.removeBackgroundTask(taskID) }
            await operation()
        }
        taskLock.lock()
        guard !stopped else {
            taskLock.unlock()
            task.cancel()
            startGate.open()
            return
        }
        backgroundTasks[taskID] = task
        taskLock.unlock()
        startGate.open()
    }

    private func removeBackgroundTask(_ id: UUID) {
        taskLock.lock()
        backgroundTasks.removeValue(forKey: id)
        taskLock.unlock()
    }

    private func pushInbound() async {
        guard var entries = try? syncQueue.fetchPending(direction: "inbound", limit: 50), !entries.isEmpty else { return }
        // Gate re-check at DRAIN time, not just capture time: a number
        // removed from the allowlist after its rows were queued must not
        // upload. Stale rows are purged, not retried.
        let gated = entries.filter { !config.syncedPhoneNumbers.contains($0.phone) }
        if !gated.isEmpty {
            for entry in gated { try? syncQueue.remove(messageGuid: entry.messageGuid) }
            crmLog("[CRM] pushInbound: purged \(gated.count) queued row(s) for un-gated numbers")
            entries.removeAll { !config.syncedPhoneNumbers.contains($0.phone) }
            if entries.isEmpty { return }
        }
        let messages = entries.compactMap { entry -> [String: Any]? in
            guard let data = entry.payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json
        }
        let body: [String: Any] = ["agent_id": config.agentID, "messages": messages]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        // Every target gets the same payload — replaces the old single
        // apiEndpoint + optional mirrorApiEndpoint pair. The FIRST target
        // is authoritative: its response drives isConnected, confirmed-guid
        // removal, and retry backoff. Every additional target is
        // fire-and-forget, same as the old mirror POST. Each target
        // resolves its OWN Authorization header (signed-in OIDC Bearer, or
        // that target's own legacy key) — never reuses another target's
        // credential, so a legacy prod key can never reach a staging (or
        // any other) target's URL.
        let targets = config.targets
        guard let primaryTarget = targets.first, let primaryURL = targetURL(primaryTarget, path: "/messages/inbound") else {
            await MainActor.run { isConnected = false }
            return
        }
        guard let primaryAuthorization = await authService.authorizationHeaderValue(for: primaryTarget) else {
            for entry in entries {
                let backoff = min(300.0, 5.0 * pow(2.0, Double(entry.retryCount)))
                try? syncQueue.incrementRetry(messageGuid: entry.messageGuid, nextRetryIn: backoff)
            }
            await MainActor.run { isConnected = false }
            crmLog("[CRM] pushInbound \(primaryTarget.name): skipped — signed out and no legacy key")
            return
        }

        let request = makeRequest(url: primaryURL, method: "POST", body: bodyData, authorization: primaryAuthorization)
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                for entry in entries {
                    let backoff = min(300.0, 5.0 * pow(2.0, Double(entry.retryCount)))
                    try? syncQueue.incrementRetry(messageGuid: entry.messageGuid, nextRetryIn: backoff)
                }
                await MainActor.run { isConnected = false }
                crmLog("[CRM] pushInbound \(primaryTarget.name): HTTP \(status)")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let confirmed = json["confirmed"] as? [String] {
                for guid in confirmed { try? syncQueue.remove(messageGuid: guid) }
            }
            await MainActor.run { isConnected = true; lastSyncTime = Date() }
            crmLog("[CRM] pushInbound \(primaryTarget.name): HTTP 200")
        } catch {
            await MainActor.run { isConnected = false }
            crmLog("[CRM] pushInbound \(primaryTarget.name): network error: \(error.localizedDescription)")
        }

        // Mirrors: fire-and-forget to every additional target (failures
        // don't affect the primary target's outcome above). Never silently
        // discarded — every mirror's outcome (including a signed-out skip)
        // gets its own crmLog line.
        for mirrorTarget in targets.dropFirst() {
            guard let mirrorURL = targetURL(mirrorTarget, path: "/messages/inbound") else {
                crmLog("[CRM] pushInbound \(mirrorTarget.name): invalid URL")
                continue
            }
            guard let mirrorAuthorization = await authService.authorizationHeaderValue(for: mirrorTarget) else {
                crmLog("[CRM] pushInbound \(mirrorTarget.name): skipped — signed out and no legacy key")
                continue
            }
            let mirrorRequest = makeRequest(url: mirrorURL, method: "POST", body: bodyData, authorization: mirrorAuthorization)
            do {
                let (_, mirrorResponse) = try await session.data(for: mirrorRequest)
                let status = (mirrorResponse as? HTTPURLResponse)?.statusCode ?? -1
                crmLog("[CRM] pushInbound \(mirrorTarget.name): HTTP \(status)")
            } catch {
                crmLog("[CRM] pushInbound \(mirrorTarget.name): network error: \(error.localizedDescription)")
            }
        }
    }

    private func pullOutbound() async {
        crmLog("[CRM] pullOutbound called → \(agentEndpoint)/messages/outbound")
        guard let url = URL(string: "\(agentEndpoint)/messages/outbound?agent_id=\(config.agentID)") else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        let request = makeRequest(url: url, method: "GET", body: nil, authorization: authorization)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else { return }

            for msg in messages {
                guard !Task.isCancelled, !isStopped else { return }
                guard let cmdID = msg["id"] as? String,
                      let phone = msg["phone"] as? String,
                      let text = msg["text"] as? String else { continue }
                crmLog("[CRM] pullOutbound: sending cmd=\(cmdID) to=\(phone) text_len=\(text.count)")
                // A portal-initiated send may target a phone that was never
                // opted in to sync; without opting it in, the sent message
                // and any reply never flow back to the backend. The opt-in
                // goes THROUGH the server gate (audited, owner-rooted);
                // requestGateAdd falls back to the old local insert against
                // a legacy backend, and a 409 (no owner) leaves the number
                // un-synced by design.
                if !config.syncedPhoneNumbers.contains(phone) {
                    if await requestGateAdd(phone) {
                        crmLog("[CRM] pullOutbound: auto-enabled sync for new contact \(phone)")
                    }
                }
                guard !Task.isCancelled, !isStopped else { return }
                let hint = chatServiceHint?(phone)
                guard !Task.isCancelled, !isStopped else { return }
                crmLog("[CRM] pullOutbound: service hint for \(phone) = \(hint ?? "nil")")
                let preRowID = chatMaxRowID?() ?? 0
                guard !Task.isCancelled, !isStopped else { return }
                let result = MessageSender.send(text: text, to: phone, preferredService: hint)
                let status: String
                let sendSuccess: Bool
                var sendError: String? = nil
                switch result {
                case .success:
                    // AppleScript success only means Messages ACCEPTED the
                    // send — a stuck iMessage to a non-iMessage recipient
                    // looks identical. Ack "sent" now; the real verdict
                    // (delivered / failed) comes from chat.db's receipt and
                    // error fields via the detached verifier below.
                    status = "sent"
                    sendSuccess = true
                    crmLog("[CRM] pullOutbound: sent cmd=\(cmdID) to=\(phone), verifying delivery")
                case .failure(let err):
                    status = "failed: \(err.localizedDescription)"
                    sendSuccess = false
                    sendError = err.localizedDescription
                    crmLog("[CRM] pullOutbound: FAILED cmd=\(cmdID) to=\(phone) error=\(err.localizedDescription)")
                }
                let outboundResult = OutboundResult(
                    commandID: cmdID, phone: phone, text: text,
                    success: sendSuccess, error: sendError, timestamp: Date()
                )
                await MainActor.run {
                    recentOutboundResults.append(outboundResult)
                    if recentOutboundResults.count > 50 { recentOutboundResults.removeFirst() }
                }
                await acknowledge(commandID: cmdID, status: status)
                crmLog("[CRM] pullOutbound: acked cmd=\(cmdID) status=\(status)")
                if sendSuccess {
                    verifyDeliveryAndAck(commandID: cmdID, phone: phone, afterRowID: preRowID)
                }
            }
        } catch {
            crmLog("[CRM] pullOutbound: network error: \(error)")
        }
    }

    private func acknowledge(commandID: String, status: String) async {
        guard let url = URL(string: "\(agentEndpoint)/messages/outbound/\(commandID)/ack") else { return }
        guard let authorization = await authorizationHeaderValue() else { return }
        let bodyData = try? JSONSerialization.data(withJSONObject: ["status": status])
        let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)
        _ = try? await session.data(for: request)
    }

    func startHistorySync(
        chatIdentifier: String,
        chatDB: ChatDatabase,
        contactName: String? = nil
    ) {
        launchBackgroundTask { [weak self] in
            await self?.syncHistory(
                chatIdentifier: chatIdentifier,
                chatDB: chatDB,
                contactName: contactName
            )
        }
    }

    private func syncHistory(chatIdentifier: String, chatDB: ChatDatabase, contactName: String? = nil) async {
        guard !Task.isCancelled, !isStopped else { return }
        crmLog("[syncHistory] START chatIdentifier=\(chatIdentifier) contact=\(contactName ?? "nil")")
        guard !config.targets.isEmpty else {
            crmLog("[syncHistory] skipped — no sync targets configured")
            return
        }
        do {
            let messages = try chatDB.fetchMessages(forChat: chatIdentifier, limit: 10000)
            guard !Task.isCancelled, !isStopped else { return }
            crmLog("[syncHistory] fetched \(messages.count) messages from chat.db")
            if let first = messages.first, let last = messages.last {
                let fmt = ISO8601DateFormatter()
                crmLog("[syncHistory] date range: \(fmt.string(from: first.date)) → \(fmt.string(from: last.date))")
                crmLog("[syncHistory] sample first id=\(first.id) date=\(fmt.string(from: first.date))")
            }

            let batches = stride(from: 0, to: messages.count, by: 100).map {
                Array(messages[$0..<min($0 + 100, messages.count)])
            }
            crmLog("[syncHistory] sending \(batches.count) batch(es)")

            for (batchIdx, batch) in batches.enumerated() {
                guard !Task.isCancelled, !isStopped else { return }
                let payload = batch.map { msg -> [String: Any] in
                    var m: [String: Any] = ["id": msg.guid, "phone": msg.senderID ?? chatIdentifier,
                     "text": msg.displayText ?? "", "timestamp": ISO8601DateFormatter().string(from: msg.date),
                     "is_from_me": msg.isFromMe, "service": msg.service]
                    if let name = contactName { m["contact_name"] = name }
                    return m
                }
                let body: [String: Any] = ["agent_id": config.agentID, "messages": payload]
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    crmLog("[syncHistory] ERROR: failed to serialize batch \(batchIdx)")
                    continue
                }

                // Same payload to every configured target — replaces the old
                // single apiEndpoint + optional mirrorApiEndpoint pair. Each
                // target is independently fire-and-forget here (unlike
                // pushInbound, syncHistory has no single "authoritative"
                // response to act on — it's a one-shot backfill, not a
                // queue that needs a confirmed-guid drain). Each target
                // resolves its OWN Authorization header (signed-in OIDC
                // Bearer, or that target's own legacy key) — never reuses
                // another target's credential (see
                // AuthService.authorizationHeaderValue(for:)), so this is
                // the SAME derived-targets basis pushInbound uses: gate/
                // outbound and content always address the same backend(s).
                for target in config.targets {
                    guard !Task.isCancelled, !isStopped else { return }
                    guard let url = targetURL(target, path: "/sync/\(chatIdentifier)/history") else {
                        crmLog("[syncHistory] \(target.name): invalid URL")
                        continue
                    }
                    guard let authorization = await authService.authorizationHeaderValue(for: target) else {
                        crmLog("[syncHistory] \(target.name): skipped — signed out and no legacy key")
                        continue
                    }
                    guard !Task.isCancelled, !isStopped else { return }
                    let request = makeRequest(url: url, method: "POST", body: bodyData, authorization: authorization)
                    do {
                        let (data, response) = try await session.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let respBody = String(data: data, encoding: .utf8) ?? "<binary>"
                        crmLog("[syncHistory] \(target.name) batch \(batchIdx) → HTTP \(status): \(respBody.prefix(200))")
                    } catch {
                        crmLog("[syncHistory] \(target.name) batch \(batchIdx) ERROR: \(error)")
                    }
                }
            }
            crmLog("[syncHistory] DONE chatIdentifier=\(chatIdentifier)")
        } catch {
            crmLog("[syncHistory] FAILED to fetch from chat.db: \(error)")
        }
    }

    @MainActor
    private func updateCounts() {
        pendingInbound = (try? syncQueue.pendingCount(direction: "inbound")) ?? 0
        pendingOutbound = (try? syncQueue.pendingCount(direction: "outbound_ack")) ?? 0
    }
}
