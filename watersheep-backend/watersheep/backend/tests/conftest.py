"""Shared pytest fixtures for the Watersheep backend."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

# Ensure the backend package is importable when running pytest from the repo root.
BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))


@pytest.fixture(autouse=True)
def isolated_database(monkeypatch, tmp_path):
    """Point every test at a fresh SQLite file and reset the cached settings."""

    db_path = tmp_path / "watersheep-test.db"
    uploads_path = tmp_path / "uploads"
    monkeypatch.setenv("WATERSHEEP_DB_PATH", str(db_path))
    monkeypatch.setenv("WATERSHEEP_UPLOADS_PATH", str(uploads_path))
    monkeypatch.setenv("WATERSHEEP_ENV", "development")
    monkeypatch.setenv("WATERSHEEP_DEBUG_ENDPOINTS", "true")

    from app.utils.config import get_settings
    get_settings.cache_clear()

    from app.services import storage
    storage.initialize_database()

    yield db_path

    get_settings.cache_clear()
