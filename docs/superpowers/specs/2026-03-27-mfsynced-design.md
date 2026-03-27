# MFSynced — Design Spec

## Overview

A native macOS SwiftUI app that mirrors the iMessage experience while adding CRM integration. Reads messages from `~/Library/Messages/chat.db`, sends via AppleScript, and syncs designated contacts with a cloud CRM via HTTP polling.

## Problem

iMessage data is locked inside Apple's Messages.app. Teams using a cloud CRM need their iMessage conversations visible there — both historical backlog and real-time messages. Each team member runs MFSynced on their Mac; the CRM gets a unified view.

## Architecture

```
Mac 1 (MFSynced) ──HTTP──┐
Mac 2 (MFSynced) ──HTTP──┤── Cloud CRM (FastAPI + PostgreSQL)
Mac 3 (MFSynced) ──HTTP──┘
```

Hub-and-spoke. The CRM is the hub. Each Mac is a spoke that:
- **Pushes** inbound messages to the CRM
- **Pulls** outbound send commands from the CRM
- **Pushes** historical backlog on demand

The Mac is always the HTTP client. The CRM never initiates connections to the Macs.

### Why HTTP Polling (Not WebSocket/MQTT)

| Concern | HTTP Polling |
|---------|-------------|
| Network reliability | Stateless — survives NAT, firewalls, sleep/wake, network changes |
| Message loss | Zero — local SQLite retry queue + CRM PostgreSQL queue |
| Infrastructure | None beyond the CRM server |
| Latency | ~5 seconds (acceptable for CRM) |
| Complexity | Two HTTP calls on a timer |

## Technology

- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI (macOS 14+)
- **SQLite**: Raw C API via Swift's built-in `sqlite3` (no dependencies)
- **Sending**: AppleScript via `NSAppleScript` to Messages.app
- **HTTP Client**: Foundation `URLSession`
- **Contacts**: `CNContactStore` (Contacts framework) for photos/names
- **Notifications**: `UNUserNotificationCenter`
- **Dependencies**: None (stdlib only)

## UI Design

### Main Window — NavigationSplitView

Faithful iMessage clone with light and dark mode support.

**Sidebar (left, 64px)**:
- Icon-only circular avatars stacked vertically
- Selected contact has blue outline ring
- Green dot overlay on CRM-synced contacts
- Compose button (pencil icon) at top
- Right-click context menu: Pin, Hide Alerts, Delete, CRM Sync toggle, Sync History

**Chat Area (right)**:
- **Header**: Centered contact avatar + name + service badge. "CRM" green badge if synced.
- **Messages**: Blue outgoing bubbles (right-aligned), gray incoming bubbles (left-aligned). Asymmetric corner radii for bubble tails. Date separators centered. Delivery status below last outgoing.
- **Compose bar**: "+" button, text field with "Message" placeholder, send button.

**Theme**:
- Follows macOS system appearance by default (`@Environment(\.colorScheme)`)
- Manual override in preferences
- Light: white background, #e9e9eb incoming, #007AFF outgoing
- Dark: #000 message area, #2c2c2e incoming, #0a84ff outgoing

### Settings Window — TabView

Three tabs: General, CRM Sync, Notifications.

**General tab**:
- Theme: System / Light / Dark
- Database path (auto-detected, override for testing)
- Poll interval for chat.db (default 2s)

**CRM Sync tab**:
- Enable/disable toggle
- CRM API endpoint URL
- API key (masked input)
- Poll interval for CRM (default 5s)
- Connection status indicator (green/yellow/red)
- Synced contacts list with message counts
- "+ Add Contact" button
- Sync queue status (pending inbound/outbound/failed)

**Notifications tab**:
- Enable/disable
- Sound on/off
- Filter: all messages / CRM contacts only

## Data Flow

### Reading Messages (chat.db polling)

Every 2 seconds:
1. Open `file:{path}?mode=ro` connection (read-only, reads WAL)
2. Query messages with `ROWID > last_seen_rowid`
3. Join with `handle`, `chat`, `attachment` tables
4. Update conversation list and active chat view
5. Close connection

Track `last_seen_rowid` for efficient incremental reads.

**SQL query** (same as tail.py, proven working):
```sql
SELECT
    m.ROWID AS message_id, m.text, m.attributedBody,
    m.is_from_me, m.date AS message_date, m.date_edited,
    m.associated_message_type, m.associated_message_emoji,
    m.cache_has_attachments, m.service,
    h.id AS sender_id,
    c.chat_identifier, c.display_name, c.style AS chat_style,
    GROUP_CONCAT(DISTINCT a.transfer_name) AS attachment_names,
    GROUP_CONCAT(DISTINCT a.mime_type) AS attachment_types
FROM message m
LEFT JOIN handle h ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN chat c ON cmj.chat_id = c.ROWID
LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
LEFT JOIN attachment a ON maj.attachment_id = a.ROWID
WHERE m.ROWID > ?
GROUP BY m.ROWID
ORDER BY m.ROWID ASC
```

**Date conversion**: `date / 1_000_000_000 + 978307200` (Apple Cocoa nanoseconds to Unix timestamp).

**attributedBody blob parsing**: Find `NSString` marker, locate `0x2b` byte, read variable-length encoded UTF-8 string. Fallback when `text` column is NULL.

### Sending Messages (AppleScript)

```applescript
tell application "Messages"
    set targetService to 1st account whose service type = iMessage
    set targetBuddy to participant "{phone}" of targetService
    send "{text}" to targetBuddy
end tell
```

Executed via `NSAppleScript`. On failure, surface error in the compose bar.

### CRM Sync Protocol

