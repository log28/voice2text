"""SQLite-backed metadata store with process-restart persistence."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime
from pathlib import Path

from app.models.schemas import BatchInfo, BatchStatus, JobInfo, JobStatus
from app.stores.base import Store


class SQLiteStore(Store):
    def __init__(self, db_path: str) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS batches (
                    batch_id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    jobs_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    job_id TEXT PRIMARY KEY,
                    batch_id TEXT NOT NULL,
                    filename TEXT NOT NULL,
                    upload_path TEXT NOT NULL,
                    output_path TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    FOREIGN KEY(batch_id) REFERENCES batches(batch_id)
                )
                """
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_batch_id ON jobs(batch_id)")
            conn.commit()

    def create_batch(self, batch: BatchInfo, jobs: list[JobInfo]) -> None:
        with self._connect() as conn:
            conn.execute("BEGIN")
            conn.execute(
                """
                INSERT INTO batches(batch_id, status, jobs_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    batch.batch_id,
                    batch.status.value,
                    json.dumps(batch.jobs),
                    batch.created_at.isoformat(),
                    batch.updated_at.isoformat(),
                ),
            )
            conn.executemany(
                """
                INSERT INTO jobs(job_id, batch_id, filename, upload_path, output_path, status, error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        job.job_id,
                        job.batch_id,
                        job.filename,
                        job.upload_path,
                        job.output_path,
                        job.status.value,
                        job.error,
                        job.created_at.isoformat(),
                        job.updated_at.isoformat(),
                    )
                    for job in jobs
                ],
            )
            conn.commit()

    def get_batch(self, batch_id: str) -> BatchInfo | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM batches WHERE batch_id = ?", (batch_id,)).fetchone()
        if not row:
            return None
        return BatchInfo(
            batch_id=row["batch_id"],
            status=BatchStatus(row["status"]),
            jobs=json.loads(row["jobs_json"]),
            created_at=datetime.fromisoformat(row["created_at"]),
            updated_at=datetime.fromisoformat(row["updated_at"]),
        )

    def get_job(self, job_id: str) -> JobInfo | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
        return self._row_to_job(row) if row else None

    def get_jobs_by_batch(self, batch_id: str) -> list[JobInfo]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM jobs WHERE batch_id = ? ORDER BY created_at ASC",
                (batch_id,),
            ).fetchall()
        return [self._row_to_job(row) for row in rows]

    def update_job_status(self, job_id: str, status: JobStatus, error: str | None = None) -> None:
        now = datetime.utcnow().isoformat()
        with self._connect() as conn:
            row = conn.execute("SELECT batch_id FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if not row:
                raise KeyError(f"Job not found: {job_id}")
            batch_id = row["batch_id"]
            conn.execute(
                "UPDATE jobs SET status = ?, error = ?, updated_at = ? WHERE job_id = ?",
                (status.value, error, now, job_id),
            )
            self._recompute_batch_status(conn, batch_id)
            conn.commit()

    def _recompute_batch_status(self, conn: sqlite3.Connection, batch_id: str) -> None:
        rows = conn.execute("SELECT status FROM jobs WHERE batch_id = ?", (batch_id,)).fetchall()
        statuses = [JobStatus(row["status"]) for row in rows]

        if all(s == JobStatus.QUEUED for s in statuses):
            batch_status = BatchStatus.CREATED
        elif any(s in (JobStatus.QUEUED, JobStatus.PROCESSING) for s in statuses):
            batch_status = BatchStatus.RUNNING
        elif all(s == JobStatus.SUCCEEDED for s in statuses):
            batch_status = BatchStatus.FINISHED
        elif all(s == JobStatus.FAILED for s in statuses):
            batch_status = BatchStatus.FAILED
        else:
            batch_status = BatchStatus.PARTIAL_FAILED

        conn.execute(
            "UPDATE batches SET status = ?, updated_at = ? WHERE batch_id = ?",
            (batch_status.value, datetime.utcnow().isoformat(), batch_id),
        )

    @staticmethod
    def _row_to_job(row: sqlite3.Row) -> JobInfo:
        return JobInfo(
            job_id=row["job_id"],
            batch_id=row["batch_id"],
            filename=row["filename"],
            upload_path=row["upload_path"],
            output_path=row["output_path"],
            status=JobStatus(row["status"]),
            error=row["error"],
            created_at=datetime.fromisoformat(row["created_at"]),
            updated_at=datetime.fromisoformat(row["updated_at"]),
        )
