"""Intent detection and fallback tests for the legacy /message endpoint."""

from app.services.message_service import detect_intent, extract_duration_minutes


def test_detects_focus_mode_phrases():
    assert detect_intent("can we start lock in mode") == "start_lock_in"
    assert detect_intent("focus mode now") == "start_lock_in"


def test_detects_motivation():
    assert detect_intent("hype me up please") == "motivate_user"
    assert detect_intent("I need motivation") == "motivate_user"


def test_unknown_falls_through_to_general_chat():
    assert detect_intent("tell me a joke about cats") == "general_chat"


def test_extract_duration_minutes_handles_common_phrasings():
    assert extract_duration_minutes("start lock in mode for 25 minutes") == 25
    assert extract_duration_minutes("focus 5 min") == 5
    assert extract_duration_minutes("lock in") is None
