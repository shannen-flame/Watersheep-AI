"""Internet research tools for assistant answers.

The assistant should not dump raw search results back to the user. This module
turns live-data questions into a small research workflow: decide if search is
needed, gather results from configured providers, rank trustworthy sources, read
short page excerpts when possible, and produce a concise sourced answer.
"""

from __future__ import annotations

import html
import logging
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from typing import Any
from urllib.parse import parse_qs, quote, unquote, urlparse

import httpx

from ..utils.config import get_settings
from .llm_provider import LLMProviderManager, LLMRequest

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class InternetAnswer:
    """Answer text plus the live data source that produced it."""

    text: str
    provider: str = "internet"
    model: str = "live-data"
    payload: dict[str, Any] | None = None


@dataclass(frozen=True)
class SearchResult:
    """A normalized web result that is safe to return to clients."""

    title: str
    url: str
    snippet: str
    source: str
    confidence: float = 0.5

    def as_dict(self) -> dict[str, Any]:
        return {
            "title": self.title,
            "url": self.url,
            "summary": self.snippet,
            "source": self.source,
            "confidence": self.confidence,
        }


@dataclass(frozen=True)
class InternetSearchReport:
    """Summarized research package returned by internet endpoints."""

    query: str
    mode: str
    summary: str
    results: list[SearchResult]
    provider: str
    confidence: float
    exact_match: bool = False
    image_keywords: str | None = None

    def as_payload(self) -> dict[str, Any]:
        return {
            "query": self.query,
            "mode": self.mode,
            "summary": self.summary,
            "results": [result.as_dict() for result in self.results],
            "provider": self.provider,
            "confidence": self.confidence,
            "exact_match": self.exact_match,
            "image_keywords": self.image_keywords,
        }


class SearchProvider:
    """Base class for swappable search providers."""

    name: str

    def is_configured(self) -> bool:
        return True

    def search(self, query: str, *, mode: str, limit: int) -> list[SearchResult]:
        raise NotImplementedError


class BraveSearchProvider(SearchProvider):
    """Brave Search API provider. Requires BRAVE_SEARCH_API_KEY."""

    name = "brave"

    def is_configured(self) -> bool:
        return bool(os.getenv("BRAVE_SEARCH_API_KEY", "").strip())

    def search(self, query: str, *, mode: str, limit: int) -> list[SearchResult]:
        api_key = os.getenv("BRAVE_SEARCH_API_KEY", "").strip()
        with httpx.Client(timeout=10, follow_redirects=True) as client:
            response = client.get(
                "https://api.search.brave.com/res/v1/web/search",
                params={"q": query, "count": min(limit, 10), "search_lang": "en"},
                headers={
                    "Accept": "application/json",
                    "X-Subscription-Token": api_key,
                    "User-Agent": "Watersheep/1.0",
                },
            )
            response.raise_for_status()
            data = response.json()

        items = (data.get("web") or {}).get("results") or []
        results: list[SearchResult] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            title = clean_text(str(item.get("title") or ""))
            url = clean_result_url(str(item.get("url") or ""))
            snippet = clean_text(str(item.get("description") or ""))
            if title and url:
                results.append(make_search_result(title, url, snippet, query=query, mode=mode))
            if len(results) >= limit:
                break
        return results


class TavilySearchProvider(SearchProvider):
    """Tavily Search API provider. Requires TAVILY_API_KEY."""

    name = "tavily"

    def is_configured(self) -> bool:
        return bool(os.getenv("TAVILY_API_KEY", "").strip())

    def search(self, query: str, *, mode: str, limit: int) -> list[SearchResult]:
        api_key = os.getenv("TAVILY_API_KEY", "").strip()
        with httpx.Client(timeout=12, follow_redirects=True) as client:
            response = client.post(
                "https://api.tavily.com/search",
                json={
                    "api_key": api_key,
                    "query": query,
                    "max_results": min(limit, 10),
                    "search_depth": "basic",
                    "include_answer": False,
                },
                headers={"User-Agent": "Watersheep/1.0"},
            )
            response.raise_for_status()
            data = response.json()

        results: list[SearchResult] = []
        for item in data.get("results") or []:
            if not isinstance(item, dict):
                continue
            title = clean_text(str(item.get("title") or ""))
            url = clean_result_url(str(item.get("url") or ""))
            snippet = clean_text(str(item.get("content") or ""))
            if title and url:
                results.append(make_search_result(title, url, snippet, query=query, mode=mode))
            if len(results) >= limit:
                break
        return results


