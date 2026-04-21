"""HTTP routes for batch audio transcription."""

from __future__ import annotations

import uuid
import zipfile
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse

from app.core.config import OUTPUT_ROOT, PROJECT_ROOT, UPLOAD_ROOT
from app.models.schemas import (
    BatchInfo,
    CreateBatchResponse,
    GetBatchResponse,
    JobInfo,
    JobPublicInfo,
    JobResultResponse,
    JobStatus,
    OrganizeTextRequest,
    OrganizeTextResponse,
)
from app.services.asr import AsrService
from app.services.batch_service import BatchService
from app.services.organizer import TranscriptOrganizer
from app.services.processor import BatchProcessor
from app.stores import Store


def create_router(store: Store) -> APIRouter:
    """Build API router with injected store backend."""
    router = APIRouter()

    asr = AsrService()
    organizer = TranscriptOrganizer()
    processor = BatchProcessor(store=store, asr_service=asr, organizer=organizer, max_concurrency=2)
    batch_service = BatchService(store=store, processor=processor)

    def _to_public_job(job: JobInfo) -> JobPublicInfo:
        return JobPublicInfo(
            job_id=job.job_id,
            batch_id=job.batch_id,
            filename=job.filename,
            status=job.status,
            error=job.error,
            created_at=job.created_at,
            updated_at=job.updated_at,
        )

    @router.get("/", response_class=HTMLResponse)
    def index() -> str:
        return (PROJECT_ROOT / "app/web/index.html").read_text(encoding="utf-8")

    @router.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @router.post("/batches", response_model=CreateBatchResponse)
    async def create_batch(background_tasks: BackgroundTasks, files: list[UploadFile] = File(...)) -> CreateBatchResponse:
        if not files:
            raise HTTPException(status_code=400, detail="No files provided")

        batch_id = f"b_{uuid.uuid4().hex[:12]}"
        batch_upload_dir = UPLOAD_ROOT / batch_id
        batch_output_dir = OUTPUT_ROOT / batch_id
        batch_upload_dir.mkdir(parents=True, exist_ok=True)
        batch_output_dir.mkdir(parents=True, exist_ok=True)

        jobs: list[JobInfo] = []
        for upload in files:
            job_id = f"j_{uuid.uuid4().hex[:12]}"
            filename = Path(upload.filename or f"{job_id}.audio").name
            upload_path = batch_upload_dir / filename
            output_path = batch_output_dir / f"{Path(filename).stem}.txt"

            file_bytes = await upload.read()
            upload_path.write_bytes(file_bytes)

            jobs.append(
                JobInfo(
                    job_id=job_id,
                    batch_id=batch_id,
                    filename=filename,
                    upload_path=str(upload_path),
                    output_path=str(output_path),
                )
            )

        batch = BatchInfo(batch_id=batch_id, jobs=[job.job_id for job in jobs])
        batch_service.create_batch(background_tasks=background_tasks, batch=batch, jobs=jobs)

        return CreateBatchResponse(batch_id=batch_id, status=batch.status, jobs=[_to_public_job(job) for job in jobs])

    @router.get("/batches/{batch_id}", response_model=GetBatchResponse)
    def get_batch(batch_id: str) -> GetBatchResponse:
        batch = store.get_batch(batch_id)
        if not batch:
            raise HTTPException(status_code=404, detail="Batch not found")

        jobs = store.get_jobs_by_batch(batch_id)
        return GetBatchResponse(
            batch_id=batch.batch_id,
            status=batch.status,
            total_jobs=len(jobs),
            queued=sum(job.status == JobStatus.QUEUED for job in jobs),
            processing=sum(job.status == JobStatus.PROCESSING for job in jobs),
            succeeded=sum(job.status == JobStatus.SUCCEEDED for job in jobs),
            failed=sum(job.status == JobStatus.FAILED for job in jobs),
            jobs=[_to_public_job(job) for job in jobs],
        )

    @router.get("/jobs/{job_id}", response_model=JobResultResponse)
    def get_job_result(job_id: str) -> JobResultResponse:
        job = store.get_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found")

        text = None
        if job.status == JobStatus.SUCCEEDED and Path(job.output_path).exists():
            text = Path(job.output_path).read_text(encoding="utf-8")

        return JobResultResponse(
            job_id=job.job_id,
            batch_id=job.batch_id,
            filename=job.filename,
            status=job.status,
            text=text,
            error=job.error,
        )

    @router.post("/organize", response_model=OrganizeTextResponse)
    def organize_transcript(payload: OrganizeTextRequest) -> OrganizeTextResponse:
        return organizer.organize(transcript=payload.transcript, occurred_at=payload.occurred_at)

    @router.get("/jobs/{job_id}/download")
    def download_job_result(job_id: str) -> FileResponse:
        job = store.get_job(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found")
        if job.status != JobStatus.SUCCEEDED:
            raise HTTPException(status_code=400, detail="Job not finished")

        output_path = Path(job.output_path)
        if not output_path.exists():
            raise HTTPException(status_code=404, detail="Result file missing")

        return FileResponse(path=output_path, media_type="text/plain", filename=output_path.name)

    @router.get("/batches/{batch_id}/download-succeeded-zip")
    def download_batch_succeeded_zip(batch_id: str) -> FileResponse:
        batch = store.get_batch(batch_id)
        if not batch:
            raise HTTPException(status_code=404, detail="Batch not found")

        jobs = store.get_jobs_by_batch(batch_id)
        succeeded_jobs = [job for job in jobs if job.status == JobStatus.SUCCEEDED]
        if not succeeded_jobs:
            raise HTTPException(status_code=400, detail="No succeeded jobs to download")

        zip_path = OUTPUT_ROOT / batch_id / f"{batch_id}_results.zip"
        zip_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
            for job in succeeded_jobs:
                output_path = Path(job.output_path)
                if output_path.exists():
                    zf.write(output_path, arcname=output_path.name)

        return FileResponse(path=zip_path, media_type="application/zip", filename=zip_path.name)

    return router
