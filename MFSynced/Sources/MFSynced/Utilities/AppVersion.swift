import Foundation

func appVersionLabel(infoDictionary: [String: Any]?) -> String {
    guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
          !version.isEmpty else {
        return "Phone Sync dev"
    }

    return "Phone Sync \(version)"
}

func appVersionLabel() -> String {
    appVersionLabel(infoDictionary: Bundle.main.infoDictionary)
}
