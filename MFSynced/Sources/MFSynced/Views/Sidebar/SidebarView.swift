import SwiftUI

struct SidebarView: View {
    @Bindable var appState: AppState
    @State private var searchText: String = ""
    @State private var isSyncingContacts = false

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
                Button(action: {
                    isSyncingContacts = true
                    Task {
                        await appState.contactStore.refresh()
                        isSyncingContacts = false
                    }
                }) {
                    if isSyncingContacts {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Sync Contacts")
            }
            .padding(8)

            Divider()

            // Content
            if let error = appState.dbError {
                dbErrorView(error)
            } else if appState.isSearching {
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

    private func dbErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            Button("Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var conversationsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        contact: appState.contactStore.contact(for: conversation.id),
                        isSelected: appState.selectedConversation?.id == conversation.id,
                        crmConfig: appState.crmConfig,
                        onSelect: { appState.selectConversation(conversation) },
                        onToggleCRMSync: { appState.toggleCRMSync(for: conversation) },
                        onSyncHistory: { Task { await appState.syncHistoryToCRM(for: conversation) } }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    let contact: Contact
    let isSelected: Bool
    let crmConfig: CRMConfig
    let onSelect: () -> Void
    let onToggleCRMSync: () -> Void
    let onSyncHistory: () -> Void

    @State private var isHovered = false
    @State private var showForwardPopover = false

    private var canForward: Bool { !crmConfig.apiEndpoint.isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                conversation: conversation,
                isSelected: isSelected,
                contact: contact
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.fullName ?? conversation.title)
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

            // Right side: forward button on hover, timestamp otherwise
            ZStack {
                if let lastMsg = conversation.lastMessage {
                    Text(lastMsg.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity((isHovered || showForwardPopover) && canForward ? 0 : 1)
                }

                if canForward {
                    Button {
                        showForwardPopover = true
                    } label: {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                            .frame(width: 26, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Forward to team")
                    .opacity((isHovered || showForwardPopover) ? 1 : 0)
                    .popover(isPresented: $showForwardPopover, arrowEdge: .trailing) {
                        ForwardSheet(
                            conversation: conversation,
                            config: crmConfig,
                            contactName: contact.fullName,
                            onDismiss: { showForwardPopover = false }
                        )
                    }
                }
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(conversation.isCRMSynced ? "Disable CRM Sync" : "Enable CRM Sync") {
                onToggleCRMSync()
            }
            if conversation.isCRMSynced {
                Button("Sync History to CRM") {
                    onSyncHistory()
                }
            }
        }
    }
}
