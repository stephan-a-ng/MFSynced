import Foundation

/// One row of the candidate catalog ChatDatabase.fetchCatalog() hands to
/// CRMSyncService.uploadCatalog() — metadata only, never message bodies.
/// By default the catalog contains 1:1 conversations only; callers may opt
/// into group chats (chat.style == 43, see Conversation.isGroup /
/// Message.isGroup) with `fetchCatalog(includeGroups: true)`.
struct ChatCatalogEntry: Equatable {
    let chatIdentifier: String
    let displayName: String?
    let lastActivityAt: Date?
    let messageCount: Int
    let isGroup: Bool
    let groupName: String?
    let participants: [String]

    init(
        chatIdentifier: String,
        displayName: String?,
        lastActivityAt: Date?,
        messageCount: Int,
        isGroup: Bool = false,
        groupName: String? = nil,
        participants: [String] = []
    ) {
        self.chatIdentifier = chatIdentifier
        self.displayName = displayName
        self.lastActivityAt = lastActivityAt
        self.messageCount = messageCount
        self.isGroup = isGroup
        self.groupName = groupName
        self.participants = participants
    }
}
