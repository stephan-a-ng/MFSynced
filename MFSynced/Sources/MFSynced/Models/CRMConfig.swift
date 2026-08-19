import Foundation

struct CRMConfig: Codable {
    var isEnabled: Bool = false
    var apiEndpoint: String = ""
    var apiKey: String = ""
    var pollIntervalSeconds: Double = 5.0
    var syncedPhoneNumbers: Set<String> = []
    /// Optional second backend that receives all syncs and forwards in parallel
    var mirrorApiEndpoint: String = ""
    var mirrorApiKey: String = ""
    /// The Message console account that owns this Mac's sync decisions.
    /// Captured at setup and carried on every heartbeat so the backend can
    /// attribute this agent; first-claim-wins is enforced server-side, not
    /// here.
    var ownerEmail: String = ""

    var hasMirror: Bool { !mirrorApiEndpoint.isEmpty && !mirrorApiKey.isEmpty }

    var agentID: String {
        if let stored = UserDefaults.standard.string(forKey: "mfsynced_agent_id") {
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "mfsynced_agent_id")
        return newID
    }

    init() {}

    // Custom Decodable: the compiler-synthesized init(from:) calls plain
    // decode(_:forKey:) for every stored property regardless of its default
    // value, so a JSON payload persisted by an older build — one that
    // predates a field added here later — fails to decode entirely and
    // load() silently resets the WHOLE config back to CRMConfig(), wiping
    // apiEndpoint/apiKey along with it. decodeIfPresent + fallback keeps a
    // missing key from taking down the rest of a legacy payload.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        apiEndpoint = try container.decodeIfPresent(String.self, forKey: .apiEndpoint) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        pollIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? 5.0
        syncedPhoneNumbers = try container.decodeIfPresent(Set<String>.self, forKey: .syncedPhoneNumbers) ?? []
        mirrorApiEndpoint = try container.decodeIfPresent(String.self, forKey: .mirrorApiEndpoint) ?? ""
        mirrorApiKey = try container.decodeIfPresent(String.self, forKey: .mirrorApiKey) ?? ""
        ownerEmail = try container.decodeIfPresent(String.self, forKey: .ownerEmail) ?? ""
    }

    static func load() -> CRMConfig {
        guard let data = UserDefaults.standard.data(forKey: "mfsynced_crm_config"),
              let config = try? JSONDecoder().decode(CRMConfig.self, from: data) else {
            return CRMConfig()
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "mfsynced_crm_config")
        }
    }
}
