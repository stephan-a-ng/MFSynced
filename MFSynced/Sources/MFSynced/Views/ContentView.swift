import SwiftUI

@MainActor
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
    let authentication: AuthenticationController

    private var chatDB: ChatDatabase
    private var lastSeenRowID: Int64 = 0
    private var pollTimer: Timer?
    private var crmService: CRMSyncService?
    private var controlServer: ControlServer?
    private var isPollingStarted = false
    private let logsDirectory: URL
    let contactStore = ContactStore()

    init() {
        self.crmConfig = CRMConfig.load()
        self.chatDB = ChatDatabase()
        self.authentication = AuthenticationController()
        self.logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        SensitiveDiagnostics.configure(logsDirectory: logsDirectory)
        clearLegacySensitiveDiagnostics()
    }

    init(authentication: AuthenticationController, logsDirectory: URL) {
        self.crmConfig = CRMConfig.load()
        self.chatDB = ChatDatabase()
        self.authentication = authentication
        self.logsDirectory = logsDirectory
        SensitiveDiagnostics.configure(logsDirectory: logsDirectory)
        clearLegacySensitiveDiagnostics()
    }

    func startPolling(interval: TimeInterval = 2.0) {
        guard authentication.state.allowsSensitiveContent else {
            lockForAuthentication()
            return
        }
        SensitiveDiagnostics.setEnabled(true)
        guard !isPollingStarted else { return }
        isPollingStarted = true
        loadConversations()
        do {
            lastSeenRowID = try chatDB.getMaxRowID()
        } catch {
            print("Failed to get max row ID: \(error)")
        }

        // AuthService.shared: the one process-wide, Keychain-backed
        // instance, so sign-in/out from the Setup/Settings UI takes effect
        // here immediately without an app relaunch.
        crmService = CRMSyncService(config: crmConfig, authService: AuthService.shared)
        // ChatDatabase has immutable configuration and opens a fresh
        // read-only SQLite connection per call, so these queries stay off
        // the main actor without sharing a sqlite handle.
        let database = chatDB
        // Outbound service routing: prefer the service the chat already lives
        // on (SMS threads -> the SMS-forwarding account, so Android
        // recipients get the text immediately instead of a stuck iMessage).
        crmService?.chatServiceHint = { phone in
            database.serviceForChat(identifier: phone)
        }
        crmService?.contactInfoProvider = { [weak self] phone in
            self?.contactStore.contactInfo(for: phone) ?? (nil, nil)
        }
        // Contact write-back (S5): console-side NAME/PHOTO edits flow down
        // to this Mac's Address Book, applied to ANY matching local
        // contact (not just already-shared ones — Stephan's call).
        crmService?.contactUpdateApplier = { [weak self] phones, displayName, photoJPEG in
            self?.contactStore.updatePhoneMirror(
                phones: phones, displayName: displayName, photoJPEG: photoJPEG
            )
            return self?.contactStore.applyContactUpdate(
                phones: phones, displayName: displayName, photoJPEG: photoJPEG
            ) ?? false
        }
        // Candidate catalog upload: every 1:1 conversation, metadata only.
        crmService?.catalogChatsProvider = {
            try database.fetchCatalog()
        }
        // Staged content upload: per-chat backfill (no cursor yet),
        // backfill-continuation (in-progress cursor), or incremental
        // (backfill-done cursor) fetch, driven by CRMSyncService.
        // stagedRowsPlan.
        crmService?.stagedMessagesProvider = { chatIdentifier, mode in
            switch mode {
            case .backfill(let limit):
                return try database.fetchMessages(forChat: chatIdentifier, limit: limit)
            case .continueBackfill(let beforeRowID, let limit):
                return try database.fetchMessages(forChat: chatIdentifier, limit: limit, beforeRowID: beforeRowID)
            case .incremental(let afterRowID, let limit):
                return try database.fetchMessages(forChat: chatIdentifier, afterRowID: afterRowID, limit: limit)
            }
        }
        let reviewSnapshots = ReviewHistorySnapshotStore(source: database)
        crmService?.reviewHistoryPageProvider = { chatIdentifier, beforeRowID, snapshotID in
            try reviewSnapshots.page(
                chatIdentifier: chatIdentifier,
                beforeRowID: beforeRowID,
                snapshotID: snapshotID
            )
        }
        crmService?.chatMaxRowID = {
            (try? database.getMaxRowID()) ?? 0
        }
        // Heartbeat's send_handle: the phone number/handle this Mac sends
        // iMessages as, so the console can show who the agent is really
        // syncing for.
        crmService?.selfHandleProvider = {
            database.selfHandle()
        }
        crmService?.deliveryProbe = { phone, afterRowID in
            database.outgoingDeliveryState(identifier: phone, afterRowID: afterRowID)
        }
        // Completeness backstop: when the server-desired gate gains a
        // number (a conversation just shared in the console), pullGate()
        // fires this once per newly-added identifier so its full history
        // backfills the same way the sidebar's "Sync History" action and
        // the forward-to-teammate flow do — beyond the ~2000 staged rows
        // the server already promoted. CRMSyncService launches this callback
        // in its tracked background-task registry, keeping the poll moving
        // while ensuring sign-out cancels the backfill.
        crmService?.historyBackfillRequest = { [weak self] chatIdentifier in
            guard let self else { return }
            self.syncHistoryToCRM(forChatIdentifier: chatIdentifier)
        }
        // The service owns the gate now (server-desired allowlist): every
        // change it applies — a gate pull, a server-routed add, the rollback
        // after a refused add — flows back here so AppState's copy and the
        // sidebar's sync flags never drift from what actually uploads.
        // Called on the main queue.
        crmService?.onConfigChanged = { [weak self] cfg in
            guard let self else { return }
            self.crmConfig = cfg
            for idx in self.conversations.indices {
                self.conversations[idx].isCRMSynced =
                    cfg.syncedPhoneNumbers.contains(self.conversations[idx].id)
            }
            if let selected = self.selectedConversation,
               let idx = self.conversations.firstIndex(where: { $0.id == selected.id }) {
                self.selectedConversation = self.conversations[idx]
            }
        }
        if crmConfig.isEnabled {
            crmService?.startPolling()
        }

        controlServer = ControlServer(syncService: crmService!)
        controlServer?.start()

        Task { _ = await NotificationService.requestPermission() }
        Task { _ = await contactStore.requestAccess() }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollForNewMessages() }
        }

    }

    func stopPolling() {
        isPollingStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        crmService?.stopPolling()
        controlServer?.stop()
        controlServer = nil
        crmService = nil
    }

    /// Immediately removes every piece of previously rendered message/sync
    /// state when authentication is absent or uncertain. ContentView also
    /// removes the entire application subtree, so this is defense in depth
    /// against a stale render when a session expires or the user signs out.
    func lockForAuthentication() {
        SensitiveDiagnostics.setEnabled(false)
        stopPolling()
        conversations = []
        selectedConversation = nil
        messages = []
        searchText = ""
        searchResults = []
        isSearching = false
        dbError = nil
        crmConfig = CRMConfig()
        clearLegacySensitiveDiagnostics()
    }

    /// Legacy API keys are incompatible with the strict OIDC privacy gate.
    /// Once the app reaches a confirmed signed-out state, remove their
    /// persisted copies as well as the in-memory config snapshot.
    func discardPersistedLegacyCredentials() {
        var persisted = CRMConfig.load()
        persisted.apiKey = ""
        persisted.mirrorApiKey = ""
        persisted.save()
    }

    /// Re-reads the persisted config and pushes it through the SAME
    /// onConfigChanged/updateConfig channel pullGate/requestGateAdd already
    /// use (see `startPolling()`'s wiring) — call after anything that
    /// persists a CRMConfig change OUTSIDE that channel, e.g. the Settings
    /// window's Sign In/Sign Out buttons (CRMSyncSettingsView), which save
    /// via `CRMConfig.save()` directly. Without this, a Settings-window
    /// sign-in only takes effect after a full app relaunch, since the
    /// already-running `crmService` never learns its config changed.
    func refreshCRMConfigAfterAuthChange() {
        guard authentication.state.allowsSensitiveContent else { return }
        crmConfig = CRMConfig.load()
        crmService?.updateConfig(crmConfig)
        if crmConfig.isEnabled {
            crmService?.startPolling()
        } else {
            crmService?.stopPolling()
            // startPolling clears the all-background-work stop latch before
            // it observes that automatic CRM polling is disabled. Manual
            // forward/history operations therefore remain available while
            // signed in, without starting a timer.
            crmService?.startPolling()
        }
    }

    func selectConversation(_ conversation: Conversation) {
        appLog("[AppState] selected conversation")
        selectedConversation = conversation
        loadMessages(for: conversation)
    }

    func loadConversations() {
        guard authentication.state.allowsSensitiveContent else { return }
        do {
            var fetched = try chatDB.fetchConversations()
            for i in fetched.indices {
                fetched[i].isCRMSynced = crmConfig.syncedPhoneNumbers.contains(fetched[i].id)
            }
            conversations = fetched
            dbError = nil
        } catch {
            print("Failed to load conversations: \(error)")
            let msg = error.localizedDescription
            if msg.contains("authorization denied") || msg.contains("not authorized") {
                dbError = "Full Disk Access required.\n\nGo to System Settings → Privacy & Security → Full Disk Access and add Phone Sync."
            } else {
                dbError = "Could not read iMessage database: \(msg)"
            }
        }
    }

    func loadMessages(for conversation: Conversation) {
        guard authentication.state.allowsSensitiveContent else { return }
        do {
            messages = try chatDB.fetchMessages(forChat: conversation.id, limit: 200)
            appLog("[AppState] loaded \(messages.count) messages")
        } catch {
            appLog("[AppState] loadMessages ERROR: \(error)")
            print("Failed to load messages: \(error)")
        }
    }

    func pollForNewMessages() {
        guard authentication.state.allowsSensitiveContent else { return }
        do {
            let newMessages = try chatDB.fetchMessages(afterRowID: lastSeenRowID)
            guard authentication.state.allowsSensitiveContent else { return }
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
            // Removal is the OWNER's call once the server gate is live: the
            // console edits the desired list and the Mac applies it on the
            // next poll. A local remove here would just be overwritten (and
            // would hide an audited decision), so it is refused with a log.
            if crmService?.serverGateActive == true {
                print("[CRM] gate remove \(conversation.id) is console-managed; use the Fleet page")
                return
            }
            crmConfig.syncedPhoneNumbers.remove(conversation.id)
            crmConfig.save()
        } else {
            // Optimistic local add for instant UI; the server add is the
            // audited source of truth and the next gate pull reconciles
            // (including rolling back if the server refused — e.g. 409
            // while the agent has no owner).
            crmConfig.syncedPhoneNumbers.insert(conversation.id)
            crmConfig.save()
            let service = crmService
            let phone = conversation.id
            Task { await service?.requestGateAdd(phone) }
        }

        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx].isCRMSynced = crmConfig.syncedPhoneNumbers.contains(conversation.id)
            if selectedConversation?.id == conversation.id {
                selectedConversation = conversations[idx]
            }
        }
    }

    func performSearch() {
        guard authentication.state.allowsSensitiveContent else { return }
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
        SensitiveDiagnostics.record(message, bufferForFleet: false)
    }

    private func clearLegacySensitiveDiagnostics() {
        SensitiveDiagnostics.purge()
    }

    func syncHistoryToCRM(for conversation: Conversation) {
        syncHistoryToCRM(forChatIdentifier: conversation.id)
    }

    /// Same backfill as `syncHistoryToCRM(for:)`, driven by a bare chat
    /// identifier instead of a loaded `Conversation`. The gate-triggered
    /// auto-backfill (`CRMSyncService.historyBackfillRequest`, wired in
    /// `startPolling()`) fires for a number the console just gated, which
    /// may not have a `Conversation` loaded in `conversations` yet — so it
    /// cannot go through `syncHistoryToCRM(for:)`'s conversation lookup.
    func syncHistoryToCRM(forChatIdentifier chatIdentifier: String) {
        guard authentication.state.allowsSensitiveContent else { return }
        let contactName = contactStore.contact(for: chatIdentifier).fullName
        appLog("[AppState] syncHistoryToCRM called id=\(chatIdentifier) crmService=\(crmService != nil)")
        guard let svc = crmService else {
            appLog("[AppState] ERROR: crmService is nil — skipping sync")
            return
        }
        svc.startHistorySync(
            chatIdentifier: chatIdentifier,
            chatDB: chatDB,
            contactName: contactName
        )
    }

    /// Enables CRM sync for a conversation and syncs history if it wasn't already enabled.
    /// Called automatically when a conversation is forwarded to a teammate.
    func enableCRMSyncIfNeeded(for conversation: Conversation) {
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
        syncHistoryToCRM(for: conversation)
    }
}

