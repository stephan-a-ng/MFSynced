import Foundation
import OSLog

private let crmLogger = Logger(subsystem: "tech.moonfive.MFSynced", category: "CRMSync")

private func crmLog(_ message: String) {
    crmLogger.info("\(message, privacy: .public)")
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

@Observable
final class CRMSyncService {
    var isConnected: Bool = false
    var lastSyncTime: Date?
    var pendingInbound: Int = 0
    var pendingOutbound: Int = 0

    private var config: CRMConfig
    private let syncQueue: SyncQueueDatabase
    private var pollTimer: Timer?
    private let session = URLSession.shared

    init(config: CRMConfig, syncQueue: SyncQueueDatabase = SyncQueueDatabase()) {
        self.config = config
        self.syncQueue = syncQueue
        crmLog("[CRM] init — isEnabled=\(config.isEnabled) endpoint='\(config.apiEndpoint)' synced=\(config.syncedPhoneNumbers.count)")
    }

    func updateConfig(_ config: CRMConfig) { self.config = config }

    func startPolling() {
        guard config.isEnabled, !config.apiEndpoint.isEmpty else {
            crmLog("[CRM] startPolling: skipped — isEnabled=\(config.isEnabled) endpoint='\(config.apiEndpoint)'")
            return
        }
        crmLog("[CRM] startPolling: starting timer every \(config.pollIntervalSeconds)s → \(config.apiEndpoint)")
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.pollIntervalSeconds, repeats: true) { [weak self] _ in
            crmLog("[CRM] timer fired")
            Task { await self?.poll() }
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

    func poll() async {
        crmLog("[CRM] poll() called")
        await pushInbound()
        await pullOutbound()
        await updateCounts()
    }

    private func pushInbound() async {
        guard let entries = try? syncQueue.fetchPending(direction: "inbound", limit: 50), !entries.isEmpty else { return }
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
                let result = MessageSender.send(text: text, to: phone)
                let status: String
                switch result {
                case .success:
                    status = "delivered"
                    crmLog("[CRM] pullOutbound: delivered cmd=\(cmdID) to=\(phone)")
                case .failure(let err):
                    status = "failed: \(err.localizedDescription)"
                    crmLog("[CRM] pullOutbound: FAILED cmd=\(cmdID) to=\(phone) error=\(err.localizedDescription)")
                }
                await acknowledge(commandID: cmdID, status: status)
                crmLog("[CRM] pullOutbound: acked cmd=\(cmdID) status=\(status)")
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
