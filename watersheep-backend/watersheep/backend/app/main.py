"""Application entrypoint for the Watersheep backend."""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .routers import api_router
from .services.storage import initialize_database
from .utils.config import get_settings
from .utils.errors import register_exception_handlers


@asynccontextmanager
async def lifespan(_: FastAPI):
    """Initialize persistent resources before serving requests."""

    initialize_database()
    yield


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""

    settings = get_settings()
    application = FastAPI(
        title=settings.app_name,
        version="0.1.0",
        description="Backend for the Watersheep context-aware smart glasses assistant.",
        lifespan=lifespan,
    )

    application.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials="*" not in settings.cors_origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    register_exception_handlers(application)
    application.include_router(api_router)
    return application


app = create_app()
