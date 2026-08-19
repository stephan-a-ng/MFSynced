import Foundation

/// One row of the candidate catalog ChatDatabase.fetchCatalog() hands to
/// CRMSyncService.uploadCatalog() — metadata only, never message bodies.
/// 1:1 conversations only; group chats (chat.style == 43, see
/// Conversation.isGroup / Message.isGroup) are excluded at the query level.
struct ChatCatalogEntry: Equatable {
    let chatIdentifier: String
    let displayName: String?
    let lastActivityAt: Date?
    let messageCount: Int
}
