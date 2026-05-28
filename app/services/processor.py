"""Background processor for batch jobs."""

from __future__ import annotations

import asyncio
from pathlib import Path

from app.core.config import OUTPUT_ROOT
from app.models.schemas import BatchInfo, JobInfo, JobStatus, OrganizeMode
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

    async def process_jobs(self, batch: BatchInfo, jobs: list[JobInfo]) -> None:
        """并发处理一个 batch 下的所有 job。"""
        semaphore = asyncio.Semaphore(self.max_concurrency)

        async def _run(job: JobInfo) -> None:
            async with semaphore:
                if batch.organize_mode == OrganizeMode.COMBINED:
                    await self._transcribe_single_job(job)
                else:
                    await self._process_single_job(job)

        await asyncio.gather(*[_run(job) for job in jobs])
        if batch.organize_mode == OrganizeMode.COMBINED:
            await self._write_combined_summary(batch, jobs)

    async def _process_single_job(self, job: JobInfo) -> None:
        """处理单个 job：更新状态 -> 调 ASR -> 持久化文本。"""
        upload_path = Path(job.upload_path)
        self.store.update_job_status(job.job_id, JobStatus.PROCESSING)
        try:
            # ASR SDK 调用是阻塞 IO，放到线程池避免卡住 event loop。
            text = await asyncio.to_thread(self.asr_service.transcribe, upload_path)
            organized = await asyncio.to_thread(self.organizer.organize, text)
            organized_header = self._build_organized_header(
                organized.time,
                organized.scene,
                organized.summary,
                organized.key_points,
                organized.action_items,
                organized.tags,
            )
            full_output = f"{organized_header}\n\n## 完整转录文本\n\n{text}"
            output_path = Path(job.output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(full_output, encoding="utf-8")
            self.store.update_job_status(job.job_id, JobStatus.SUCCEEDED)
        except Exception as exc:  # noqa: BLE001
            self.store.update_job_status(job.job_id, JobStatus.FAILED, str(exc))

    async def _transcribe_single_job(self, job: JobInfo) -> None:
        """合并整理模式：每个 job 只负责 ASR，并写出原始转录 Markdown。"""
        upload_path = Path(job.upload_path)
        self.store.update_job_status(job.job_id, JobStatus.PROCESSING)
        try:
            text = await asyncio.to_thread(self.asr_service.transcribe, upload_path)
            output_path = Path(job.output_path)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(self._build_raw_transcript_markdown(job.filename, text), encoding="utf-8")
            self.store.update_job_status(job.job_id, JobStatus.SUCCEEDED)
        except Exception as exc:  # noqa: BLE001
            self.store.update_job_status(job.job_id, JobStatus.FAILED, str(exc))

    async def _write_combined_summary(self, batch: BatchInfo, jobs: list[JobInfo]) -> None:
        """把本批次成功转录的音频合并成一个概要整理 Markdown。"""
        sections: list[str] = []
        for job in jobs:
            current = self.store.get_job(job.job_id)
            output_path = Path(job.output_path)
            if not current or current.status != JobStatus.SUCCEEDED or not output_path.exists():
                continue
            transcript = self._extract_transcript_text(output_path.read_text(encoding="utf-8"))
            sections.append(f"## {job.filename}\n\n{transcript}")

        if not sections:
            return

        combined_transcript = "\n\n---\n\n".join(sections)
        organized = await asyncio.to_thread(self.organizer.organize, combined_transcript)
        output_path = self.combined_output_path(batch.batch_id)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(organized.markdown, encoding="utf-8")

    @staticmethod
    def combined_output_path(batch_id: str) -> Path:
        return OUTPUT_ROOT / batch_id / "combined-summary.md"

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
            "# 整理提炼\n\n"
            f"- **时间**: {time_text}\n"
            f"- **场景**: {scene}\n\n"
            "## 摘要\n\n"
            f"{summary}\n\n"
            "## 关键点\n\n"
            f"{key_points_text}\n\n"
            "## 可执行事项\n\n"
            f"{action_items_text}\n\n"
            "## 标签\n\n"
            f"{tags_text}"
        )

    @staticmethod
    def _build_raw_transcript_markdown(filename: str, transcript: str) -> str:
        return f"# 原始转录\n\n- **文件**: {filename}\n\n## 完整转录文本\n\n{transcript}"

    @staticmethod
    def _extract_transcript_text(markdown: str) -> str:
        marker = "## 完整转录文本"
        if marker not in markdown:
            return markdown.strip()
        return markdown.split(marker, 1)[1].strip()
