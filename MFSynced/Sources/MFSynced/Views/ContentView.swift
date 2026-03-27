import SwiftUI

@Observable
final class AppState {
    var conversations: [Conversation] = []
    var selectedConversation: Conversation?
    var messages: [Message] = []
    var searchText: String = ""
    var searchResults: [Message] = []
    var isSearching: Bool = false
    var crmConfig: CRMConfig

    private var chatDB: ChatDatabase
    private var lastSeenRowID: Int64 = 0
    private var pollTimer: Timer?
    private var crmService: CRMSyncService?
    private let contactStore = ContactStore()

    init() {
        self.crmConfig = CRMConfig.load()
        self.chatDB = ChatDatabase()
    }

    func startPolling(interval: TimeInterval = 2.0) {
        loadConversations()
        do {
            lastSeenRowID = try chatDB.getMaxRowID()
        } catch {
            print("Failed to get max row ID: \(error)")
        }

        crmService = CRMSyncService(config: crmConfig)
        if crmConfig.isEnabled {
            crmService?.startPolling()
        }

        Task { _ = await NotificationService.requestPermission() }
        Task { _ = await contactStore.requestAccess() }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollForNewMessages()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        crmService?.stopPolling()
    }

    func selectConversation(_ conversation: Conversation) {
        selectedConversation = conversation
        loadMessages(for: conversation)
    }

    func loadConversations() {
        do {
            var fetched = try chatDB.fetchConversations()
            for i in fetched.indices {
                fetched[i].isCRMSynced = crmConfig.syncedPhoneNumbers.contains(fetched[i].id)
            }
            conversations = fetched
        } catch {
            print("Failed to load conversations: \(error)")
        }
    }

    func loadMessages(for conversation: Conversation) {
        do {
            messages = try chatDB.fetchMessages(forChat: conversation.id, limit: 200)
        } catch {
            print("Failed to load messages: \(error)")
        }
    }

    func pollForNewMessages() {
        do {
            let newMessages = try chatDB.fetchMessages(afterRowID: lastSeenRowID)
            guard !newMessages.isEmpty else { return }

            if let maxID = newMessages.map(\.id).max() {
                lastSeenRowID = maxID
            }

            // Queue each new message for CRM sync and fire notifications
            for msg in newMessages {
                crmService?.queueInbound(message: msg)
                if !msg.isFromMe && !msg.isTapback {
                    let sender = msg.senderID ?? "Unknown"
                    NotificationService.showMessageNotification(
                        sender: sender,
                        text: msg.displayText ?? "[Attachment]",
                        chatIdentifier: msg.chatIdentifier ?? ""
                    )
                }
            }

            // Reload conversations to pick up new last-message ordering
            loadConversations()

            // Append new messages to current chat if relevant
            if let selected = selectedConversation {
                let relevant = newMessages.filter { $0.chatIdentifier == selected.id }
                if !relevant.isEmpty {
                    messages.append(contentsOf: relevant)
                }
            }
        } catch {
            print("Poll error: \(error)")
        }
    }

    func toggleCRMSync(for conversation: Conversation) {
        if crmConfig.syncedPhoneNumbers.contains(conversation.id) {
            crmConfig.syncedPhoneNumbers.remove(conversation.id)
        } else {
            crmConfig.syncedPhoneNumbers.insert(conversation.id)
        }
        crmConfig.save()

        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx].isCRMSynced = crmConfig.syncedPhoneNumbers.contains(conversation.id)
            if selectedConversation?.id == conversation.id {
                selectedConversation = conversations[idx]
            }
        }
    }

    func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            clearSearch()
            return
        }
        do {
            searchResults = try chatDB.searchMessages(query: searchText)
            isSearching = true
        } catch {
            print("Search error: \(error)")
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        isSearching = false
    }

    func syncHistoryToCRM(for conversation: Conversation) async {
        await crmService?.syncHistory(chatIdentifier: conversation.id, chatDB: chatDB)
    }
}

struct ContentView: View {
    @State private var appState = AppState()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if let conversation = appState.selectedConversation {
                ChatView(
                    conversation: conversation,
                    messages: appState.messages
                )
            } else {
                Text("Select a conversation")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            appState.startPolling()
        }
        .onDisappear {
            appState.stopPolling()
        }
    }
}
