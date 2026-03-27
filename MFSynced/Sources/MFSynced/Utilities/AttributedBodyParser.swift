import Foundation

enum AttributedBodyParser {
    static func extractText(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }

        let bytes = [UInt8](data)
        let marker: [UInt8] = Array("NSString".utf8)

        guard let markerIndex = findSubarray(marker, in: bytes) else { return nil }
        var idx = markerIndex + marker.count

        guard let plusIndex = bytes[idx...].firstIndex(of: 0x2b) else { return nil }
        idx = plusIndex + 1
        guard idx < bytes.count else { return nil }

        let lengthByte = bytes[idx]
        idx += 1
        let length: Int

        if lengthByte >= 0x80 {
            let extraBytes = Int(lengthByte - 0x80)
            guard idx + extraBytes <= bytes.count else { return nil }
            var value = 0
            for i in 0..<extraBytes {
                value = (value << 8) | Int(bytes[idx + i])
            }
            length = value
            idx += extraBytes
        } else {
            length = Int(lengthByte)
        }

        guard length > 0 else { return nil }

        if idx < bytes.count && bytes[idx] == 0x00 {
            idx += 1
        }

        guard idx + length <= bytes.count else { return nil }
        let textBytes = Array(bytes[idx..<idx + length])
        let text = String(bytes: textBytes, encoding: .utf8)
        return text?.isEmpty == true ? nil : text
    }

    private static func findSubarray(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<i + needle.count]) == needle {
                return i
            }
        }
        return nil
    }
}
