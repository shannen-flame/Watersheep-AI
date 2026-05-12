"""Provider-agnostic parsing helpers in llm_provider."""

from app.services.llm_provider import _extract_ollama_text, _normalize_model_text


def test_extract_text_from_ollama_generate_response():
    payload = {"response": "hello there"}
    assert _extract_ollama_text(payload) == "hello there"


def test_extract_text_from_ollama_chat_message_content():
    payload = {"message": {"content": "hi from chat"}}
    assert _extract_ollama_text(payload) == "hi from chat"


def test_extract_text_from_openai_style_choices():
    payload = {"choices": [{"message": {"content": "hi from openai"}}]}
    assert _extract_ollama_text(payload) == "hi from openai"


def test_normalize_unwraps_quoted_string():
    assert _normalize_model_text('"wrapped"') == "wrapped"


def test_normalize_pulls_assistant_message_from_json_blob():
    blob = '{"assistant_message": "hello", "vision_summary": "ignore"}'
    assert _normalize_model_text(blob) == "hello"
