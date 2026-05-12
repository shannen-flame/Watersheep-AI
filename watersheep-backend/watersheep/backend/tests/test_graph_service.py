"""Knowledge graph entity extraction tests."""

from datetime import datetime, timezone

from app.models.schemas import MemoryCreate
from app.services.graph_service import _build_graph_data, _extract_entities
from app.services.memory_service import create_memory


def test_extract_entities_pulls_capitalized_phrases():
    text = "Saw a Calculus Textbook on the desk near Costa Coffee"
    entities = _extract_entities(text)
    joined = " ".join(entities)
    assert "calculus textbook" in joined or "calculus" in joined
    assert "costa coffee" in joined or "costa" in joined


def test_extract_entities_drops_stopwords():
    text = "I am looking at a person showing me the thing"
    entities = _extract_entities(text)
    # All of these are filtered as stopwords.
    assert "looking" not in entities
    assert "person" not in entities
    assert "thing" not in entities


def test_extract_entities_empty_input_returns_empty_list():
    assert _extract_entities("") == []


def test_build_graph_data_uses_summary_text_when_objects_empty():
    saved = create_memory(
        MemoryCreate(
            summary="Met Sarah at Costa Coffee to review the calculus homework",
            location="London",
            transcript=None,
            detected_objects=[],
            timestamp=datetime.now(timezone.utc),
        )
    )
    graph = _build_graph_data([saved])
    node_ids = {node["id"] for node in graph["nodes"]}
    # Even with no detected_objects, we should pull a few entities from the summary.
    assert len(node_ids) >= 2
    assert "london" in node_ids  # location
    # At least one extracted entity should be present.
    extracted = node_ids - {"london"}
    assert len(extracted) > 0
    # Edges should connect concepts to the location.
    assert any(edge["source"] == "london" or edge["target"] == "london" for edge in graph["edges"])
