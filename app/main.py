"""FastAPI app entrypoint."""

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.api.routes import create_router
from app.core.config import SQLITE_DB_PATH, STORE_BACKEND, UPLOAD_ROOT
from app.stores import InMemoryStore, SQLiteStore, Store


app = FastAPI(title="voice2text", version="0.1.0")
app.mount("/public/uploads", StaticFiles(directory=UPLOAD_ROOT), name="public_uploads")


def _build_store() -> Store:
    if STORE_BACKEND == "sqlite":
        return SQLiteStore(db_path=SQLITE_DB_PATH)
    return InMemoryStore()


app.include_router(create_router(_build_store()))
