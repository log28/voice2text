"""ASR service wrapper.

把具体的阿里云百炼（DashScope）语音识别调用集中在一个类里，
并保持与原有调用方一致的接口，方便后续替换为其他提供商。
"""

from __future__ import annotations

import os
from pathlib import Path

from openai import APIStatusError, NotFoundError, OpenAI
from dotenv import load_dotenv


class AsrService:
    def __init__(
        self,
        model: str | None = None,
        base_url: str | None = None,
    ) -> None:
        """初始化阿里云百炼兼容客户端并读取环境变量。"""
        # 自动加载项目根目录下的 .env，方便本地开发直接配置密钥。
        load_dotenv()

        api_key = os.getenv("DASHSCOPE_API_KEY")
        if not api_key:
            raise RuntimeError("DASHSCOPE_API_KEY is required")

        self.base_url = base_url or os.getenv("DASHSCOPE_BASE_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1")
        self.client = OpenAI(api_key=api_key, base_url=self.base_url)
        # 默认模型使用 fun-asr，可通过环境变量覆盖。
        self.model = model or os.getenv("DASHSCOPE_ASR_MODEL", "fun-asr")

    def transcribe(self, file_path: Path) -> str:
        """将单个音频文件转录为文本。"""
        with file_path.open("rb") as audio_file:
            try:
                response = self.client.audio.transcriptions.create(
                    model=self.model,
                    file=audio_file,
                )
            except NotFoundError as exc:
                detail = self._extract_error_detail(exc)
                raise RuntimeError(
                    f"ASR request failed with 404. model='{self.model}' may be unavailable "
                    f"for your DashScope account/region. base_url='{self.base_url}'. detail='{detail}'. "
                    "Please check DASHSCOPE_BASE_URL, DASHSCOPE_API_KEY region, and DASHSCOPE_ASR_MODEL."
                ) from exc
            except APIStatusError as exc:
                detail = self._extract_error_detail(exc)
                raise RuntimeError(
                    f"ASR request failed with status={exc.status_code}. model='{self.model}', "
                    f"base_url='{self.base_url}', detail='{detail}'."
                ) from exc
        return response.text

    @staticmethod
    def _extract_error_detail(exc: APIStatusError) -> str:
        """提取上游返回的错误信息，便于直接排查配置问题。"""
        body = getattr(exc, "body", None)
        if isinstance(body, dict):
            message = body.get("message") or body.get("code")
            if message:
                return str(message)
        response = getattr(exc, "response", None)
        if response is not None:
            try:
                payload = response.json()
                if isinstance(payload, dict):
                    message = payload.get("message") or payload.get("code") or payload.get("detail")
                    if message:
                        return str(message)
                    return str(payload)
            except Exception:  # noqa: BLE001
                pass
            text = getattr(response, "text", None)
            if text:
                return str(text)[:500]
        return str(exc)
