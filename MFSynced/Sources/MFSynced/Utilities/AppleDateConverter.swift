import Foundation

enum AppleDateConverter {
    static let appleEpochOffset: TimeInterval = 978307200
    static let nsPerSecond: Double = 1_000_000_000

    static func toDate(_ appleNanoseconds: Int64) -> Date? {
        guard appleNanoseconds > 0 else { return nil }
        let unixTimestamp = Double(appleNanoseconds) / nsPerSecond + appleEpochOffset
        return Date(timeIntervalSince1970: unixTimestamp)
    }

    static func toISO8601(_ appleNanoseconds: Int64) -> String? {
        guard let date = toDate(appleNanoseconds) else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}
