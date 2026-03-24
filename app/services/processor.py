"""Background processor for batch jobs."""

from __future__ import annotations

import asyncio
from pathlib import Path

from app.models.schemas import JobInfo, JobStatus
from app.services.asr import AsrService
from app.services.store import InMemoryStore


class BatchProcessor:
    def __init__(self, store: InMemoryStore, asr_service: AsrService, max_concurrency: int = 2) -> None:
        """max_concurrency 控制同时转录的文件数，避免过载/限流。"""
        self.store = store
        self.asr_service = asr_service
        self.max_concurrency = max_concurrency

    async def process_jobs(self, jobs: list[JobInfo]) -> None:
        """并发处理一个 batch 下的所有 job。"""
        semaphore = asyncio.Semaphore(self.max_concurrency)

        async def _run(job: JobInfo) -> None:
            async with semaphore:
                await self._process_single_job(job)

        await asyncio.gather(*[_run(job) for job in jobs])

    async def _process_single_job(self, job: JobInfo) -> None:
        """处理单个 job：更新状态 -> 调 ASR -> 持久化文本。"""
        self.store.update_job_status(job.job_id, JobStatus.PROCESSING)
        try:
            # ASR SDK 调用是阻塞 IO，放到线程池避免卡住 event loop。
            text = await asyncio.to_thread(self.asr_service.transcribe, Path(job.upload_path))
            output_path = Path(job.output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(text, encoding="utf-8")
            self.store.update_job_status(job.job_id, JobStatus.SUCCEEDED)
        except Exception as exc:  # noqa: BLE001
            self.store.update_job_status(job.job_id, JobStatus.FAILED, str(exc))
