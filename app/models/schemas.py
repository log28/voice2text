from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, Field


class JobStatus(str, Enum):
    """单个音频转录任务的生命周期状态。"""

    QUEUED = "queued"
    PROCESSING = "processing"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


class BatchStatus(str, Enum):
    """一批任务的聚合状态。"""

    CREATED = "created"
    RUNNING = "running"
    FINISHED = "finished"
    PARTIAL_FAILED = "partial_failed"
    FAILED = "failed"


class JobInfo(BaseModel):
    """单个上传文件对应的任务元数据。"""

    job_id: str
    batch_id: str
    filename: str
    upload_path: str
    output_path: str
    status: JobStatus = JobStatus.QUEUED
    error: str | None = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class BatchInfo(BaseModel):
    """一批文件任务的元数据。"""

    batch_id: str
    status: BatchStatus = BatchStatus.CREATED
    jobs: list[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class CreateBatchResponse(BaseModel):
    """创建批量任务时返回的数据。"""

    batch_id: str
    status: BatchStatus
    jobs: list[JobInfo]


class GetBatchResponse(BaseModel):
    """查询批次状态时返回的数据。"""

    batch_id: str
    status: BatchStatus
    total_jobs: int
    queued: int
    processing: int
    succeeded: int
    failed: int
    jobs: list[JobInfo]


class JobResultResponse(BaseModel):
    """查询单个任务转录结果时返回的数据。"""

    job_id: str
    batch_id: str
    filename: str
    status: JobStatus
    text: str | None = None
    error: str | None = None


class OrganizeTextRequest(BaseModel):
    """转写文本整理请求。"""

    transcript: str = Field(min_length=1, description="ASR 原始转写文本")
    occurred_at: datetime | None = Field(default=None, description="可选：语音内容发生时间")


class OrganizeTextResponse(BaseModel):
    """转写文本整理结果。"""

    time: str
    scene: str
    summary: str
    key_points: list[str]
    action_items: list[str]
    tags: list[str]
    transcript: str
    markdown: str
