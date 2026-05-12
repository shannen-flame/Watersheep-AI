"""Live-data assistant routing."""

from app.models.schemas import AskQuestionRequest
from app.services import assistant_service
from app.services.internet_service import (
    InternetAnswer,
    InternetSearchReport,
    SearchResult,
    answer_live_data_question,
    clean_city_candidate,
    extract_weather_city,
    format_research_answer,
    is_crypto_price_question,
    research_web,
    should_use_web_search,
)
from app.utils.config import get_settings


def test_assistant_uses_live_data_before_llm(monkeypatch):
    """Live weather/price questions should not be answered from stale model memory."""

    monkeypatch.setattr(
        assistant_service,
        "answer_live_data_question",
        lambda _question: InternetAnswer(
            text="Bitcoin is $100 USD. Source: CoinGecko live price.",
            model="coingecko",
        ),
    )

    def fail_if_llm_called(*_args, **_kwargs):
        raise AssertionError("Live-data questions should not call the text LLM.")

    monkeypatch.setattr(assistant_service, "answer_general_question_full", fail_if_llm_called)

    response = assistant_service.answer_question(
        AskQuestionRequest(question="what is the pricew of bit coin")
    )

    assert response.assistant_message.startswith("Bitcoin is $100")
    assert response.llm_provider == "internet"
    assert response.llm_model == "coingecko"


def test_weather_city_uses_default_for_my_city(monkeypatch):
    monkeypatch.setenv("WATERSHEEP_DEFAULT_CITY", "Manchester")
    get_settings.cache_clear()

    assert extract_weather_city("what's the weather tdy in ma city") == "Manchester"


def test_weather_city_extracts_explicit_city(monkeypatch):
    monkeypatch.setenv("WATERSHEEP_DEFAULT_CITY", "")
    get_settings.cache_clear()

    assert extract_weather_city("what's the weather today in Birmingham") == "birmingham"
    assert clean_city_candidate("new york today") == "new york"


def test_crypto_price_detects_typo_question():
    assert is_crypto_price_question("whats is the pricew of bit coin")


def test_current_questions_trigger_web_search(monkeypatch):
    monkeypatch.setenv("WATERSHEEP_ENABLE_WEB_SEARCH", "true")
    get_settings.cache_clear()

    assert should_use_web_search("what is the latest news about ai")
    assert should_use_web_search("who is the current ceo of apple")


def test_generic_web_search_answer_uses_results(monkeypatch):
    monkeypatch.setenv("WATERSHEEP_ENABLE_WEB_SEARCH", "true")
    get_settings.cache_clear()

    from app.services import internet_service

    monkeypatch.setattr(
        internet_service,
        "search_web",
        lambda _query, **_kwargs: (
            [
                SearchResult(
                    title="Live result",
                    snippet="This came from a current web result.",
                    url="https://example.com/live",
                    source="example.com",
                    confidence=0.8,
                )
            ],
            "test-search",
        ),
    )
    monkeypatch.setattr(
        internet_service,
        "summarize_search_results",
        lambda _query, _results, **_kwargs: "Based on web results, this came from a current web result.",
    )

    response = answer_live_data_question("latest launch news")

    assert response is not None
    assert response.model == "web-search:test-search"
    assert "current web result" in response.text
    assert "https://example.com/live" in response.text


def test_research_formats_summary_with_sources():
    report = InternetSearchReport(
        query="search example",
        mode="web",
        summary="Based on web results, here is the filtered answer.",
        results=[
            SearchResult(
                title="Official docs",
                snippet="Useful page",
                url="https://example.com/docs",
                source="example.com",
                confidence=0.9,
            )
        ],
        provider="test",
        confidence=0.9,
    )

    answer = format_research_answer(report)

    assert answer.startswith("Based on web results")
    assert "Sources:" in answer
    assert "https://example.com/docs" in answer


def test_research_web_returns_no_result_message(monkeypatch):
    from app.services import internet_service

    monkeypatch.setattr(internet_service, "search_web", lambda _query, **_kwargs: ([], "test-search"))

    report = research_web("look this up", max_results=3)

    assert report.results == []
    assert "could not find" in report.summary


def test_web_search_can_be_disabled(monkeypatch):
    monkeypatch.setenv("WATERSHEEP_ENABLE_WEB_SEARCH", "false")
    get_settings.cache_clear()

    assert not should_use_web_search("latest news today")
