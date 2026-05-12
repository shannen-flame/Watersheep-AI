"""Current-scene assistant behavior."""

from app.models.schemas import AskQuestionRequest
from app.services import assistant_service


def test_present_scene_question_returns_exact_current_scene(monkeypatch):
    """Do not let the chat model reinterpret already-correct vision captions."""

    def fail_if_llm_called(*_args, **_kwargs):
        raise AssertionError("Current-scene questions should not call the text LLM.")

    monkeypatch.setattr(assistant_service, "answer_general_question_full", fail_if_llm_called)

    response = assistant_service.answer_question(
        AskQuestionRequest(
            question="explain scene",
            scene_context=(
                "Current scene: A tub of styling clay on a bedroom desk. "
                "Recent conversation: Assistant: You are in a park."
            ),
        )
    )

    assert response.llm_provider == "scene_context"
    assert response.used_memories == []
    assert "styling clay" in response.assistant_message
    assert "park" not in response.assistant_message


def test_scene_intent_includes_common_user_phrases():
    assert assistant_service.is_present_scene_question("wht am i seeing")
    assert assistant_service.is_present_scene_question("explain the scene")
    assert assistant_service.is_present_scene_question("tell me what you see")
