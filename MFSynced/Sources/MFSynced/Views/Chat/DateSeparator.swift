import SwiftUI

struct DateSeparator: View {
    let date: Date

    private var label: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today' h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        }
        return formatter.string(from: date)
    }

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
