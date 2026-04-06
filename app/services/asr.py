"""ASR service wrapper.

把具体的阿里云百炼（DashScope）语音识别调用集中在一个类里，
并保持与原有调用方一致的接口，方便后续替换为其他提供商。
"""

from __future__ import annotations

import os
from pathlib import Path

from openai import OpenAI


class AsrService:
    def __init__(
        self,
        model: str | None = None,
        base_url: str = "https://dashscope.aliyuncs.com/compatible-mode/v1",
    ) -> None:
        """初始化阿里云百炼兼容客户端并读取环境变量。"""
        api_key = os.getenv("DASHSCOPE_API_KEY")
        if not api_key:
            raise RuntimeError("DASHSCOPE_API_KEY is required")

        self.client = OpenAI(api_key=api_key, base_url=base_url)
        self.model = model or os.getenv("DASHSCOPE_ASR_MODEL", "fun-asr")

    def transcribe(self, file_path: Path) -> str:
        """将单个音频文件转录为文本。"""
        with file_path.open("rb") as audio_file:
            response = self.client.audio.transcriptions.create(
                model=self.model,
                file=audio_file,
            )
        return response.text
