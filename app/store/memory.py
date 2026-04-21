"""Thread-safe in-memory metadata store."""

from __future__ import annotations

from datetime import datetime
from threading import Lock

from app.models.schemas import BatchInfo, BatchStatus, JobInfo, JobStatus
from app.store.base import Store


class InMemoryStore(Store):
    def __init__(self) -> None:
        self._batches: dict[str, BatchInfo] = {}
        self._jobs: dict[str, JobInfo] = {}
        self._lock = Lock()

    def create_batch(self, batch: BatchInfo, jobs: list[JobInfo]) -> None:
        with self._lock:
            self._batches[batch.batch_id] = batch
            for job in jobs:
                self._jobs[job.job_id] = job

    def get_batch(self, batch_id: str) -> BatchInfo | None:
        return self._batches.get(batch_id)

    def get_job(self, job_id: str) -> JobInfo | None:
        return self._jobs.get(job_id)

    def get_jobs_by_batch(self, batch_id: str) -> list[JobInfo]:
        batch = self.get_batch(batch_id)
        if not batch:
            return []
        return [self._jobs[job_id] for job_id in batch.jobs]

    def update_job_status(self, job_id: str, status: JobStatus, error: str | None = None) -> None:
        with self._lock:
            job = self._jobs[job_id]
            job.status = status
            job.error = error
            job.updated_at = datetime.utcnow()
            self._recompute_batch_status(job.batch_id)

    def _recompute_batch_status(self, batch_id: str) -> None:
        batch = self._batches[batch_id]
        jobs = [self._jobs[jid] for jid in batch.jobs]

        statuses = [j.status for j in jobs]
        if all(s == JobStatus.QUEUED for s in statuses):
            batch.status = BatchStatus.CREATED
        elif any(s in (JobStatus.QUEUED, JobStatus.PROCESSING) for s in statuses):
            batch.status = BatchStatus.RUNNING
        elif all(s == JobStatus.SUCCEEDED for s in statuses):
            batch.status = BatchStatus.FINISHED
        elif all(s == JobStatus.FAILED for s in statuses):
            batch.status = BatchStatus.FAILED
        else:
            batch.status = BatchStatus.PARTIAL_FAILED

        batch.updated_at = datetime.utcnow()
