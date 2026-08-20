import Foundation

/// One backend Phone Sync forwards synced content to.
struct SyncTarget: Codable, Equatable {
    let name: String
    let url: URL
    /// A pre-OIDC (OpenID Connect) per-target API key, present ONLY on a
    /// target derived from a legacy single/mirror-endpoint config by
    /// `CRMConfig.applyLegacyTargetMigrationIfNeeded()` — target 1 carries
    /// the legacy `apiEndpoint`'s own `apiKey`, target 2 (if any) carries
    /// `mirrorApiEndpoint`'s own `mirrorApiKey`. Deliberately excluded from
    /// Codable (see `CodingKeys` below): the key already lives in
    /// CRMConfig's own `apiKey`/`mirrorApiKey` fields, so persisting it
    /// here too would just be a second plaintext copy of the same secret
    /// in the same UserDefaults blob. `nil` for the [prod, staging]
    /// defaults, which never had a legacy key to carry.
    var legacyKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, url
    }
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

    /// True exactly when the stored/decoded JSON had NO "targets" key at
    /// all — i.e. this payload predates dual/multi-target sync entirely (a
    /// pre-Slice-A legacy install). `CRMConfig.load()` uses this, combined
    /// with a non-empty `apiEndpoint`, to decide whether to run the
    /// legacy-target migration on top of the [prod, staging] defaults
    /// `init(from:)` already fell back to (see its own doc comment) — a
    /// fresh sign-in-only install decodes the very same way (no "targets"
    /// key either, since it's never been saved yet), so this flag alone
    /// can't distinguish the two cases. Deliberately excluded from
    /// `CodingKeys` (see below): it is decode-time bookkeeping only, never
    /// persisted. A config built via the plain `init()` — every test that
    /// doesn't decode JSON directly — always reads `false`.
    private(set) var decodedWithoutTargetsKey: Bool = false

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

    /// Every key `init(from:)` decodes, EXCLUDING `decodedWithoutTargetsKey`
    /// — that field is decode-time bookkeeping only (see its doc comment),
    /// never part of the persisted shape. An explicit enum here (rather
    /// than the compiler-synthesized one) is required to leave it out:
    /// Swift skips a stored property from synthesized `encode(to:)` only
    /// when it is BOTH absent from `CodingKeys` AND has a default value,
    /// which `decodedWithoutTargetsKey` has.
    enum CodingKeys: String, CodingKey {
        case isEnabled, apiEndpoint, apiKey, pollIntervalSeconds, syncedPhoneNumbers
        case mirrorApiEndpoint, mirrorApiKey, ownerEmail, targets
    }

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
        decodedWithoutTargetsKey = !container.contains(.targets)
        // A legacy payload has no "targets" key at all (it predates
        // dual-target sync entirely) — fall back to the [prod, staging]
        // defaults rather than decoding to an empty/missing list. This is
        // the RAW decode shape pinned by
        // SyncTargetsTests.testCRMConfigDecodesLegacyShapeAndPreservesCoreFields
        // — the further legacy-endpoint migration below runs ONLY in
        // `load()`, one layer up, so that pin and the real migrated
        // runtime behavior both hold. See `applyLegacyTargetMigrationIfNeeded`.
        targets = try container.decodeIfPresent([SyncTarget].self, forKey: .targets) ?? Self.defaultTargets
    }

    static func load() -> CRMConfig {
        guard let data = UserDefaults.standard.data(forKey: "mfsynced_crm_config"),
              var config = try? JSONDecoder().decode(CRMConfig.self, from: data) else {
            return CRMConfig()
        }
        config.applyLegacyTargetMigrationIfNeeded()
        return config
    }

    /// Migrates a legacy (pre-dual-target) install's single `apiEndpoint`/
    /// `apiKey` and optional `mirrorApiEndpoint`/`mirrorApiKey` pair into
    /// real per-target `SyncTarget`s, so every caller that reads
    /// `config.targets` — gate/heartbeat/catalog/staged pulls AND
    /// pushInbound/syncHistory's content pushes alike — addresses the SAME
    /// backend(s) the install was always configured for, instead of the
    /// [prod, staging] Moon Five defaults a legacy JSON payload's missing
    /// "targets" key would otherwise fall back to (see `init(from:)`).
    /// Without this, a legacy install's PROD apiKey would get attached to
    /// the (wrong, unrelated) staging default target, and an install that
    /// never opted into a mirror would start streaming message bodies to
    /// staging it never asked for.
    ///
    /// Deliberately layered here, in `load()`, rather than inside
    /// `init(from:)`: `SyncTargetsTests.
    /// testCRMConfigDecodesLegacyShapeAndPreservesCoreFields` pins the RAW
    /// `JSONDecoder().decode(CRMConfig.self, from:)` shape for a legacy
    /// payload to the [prod, staging] defaults, unmigrated — every real
    /// call site in this app goes through `load()`, though, so the pinned
    /// decode test and the actually-migrated runtime behavior both hold.
    ///
    /// Gated on `decodedWithoutTargetsKey` (this payload predates
    /// dual-target sync entirely) AND a non-empty `apiEndpoint` — the one
    /// field a fresh, sign-in-only install NEVER populates (see its own
    /// doc comment) — so an already-migrated config (which now has an
    /// explicit "targets" key on disk, since `save()` always encodes one)
    /// is never re-migrated on top of whatever's been persisted since.
    private mutating func applyLegacyTargetMigrationIfNeeded() {
        guard decodedWithoutTargetsKey, !apiEndpoint.isEmpty,
              let primaryURL = URL(string: apiEndpoint) else { return }
        var migrated = [SyncTarget(name: "primary", url: primaryURL, legacyKey: apiKey)]
        // Mirror only when BOTH mirror fields are non-empty — a legacy
        // install that never opted into a second backend must not
        // suddenly start streaming content to one it never configured.
        if !mirrorApiEndpoint.isEmpty, !mirrorApiKey.isEmpty,
           let mirrorURL = URL(string: mirrorApiEndpoint) {
            migrated.append(SyncTarget(name: "mirror", url: mirrorURL, legacyKey: mirrorApiKey))
        }
        targets = migrated
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "mfsynced_crm_config")
        }
    }
}