struct ContentView: View {
    // Shared with the Settings scene (see MFSyncedApp) so a sign-in/out in
    // the Settings window's CRM Sync tab reaches the SAME running
    // CRMSyncService this view's polling drives — not a second,
    // disconnected AppState instance.
    let appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showSetup = false
    @State private var lastReconciledAuthenticationState: AuthenticationState?

    private var needsSetup: Bool {
        let setupComplete = UserDefaults.standard.bool(forKey: "mfsynced_setup_complete")
        return !setupComplete || appState.dbError != nil
    }

    var body: some View {
        Group {
            switch AuthenticatedContentMode.resolve(for: appState.authentication.state) {
            case .authenticationOnly:
                AuthenticationGateView(authentication: appState.authentication)
            case .sensitiveApplication:
                authenticatedApplication
            }
        }
        .task {
            await appState.authentication.validateStartupSession()
            reconcileAuthenticationState()

            // Keep the persistent status honest after startup. A dead
            // refresh token or validation failure re-locks both scenes and
            // clears cached display state instead of silently falling back.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    return
                }
                await appState.authentication.revalidateAuthenticatedSession()
                reconcileAuthenticationState()
            }
        }
        .onChange(of: appState.authentication.state) {
            reconcileAuthenticationState()
        }
        .onDisappear {
            appState.stopPolling()
        }
    }

    @ViewBuilder
    private var authenticatedApplication: some View {
        VStack(spacing: 0) {
            authenticatedStatusBar
            Divider()
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
            .sheet(isPresented: $showSetup) {
                SetupView(isPresented: $showSetup, authentication: appState.authentication) {
                    // Re-run startup after setup so conversations load
                    appState.stopPolling()
                    appState.crmConfig = CRMConfig.load()
                    appState.startPolling()
                }
            }
        }
    }

    private var authenticatedStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text("Authenticated")
                .font(.callout.bold())
            if let email = appState.authentication.state.authenticatedEmail {
                Text(email)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign Out") {
                Task { await appState.authentication.signOut() }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
        .accessibilityIdentifier("authenticated-status")
    }

    private func reconcileAuthenticationState() {
        let state = appState.authentication.state
        guard state != lastReconciledAuthenticationState else { return }
        lastReconciledAuthenticationState = state
        if state.allowsSensitiveContent {
            appState.refreshCRMConfigAfterAuthChange()
            appState.startPolling()
        } else {
            showSetup = false
            if state == .signedOut {
                appState.discardPersistedLegacyCredentials()
            }
            appState.lockForAuthentication()
        }
    }
}
