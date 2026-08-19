import Foundation
import OSLog

private let crmLogger = Logger(subsystem: "tech.moonfive.MFSynced", category: "CRMSync")

private func crmLog(_ message: String) {
    crmLogger.info("\(message, privacy: .public)")
    // Buffered for upload to the nexus (drained by uploadLogs each poll) —
    // an append can never block or fail, see FleetLogBuffer.
    FleetLogBuffer.shared.append(line: message)
    // Also write to file for easy tailing
    let path = NSHomeDirectory() + "/Library/Logs/mfsynced_crm.log"
    let line = "\(Date()): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path),
       let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/Library/Logs",
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path))
    }
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
    var chatServiceHint: ((String) -> String?)?
    /// CNContactStore name + JPEG for a phone; injected like chatServiceHint.
    var contactInfoProvider: ((String) -> (name: String?, photoJPEG: Data?))?
    // Internal (not private) for test visibility of retry semantics.
    var pushedContactPhones = Set<String>()
    /// chat.db's current max message ROWID — watermark taken just before a
    /// send so the verifier can find the row that send created.
    var chatMaxRowID: (() -> Int64)?
    /// Delivery state (receipt + error code) of the first outgoing message
    /// after a watermark; nil until Messages writes the row.
    var deliveryProbe: ((String, Int64) -> (delivered: Bool, errorCode: Int)?)?
    private var pollTimer: Timer?
    /// Main-thread only (timer closure + main-actor reset).
    private var pollInFlight = false
    private let session = URLSession.shared
    /// App-process start, for the heartbeat's uptime_seconds.
    private let launchedAt = Date()

    init(config: CRMConfig, syncQueue: SyncQueueDatabase = SyncQueueDatabase()) {
        self._config = config
        self.syncQueue = syncQueue
        crmLog("[CRM] init — isEnabled=\(config.isEnabled) endpoint='\(config.apiEndpoint)' synced=\(config.syncedPhoneNumbers.count)")
    }

    func updateConfig(_ config: CRMConfig) {
        configLock.lock()
        _config = config
        configLock.unlock()
    }

    func startPolling() {
        guard config.isEnabled, !config.apiEndpoint.isEmpty else {
            crmLog("[CRM] startPolling: skipped — isEnabled=\(config.isEnabled) endpoint='\(config.apiEndpoint)'")
            return
        }
        crmLog("[CRM] startPolling: starting timer every \(config.pollIntervalSeconds)s → \(config.apiEndpoint)")
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
            Task {
                await self.poll()
                await MainActor.run { self.pollInFlight = false }
            }
        }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

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
        crmLog("[CRM] poll() called")
        await pullGate()
        await sendHeartbeat()
        await pushInbound()
        await pullOutbound()
        await pushContactInfo()
        await updateCounts()
        // Last on purpose: logs describe the tick that just happened, and a
        // slow/failed upload must never delay the messaging work above.
        await uploadLogs()
    }

    /// Drain one batch of buffered crmLog lines to the nexus
    /// (POST {apiEndpoint}/logs). Failure re-buffers the batch (drop-oldest
    /// cap applies); a legacy backend (404) discards it — there is nowhere
    /// for those lines to go, and hoarding them would only evict newer ones.
    func uploadLogs() async {
        let batch = FleetLogBuffer.shared.drain(max: 200)
        guard !batch.isEmpty else { return }
        guard let url = URL(string: "\(config.apiEndpoint)/logs") else { return }

        let iso = ISO8601DateFormatter()
        let lines: [[String: Any]] = batch.map { entry in
            [
                "ts": iso.string(from: entry.ts),
                "level": entry.level,
                "category": entry.category,
                "line": entry.line,
            ]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["agent_id": config.agentID, "lines": lines]
        )
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                FleetLogBuffer.shared.requeue(batch)
                return
            }
            switch http.statusCode {
            case 200:
                break
            case 404:
                break  // Legacy backend: no log wire; drop the batch.
            default:
                FleetLogBuffer.shared.requeue(batch)
            }
        } catch {
            FleetLogBuffer.shared.requeue(batch)
        }
    }

    /// Pull the server-desired allowlist and APPLY it (config-sync pattern:
    /// desired → applied → reported back via the next heartbeat).
    ///
    /// Removal is enforced all the way down: a number that left the gate is
    /// dropped from the local set AND its already-queued rows are purged, so
    /// nothing captured earlier keeps uploading after the owner revoked it.
    func pullGate() async {
        guard let url = URL(string: "\(config.apiEndpoint)/gate") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
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
            mutateConfig { $0.syncedPhoneNumbers = desired }
            crmLog(
                "[CRM] gate applied: \(desired.count) number(s) "
                + "(+\(desired.subtracting(current).count) -\(removed.count))"
            )
        } catch {
            // Offline or transient — keep the last applied list.
        }
    }

    /// Put a number through the gate via the server (audited, owner-rooted).
    /// Returns true when the number is synced after the call. Against the
    /// legacy backend (404) it falls back to the old local-only add.
    @discardableResult
    func requestGateAdd(_ phone: String) async -> Bool {
        guard let url = URL(string: "\(config.apiEndpoint)/gate/entries") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["phone": phone])
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
        appVersion: String?
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
        return body
    }

    func sendHeartbeat() async {
        guard let url = URL(string: "\(config.apiEndpoint)/heartbeat") else { return }
        let body = Self.heartbeatBody(
            config: config,
            hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            uptimeSeconds: Int(Date().timeIntervalSince(launchedAt)),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
    func pushContactInfo() async {
        guard let provider = contactInfoProvider else { return }
        for phone in config.syncedPhoneNumbers where !pushedContactPhones.contains(phone) {
            let (name, photoJPEG) = provider(phone)
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

            guard let url = URL(string: "\(config.apiEndpoint)/contacts"),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            if let (_, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                crmLog("[CRM] pushContactInfo: sent \(phone) photo=\(photoJPEG != nil)")
            } else {
                // Retry on a later poll. Deliberate for transient failures
                // (offline); a permanently-failing backend costs one small
                // POST per synced phone per poll, accepted.
                pushedContactPhones.remove(phone)
            }
        }
    }

    /// Watch chat.db for the just-sent message's delivery receipt or error
    /// and upgrade the ack accordingly. No verdict within the window leaves
    /// the command at "sent" — honest for plain SMS, which may never produce
    /// a receipt; a receipt upgrades to "delivered"; a Messages error code
    /// acks "failed" so the portal finally SHOWS undelivered sends.
    private func verifyDeliveryAndAck(commandID: String, phone: String, afterRowID: Int64) {
        guard let probe = deliveryProbe else { return }
        Task.detached { [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
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
        guard let url = URL(string: "\(config.apiEndpoint)/messages/inbound") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                for entry in entries {
                    let backoff = min(300.0, 5.0 * pow(2.0, Double(entry.retryCount)))
                    try? syncQueue.incrementRetry(messageGuid: entry.messageGuid, nextRetryIn: backoff)
                }
                await MainActor.run { isConnected = false }
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let confirmed = json["confirmed"] as? [String] {
                for guid in confirmed { try? syncQueue.remove(messageGuid: guid) }
            }
            await MainActor.run { isConnected = true; lastSyncTime = Date() }
        } catch {
            await MainActor.run { isConnected = false }
        }

        // Mirror: fire-and-forget to second backend (failures don't affect primary)
        if config.hasMirror,
           let mirrorURL = URL(string: "\(config.mirrorApiEndpoint)/messages/inbound") {
            var mirrorReq = URLRequest(url: mirrorURL)
            mirrorReq.httpMethod = "POST"
            mirrorReq.setValue("Bearer \(config.mirrorApiKey)", forHTTPHeaderField: "Authorization")
            mirrorReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            mirrorReq.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await session.data(for: mirrorReq)
        }
    }

    private func pullOutbound() async {
        crmLog("[CRM] pullOutbound called → \(config.apiEndpoint)/messages/outbound")
        guard let url = URL(string: "\(config.apiEndpoint)/messages/outbound?agent_id=\(config.agentID)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else { return }

            for msg in messages {
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
                let hint = chatServiceHint?(phone)
                crmLog("[CRM] pullOutbound: service hint for \(phone) = \(hint ?? "nil")")
                let preRowID = chatMaxRowID?() ?? 0
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
        guard let url = URL(string: "\(config.apiEndpoint)/messages/outbound/\(commandID)/ack") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["status": status])
        _ = try? await session.data(for: request)
    }

    func syncHistory(chatIdentifier: String, chatDB: ChatDatabase, contactName: String? = nil) async {
        crmLog("[syncHistory] START chatIdentifier=\(chatIdentifier) contact=\(contactName ?? "nil")")
        do {
            let messages = try chatDB.fetchMessages(forChat: chatIdentifier, limit: 10000)
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

                // Primary
                if let url = URL(string: "\(config.apiEndpoint)/sync/\(chatIdentifier)/history") {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = bodyData
                    do {
                        let (data, response) = try await session.data(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let body = String(data: data, encoding: .utf8) ?? "<binary>"
                        crmLog("[syncHistory] primary batch \(batchIdx) → HTTP \(status): \(body.prefix(200))")
                    } catch {
                        crmLog("[syncHistory] primary batch \(batchIdx) ERROR: \(error)")
                    }
                } else {
                    crmLog("[syncHistory] primary: invalid URL from endpoint '\(config.apiEndpoint)'")
                }

                // Mirror
                if config.hasMirror,
                   let mirrorURL = URL(string: "\(config.mirrorApiEndpoint)/sync/\(chatIdentifier)/history") {
                    var mirrorReq = URLRequest(url: mirrorURL)
                    mirrorReq.httpMethod = "POST"
                    mirrorReq.setValue("Bearer \(config.mirrorApiKey)", forHTTPHeaderField: "Authorization")
                    mirrorReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    mirrorReq.httpBody = bodyData
                    do {
                        let (data, response) = try await session.data(for: mirrorReq)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let body = String(data: data, encoding: .utf8) ?? "<binary>"
                        crmLog("[syncHistory] mirror batch \(batchIdx) → HTTP \(status): \(body.prefix(200))")
                    } catch {
                        crmLog("[syncHistory] mirror batch \(batchIdx) ERROR: \(error)")
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
