"""Build a Graphify knowledge graph from stored memories.

Tries to call the `graphify` CLI first. If it is not installed or fails,
falls back to a self-contained vis.js HTML graph built directly from the
memory database.
"""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

from .memory_service import list_memories
from ..models.schemas import MemoryResponse


# Stopwords specific to assistant-style narration. We keep this small on
# purpose — too aggressive a filter and the graph loses real concepts.
_GRAPH_STOPWORDS = frozenset({
    "a", "an", "the", "and", "or", "but", "if", "then", "else", "of", "in",
    "on", "at", "to", "for", "with", "by", "from", "into", "onto", "as",
    "is", "are", "was", "were", "be", "been", "being", "am", "do", "does",
    "did", "have", "has", "had", "having", "i", "me", "my", "mine", "you",
    "your", "yours", "he", "him", "his", "she", "her", "hers", "it", "its",
    "we", "us", "our", "they", "them", "their", "this", "that", "these",
    "those", "there", "here", "what", "which", "who", "whom", "whose",
    "when", "where", "why", "how", "not", "no", "yes", "so", "very",
    "really", "just", "some", "any", "all", "each", "every", "more", "most",
    "less", "least", "few", "many", "much", "can", "could", "will", "would",
    "should", "may", "might", "must", "shall", "now", "then", "than",
    "also", "too", "only", "own", "same", "such", "see", "seen", "saw",
    "look", "looking", "looks", "looked", "user", "watersheep", "scene",
    "image", "picture", "photo", "frame", "show", "shows", "showing",
    "appears", "appear", "seems", "seem", "currently", "person", "people",
    "thing", "things", "object", "objects",
})

_TOKEN_PATTERN = re.compile(r"[A-Za-z][A-Za-z'\-]{2,}")


def _extract_entities(text: str, *, limit: int = 5) -> list[str]:
    """Pull out the most informative noun-like tokens from a memory summary.

    Heuristics, in priority order:
      1. Capitalized multi-word phrases (likely proper nouns / places).
      2. Bigrams that aren't stopword-heavy.
      3. Single tokens that aren't stopwords or super short.
    """

    if not text:
        return []
    cleaned = text.strip()

    # Pass 1: capitalized phrases like "Calculus Textbook" or "Costa Coffee".
    phrases: list[str] = []
    for match in re.finditer(r"\b([A-Z][a-z'\-]{2,}(?:\s+[A-Z][a-z'\-]{2,}){0,3})\b", cleaned):
        phrase = match.group(1)
        if not all(p.lower() in _GRAPH_STOPWORDS for p in phrase.lower().split()):
            phrases.append(phrase.lower())

    # Pass 2: notable single tokens.
    raw_tokens = _TOKEN_PATTERN.findall(cleaned.lower())
    token_counts = Counter(
        token for token in raw_tokens
        if token not in _GRAPH_STOPWORDS and len(token) > 3
    )

    # Combine, de-dup while preserving order.
    seen: set[str] = set()
    ordered: list[str] = []
    for phrase in phrases:
        if phrase not in seen:
            seen.add(phrase)
            ordered.append(phrase)
    for token, _ in token_counts.most_common():
        if token not in seen and not any(token in phrase for phrase in seen):
            seen.add(token)
            ordered.append(token)
        if len(ordered) >= limit:
            break

    return ordered[:limit]


# ---------------------------------------------------------------------------
# Markdown export helpers
# ---------------------------------------------------------------------------

def _memory_to_markdown(memory: MemoryResponse) -> str:
    """Render a single memory as a Graphify-friendly markdown document."""
    timestamp_label = memory.timestamp.strftime("%Y-%m-%d %H:%M")
    location_label = memory.location or "Unknown Location"
    lines = [
        f"# Memory: {timestamp_label} — {location_label}",
        "",
        f"**Summary:** {memory.summary}",
        "",
    ]
    if memory.location:
        lines += [f"**Location:** {memory.location}", ""]
    if memory.detected_objects:
        lines += ["**Detected Objects:**"]
        lines += [f"- {obj}" for obj in memory.detected_objects]
        lines += [""]
    if memory.transcript:
        lines += [f"**Transcript:** {memory.transcript}", ""]
    return "\n".join(lines)


def _export_memories_to_dir(memories: list[MemoryResponse], directory: Path) -> None:
    for memory in memories:
        (directory / f"memory_{memory.id}.md").write_text(
            _memory_to_markdown(memory), encoding="utf-8"
        )


# ---------------------------------------------------------------------------
# Graphify CLI integration
# ---------------------------------------------------------------------------

