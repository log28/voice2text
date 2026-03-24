"""ASR service wrapper.

把具体的 OpenAI Whisper 调用集中在一个类里，方便后续替换为其他提供商。
"""

from __future__ import annotations

import os
from pathlib import Path

from openai import OpenAI


class AsrService:
    def __init__(self, model: str = "whisper-1") -> None:
        """初始化 ASR 客户端并读取环境变量。"""
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError("OPENAI_API_KEY is required")
        self.client = OpenAI(api_key=api_key)
        self.model = model

    def transcribe(self, file_path: Path) -> str:
        """将单个音频文件转录为文本。"""
        with file_path.open("rb") as audio_file:
            response = self.client.audio.transcriptions.create(
                model=self.model,
                file=audio_file,
            )
        return response.text