class SerpAPISearchProvider(SearchProvider):
    """SerpAPI provider. Requires SERPAPI_API_KEY."""

    name = "serpapi"

    def is_configured(self) -> bool:
        return bool(os.getenv("SERPAPI_API_KEY", "").strip())

    def search(self, query: str, *, mode: str, limit: int) -> list[SearchResult]:
        api_key = os.getenv("SERPAPI_API_KEY", "").strip()
        params = {
            "engine": "google",
            "q": query,
            "api_key": api_key,
            "num": min(limit, 10),
        }
        if mode == "product":
            params["tbm"] = "shop"

        with httpx.Client(timeout=12, follow_redirects=True) as client:
            response = client.get("https://serpapi.com/search.json", params=params)
            response.raise_for_status()
            data = response.json()

        raw_items = data.get("shopping_results") if mode == "product" else data.get("organic_results")
        results: list[SearchResult] = []
        for item in raw_items or []:
            if not isinstance(item, dict):
                continue
            title = clean_text(str(item.get("title") or ""))
            url = clean_result_url(str(item.get("link") or item.get("product_link") or ""))
            snippet = clean_text(str(item.get("snippet") or item.get("description") or item.get("price") or ""))
            if title and url:
                results.append(make_search_result(title, url, snippet, query=query, mode=mode))
            if len(results) >= limit:
                break
        return results


class DuckDuckGoSearchProvider(SearchProvider):
    """No-key fallback provider based on DuckDuckGo endpoints."""

    name = "duckduckgo"

    def search(self, query: str, *, mode: str, limit: int) -> list[SearchResult]:
        instant_results = search_duckduckgo_instant_answer(query, limit=limit)
        if len(instant_results) >= limit:
            return instant_results[:limit]

        html_query = query
        if mode == "product":
            html_query = f"{query} buy product"
        html_results = search_duckduckgo_html(html_query, limit=limit)
        return merge_results([*instant_results, *html_results], limit=limit)


CRYPTO_ALIASES: dict[str, tuple[str, str]] = {
    "bitcoin": ("bitcoin", "Bitcoin"),
    "bit coin": ("bitcoin", "Bitcoin"),
    "btc": ("bitcoin", "Bitcoin"),
    "ethereum": ("ethereum", "Ethereum"),
    "ether": ("ethereum", "Ethereum"),
    "eth": ("ethereum", "Ethereum"),
    "solana": ("solana", "Solana"),
    "sol": ("solana", "Solana"),
}

WEATHER_CODE_LABELS: dict[int, str] = {
    0: "clear",
    1: "mostly clear",
    2: "partly cloudy",
    3: "cloudy",
    45: "foggy",
    48: "foggy",
    51: "light drizzle",
    53: "drizzle",
    55: "heavy drizzle",
    61: "light rain",
    63: "rain",
    65: "heavy rain",
    71: "light snow",
    73: "snow",
    75: "heavy snow",
    80: "light showers",
    81: "showers",
    82: "heavy showers",
    95: "thunderstorms",
    96: "thunderstorms with hail",
    99: "thunderstorms with hail",
}

WEB_SEARCH_TRIGGERS: tuple[str, ...] = (
    "search",
    "look up",
    "look it up",
    "google",
    "internet",
    "web",
    "latest",
    "current",
    "currently",
    "right now",
    "live",
    "today",
    "tdy",
    "news",
    "recent",
    "recently",
    "new",
    "update",
    "updated",
    "score",
    "scores",
    "who won",
    "when is",
    "when does",
    "release date",
    "available now",
    "buy",
    "where can i buy",
    "price",
    "pricing",
    "review",
    "reviews",
    "compare",
    "product",
    "near me",
    "open now",
    "opening hours",
    "documentation",
    "docs",
    "api error",
    "error code",
    "tutorial",
    "software update",
    "version",
)

PRODUCT_TRIGGERS: tuple[str, ...] = (
    "buy",
    "where can i buy",
    "find this product",
    "find similar",
    "similar items",
    "product",
    "shoe",
    "clothing",
    "gadget",
    "price",
    "pricing",
    "shop",
)

OFFICIAL_HINTS: tuple[str, ...] = (
    "official",
    "docs",
    "documentation",
    "developer",
    "support",
    "help",
    ".gov",
    ".edu",
)


def answer_live_data_question(question: str) -> InternetAnswer | None:
    """Return an internet-backed answer when the intent is clear."""

    normalized = normalize_text(question)
    if is_weather_question(normalized):
        return answer_weather_question(question)
    if is_crypto_price_question(normalized):
        return answer_crypto_price_question(normalized)
    if should_use_web_search(normalized):
        return answer_web_search_question(question)
    return None


def is_weather_question(normalized: str) -> bool:
    """Detect current weather questions."""

    weather_terms = ("weather", "temperature", "forecast", "rain today", "raining")
    return any(term in normalized for term in weather_terms)


