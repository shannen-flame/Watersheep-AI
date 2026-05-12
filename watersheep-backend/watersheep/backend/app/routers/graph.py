"""Knowledge graph endpoints."""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

from ..models.schemas import GraphResponse
from ..services.graph_service import build_graph_html, build_graph_json

router = APIRouter(prefix="/api/graph", tags=["graph"])


@router.get("", response_model=GraphResponse)
async def get_graph() -> GraphResponse:
    """Return the knowledge graph as JSON (nodes + edges)."""
    data = build_graph_json()
    return GraphResponse(**data)


@router.get("/html", response_class=HTMLResponse)
async def get_graph_html() -> str:
    """Return the interactive Graphify HTML visualization."""
    return build_graph_html()
