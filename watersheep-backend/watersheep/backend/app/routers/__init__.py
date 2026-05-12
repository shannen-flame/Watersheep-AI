"""API router exports for the Watersheep backend."""

from fastapi import APIRouter

from . import assistant, graph, health, internet, vision


api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(assistant.router)
api_router.include_router(assistant.legacy_router)
api_router.include_router(vision.router)
api_router.include_router(vision.legacy_router)
api_router.include_router(internet.router)
api_router.include_router(graph.router)

__all__ = ["api_router"]
