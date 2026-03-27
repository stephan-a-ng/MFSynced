import Foundation

struct CRMConfig: Codable {
    var isEnabled: Bool = false
    var apiEndpoint: String = ""
    var apiKey: String = ""
    var pollIntervalSeconds: Double = 5.0
    var syncedPhoneNumbers: Set<String> = []

    var agentID: String {
        if let stored = UserDefaults.standard.string(forKey: "mfsynced_agent_id") {
            return stored
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "mfsynced_agent_id")
        return newID
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