**Mac pushes inbound messages** (every 5s):
```
POST /api/messages/inbound
Authorization: Bearer {api_key}

{
  "agent_id": "mac-uuid",
  "messages": [
    {
      "id": "message-guid",
      "phone": "+15105482606",
      "text": "Yes tomorrow 10 am ok for you!",
      "timestamp": "2026-03-27T14:41:50Z",
      "is_from_me": false,
      "service": "iMessage",
      "attachments": []
    }
  ]
}

Response: { "confirmed": ["message-guid", ...] }
```

Mac removes confirmed messages from local retry queue.

**Mac pulls outbound commands** (every 5s):
```
GET /api/messages/outbound?agent_id=mac-uuid&since=last_id
Authorization: Bearer {api_key}

Response: {
  "messages": [
    {
      "id": "cmd-uuid",
      "phone": "+15105482606",
      "text": "Following up on our conversation...",
    }
  ]
}
```

Mac sends each via AppleScript, then acknowledges:
```
POST /api/messages/outbound/{cmd-uuid}/ack
Authorization: Bearer {api_key}

{ "status": "delivered" }   // or "failed" with error details
```

**History sync** (on demand):
```
POST /api/sync/{phone}/history
Authorization: Bearer {api_key}

{
  "agent_id": "mac-uuid",
  "messages": [ ... all historical messages for this contact ... ]
}
```

Triggered via right-click "Sync History to CRM" or settings panel. Sends in batches of 100 messages.

### Local Retry Queue

SQLite database at `~/Library/Application Support/MFSynced/sync_queue.db`:

```sql
CREATE TABLE sync_queue (
    id INTEGER PRIMARY KEY,
    direction TEXT NOT NULL,  -- 'inbound' (to CRM) or 'outbound_ack' (delivery confirmation)
    message_guid TEXT UNIQUE,
    phone TEXT,
    payload TEXT,  -- JSON
    created_at REAL,
    retry_count INTEGER DEFAULT 0,
    next_retry_at REAL
);
```

Messages stay in queue until CRM confirms receipt. Exponential backoff on failure (5s, 10s, 20s, 40s... capped at 5 minutes).

## App Structure (Xcode Project)

```
MFSynced/
  MFSyncedApp.swift              -- @main, WindowGroup + Settings
  Models/
    Message.swift                 -- Message struct
    Conversation.swift            -- Conversation struct (chat + messages)
    Contact.swift                 -- Contact with CRM sync flag
    CRMConfig.swift               -- CRM connection settings
  Views/
    ContentView.swift             -- NavigationSplitView (sidebar + detail)
    Sidebar/
      SidebarView.swift           -- Avatar list
      AvatarView.swift            -- Circular avatar with initials/photo
    Chat/
      ChatView.swift              -- Message list + compose bar
      MessageBubble.swift         -- Individual bubble (in/out styling)
      ComposeBar.swift            -- Text input + send button
      DateSeparator.swift         -- Centered date label
    Settings/
      SettingsView.swift          -- TabView with 3 tabs
      CRMSyncSettingsView.swift   -- CRM config tab
      GeneralSettingsView.swift   -- Theme, intervals
      NotificationSettingsView.swift
  Services/
    ChatDatabase.swift            -- SQLite read-only access to chat.db
    MessageSender.swift           -- AppleScript message sending
    ContactStore.swift            -- CNContactStore wrapper for photos/names
    CRMSyncService.swift          -- HTTP polling, retry queue
    SyncQueueDatabase.swift       -- Local retry queue SQLite
    NotificationService.swift     -- UNUserNotificationCenter wrapper
  Utilities/
    AppleDateConverter.swift      -- Cocoa timestamp conversion
    AttributedBodyParser.swift    -- NSKeyedArchiver blob extraction
```

## Features

### Contact Photos
- Query `CNContactStore` by phone number / email
- Display contact photo in avatar, fall back to colored initials
- Cache contact lookups in memory (refresh on app launch)

### Image Previews
- Attachment paths from `attachment.filename` column (relative to `~/Library/Messages/Attachments/`)
- Load thumbnails via `NSImage` for image MIME types
- Show inline in chat below the message bubble

### Search
- `WHERE m.text LIKE '%query%'` across all messages
- Results shown in a search overlay with conversation context
- Tap result to jump to that message in the conversation

### Notifications
- `UNUserNotificationCenter` for native macOS notifications
- Fire when a new incoming message arrives (not from_me)
- Include sender name and message preview
- Click notification opens the conversation

## Permissions

The app requires:
- **Full Disk Access** — to read `~/Library/Messages/chat.db` (user grants in System Settings)
- **Contacts** — to read contact photos/names (system prompt on first use)
- **Notifications** — to show alerts (system prompt on first use)
- **Accessibility** (optional) — if AppleScript requires it for Messages.app automation

## Verification Plan

1. **Build and launch**: Xcode build, app opens with conversation list populated from chat.db
2. **Light/dark mode**: Toggle macOS appearance, verify both themes render correctly
3. **Message display**: Scroll through conversations, verify bubbles, timestamps, tapbacks, attachments
4. **Send a message**: Type in compose bar, send, verify it appears in Messages.app
5. **CRM sync**: Configure endpoint, mark a contact, verify inbound POST fires within 5s
6. **CRM outbound**: Queue a message in CRM, verify Mac picks it up and sends
7. **History sync**: Right-click contact, sync history, verify CRM receives full backlog
8. **Retry queue**: Disconnect CRM, send messages, reconnect, verify queued messages deliver
9. **Search**: Search for a keyword, verify results appear with correct conversation context
10. **Notifications**: Background the app, receive a message, verify native notification appears
