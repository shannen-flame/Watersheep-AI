"""SQLite storage helpers for the modular Watersheep backend."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from ..utils.config import get_settings
from ..utils.errors import AppError


def get_database_path() -> Path:
    """Return the configured SQLite database path."""

    settings = get_settings()
    return settings.database_path


def get_connection() -> sqlite3.Connection:
    """Open a SQLite connection tuned for app-level concurrency."""

    try:
        connection = sqlite3.connect(
            get_database_path(),
            timeout=30,
            isolation_level=None,
            check_same_thread=False,
        )
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=NORMAL")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection
    except sqlite3.Error as exc:
        raise AppError("Could not connect to the SQLite database.", status_code=500) from exc


def initialize_database() -> None:
    """Create the starter tables used by the backend."""

    try:
        get_database_path().parent.mkdir(parents=True, exist_ok=True)
        with get_connection() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS memories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp TEXT NOT NULL,
                    location TEXT,
                    summary TEXT NOT NULL,
                    transcript TEXT,
                    detected_objects TEXT NOT NULL DEFAULT '[]',
                    image_path TEXT,
                    embedding TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_memories_timestamp
                ON memories(timestamp DESC);

                CREATE TABLE IF NOT EXISTS interaction_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_type TEXT NOT NULL,
                    source TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_interaction_events_type_time
                ON interaction_events(event_type, created_at DESC);

                CREATE TABLE IF NOT EXISTS personalization_signals (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    signal_key TEXT NOT NULL,
                    signal_value TEXT NOT NULL,
                    score REAL NOT NULL DEFAULT 0,
                    metadata TEXT NOT NULL DEFAULT '{}',
                    updated_at TEXT NOT NULL,
                    UNIQUE(signal_key, signal_value)
                );

                CREATE INDEX IF NOT EXISTS idx_personalization_signals_score
                ON personalization_signals(signal_key, score DESC);

                CREATE TABLE IF NOT EXISTS conversation_turns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    role TEXT NOT NULL,
                    text TEXT NOT NULL,
                    source TEXT,
                    created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_conversation_turns_created
                ON conversation_turns(created_at DESC);
                """
            )
    except OSError as exc:
        raise AppError("Could not prepare the backend storage directory.", status_code=500) from exc