def is_crypto_price_question(normalized: str) -> bool:
    """Detect common crypto price questions."""

    if "price" not in normalized and "worth" not in normalized and "how much" not in normalized:
        return False
    return any(alias in normalized for alias in CRYPTO_ALIASES)


def should_use_web_search(normalized: str) -> bool:
    """Detect questions that need current web data instead of static LLM memory."""

    if not get_settings().enable_web_search:
        return False

    if any(trigger in normalized for trigger in WEB_SEARCH_TRIGGERS):
        return True

    current_patterns = (
        r"\bwho is the (?:ceo|president|prime minister|leader|mayor)\b",
        r"\bwhat is the (?:stock|share) price\b",
        r"\bwhat happened (?:today|yesterday)\b",
        r"\bhow do i fix .*(?:error|exception|crash|failed|misuse)\b",
    )
    return any(re.search(pattern, normalized) for pattern in current_patterns)


def answer_web_search_question(question: str) -> InternetAnswer:
    """Research the web, summarise useful results, and include sources."""

    try:
        mode = infer_search_mode(question)
        report = research_web(question, mode=mode)
        return InternetAnswer(
            text=format_research_answer(report),
            model=f"web-search:{report.provider}",
            payload=report.as_payload(),
        )
    except Exception as exc:
        logger.warning("Web research failed: %s", exc)
        return InternetAnswer(
            text="I tried to check online, but web search is not reachable right now.",
            model="web-search:error",
        )


def research_web(
    query: str,
    *,
    mode: str = "web",
    scene_context: str | None = None,
    image_keywords: str | None = None,
    max_results: int | None = None,
    provider: str | None = None,
) -> InternetSearchReport:
    """Run a web/product research pass and return a filtered summary."""

    settings = get_settings()
    limit = max(1, min(max_results or settings.search_max_results, 8))
    focused_query = build_focused_query(query, mode=mode, scene_context=scene_context, image_keywords=image_keywords)
    provider_name = provider or settings.search_provider
    results, used_provider = search_web(focused_query, mode=mode, limit=limit, provider=provider_name)
    ranked = rank_results(results, query=focused_query, mode=mode)[:limit]

    if settings.search_fetch_pages and ranked:
        ranked = augment_results_with_page_excerpts(ranked[: min(3, limit)], query=focused_query, mode=mode) + ranked[min(3, limit):]
        ranked = rank_results(merge_results(ranked, limit=limit), query=focused_query, mode=mode)[:limit]

    if not ranked:
        return InternetSearchReport(
            query=focused_query,
            mode=mode,
            summary="I checked online but could not find a reliable result for that.",
            results=[],
            provider=used_provider,
            confidence=0.0,
            exact_match=False,
            image_keywords=image_keywords,
        )

    exact_match = infer_exact_product_match(focused_query, ranked) if mode in {"product", "image"} else False
    summary = summarize_search_results(focused_query, ranked, mode=mode, exact_match=exact_match)
    confidence = round(sum(result.confidence for result in ranked[:3]) / max(1, min(3, len(ranked))), 2)
    return InternetSearchReport(
        query=focused_query,
        mode=mode,
        summary=summary,
        results=ranked,
        provider=used_provider,
        confidence=confidence,
        exact_match=exact_match,
        image_keywords=image_keywords,
    )


def search_web(
    query: str,
    *,
    mode: str = "web",
    limit: int = 5,
    provider: str | None = None,
) -> tuple[list[SearchResult], str]:
    """Search configured providers with fallback."""

    providers = make_search_providers(provider)
    errors: list[str] = []
    for search_provider in providers:
        if not search_provider.is_configured():
            continue
        try:
            results = search_provider.search(query, mode=mode, limit=limit)
            if results:
                return merge_results(results, limit=limit), search_provider.name
        except Exception as exc:
            errors.append(f"{search_provider.name}: {exc}")
            logger.warning("Search provider %s failed: %s", search_provider.name, exc)
    if errors:
        logger.info("All search providers failed or returned empty results: %s", "; ".join(errors))
    return [], providers[0].name if providers else "none"


def make_search_providers(preferred: str | None = None) -> list[SearchProvider]:
    """Build provider fallback order from env/settings."""

    registry: dict[str, SearchProvider] = {
        "brave": BraveSearchProvider(),
        "tavily": TavilySearchProvider(),
        "serpapi": SerpAPISearchProvider(),
        "duckduckgo": DuckDuckGoSearchProvider(),
    }
    preferred_name = (preferred or "auto").strip().lower()
    order: list[str]
    if preferred_name in {"", "auto"}:
        order = ["brave", "tavily", "serpapi", "duckduckgo"]
    else:
        order = [preferred_name, "brave", "tavily", "serpapi", "duckduckgo"]

    providers: list[SearchProvider] = []
    seen: set[str] = set()
    for name in order:
        provider = registry.get(name)
        if provider is not None and name not in seen:
            providers.append(provider)
            seen.add(name)
    return providers


