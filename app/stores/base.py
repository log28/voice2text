"""Store abstraction for batch/job metadata."""

from __future__ import annotations

from abc import ABC, abstractmethod

from app.models.schemas import BatchInfo, JobInfo, JobStatus


class Store(ABC):
    """Metadata store interface.

    Backends can be in-memory, sqlite, or other durable stores.
    """

    @abstractmethod
    def create_batch(self, batch: BatchInfo, jobs: list[JobInfo]) -> None:
        """Atomically create one batch and all related jobs."""

    @abstractmethod
    def get_batch(self, batch_id: str) -> BatchInfo | None:
        """Fetch batch by id."""

    @abstractmethod
    def get_job(self, job_id: str) -> JobInfo | None:
        """Fetch job by id."""

    @abstractmethod
    def get_jobs_by_batch(self, batch_id: str) -> list[JobInfo]:
        """List jobs in one batch."""

    @abstractmethod
    def update_job_status(self, job_id: str, status: JobStatus, error: str | None = None) -> None:
        """Update a job status and recompute batch status."""