def _run_graphify(memory_dir: Path, output_dir: Path) -> str | None:
    """Run `graphify run <memory_dir>` and return the produced HTML, or None."""
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(
            ["graphify", "run", str(memory_dir), "--output", str(output_dir)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            return None
        for html_file in sorted(output_dir.rglob("*.html")):
            content = html_file.read_text(encoding="utf-8")
            if content.strip():
                return content
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return None


# ---------------------------------------------------------------------------
# Fallback: native vis.js graph
# ---------------------------------------------------------------------------

def _build_graph_data(memories: list[MemoryResponse]) -> dict:
    """Build node/edge dicts from memory co-occurrence.

    Nodes come from three sources:
      - explicit `location` field
      - explicit `detected_objects` list
      - entities extracted from `summary` and `transcript` text

    Edges are added for every pair of entities that co-occur in the same
    memory, plus a location -> entity edge for each memory that has one.
    """
    nodes: dict[str, dict] = {}
    edges: list[dict] = []
    edge_weights: dict[tuple[str, str], int] = {}

    def _add_node(key: str, node_type: str) -> None:
        if key not in nodes:
            nodes[key] = {"id": key, "label": key, "type": node_type, "count": 0}
        nodes[key]["count"] += 1

    def _add_edge(a: str, b: str) -> None:
        if a == b:
            return
        key = (min(a, b), max(a, b))
        edge_weights[key] = edge_weights.get(key, 0) + 1

    for memory in memories:
        loc = (memory.location or "").strip().lower()
        if loc:
            _add_node(loc, "location")

        explicit_objects = [
            obj.strip().lower()
            for obj in memory.detected_objects
            if obj and obj.strip()
        ]
        for obj in explicit_objects:
            _add_node(obj, "object")

        text_blob = " ".join(
            part for part in [memory.summary, memory.transcript or ""] if part
        )
        entities = _extract_entities(text_blob, limit=6)
        # Don't double-count: skip an entity if we already have it as an explicit object.
        new_entities = [e for e in entities if e not in explicit_objects and e != loc]
        for entity in new_entities:
            _add_node(entity, "entity")

        all_concepts = explicit_objects + new_entities
        for i, a in enumerate(all_concepts):
            if loc:
                _add_edge(a, loc)
            for b in all_concepts[i + 1:]:
                _add_edge(a, b)

    for (src, tgt), weight in edge_weights.items():
        edges.append({"source": src, "target": tgt, "weight": weight})

    return {"nodes": list(nodes.values()), "edges": edges}


def _vis_js_html(nodes: list[dict], edges: list[dict]) -> str:
    nodes_js = json.dumps(nodes)
    edges_js = json.dumps(edges)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Watersheep Knowledge Graph</title>
<script src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
<style>
  html, body {{ margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden;
    background: #0a0a1a; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }}
  #graph {{ width: 100%; height: 100%; }}
  #legend {{ position: absolute; bottom: 16px; left: 16px; display: flex; gap: 10px; }}
  .legend-item {{ display: flex; align-items: center; gap: 6px;
    color: rgba(255,255,255,0.7); font-size: 12px; }}
  .dot {{ width: 12px; height: 12px; border-radius: 50%; }}
</style>
</head>
<body>
<div id="graph"></div>
<div id="legend">
  <div class="legend-item"><div class="dot" style="background:#00d4ff"></div>Location</div>
  <div class="legend-item"><div class="dot" style="background:#7c3aed"></div>Object</div>
  <div class="legend-item"><div class="dot" style="background:#22c55e"></div>Entity</div>
</div>
<script>
(function() {{
  const rawNodes = {nodes_js};
  const rawEdges = {edges_js};
  const colorMap = {{ location: '#00d4ff', object: '#7c3aed', entity: '#22c55e' }};

  const visNodes = new vis.DataSet(rawNodes.map(n => ({{
    id: n.id,
    label: n.label,
    value: n.count,
    color: {{
      background: colorMap[n.type] || '#888',
      border: 'rgba(255,255,255,0.3)',
      highlight: {{ background: '#fff', border: colorMap[n.type] || '#888' }}
    }},
    font: {{ color: '#fff', size: 13 }},
    title: n.type.charAt(0).toUpperCase() + n.type.slice(1) + ': ' + n.label + ' (' + n.count + ' memories)'
  }})));

  const visEdges = new vis.DataSet(rawEdges.map((e, i) => ({{
    id: i, from: e.source, to: e.target,
    width: Math.min(e.weight * 0.8 + 0.5, 6),
    color: {{ color: 'rgba(255,255,255,0.15)', highlight: 'rgba(255,255,255,0.7)' }},
    smooth: {{ type: 'continuous' }}
  }})));

  const container = document.getElementById('graph');
  new vis.Network(container, {{ nodes: visNodes, edges: visEdges }}, {{
    physics: {{
      solver: 'forceAtlas2Based',
      forceAtlas2Based: {{ gravitationalConstant: -60, centralGravity: 0.01, springLength: 120 }},
      stabilization: {{ iterations: 150 }}
    }},
    interaction: {{ hover: true, tooltipDelay: 100, navigationButtons: false }},
    nodes: {{ shape: 'dot', scaling: {{ min: 12, max: 42 }} }}
  }});
}})();
</script>
</body>
</html>"""


def _empty_html() -> str:
    return """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="background:#0a0a1a;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<p style="color:rgba(255,255,255,0.6);font-family:-apple-system,sans-serif;font-size:16px">
No memories yet — start capturing!
</p>
</body></html>"""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def build_graph_html() -> str:
    """Return an HTML knowledge graph for all stored memories.

    Tries the Graphify CLI first; falls back to a native vis.js render.
    """
    memories = list_memories(limit=500)
    if not memories:
        return _empty_html()

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        memory_dir = tmp / "memories"
        memory_dir.mkdir()
        _export_memories_to_dir(memories, memory_dir)

        html = _run_graphify(memory_dir, tmp / "graphify_output")
        if html:
            return html

    graph = _build_graph_data(memories)
    return _vis_js_html(graph["nodes"], graph["edges"])


def build_graph_json() -> dict:
    """Return a JSON graph (nodes + edges) built from stored memories."""
    memories = list_memories(limit=500)
    if not memories:
        return {"nodes": [], "edges": []}
    return _build_graph_data(memories)