def search_duckduckgo_instant_answer(query: str, *, limit: int) -> list[SearchResult]:
    """Use DuckDuckGo's instant-answer JSON for direct facts and topics."""

    with httpx.Client(timeout=8, follow_redirects=True) as client:
        response = client.get(
            "https://api.duckduckgo.com/",
            params={
                "q": query,
                "format": "json",
                "no_html": "1",
                "no_redirect": "1",
                "skip_disambig": "1",
            },
            headers={"User-Agent": "Watersheep/1.0"},
        )
        response.raise_for_status()
        data = response.json()

    results: list[SearchResult] = []
    answer = str(data.get("Answer") or "").strip()
    answer_type = str(data.get("AnswerType") or "").strip()
    if answer:
        url = str(data.get("AbstractURL") or "https://duckduckgo.com/")
        results.append(make_search_result(answer_type.upper() if answer_type else "DuckDuckGo answer", url, answer, query=query))

    abstract = str(data.get("AbstractText") or "").strip()
    if abstract:
        url = str(data.get("AbstractURL") or "https://duckduckgo.com/")
        results.append(make_search_result(str(data.get("Heading") or "DuckDuckGo result"), url, abstract, query=query))

    for topic in flatten_related_topics(data.get("RelatedTopics")):
        if len(results) >= limit:
            break
        text = str(topic.get("Text") or "").strip()
        if not text:
            continue
        title = text.split(" - ", 1)[0][:120]
        url = str(topic.get("FirstURL") or "https://duckduckgo.com/")
        results.append(make_search_result(title, url, text, query=query))
    return results[:limit]


def search_duckduckgo_html(query: str, *, limit: int) -> list[SearchResult]:
    """Use DuckDuckGo's HTML result page as a generic web-search fallback."""

    with httpx.Client(timeout=10, follow_redirects=True) as client:
        response = client.post(
            "https://html.duckduckgo.com/html/",
            data={"q": query},
            headers={"User-Agent": "Watersheep/1.0"},
        )
        response.raise_for_status()

    parser = DuckDuckGoHTMLParser(limit=limit)
    parser.feed(response.text)
    return parser.results[:limit]


def summarize_search_results(
    query: str,
    results: list[SearchResult],
    *,
    mode: str,
    exact_match: bool = False,
) -> str:
    """Summarise search results using the LLM, with deterministic fallback."""

    source_notes = "\n".join(
        f"{index}. {result.title}\nURL: {result.url}\nSource: {result.source}\nExcerpt: {result.snippet}"
        for index, result in enumerate(results[:5], start=1)
    )
    product_instruction = (
        "If this is a product/image search, say whether the results look exact or only similar. "
        "Do not pretend an uncertain match is exact."
    )
    if not get_settings().search_use_llm_summary:
        return deterministic_summary(query, results, mode=mode, exact_match=exact_match)

    prompt = f"""
You are Watersheep's internet research summariser.

User query:
{query}

Search mode: {mode}
Exact product match signal: {exact_match}

Source notes:
{source_notes}

Write a short helpful answer based only on the source notes. Filter out weak or duplicate results.
Mention that this is based on web results. Include no made-up facts and no made-up links.
{product_instruction}
Do not greet the user. Do not add a sign-off.
Keep it conversational and concise.
"""
    response = LLMProviderManager().generate(LLMRequest(prompt=prompt, timeout_seconds=20))
    if response and response.text.strip():
        return ensure_web_result_attribution(clean_research_summary(response.text))
    return deterministic_summary(query, results, mode=mode, exact_match=exact_match)


