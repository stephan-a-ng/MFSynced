import Foundation
import Network
import OSLog

private let controlLogger = Logger(subsystem: "tech.moonfive.MFSynced", category: "ControlServer")

/// Minimal localhost-only HTTP control API for e2e testing.
/// Listens on 127.0.0.1:7891 using Apple's Network framework.
final class ControlServer {
    private var listener: NWListener?
    private let syncService: CRMSyncService
    private let port: UInt16

    init(syncService: CRMSyncService, port: UInt16 = 7891) {
        self.syncService = syncService
        self.port = port
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        do {
            listener = try NWListener(using: params)
        } catch {
            controlLogger.error("[ControlServer] Failed to create listener: \(error.localizedDescription, privacy: .public)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                controlLogger.info("[ControlServer] Listening on 127.0.0.1:\(self.port, privacy: .public)")
            case .failed(let err):
                controlLogger.error("[ControlServer] Listener failed: \(err.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener?.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data else {
                conn.cancel()
                return
            }
            let (method, path, body) = self.parseHTTPRequest(data)
            self.route(method: method, path: path, body: body) { statusCode, responseBody in
                self.sendHTTPResponse(conn, statusCode: statusCode, body: responseBody)
            }
        }
    }

    // MARK: - HTTP parsing (minimal — enough for curl/httpx)

    private func parseHTTPRequest(_ data: Data) -> (method: String, path: String, body: Data?) {
        guard let raw = String(data: data, encoding: .utf8) else {
            return ("GET", "/", nil)
        }
        let headerBodySplit = raw.components(separatedBy: "\r\n\r\n")
        let headerSection = headerBodySplit[0]
        let bodyString = headerBodySplit.count > 1 ? headerBodySplit[1] : nil

        let firstLine = headerSection.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        let body = bodyString?.data(using: .utf8)
        return (method, path, body)
    }

    private func sendHTTPResponse(_ conn: NWConnection, statusCode: Int, body: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var fullResponse = response.data(using: .utf8)!
        fullResponse.append(body)

        conn.send(content: fullResponse, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: Data?, completion: @escaping (Int, Data) -> Void) {
        switch (method, path) {
        case ("GET", "/health"):
            handleHealth(completion: completion)
        case ("POST", "/poll"):
            handlePoll(completion: completion)
        case ("GET", "/outbound-log"):
            handleOutboundLog(completion: completion)
        case ("POST", "/send"):
            handleSend(body: body, completion: completion)
        default:
            let resp: [String: Any] = ["error": "Not found", "path": path]
            completion(404, jsonData(resp))
        }
    }

    // MARK: - Handlers

    private func handleHealth(completion: @escaping (Int, Data) -> Void) {
        Task { @MainActor in
            let resp: [String: Any] = [
                "status": "ok",
                "crm_enabled": self.syncService.isConnected || self.syncService.lastSyncTime != nil,
                "crm_connected": self.syncService.isConnected,
                "last_sync_time": self.syncService.lastSyncTime.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "pending_inbound": self.syncService.pendingInbound,
                "pending_outbound": self.syncService.pendingOutbound,
                "outbound_log_count": self.syncService.recentOutboundResults.count,
            ]
            completion(200, self.jsonData(resp))
        }
    }

    private func handlePoll(completion: @escaping (Int, Data) -> Void) {
        Task {
            let countBefore = await MainActor.run { self.syncService.recentOutboundResults.count }
            await self.syncService.poll()
            let results = await MainActor.run { Array(self.syncService.recentOutboundResults.suffix(from: min(countBefore, self.syncService.recentOutboundResults.count))) }

            let entries = results.map { r -> [String: Any] in
                [
                    "command_id": r.commandID,
                    "phone": r.phone,
                    "text": r.text,
                    "success": r.success,
                    "error": r.error as Any,
                    "timestamp": ISO8601DateFormatter().string(from: r.timestamp),
                ]
            }
            let resp: [String: Any] = [
                "status": "poll_complete",
                "outbound_results": entries,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ]
            completion(200, self.jsonData(resp))
        }
    }

    private func handleOutboundLog(completion: @escaping (Int, Data) -> Void) {
        Task { @MainActor in
            let entries = self.syncService.recentOutboundResults.map { r -> [String: Any] in
                [
                    "command_id": r.commandID,
                    "phone": r.phone,
                    "text": r.text,
                    "success": r.success,
                    "error": r.error as Any,
                    "timestamp": ISO8601DateFormatter().string(from: r.timestamp),
                ]
            }
            completion(200, self.jsonData(["entries": entries]))
        }
    }

    private func handleSend(body: Data?, completion: @escaping (Int, Data) -> Void) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let phone = json["phone"] as? String,
              let text = json["text"] as? String else {
            completion(400, jsonData(["error": "Missing phone or text in request body"]))
            return
        }
        let result = MessageSender.send(text: text, to: phone)
        switch result {
        case .success:
            completion(200, jsonData(["status": "sent", "phone": phone]))
        case .failure(let err):
            completion(500, jsonData(["status": "failed", "error": err.localizedDescription]))
        }
    }

    // MARK: - Helpers

    private func jsonData(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? "{}".data(using: .utf8)!
    }
}
