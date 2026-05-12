"""Compatibility entrypoint for running the modular Watersheep app."""

try:
    from watersheep.backend.app.main import app
except ImportError:
    from app.main import app
