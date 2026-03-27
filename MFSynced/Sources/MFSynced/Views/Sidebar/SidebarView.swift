import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        appState.searchText = searchText
                        appState.performSearch()
                    }
                    .onChange(of: searchText) { _, newValue in
                        if newValue.isEmpty {
                            appState.clearSearch()
                        }
                    }
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        appState.clearSearch()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)

            Divider()

            // Content
            if appState.isSearching {
                searchResultsList
            } else {
                conversationsList
            }
        }
    }

    private var searchResultsList: some View {
        List(appState.searchResults) { message in
            VStack(alignment: .leading, spacing: 2) {
                Text(message.senderID ?? (message.isFromMe ? "Me" : "Unknown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.displayText ?? "")
                    .lineLimit(2)
                    .font(.subheadline)
                Text(message.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if let chatID = message.chatIdentifier {
                    if let conv = appState.conversations.first(where: { $0.id == chatID }) {
                        appState.selectConversation(conv)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var conversationsList: some View {
        List(appState.conversations, selection: Binding<Conversation?>(
            get: { appState.selectedConversation },
            set: { conv in
                if let conv {
                    appState.selectConversation(conv)
                }
            }
        )) { conversation in
            HStack(spacing: 10) {
                AvatarView(
                    conversation: conversation,
                    isSelected: appState.selectedConversation?.id == conversation.id
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let lastMsg = conversation.lastMessage {
                        Text(lastMsg.displayText ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let lastMsg = conversation.lastMessage {
                    Text(lastMsg.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .tag(conversation)
            .contextMenu {
                Button(conversation.isCRMSynced ? "Disable CRM Sync" : "Enable CRM Sync") {
                    appState.toggleCRMSync(for: conversation)
                }
                if conversation.isCRMSynced {
                    Button("Sync History to CRM") {
                        Task {
                            await appState.syncHistoryToCRM(for: conversation)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
