"""FastAPI entrypoint for batch audio transcription.

这个模块主要负责：
1) 接收用户批量上传的音频文件；
2) 创建 batch/job 元数据并写入 store；
3) 把转录任务丢给后台处理；
4) 提供查询状态和下载结果的 API。
"""

from __future__ import annotations

import uuid
import zipfile
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

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
from app.services.organizer import TranscriptOrganizer
from app.services.processor import BatchProcessor
from app.store import InMemoryStore, SQLiteStore, Store

from app.core.config import OUTPUT_ROOT, PROJECT_ROOT, SQLITE_DB_PATH, STORE_BACKEND, UPLOAD_ROOT

app = FastAPI(title="voice2text", version="0.1.0")
app.mount("/public/uploads", StaticFiles(directory=UPLOAD_ROOT), name="public_uploads")


def _build_store() -> Store:
    if STORE_BACKEND == "sqlite":
        return SQLiteStore(db_path=SQLITE_DB_PATH)
    return InMemoryStore()


store = _build_store()
asr = AsrService()
organizer = TranscriptOrganizer()
processor = BatchProcessor(store=store, asr_service=asr, organizer=organizer, max_concurrency=2)


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    """返回简化版前端页面。"""
    return (PROJECT_ROOT / "app/web/index.html").read_text(encoding="utf-8")


@app.get("/health")
def health() -> dict[str, str]:
    """健康检查接口，给监控或部署探活使用。"""
    return {"status": "ok"}


def _to_public_job(job: JobInfo) -> JobPublicInfo:
    """将内部 job 模型转换为对外安全字段。"""
    return JobPublicInfo(
        job_id=job.job_id,
        batch_id=job.batch_id,
        filename=job.filename,
        status=job.status,
        error=job.error,
        created_at=job.created_at,
        updated_at=job.updated_at,
    )


@app.post("/batches", response_model=CreateBatchResponse)
async def create_batch(background_tasks: BackgroundTasks, files: list[UploadFile] = File(...)) -> CreateBatchResponse:
    """创建一个批量转录任务。

    - 每个上传文件会生成一个 job；
    - 整组 job 属于同一个 batch_id；
    - 返回后即异步开始处理，前端可轮询 /batches/{batch_id} 查看进度。
    """
    if not files:
        raise HTTPException(status_code=400, detail="No files provided")

    batch_id = f"b_{uuid.uuid4().hex[:12]}"
    batch_upload_dir = UPLOAD_ROOT / batch_id
    batch_output_dir = OUTPUT_ROOT / batch_id
    batch_upload_dir.mkdir(parents=True, exist_ok=True)
    batch_output_dir.mkdir(parents=True, exist_ok=True)

    jobs: list[JobInfo] = []
    for upload in files:
        # 为每个文件单独生成 job，保证可独立追踪成功/失败状态。
        job_id = f"j_{uuid.uuid4().hex[:12]}"
        # 仅保留文件名本体，避免路径穿越（如 ../../etc/passwd）。
        filename = Path(upload.filename or f"{job_id}.audio").name
        upload_path = batch_upload_dir / filename
        output_path = batch_output_dir / f"{Path(filename).stem}.txt"

        # 先保存原始上传文件，再交给后台 worker 做转录。
        file_bytes = await upload.read()
        upload_path.write_bytes(file_bytes)

        job = JobInfo(
            job_id=job_id,
            batch_id=batch_id,
            filename=filename,
            upload_path=str(upload_path),
            output_path=str(output_path),
        )
        jobs.append(job)

    batch = BatchInfo(batch_id=batch_id, jobs=[job.job_id for job in jobs])
    store.create_batch(batch=batch, jobs=jobs)
    # 通过 BackgroundTasks 异步执行，避免阻塞当前 HTTP 请求。
    background_tasks.add_task(processor.process_jobs, jobs)

    return CreateBatchResponse(batch_id=batch_id, status=batch.status, jobs=[_to_public_job(job) for job in jobs])


@app.get("/batches/{batch_id}", response_model=GetBatchResponse)
def get_batch(batch_id: str) -> GetBatchResponse:
    """查询 batch 级别的整体进度和每个 job 状态。"""
    batch = store.get_batch(batch_id)
    if not batch:
        raise HTTPException(status_code=404, detail="Batch not found")

    jobs = store.get_jobs_by_batch(batch_id)
    queued = sum(job.status == JobStatus.QUEUED for job in jobs)
    processing = sum(job.status == JobStatus.PROCESSING for job in jobs)
    succeeded = sum(job.status == JobStatus.SUCCEEDED for job in jobs)
    failed = sum(job.status == JobStatus.FAILED for job in jobs)

    return GetBatchResponse(
        batch_id=batch.batch_id,
        status=batch.status,
        total_jobs=len(jobs),
        queued=queued,
        processing=processing,
        succeeded=succeeded,
        failed=failed,
        jobs=[_to_public_job(job) for job in jobs],
    )


@app.get("/jobs/{job_id}", response_model=JobResultResponse)
def get_job_result(job_id: str) -> JobResultResponse:
    """查询单个 job 的转录结果。"""
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


@app.post("/organize", response_model=OrganizeTextResponse)
def organize_transcript(payload: OrganizeTextRequest) -> OrganizeTextResponse:
    """将 ASR 文本整理为结构化摘要和待办项。"""
    return organizer.organize(transcript=payload.transcript, occurred_at=payload.occurred_at)


@app.get("/jobs/{job_id}/download")
def download_job_result(job_id: str) -> FileResponse:
    """下载单个 job 的 txt 结果文件。"""
    job = store.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.status != JobStatus.SUCCEEDED:
        raise HTTPException(status_code=400, detail="Job not finished")

    output_path = Path(job.output_path)
    if not output_path.exists():
        raise HTTPException(status_code=404, detail="Result file missing")

    return FileResponse(path=output_path, media_type="text/plain", filename=output_path.name)


@app.get("/batches/{batch_id}/download-succeeded-zip")
def download_batch_succeeded_zip(batch_id: str) -> FileResponse:
    """打包并下载该 batch 已成功转写的 txt 文件。"""
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
