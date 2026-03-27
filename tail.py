#!/usr/bin/env python3
"""Tail iMessage messages from the local chat.db database."""

import argparse
import datetime
import os
import pathlib
import signal
import sqlite3
import sys
import time

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CHAT_DB_PATH = pathlib.Path.home() / "Library" / "Messages" / "chat.db"
APPLE_EPOCH_OFFSET = 978307200  # seconds between Unix epoch and 2001-01-01
NS_TO_SEC = 1_000_000_000


class C:
    """ANSI color codes."""

    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    CYAN = "\033[36m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    MAGENTA = "\033[35m"
    BLUE = "\033[34m"
    RED = "\033[31m"
    GRAY = "\033[90m"


TAPBACK_TYPES = {
    2000: "Loved",
    2001: "Liked",
    2002: "Disliked",
    2003: "Laughed at",
    2004: "Emphasized",
    2005: "Questioned",
    2006: "",  # emoji reaction — use associated_message_emoji
    2007: "",  # newer type
    3000: "Removed love from",
    3001: "Removed like from",
    3002: "Removed dislike from",
    3003: "Removed laugh from",
    3004: "Removed emphasis from",
    3005: "Removed question from",
    3006: "Removed reaction from",
}

SEND_EFFECTS = {
    "com.apple.MobileSMS.expressivesend.gentle": "Sent Gently",
    "com.apple.MobileSMS.expressivesend.impact": "Sent with Impact",
    "com.apple.MobileSMS.expressivesend.invisibleink": "Sent with Invisible Ink",
    "com.apple.MobileSMS.expressivesend.loud": "Sent with Loud Effect",
}

MESSAGE_QUERY = """\
SELECT
    m.ROWID          AS message_id,
    m.text,
    m.attributedBody,
    m.is_from_me,
    m.date           AS message_date,
    m.date_edited,
    m.associated_message_type,
    m.associated_message_emoji,
    m.cache_has_attachments,
    m.expressive_send_style_id,
    m.service,
    h.id             AS sender_id,
    c.chat_identifier,
    c.display_name   AS chat_display_name,
    c.style          AS chat_style,
    GROUP_CONCAT(DISTINCT a.transfer_name) AS attachment_names,
    GROUP_CONCAT(DISTINCT a.mime_type)     AS attachment_types
FROM message m
LEFT JOIN handle h              ON m.handle_id = h.ROWID
LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
LEFT JOIN chat c                ON cmj.chat_id = c.ROWID
LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id
LEFT JOIN attachment a          ON maj.attachment_id = a.ROWID
WHERE m.ROWID > ?{chat_filter}
GROUP BY m.ROWID
ORDER BY m.ROWID ASC
"""

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Tail iMessage messages in real-time.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--db",
        type=pathlib.Path,
        default=CHAT_DB_PATH,
        help="Path to chat.db (default: ~/Library/Messages/chat.db)",
    )
    p.add_argument(
        "-i",
        "--interval",
        type=float,
        default=2.0,
        help="Poll interval in seconds (default: 2.0)",
    )
    p.add_argument(
        "-n",
        "--last",
        type=int,
        default=0,
        help="Show last N messages on startup",
    )
    p.add_argument(
        "--no-color",
        action="store_true",
        help="Disable colored output",
    )
    p.add_argument(
        "--no-tapbacks",
        action="store_true",
        help="Hide tapback/reaction messages",
    )
    p.add_argument(
        "--chat",
        type=str,
        default=None,
        help="Filter to a specific chat identifier (phone number or email)",
    )
    return p.parse_args()


# ---------------------------------------------------------------------------
# Database access
# ---------------------------------------------------------------------------