def clean_research_summary(value: str) -> str:
    """Remove chatty boilerplate from model summaries."""

    cleaned = clean_text(value)
    cleaned = re.sub(r"^(hello|hi|hey)[,!.\s]+", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s+(that's all i have for now|hope this helps)[.!]?$", "", cleaned, flags=re.IGNORECASE)
    return cleaned.strip()


def ensure_web_result_attribution(value: str) -> str:
    """Make the source of the answer explicit even if the model forgets."""

    normalized = value.lower()
    if "based on web results" in normalized or "based on online results" in normalized:
        return value
    return f"Based on web results, {value[:1].lower()}{value[1:]}" if value else value


def deterministic_summary(
    query: str,
    results: list[SearchResult],
    *,
    mode: str,
    exact_match: bool = False,
) -> str:
    """Fallback summary when no LLM provider can summarise the snippets."""

    if not results:
        return "I checked online but could not find a reliable result for that."

    if mode in {"product", "image"}:
        lead = "Based on web results, I found likely exact matches:" if exact_match else "Based on web results, I found similar matches, but I am not fully sure it is the exact item:"
    else:
        lead = "Based on web results, the most useful information I found is:"

    parts = [lead]
    for result in results[:3]:
        snippet = result.snippet or "No summary was available from this source."
        parts.append(f"{result.title}: {snippet}")
    return " ".join(parts)


def format_research_answer(report: InternetSearchReport) -> str:
    """Format a report for assistant/chat responses with source links."""

    if not report.results:
        return report.summary

    lines = [report.summary.strip()]
    lines.append("")
    lines.append("Sources:")
    for result in report.results[:5]:
        title = result.title or result.source or "Source"
        lines.append(f"- {title}: {result.url}")
    return "\n".join(lines).strip()


def build_focused_query(
    query: str,
    *,
    mode: str,
    scene_context: str | None = None,
    image_keywords: str | None = None,
) -> str:
    """Make a compact search query from chat text, scene text, and image terms."""

    pieces = [query.strip()]
    if image_keywords:
        pieces.insert(0, image_keywords.strip())
    elif scene_context and mode in {"image", "product"}:
        pieces.insert(0, scene_context.strip())

    joined = " ".join(piece for piece in pieces if piece)
    joined = re.sub(
        r"\b(search this online|look this up|find this product|where can i buy this|what is this|what's this|summari[sz]e this from the internet)\b",
        "",
        joined,
        flags=re.IGNORECASE,
    )
    joined = clean_text(joined)
    if mode == "product" and not any(term in joined.lower() for term in ("buy", "price", "product", "shop")):
        joined = f"{joined} product buy"
    if mode == "image" and not any(term in joined.lower() for term in ("product", "similar", "buy", "what is")):
        joined = f"{joined} identify object product"
    return joined[:300] or query.strip()


def infer_search_mode(query: str) -> str:
    """Infer generic web vs product-oriented search."""

    normalized = normalize_text(query)
    if any(trigger in normalized for trigger in PRODUCT_TRIGGERS):
        return "product"
    return "web"


def infer_exact_product_match(query: str, results: list[SearchResult]) -> bool:
    """Conservative exact-match signal for product/image search."""

    query_tokens = meaningful_tokens(query)
    if len(query_tokens) < 3:
        return False
    for result in results[:3]:
        title_tokens = meaningful_tokens(result.title)
        overlap = len(query_tokens & title_tokens) / max(1, len(query_tokens))
        if overlap >= 0.55 and result.confidence >= 0.7:
            return True
    return False


def meaningful_tokens(value: str) -> set[str]:
    stop = {
        "the",
        "and",
        "for",
        "with",
        "this",
        "that",
        "what",
        "where",
        "can",
        "buy",
        "product",
        "online",
        "find",
        "similar",
        "items",
    }
    return {
        token
        for token in re.findall(r"[a-z0-9][a-z0-9+'-]{1,}", value.lower())
        if token not in stop
    }


def rank_results(results: list[SearchResult], *, query: str, mode: str) -> list[SearchResult]:
    """Deduplicate and rank by source quality and query match."""

    reranked: list[SearchResult] = []
    for result in merge_results(results, limit=20):
        reranked.append(
            SearchResult(
                title=result.title,
                url=result.url,
                snippet=result.snippet,
                source=result.source,
                confidence=score_result_confidence(result, query=query, mode=mode),
            )
        )
    return sorted(reranked, key=lambda item: item.confidence, reverse=True)


def score_result_confidence(result: SearchResult, *, query: str, mode: str) -> float:
    """Small transparent scoring heuristic for client confidence badges."""

    score = 0.45
    haystack = f"{result.title} {result.snippet} {result.source}".lower()
    query_tokens = meaningful_tokens(query)
    if query_tokens:
        overlap = len(query_tokens & meaningful_tokens(haystack)) / max(1, len(query_tokens))
        score += min(overlap, 0.35)
    source = result.source.lower()
    if any(hint in source or hint in haystack for hint in OFFICIAL_HINTS):
        score += 0.12
    if mode == "product" and any(domain in source for domain in ("amazon.", "ebay.", "etsy.", "walmart.", "target.", "bestbuy.", "nike.", "adidas.", "apple.", "shop.")):
        score += 0.08
    if not result.snippet:
        score -= 0.12
    return round(max(0.05, min(score, 0.98)), 2)


def augment_results_with_page_excerpts(
    results: list[SearchResult],
    *,
    query: str,
    mode: str,
) -> list[SearchResult]:
    """Fetch short readable excerpts for top results when pages allow it."""

    augmented: list[SearchResult] = []
    for result in results:
        excerpt = fetch_page_excerpt(result.url)
        snippet = result.snippet
        if excerpt and excerpt.lower() not in snippet.lower():
            snippet = clean_text(f"{snippet} {excerpt}")[:900]
        augmented.append(
            SearchResult(
                title=result.title,
                url=result.url,
                snippet=snippet,
                source=result.source,
                confidence=score_result_confidence(result, query=query, mode=mode),
            )
        )
    return augmented


def fetch_page_excerpt(url: str) -> str:
    """Read a short HTML page excerpt. Non-HTML and blocked pages are skipped."""

    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return ""
    try:
        with httpx.Client(timeout=5, follow_redirects=True) as client:
            response = client.get(url, headers={"User-Agent": "Watersheep/1.0"})
            response.raise_for_status()
            content_type = response.headers.get("content-type", "")
            if "text/html" not in content_type:
                return ""
            parser = PageExcerptParser()
            parser.feed(response.text[:250_000])
            return clean_text(" ".join(parser.parts))[:700]
    except Exception as exc:
        logger.debug("Could not fetch page excerpt for %s: %s", url, exc)
        return ""


def make_search_result(
    title: str,
    url: str,
    snippet: str,
    *,
    query: str,
    mode: str = "web",
) -> SearchResult:
    cleaned_url = clean_result_url(url)
    source = source_name_from_url(cleaned_url)
    result = SearchResult(
        title=clean_text(title)[:180] or source or "Result",
        url=cleaned_url,
        snippet=clean_text(snippet)[:900],
        source=source,
        confidence=0.5,
    )
    return SearchResult(
        title=result.title,
        url=result.url,
        snippet=result.snippet,
        source=result.source,
        confidence=score_result_confidence(result, query=query, mode=mode),
    )


def merge_results(results: list[SearchResult], *, limit: int) -> list[SearchResult]:
    """Deduplicate results by normalized URL/title."""

    merged: list[SearchResult] = []
    seen: set[str] = set()
    for result in results:
        key = normalize_result_key(result.url or result.title)
        if not key or key in seen:
            continue
        seen.add(key)
        merged.append(result)
        if len(merged) >= limit:
            break
    return merged


def normalize_result_key(value: str) -> str:
    parsed = urlparse(value)
    if parsed.netloc:
        return f"{parsed.netloc.lower()}{parsed.path.rstrip('/')}".removeprefix("www.")
    return clean_text(value).lower()


class DuckDuckGoHTMLParser(HTMLParser):
    """Extract result titles, links, and snippets from DuckDuckGo HTML."""

    def __init__(self, *, limit: int) -> None:
        super().__init__()
        self.limit = limit
        self.results: list[SearchResult] = []
        self._active: dict[str, str] | None = None
        self._capture: str | None = None
        self._buffer: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = {name: value or "" for name, value in attrs}
        class_value = attr_map.get("class", "")
        if tag == "a" and "result__a" in class_value:
            self._active = {"title": "", "url": clean_result_url(attr_map.get("href", "")), "snippet": ""}
            self._capture = "title"
            self._buffer = []
        elif self._active is not None and (
            ("result__snippet" in class_value) or ("result__body" in class_value)
        ):
            self._capture = "snippet"
            self._buffer = []

    def handle_data(self, data: str) -> None:
        if self._capture:
            self._buffer.append(data)

    def handle_endtag(self, tag: str) -> None:
        if self._active is None or self._capture is None:
            return
        if self._capture == "title" and tag == "a":
            self._active["title"] = clean_text(" ".join(self._buffer))
            self._capture = None
            self._buffer = []
        elif self._capture == "snippet" and tag in {"a", "div"}:
            self._active["snippet"] = clean_text(" ".join(self._buffer))
            self._capture = None
            self._buffer = []
            if self._active.get("title") and len(self.results) < self.limit:
                self.results.append(
                    make_search_result(
                        self._active["title"],
                        self._active["url"],
                        self._active["snippet"],
                        query=self._active["title"],
                    )
                )
            self._active = None


class PageExcerptParser(HTMLParser):
    """Collect readable text from title, headings, and paragraphs."""

    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._capture = False
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style", "noscript", "svg"}:
            self._skip_depth += 1
            return
        self._capture = tag in {"title", "h1", "h2", "p", "li"}

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript", "svg"} and self._skip_depth:
            self._skip_depth -= 1
        self._capture = False

    def handle_data(self, data: str) -> None:
        if self._skip_depth or not self._capture:
            return
        cleaned = clean_text(data)
        if len(cleaned) >= 35:
            self.parts.append(cleaned)


def flatten_related_topics(value: Any) -> list[dict[str, Any]]:
    """Flatten DuckDuckGo related-topic groups."""

    if not isinstance(value, list):
        return []

    flattened: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        if isinstance(item.get("Topics"), list):
            flattened.extend(flatten_related_topics(item["Topics"]))
        else:
            flattened.append(item)
    return flattened


def clean_result_url(url: str) -> str:
    """Unwrap DuckDuckGo redirect URLs."""

    if not url:
        return ""
    parsed = urlparse(html.unescape(url))
    query = parse_qs(parsed.query)
    uddg = query.get("uddg")
    if uddg:
        return unquote(uddg[0])
    if parsed.netloc == "duckduckgo.com" and parsed.path == "/l/":
        return unquote(query.get("uddg", [url])[0])
    return html.unescape(url)


def source_name_from_url(url: str) -> str:
    parsed = urlparse(url)
    host = parsed.netloc.lower().removeprefix("www.")
    return host or "web"


def clean_text(value: str) -> str:
    """Clean HTML text into one readable line."""

    return re.sub(r"\s+", " ", html.unescape(value)).strip()


def normalize_text(value: str) -> str:
    """Normalize user text for intent checks."""

    return re.sub(r"\s+", " ", value.strip().lower())


def extract_weather_city(question: str) -> str:
    """Extract a city from 'weather in X' or fall back to configured city."""

    settings = get_settings()
    normalized = normalize_text(question)
    default_city = settings.default_city.strip()

    if any(phrase in normalized for phrase in ("my city", "ma city", "here", "near me")):
        return default_city

    match = re.search(
        r"(?:weather|temperature|forecast|raining|rain)\s+(?:today\s+)?(?:in|for|at)\s+(.+)",
        normalized,
    )
    if match:
        return clean_city_candidate(match.group(1))

    match = re.search(r"\b(?:in|for|at)\s+([a-z][a-z .'-]{1,80})", normalized)
    if match:
        return clean_city_candidate(match.group(1))

    return default_city


def clean_city_candidate(candidate: str) -> str:
    """Trim common time words from a city candidate."""

    cleaned = candidate.strip(" ?!.")
    stop_phrases = (
        " today",
        " tdy",
        " tomorrow",
        " tonight",
        " right now",
        " now",
        " this morning",
        " this afternoon",
        " this evening",
    )
    for phrase in stop_phrases:
        index = cleaned.find(phrase)
        if index != -1:
            cleaned = cleaned[:index]
    return cleaned.strip(" ?!.")


def geocode_city(city: str) -> dict[str, Any]:
    """Resolve a city name through Open-Meteo geocoding."""

    with httpx.Client(timeout=8) as client:
        response = client.get(
            "https://geocoding-api.open-meteo.com/v1/search",
            params={"name": city, "count": 1, "language": "en", "format": "json"},
        )
        response.raise_for_status()
        data = response.json()

    results = data.get("results")
    if not isinstance(results, list) or not results:
        raise ValueError(f"city not found: {city}")

    place = results[0]
    if not isinstance(place, dict):
        raise ValueError("invalid geocoding result")
    return place


def fetch_weather(place: dict[str, Any]) -> dict[str, Any]:
    """Fetch current and daily weather for a resolved place."""

    country_code = str(place.get("country_code") or "").upper()
    use_us_units = country_code == "US"
    params: dict[str, Any] = {
        "latitude": place["latitude"],
        "longitude": place["longitude"],
        "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
        "timezone": "auto",
        "forecast_days": 1,
    }
    if use_us_units:
        params.update(
            {
                "temperature_unit": "fahrenheit",
                "wind_speed_unit": "mph",
                "precipitation_unit": "inch",
            }
        )

    with httpx.Client(timeout=8) as client:
        response = client.get("https://api.open-meteo.com/v1/forecast", params=params)
        response.raise_for_status()
        return response.json()


def format_weather_answer(place: dict[str, Any], forecast: dict[str, Any]) -> str:
    """Format a concise weather answer."""

    current = forecast.get("current") or {}
    daily = forecast.get("daily") or {}
    current_units = forecast.get("current_units") or {}
    daily_units = forecast.get("daily_units") or {}

    city = place.get("name") or "your city"
    admin = place.get("admin1")
    country = place.get("country_code") or place.get("country")
    place_name = ", ".join(str(part) for part in (city, admin or country) if part)

    temp_unit = current_units.get("temperature_2m", "")
    wind_unit = current_units.get("wind_speed_10m", "")
    temp = current.get("temperature_2m")
    feels = current.get("apparent_temperature")
    wind = current.get("wind_speed_10m")
    condition = WEATHER_CODE_LABELS.get(int(current.get("weather_code") or 0), "mixed conditions")

    highs = daily.get("temperature_2m_max") or []
    lows = daily.get("temperature_2m_min") or []
    rain_chances = daily.get("precipitation_probability_max") or []
    high_unit = daily_units.get("temperature_2m_max", temp_unit)

    parts = [f"Weather in {place_name} today: {condition}"]
    if temp is not None:
        current_text = f"{format_number(temp)}{temp_unit} now"
        if feels is not None:
            current_text += f", feels like {format_number(feels)}{temp_unit}"
        parts.append(current_text)
    if highs and lows:
        parts.append(f"high {format_number(highs[0])}{high_unit}, low {format_number(lows[0])}{high_unit}")
    if rain_chances:
        parts.append(f"rain chance {format_number(rain_chances[0])}%")
    if wind is not None:
        parts.append(f"wind {format_number(wind)} {wind_unit}")

    return "; ".join(parts) + ". Source: Open-Meteo live weather."


def answer_weather_question(question: str) -> InternetAnswer:
    """Fetch live weather from Open-Meteo."""

    city = extract_weather_city(question)
    if not city:
        return InternetAnswer(
            text=(
                "Tell me the city for weather, or set WATERSHEEP_DEFAULT_CITY "
                "in the backend .env for 'my city'."
            ),
            model="open-meteo:missing-city",
        )

    try:
        place = geocode_city(city)
        forecast = fetch_weather(place)
        text = format_weather_answer(place, forecast)
        return InternetAnswer(text=text, model="open-meteo", payload={"place": place})
    except Exception as exc:
        logger.warning("Weather lookup failed: %s", exc)
        return InternetAnswer(
            text="I couldn't reach the live weather service right now.",
            model="open-meteo:error",
        )


def extract_crypto_coin(normalized: str) -> tuple[str | None, str | None]:
    """Return CoinGecko id and display name from a question."""

    for alias, coin in CRYPTO_ALIASES.items():
        if alias in normalized:
            return coin
    return None, None


def fetch_crypto_price(coin_id: str) -> dict[str, Any]:
    """Fetch USD price and 24h change from CoinGecko."""

    with httpx.Client(timeout=8) as client:
        response = client.get(
            "https://api.coingecko.com/api/v3/simple/price",
            params={
                "ids": coin_id,
                "vs_currencies": "usd",
                "include_24hr_change": "true",
                "include_last_updated_at": "true",
            },
        )
        response.raise_for_status()
        return response.json()


def answer_crypto_price_question(normalized: str) -> InternetAnswer:
    """Fetch live crypto prices from CoinGecko."""

    coin_id, coin_name = extract_crypto_coin(normalized)
    if not coin_id:
        return InternetAnswer(text="Which coin do you want the price for?", model="coingecko:missing-coin")

    try:
        data = fetch_crypto_price(coin_id)
        coin_data = data.get(coin_id)
        if not isinstance(coin_data, dict):
            raise ValueError("coin missing from response")
        text = format_crypto_answer(coin_name, coin_data)
        return InternetAnswer(text=text, model="coingecko", payload={"coin": coin_id})
    except Exception as exc:
        logger.warning("Crypto lookup failed: %s", exc)
        return InternetAnswer(
            text=f"I couldn't reach the live {coin_name} price service right now.",
            model="coingecko:error",
        )


def format_crypto_answer(coin_name: str, coin_data: dict[str, Any]) -> str:
    """Format a concise crypto price answer."""

    price = coin_data.get("usd")
    change = coin_data.get("usd_24h_change")
    updated_at = coin_data.get("last_updated_at")
    if price is None:
        raise ValueError("price missing")

    answer = f"{coin_name} is ${format_money(price)} USD"
    if change is not None:
        direction = "up" if float(change) >= 0 else "down"
        answer += f", {direction} {abs(float(change)):.2f}% over 24h"
    if isinstance(updated_at, int):
        updated = datetime.fromtimestamp(updated_at, tz=timezone.utc).strftime("%H:%M UTC")
        answer += f" (updated {updated})"
    return answer + ". Source: CoinGecko live price."


def duckduckgo_search_url(query: str) -> str:
    return f"https://duckduckgo.com/?q={quote(query)}"


def format_number(value: Any) -> str:
    """Compact numeric formatting."""

    number = float(value)
    if number.is_integer():
        return str(int(number))
    return f"{number:.1f}"


def format_money(value: Any) -> str:
    """Format money with enough precision for small values."""

    number = float(value)
    if number >= 100:
        return f"{number:,.0f}"
    if number >= 1:
        return f"{number:,.2f}"
    return f"{number:.6f}".rstrip("0").rstrip(".")
