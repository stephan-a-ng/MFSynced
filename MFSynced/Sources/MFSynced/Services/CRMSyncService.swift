import Foundation

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
    }

    func updateConfig(_ config: CRMConfig) { self.config = config }

    func startPolling() {
        guard config.isEnabled, !config.apiEndpoint.isEmpty else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: config.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    func queueInbound(message: Message) {
        guard config.syncedPhoneNumbers.contains(message.chatIdentifier ?? "") else { return }
        let payload: [String: Any] = [
            "id": message.guid,
            "phone": message.senderID ?? message.chatIdentifier ?? "",
            "text": message.displayText ?? "",
            "timestamp": AppleDateConverter.toISO8601(message.id) ?? "",
            "is_from_me": message.isFromMe,
            "service": message.service,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        try? syncQueue.enqueue(direction: "inbound", messageGuid: message.guid, phone: message.chatIdentifier ?? "", payload: jsonString)
    }

    func poll() async {
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
    }

    private func pullOutbound() async {
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
                let result = MessageSender.send(text: text, to: phone)
                let status: String
                switch result {
                case .success: status = "delivered"
                case .failure(let err): status = "failed: \(err.localizedDescription)"
                }
                await acknowledge(commandID: cmdID, status: status)
            }
        } catch { }
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

    func syncHistory(chatIdentifier: String, chatDB: ChatDatabase) async {
        do {
            let messages = try chatDB.fetchMessages(forChat: chatIdentifier, limit: 10000)
            let batches = stride(from: 0, to: messages.count, by: 100).map {
                Array(messages[$0..<min($0 + 100, messages.count)])
            }
            for batch in batches {
                let payload = batch.map { msg -> [String: Any] in
                    ["id": msg.guid, "phone": msg.senderID ?? chatIdentifier, "text": msg.displayText ?? "",
                     "timestamp": AppleDateConverter.toISO8601(msg.id) ?? "", "is_from_me": msg.isFromMe, "service": msg.service]
                }
                let body: [String: Any] = ["agent_id": config.agentID, "messages": payload]
                guard let url = URL(string: "\(config.apiEndpoint)/sync/\(chatIdentifier)/history") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                _ = try? await session.data(for: request)
            }
        } catch { print("History sync failed: \(error)") }
    }

    @MainActor
    private func updateCounts() {
        pendingInbound = (try? syncQueue.pendingCount(direction: "inbound")) ?? 0
        pendingOutbound = (try? syncQueue.pendingCount(direction: "outbound_ack")) ?? 0
    }
}
