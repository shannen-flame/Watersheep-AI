"""Conversation persistence tests."""

from app.models.schemas import ConversationTurnCreate
from app.services.conversation_service import append_turn, clear_turns, list_turns


def test_append_and_list_returns_chronological_order():
    append_turn(ConversationTurnCreate(role="user", text="hello", source="typed"))
    append_turn(ConversationTurnCreate(role="assistant", text="hi back", source="typed"))

    history = list_turns(limit=10)
    assert history.count == 2
    assert history.turns[0].role == "user"
    assert history.turns[1].role == "assistant"


def test_clear_turns_resets_history():
    append_turn(ConversationTurnCreate(role="user", text="ping", source="typed"))
    clear_turns()

    history = list_turns(limit=10)
    assert history.count == 0


def test_unknown_role_is_normalized_to_user():
    append_turn(ConversationTurnCreate(role="weird", text="ping", source="typed"))
    history = list_turns(limit=10)
    assert history.turns[0].role == "user"
