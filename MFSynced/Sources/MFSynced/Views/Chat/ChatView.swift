import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    let messages: [Message]
    @Environment(\.colorScheme) private var colorScheme

    private var filteredMessages: [Message] {
        messages.filter { !$0.isTapback }
    }

    private var groupedMessages: [(date: Date, messages: [Message])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredMessages) { msg in
            calendar.startOfDay(for: msg.date)
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, messages: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chat header
            chatHeader

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(groupedMessages, id: \.date) { group in
                            DateSeparator(date: group.messages.first?.date ?? group.date)

                            ForEach(group.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) {
                    if let lastMsg = filteredMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMsg.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let lastMsg = filteredMessages.last {
                        proxy.scrollTo(lastMsg.id, anchor: .bottom)
                    }
                }
            }

            // Compose bar
            ComposeBar(chatIdentifier: conversation.id)
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
    }

    private var chatHeader: some View {
        VStack(spacing: 4) {
            avatarSmall

            HStack(spacing: 4) {
                Text(conversation.title)
                    .font(.headline)

                if conversation.isCRMSynced {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            Text(conversation.service)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var avatarSmall: some View {
        let hash = abs(conversation.id.hashValue)
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple, .pink,
        ]
        let avatarColor = colors[hash % colors.count]

        return Circle()
            .fill(avatarColor)
            .frame(width: 32, height: 32)
            .overlay(
                Text(conversation.initials)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
