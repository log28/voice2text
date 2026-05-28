"""Batch orchestration service."""

from __future__ import annotations

from fastapi import BackgroundTasks

from app.models.schemas import BatchInfo, JobInfo
from app.services.processor import BatchProcessor
from app.stores import Store


class BatchService:
    """Coordinates batch persistence and background execution."""

    def __init__(self, store: Store, processor: BatchProcessor) -> None:
        self.store = store
        self.processor = processor

    def create_batch(self, background_tasks: BackgroundTasks, batch: BatchInfo, jobs: list[JobInfo]) -> None:
        self.store.create_batch(batch=batch, jobs=jobs)
        background_tasks.add_task(self.processor.process_jobs, batch, jobs)
