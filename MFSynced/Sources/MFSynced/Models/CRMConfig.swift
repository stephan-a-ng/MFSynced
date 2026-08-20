import Foundation

/// One backend Phone Sync forwards synced content to.
struct SyncTarget: Codable, Equatable {
    let name: String
    let url: URL
}

struct CRMConfig: Codable {
    /// Every backend this Mac forwards synced content to, replacing the old
    /// single `apiEndpoint` + optional `mirrorApiEndpoint` pair now that
    /// sign-in is OIDC-based (one Bearer token both targets trust) rather
    /// than a per-endpoint API key. Defaults to [prod, staging] so a
    /// freshly signed-in install needs no manual endpoint entry.
    static let defaultTargets: [SyncTarget] = [
        SyncTarget(name: "prod", url: URL(string: "https://message.moonfive.tech/v1/agent")!),
        SyncTarget(name: "staging", url: URL(string: "https://message-api-staging-435877221234.us-west1.run.app/v1/agent")!),
    ]

    var isEnabled: Bool = false
    /// Legacy pre-OIDC endpoint. Kept decodable for installs that predate
    /// `targets`; CRMSyncService only reads it as a fallback for the small
    /// set of single-target calls that haven't migrated to `targets` (see
    /// `CRMSyncService.agentEndpoint`) — a fresh sign-in-only install never
    /// populates this field at all.
    var apiEndpoint: String = ""
    /// Legacy per-agent API key. Kept decodable and usable as a fallback
    /// ONLY while signed out of OIDC, so an already-installed agent keeps
    /// working through the migration without forcing an immediate
    /// re-sign-in (see `CRMSyncService.authorizationHeaderValue`).
    var apiKey: String = ""
    var pollIntervalSeconds: Double = 5.0
    var syncedPhoneNumbers: Set<String> = []
    /// Legacy: optional second backend that received all syncs in parallel
    /// before `targets` existed. Kept decodable only — superseded by
    /// `targets`, which CRMSyncService now iterates instead.
    var mirrorApiEndpoint: String = ""
    var mirrorApiKey: String = ""
    /// The Message console account that owns this Mac's sync decisions.
    /// Captured at setup and carried on every heartbeat so the backend can
    /// attribute this agent; first-claim-wins is enforced server-side, not
    /// here.
    var ownerEmail: String = ""
    var targets: [SyncTarget] = CRMConfig.defaultTargets

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
        // A legacy payload has no "targets" key at all (it predates
        // dual-target sync entirely) — fall back to the [prod, staging]
        // defaults rather than decoding to an empty/missing list.
        targets = try container.decodeIfPresent([SyncTarget].self, forKey: .targets) ?? Self.defaultTargets
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
