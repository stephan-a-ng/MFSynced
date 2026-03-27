import SwiftUI

struct AvatarView: View {
    let conversation: Conversation
    let isSelected: Bool
    var contact: Contact?

    private var avatarColor: Color {
        let hash = abs(conversation.id.hashValue)
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple, .pink,
        ]
        return colors[hash % colors.count]
    }

    private var displayInitials: String {
        if let name = contact?.fullName, !name.isEmpty {
            let words = name.split(separator: " ").prefix(2)
            return words.map { String($0.prefix(1)).uppercased() }.joined()
        }
        return conversation.initials
    }

    var body: some View {
        ZStack {
            if let photo = contact?.photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(avatarColor)
                    .frame(width: 44, height: 44)

                Text(displayInitials)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }

            if conversation.isCRMSynced {
                Circle()
                    .fill(.green)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                    )
                    .offset(x: 15, y: 15)
            }
        }
        .frame(width: 56, height: 56)
        .overlay(
            Circle()
                .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                .frame(width: 50, height: 50)
        )
    }
}
