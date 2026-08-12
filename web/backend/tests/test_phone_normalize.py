"""
Tests for phone number normalization.

Normalizes freeform phone input (as typed by a user, or pulled from a
Messages export) into the canonical form the rest of the app stores and
matches on:
  - 10-digit US numbers get a "+1" prefix.
  - 11-digit numbers already starting with "1" get a bare "+" prefix.
  - Already-E.164 input ("+...") is preserved, stripped of formatting.
  - Short codes (all-digit, not 10/11 digits) pass through unchanged —
    these aren't phone numbers in the NANP (North American Numbering Plan) sense and have no country code
    to infer.
  - Anything with no digits at all is not a phone number; raise.
"""
import pytest

from app.services.phone import normalize_phone


# ---------------------------------------------------------------------------
# Formatted US numbers -> E.164
# ---------------------------------------------------------------------------

def test_dashed_number_normalizes_to_e164():
    assert normalize_phone("555-123-4567") == "+15551234567"


def test_parens_and_spaces_normalize_to_e164():
    assert normalize_phone("(510) 548 2606") == "+15105482606"


# ---------------------------------------------------------------------------
# Already-normalized / bare 11-digit input
# ---------------------------------------------------------------------------

def test_already_e164_is_unchanged():
    assert normalize_phone("+15105482606") == "+15105482606"


def test_bare_11_digit_leading_1_gets_plus():
    assert normalize_phone("15551234567") == "+15551234567"


# ---------------------------------------------------------------------------
# International input: "+"-prefixed keeps + and digits, no NANP inference
# ---------------------------------------------------------------------------

def test_international_number_strips_formatting_but_keeps_plus():
    assert normalize_phone("+44 20 7946 0958") == "+442079460958"


# ---------------------------------------------------------------------------
# Short codes: all-digit, not 10/11 digits -> unchanged
# ---------------------------------------------------------------------------

def test_short_code_passes_through_unchanged():
    assert normalize_phone("34913") == "34913"


# ---------------------------------------------------------------------------
# Invalid input -> ValueError
# ---------------------------------------------------------------------------

def test_empty_string_raises_value_error():
    with pytest.raises(ValueError):
        normalize_phone("")


def test_no_digits_raises_value_error():
    with pytest.raises(ValueError):
        normalize_phone("abc")
