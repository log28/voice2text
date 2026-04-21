"""Background processor for batch jobs."""

from __future__ import annotations

import asyncio
from pathlib import Path

from app.models.schemas import JobInfo, JobStatus
from app.services.asr import AsrService
from app.services.organizer import TranscriptOrganizer
from app.stores import Store


class BatchProcessor:
    def __init__(
        self,
        store: Store,
        asr_service: AsrService,
        organizer: TranscriptOrganizer,
        max_concurrency: int = 2,
    ) -> None:
        """max_concurrency 控制同时转录的文件数，避免过载/限流。"""
        self.store = store
        self.asr_service = asr_service
        self.organizer = organizer
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
        upload_path = Path(job.upload_path)
        self.store.update_job_status(job.job_id, JobStatus.PROCESSING)
        try:
            # ASR SDK 调用是阻塞 IO，放到线程池避免卡住 event loop。
            text = await asyncio.to_thread(self.asr_service.transcribe, upload_path)
            organized = await asyncio.to_thread(self.organizer.organize, text)
            organized_header = self._build_organized_header(organized.time, organized.scene, organized.summary, organized.key_points, organized.action_items, organized.tags)
            full_output = f"{organized_header}\n\n完整转录文本：\n{text}"
            output_path = Path(job.output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(full_output, encoding="utf-8")
            self.store.update_job_status(job.job_id, JobStatus.SUCCEEDED)
        except Exception as exc:  # noqa: BLE001
            self.store.update_job_status(job.job_id, JobStatus.FAILED, str(exc))

    @staticmethod
    def _build_organized_header(
        time_text: str,
        scene: str,
        summary: str,
        key_points: list[str],
        action_items: list[str],
        tags: list[str],
    ) -> str:
        key_points_text = "\n".join(f"- {item}" for item in key_points) or "- （暂无）"
        action_items_text = "\n".join(f"- {item}" for item in action_items) or "- （暂无）"
        tags_text = " ".join(tags) if tags else "#未分类"
        return (
            "【整理提炼】\n"
            f"时间：{time_text}\n"
            f"场景：{scene}\n\n"
            f"摘要：\n{summary}\n\n"
            f"关键点：\n{key_points_text}\n\n"
            f"可执行事项：\n{action_items_text}\n\n"
            f"标签：\n{tags_text}"
        )
