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
    var dbError: String? = nil

    private var chatDB: ChatDatabase
    private var lastSeenRowID: Int64 = 0
    private var pollTimer: Timer?
    private var crmService: CRMSyncService?
    let contactStore = ContactStore()

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

        // Diagnostic: dump the +12039185024 thread immediately on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.dumpThreadDiagnostic(chatIdentifier: "+12039185024")
        }
    }

    private func dumpThreadDiagnostic(chatIdentifier: String) {
        do {
            let msgs = try chatDB.fetchMessages(forChat: chatIdentifier, limit: 50)
            appLog("[diag] \(chatIdentifier) → \(msgs.count) messages")
            let iso = ISO8601DateFormatter()
            let lines = msgs.map { m -> String in
                let ts = iso.string(from: m.date)
                let dir = m.isFromMe ? "me  " : "them"
                return "[\(ts)][\(dir)] \(m.displayText ?? "(nil)")"
            }
            let dump = "Thread: \(chatIdentifier) (\(msgs.count) msgs)\n" + lines.joined(separator: "\n") + "\n"
            let dumpPath = NSHomeDirectory() + "/Library/Logs/mfsynced_messages.txt"
            if let data = dump.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: dumpPath) {
                    handle.truncateFile(atOffset: 0); handle.write(data); handle.closeFile()
                } else { try? data.write(to: URL(fileURLWithPath: dumpPath)) }
            }
            appLog("[diag] dump written to mfsynced_messages.txt")
        } catch {
            appLog("[diag] ERROR: \(error)")
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        crmService?.stopPolling()
    }

    func selectConversation(_ conversation: Conversation) {
        appLog("[AppState] selectConversation id=\(conversation.id)")
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
            dbError = nil
            // Dump conversation list so external tools can find chat identifiers
            let dump = fetched.map { "\($0.id)\t\($0.displayName)" }.joined(separator: "\n")
            try? dump.write(toFile: NSHomeDirectory() + "/Library/Logs/mfsynced_conversations.txt", atomically: true, encoding: .utf8)
        } catch {
            print("Failed to load conversations: \(error)")
            let msg = error.localizedDescription
            if msg.contains("authorization denied") || msg.contains("not authorized") {
                dbError = "Full Disk Access required.\n\nGo to System Settings → Privacy & Security → Full Disk Access and add MFSynced."
            } else {
                dbError = "Could not read iMessage database: \(msg)"
            }
        }
    }

    func loadMessages(for conversation: Conversation) {
        do {
            messages = try chatDB.fetchMessages(forChat: conversation.id, limit: 200)
            appLog("[AppState] loadMessages id=\(conversation.id) count=\(messages.count)")
            // Dump all parsed messages to a readable log file
            let iso = ISO8601DateFormatter()
            let lines = messages.map { m -> String in
                let ts = iso.string(from: m.date)
                let dir = m.isFromMe ? "me  " : "them"
                let text = m.displayText ?? "(nil)"
                return "[\(ts)][\(dir)] \(text)"
            }
            let dump = "Thread: \(conversation.id) (\(messages.count) msgs)\n" + lines.joined(separator: "\n") + "\n"
            appLog("[AppState] dump preview: \(lines.last ?? "(none)")")
            let dumpPath = NSHomeDirectory() + "/Library/Logs/mfsynced_messages.txt"
            if let dumpData = dump.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: dumpPath) {
                    handle.truncateFile(atOffset: 0)
                    handle.write(dumpData)
                    handle.closeFile()
                } else {
                    try? dumpData.write(to: URL(fileURLWithPath: dumpPath))
                }
            }
        } catch {
            appLog("[AppState] loadMessages ERROR: \(error)")
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
                let contactName = contactStore.contact(for: msg.chatIdentifier ?? "").fullName
                crmService?.queueInbound(message: msg, contactName: contactName)
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

    private func appLog(_ message: String) {
        let path = NSHomeDirectory() + "/Library/Logs/mfsynced_crm.log"
        let line = "\(Date()): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func syncHistoryToCRM(for conversation: Conversation) async {
        let contactName = contactStore.contact(for: conversation.id).fullName
        appLog("[AppState] syncHistoryToCRM called id=\(conversation.id) crmService=\(crmService != nil)")
        guard let svc = crmService else {
            appLog("[AppState] ERROR: crmService is nil — skipping sync")
            return
        }
        await svc.syncHistory(chatIdentifier: conversation.id, chatDB: chatDB, contactName: contactName)
    }

    /// Enables CRM sync for a conversation and syncs history if it wasn't already enabled.
    /// Called automatically when a conversation is forwarded to a teammate.
    func enableCRMSyncIfNeeded(for conversation: Conversation) async {
        guard !crmConfig.syncedPhoneNumbers.contains(conversation.id) else { return }
        crmConfig.syncedPhoneNumbers.insert(conversation.id)
        crmConfig.save()
        crmService?.updateConfig(crmConfig)
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx].isCRMSynced = true
            if selectedConversation?.id == conversation.id {
                selectedConversation = conversations[idx]
            }
        }
        await syncHistoryToCRM(for: conversation)
    }
}

struct ContentView: View {
    @State private var appState = AppState()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showSetup = false

    private var needsSetup: Bool {
        let setupComplete = UserDefaults.standard.bool(forKey: "mfsynced_setup_complete")
        return !setupComplete || appState.dbError != nil
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if appState.dbError != nil {
                            Button {
                                showSetup = true
                            } label: {
                                Label("Setup", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .help("Fix setup issues")
                        }
                    }
                }
        } detail: {
            if let conversation = appState.selectedConversation {
                ChatView(
                    conversation: conversation,
                    messages: appState.messages,
                    contact: appState.contactStore.contact(for: conversation.id),
                    contactStore: appState.contactStore
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
            if needsSetup {
                // Small delay so the window is visible before the sheet appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showSetup = true
                }
            }
        }
        .onDisappear {
            appState.stopPolling()
        }
        .sheet(isPresented: $showSetup) {
            SetupView(isPresented: $showSetup) {
                // Re-run startup after setup so conversations load
                appState.stopPolling()
                appState.crmConfig = CRMConfig.load()
                appState.startPolling()
            }
        }
    }
}