def get_connection(db_path: pathlib.Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only = ON")
    return conn


def get_max_rowid(conn: sqlite3.Connection) -> int:
    row = conn.execute("SELECT MAX(ROWID) FROM message").fetchone()
    return row[0] or 0


def fetch_new_messages(
    conn: sqlite3.Connection,
    last_rowid: int,
    chat_filter: str | None = None,
) -> list[sqlite3.Row]:
    if chat_filter:
        query = MESSAGE_QUERY.format(
            chat_filter=" AND c.chat_identifier = ?"
        )
        params = (last_rowid, chat_filter)
    else:
        query = MESSAGE_QUERY.format(chat_filter="")
        params = (last_rowid,)
    return conn.execute(query, params).fetchall()


# ---------------------------------------------------------------------------
# Decoding helpers
# ---------------------------------------------------------------------------


def apple_date_to_str(apple_ns: int | None) -> str:
    if not apple_ns:
        return ""
    try:
        unix_ts = apple_ns / NS_TO_SEC + APPLE_EPOCH_OFFSET
        dt = datetime.datetime.fromtimestamp(unix_ts)
        return dt.strftime("%H:%M:%S")
    except (OSError, ValueError, OverflowError):
        return ""


def extract_text_from_attributed_body(blob: bytes) -> str | None:
    """Extract plain text from an NSKeyedArchiver-encoded attributedBody blob."""
    if not blob:
        return None
    try:
        # Find NSString marker
        marker = b"NSString"
        idx = blob.find(marker)
        if idx == -1:
            return None
        idx += len(marker)

        # Find the 0x2b ('+') byte that precedes the string payload
        plus_idx = blob.find(b"\x2b", idx)
        if plus_idx == -1:
            return None
        idx = plus_idx + 1

        # Read length encoding
        length_byte = blob[idx]
        idx += 1
        if length_byte >= 0x80:
            # Multi-byte length: (length_byte - 0x80) additional bytes, big-endian
            extra = length_byte - 0x80
            length = int.from_bytes(blob[idx : idx + extra], "big")
            idx += extra
        else:
            length = length_byte

        # Skip optional 0x00 separator
        if idx < len(blob) and blob[idx] == 0x00:
            idx += 1

        text = blob[idx : idx + length].decode("utf-8", errors="replace")
        return text if text else None
    except (IndexError, ValueError):
        return None


def get_message_text(row: sqlite3.Row) -> str | None:
    text = row["text"]
    if text and text.strip("\ufffc").strip():
        return text
    body = extract_text_from_attributed_body(row["attributedBody"])
    if body:
        return body
    return None


def format_tapback(row: sqlite3.Row) -> str | None:
    amt = row["associated_message_type"]
    if not amt or amt == 0:
        return None

    if amt == 1000:
        return "[Sticker]"

    label = TAPBACK_TYPES.get(amt)
    if label is None:
        return f"[Reaction type {amt}]"

    # Emoji reaction
    if amt in (2006, 3006):
        emoji = row["associated_message_emoji"] or "?"
        if amt == 2006:
            return f"Reacted {emoji}"
        return f"Removed {emoji}"

    # Text-based tapback — the text column often has e.g. 'Liked "hello"'
    text = row["text"]
    if text:
        return text

    return f"{label} a message" if label else f"[Reaction type {amt}]"


def format_attachment_info(row: sqlite3.Row) -> str | None:
    if not row["cache_has_attachments"]:
        return None
    names = row["attachment_names"]
    types = row["attachment_types"]
    if not names:
        return "[Attachment]"
    name_list = names.split(",")
    type_list = types.split(",") if types else [""] * len(name_list)
    parts = []
    for name, mime in zip(name_list, type_list):
        name = name.strip()
        mime = mime.strip()
        if mime:
            parts.append(f"[{name} ({mime})]")
        else:
            parts.append(f"[{name}]")
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------


def col(text: str, color: str, enabled: bool) -> str:
    if not enabled:
        return text
    return f"{color}{text}{C.RESET}"


def format_message(row: sqlite3.Row, colors: bool) -> str:
    timestamp = apple_date_to_str(row["message_date"])
    is_from_me = row["is_from_me"]
    sender = "Me" if is_from_me else (row["sender_id"] or "Unknown")
    service = row["service"] or ""
    is_group = row["chat_style"] == 43
    chat_name = row["chat_display_name"] or row["chat_identifier"] or ""
    amt = row["associated_message_type"] or 0

    # Build timestamp part
    ts = col(f"[{timestamp}]", C.CYAN, colors) if timestamp else ""

    # Service badge
    svc = f" ({service})" if service else ""

    # Sender with color
    if is_from_me:
        sender_str = col(f"Me{svc}", C.GREEN + C.BOLD, colors)
    else:
        sender_str = col(f"{sender}{svc}", C.YELLOW, colors)

    # Group chat prefix
    group_prefix = ""
    if is_group and chat_name:
        group_prefix = col(f"[{chat_name}] ", C.MAGENTA, colors)

    # Tapback / reaction
    if amt != 0:
        tapback_text = format_tapback(row)
        if tapback_text:
            return f"{ts}   {group_prefix}{sender_str} {col(tapback_text, C.DIM, colors)}"

    # Message text
    text = get_message_text(row)
    attachment_info = format_attachment_info(row)

    # Suffix annotations
    suffix_parts = []
    if row["date_edited"]:
        suffix_parts.append(col(" [edited]", C.DIM, colors))
    effect_id = row["expressive_send_style_id"]
    if effect_id and effect_id in SEND_EFFECTS:
        suffix_parts.append(col(f" [{SEND_EFFECTS[effect_id]}]", C.DIM, colors))
    suffix = "".join(suffix_parts)

    lines = []
    if text:
        lines.append(f"{ts} {group_prefix}{sender_str} > {text}{suffix}")
    elif attachment_info:
        lines.append(
            f"{ts} {group_prefix}{sender_str} > {col(attachment_info.split(chr(10))[0], C.BLUE, colors)}{suffix}"
        )
    else:
        lines.append(
            f"{ts} {group_prefix}{sender_str} > {col('[empty message]', C.DIM, colors)}{suffix}"
        )

    # Attachment lines (below message text)
    if text and attachment_info:
        indent = " " * (len(f"[{timestamp}] ") + len(f"{sender}{svc} > "))
        for att_line in attachment_info.split("\n"):
            lines.append(f"{indent}{col(att_line, C.BLUE, colors)}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

running = True


def main() -> None:
    global running
    args = parse_args()
    db_path = args.db
    interval = args.interval
    show_last = args.last
    use_colors = not args.no_color and sys.stdout.isatty()
    show_tapbacks = not args.no_tapbacks
    chat_filter = args.chat

    if not db_path.exists():
        print(
            f"Error: {db_path} not found.\n"
            "Make sure Full Disk Access is enabled for your terminal in\n"
            "System Settings > Privacy & Security > Full Disk Access.",
            file=sys.stderr,
        )
        sys.exit(1)

    def handle_signal(sig: int, frame) -> None:
        global running
        running = False

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    # Initial state
    try:
        conn = get_connection(db_path)
        max_rowid = get_max_rowid(conn)
        conn.close()
    except sqlite3.OperationalError as e:
        print(f"Error opening database: {e}", file=sys.stderr)
        print(
            "You may need to grant Full Disk Access to your terminal in\n"
            "System Settings > Privacy & Security > Full Disk Access.",
            file=sys.stderr,
        )
        sys.exit(1)

    last_seen_rowid = max_rowid

    # Show history
    if show_last > 0:
        start_rowid = max(0, max_rowid - show_last)
        try:
            conn = get_connection(db_path)
            rows = fetch_new_messages(conn, start_rowid, chat_filter)
            conn.close()
            for row in rows:
                if not show_tapbacks and (row["associated_message_type"] or 0) != 0:
                    continue
                print(format_message(row, use_colors))
                last_seen_rowid = row["message_id"]
        except sqlite3.OperationalError:
            pass
        print(col("---", C.DIM, use_colors))

    print(
        col(
            f"Tailing {db_path} (every {interval}s, Ctrl+C to stop)",
            C.DIM,
            use_colors,
        )
    )

    # Poll loop
    while running:
        try:
            conn = get_connection(db_path)
            rows = fetch_new_messages(conn, last_seen_rowid, chat_filter)
            conn.close()
            for row in rows:
                if not show_tapbacks and (row["associated_message_type"] or 0) != 0:
                    continue
                print(format_message(row, use_colors))
                last_seen_rowid = row["message_id"]
        except sqlite3.OperationalError as e:
            if "locked" not in str(e).lower() and "busy" not in str(e).lower():
                print(f"Database error: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)

        # Sleep in small increments for responsive Ctrl+C
        remaining = interval
        while running and remaining > 0:
            time.sleep(min(0.25, remaining))
            remaining -= 0.25

    print("\nStopped.")


if __name__ == "__main__":
    main()
