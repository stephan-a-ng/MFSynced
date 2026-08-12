"""Phone number normalization for the send API.

Accepts loosely-formatted phone numbers from the web UI (spaces, dashes,
parens, dots) and normalizes them to E.164-ish form so they match the
`phone` values already stored by the Mac agent (see app/services/message_service.py
inbound path, which stores whatever the Messages app / Contacts gives it).
"""
import re

_STRIP_CHARS_RE = re.compile(r"[ \-\(\)\.]")
_NON_DIGIT_RE = re.compile(r"\D")


def normalize_phone(raw: str) -> str:
    """Normalize a raw phone number string.

    - Strips spaces, dashes, parens, and dots.
    - "+"-prefixed numbers become "+" followed by their digits.
    - Bare 10-digit numbers are assumed US/CA and prefixed "+1".
    - Bare 11-digit numbers starting with "1" become "+"-prefixed.
    - Other all-digit strings (e.g. short codes) are returned unchanged
      (as digits only).
    - Raises ValueError if there are no digits at all.
    """
    if not raw:
        raise ValueError("phone number is empty")

    cleaned = _STRIP_CHARS_RE.sub("", raw.strip())
    if not cleaned:
        raise ValueError("phone number is empty")

    is_plus = cleaned.startswith("+")
    digits = _NON_DIGIT_RE.sub("", cleaned)
    if not digits:
        raise ValueError("phone number has no digits")

    if is_plus:
        return "+" + digits
    if len(digits) == 10:
        return "+1" + digits
    if len(digits) == 11 and digits.startswith("1"):
        return "+" + digits
    return digits
