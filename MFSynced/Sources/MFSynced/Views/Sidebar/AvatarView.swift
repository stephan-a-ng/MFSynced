import SwiftUI

struct AvatarView: View {
    let conversation: Conversation
    let isSelected: Bool

    private var avatarColor: Color {
        let hash = abs(conversation.id.hashValue)
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple, .pink,
        ]
        return colors[hash % colors.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
                .frame(width: 44, height: 44)

            Text(conversation.initials)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

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
