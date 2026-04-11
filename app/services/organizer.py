"""LLM-based transcript organizer service."""

from __future__ import annotations

import json
import os
from datetime import datetime
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from app.models.schemas import OrganizeTextResponse


class TranscriptOrganizer:
    def __init__(self) -> None:
        self.api_key = os.getenv("DASHSCOPE_API_KEY", "").strip()
        self.base_url = os.getenv("DASHSCOPE_BASE_URL", "https://dashscope.aliyuncs.com/api/v1").rstrip("/")
        self.model = os.getenv("DASHSCOPE_LLM_MODEL", "qwen-plus")

    def organize(self, transcript: str, occurred_at: datetime | None = None) -> OrganizeTextResponse:
        """调用大模型整理转写文本；失败时回退到规则化结果。"""
        if not self.api_key:
            return self._fallback(transcript=transcript, occurred_at=occurred_at)

        try:
            return self._call_llm(transcript=transcript, occurred_at=occurred_at)
        except Exception:
            return self._fallback(transcript=transcript, occurred_at=occurred_at)

    def _call_llm(self, transcript: str, occurred_at: datetime | None) -> OrganizeTextResponse:
        system_prompt = (
            "你是专业的语音转写整理助手。请在不改动原始转写文本任何字词的前提下，生成结构化整理结果。"
            "场景仅能是：会议、灵感、日常。标签需带#前缀。"
            "必须返回 JSON 对象，字段：time, scene, summary, key_points, action_items, tags。"
            "其中 key_points/action_items/tags 必须是字符串数组，summary 控制在 1-2 句话。"
        )
        occurred_text = occurred_at.isoformat() if occurred_at else "未提供"
        user_prompt = (
            f"发生时间：{occurred_text}\n"
            "请整理以下语音文本：\n"
            f"{transcript}"
        )
        payload = {
            "model": self.model,
            "input": {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ]
            },
            "parameters": {"result_format": "message", "temperature": 0.2},
        }
        response = self._request_json(
            "POST",
            f"{self.base_url}/services/aigc/text-generation/generation",
            payload=payload,
        )
        llm_content = self._extract_message_content(response)
        parsed = self._safe_load_json(llm_content)

        result = OrganizeTextResponse(
            time=str(parsed.get("time") or self._format_time(occurred_at)),
            scene=self._normalize_scene(parsed.get("scene")),
            summary=str(parsed.get("summary") or "未生成摘要"),
            key_points=self._normalize_list(parsed.get("key_points")),
            action_items=self._normalize_list(parsed.get("action_items")),
            tags=self._normalize_tags(parsed.get("tags")),
            transcript=transcript,
            markdown="",
        )
        result.markdown = self._to_markdown(result)
        return result

    def _fallback(self, transcript: str, occurred_at: datetime | None) -> OrganizeTextResponse:
        preview = transcript.replace("\n", " ").strip()
        if len(preview) > 80:
            preview = f"{preview[:80]}..."
        result = OrganizeTextResponse(
            time=self._format_time(occurred_at),
            scene="日常",
            summary=f"该段语音主要提到：{preview}" if preview else "该段语音内容较短，建议补充更多上下文。",
            key_points=["建议人工补充关键点（当前为降级结果）。"],
            action_items=["建议复核并补充可执行事项。"],
            tags=["#语音整理"],
            transcript=transcript,
            markdown="",
        )
        result.markdown = self._to_markdown(result)
        return result

    def _extract_message_content(self, response: dict) -> str:
        output = response.get("output", {})
        choices = output.get("choices", [])
        if not choices:
            raise RuntimeError("LLM response missing choices")
        message = choices[0].get("message", {})
        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            raise RuntimeError("LLM response missing message content")
        return content

    def _request_json(self, method: str, url: str, payload: dict | None = None) -> dict:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = Request(url, data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.api_key}")
        request.add_header("Content-Type", "application/json")
        try:
            with urlopen(request, timeout=120) as response:  # noqa: S310
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"LLM request failed: method='{method}', url='{url}', status={exc.code}, detail='{detail}'"
            ) from exc

    def _safe_load_json(self, content: str) -> dict:
        cleaned = content.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.strip("`")
            cleaned = cleaned.replace("json\n", "", 1)
        return json.loads(cleaned)

    @staticmethod
    def _normalize_scene(scene: object) -> str:
        raw = str(scene or "").strip()
        if raw in {"会议", "灵感", "日常"}:
            return raw
        return "日常"

    @staticmethod
    def _normalize_list(value: object) -> list[str]:
        if isinstance(value, list):
            return [str(item).strip() for item in value if str(item).strip()]
        return []

    @staticmethod
    def _normalize_tags(value: object) -> list[str]:
        tags = TranscriptOrganizer._normalize_list(value)
        normalized: list[str] = []
        for tag in tags:
            normalized.append(tag if tag.startswith("#") else f"#{tag}")
        return normalized

    @staticmethod
    def _format_time(occurred_at: datetime | None) -> str:
        return occurred_at.isoformat() if occurred_at else datetime.utcnow().isoformat()

    @staticmethod
    def _to_markdown(result: OrganizeTextResponse) -> str:
        key_points = "\n".join(f"- {item}" for item in result.key_points) or "- （暂无）"
        action_items = "\n".join(f"- {item}" for item in result.action_items) or "- （暂无）"
        tags = " ".join(result.tags) if result.tags else "#未分类"
        return (
            f"【时间】\n{result.time}\n\n"
            f"【场景】\n{result.scene}\n\n"
            f"【摘要】\n{result.summary}\n\n"
            f"【关键点】\n{key_points}\n\n"
            f"【可执行事项】\n{action_items}\n\n"
            f"【标签】\n{tags}\n\n"
            f"【语音文本】\n{result.transcript}"
        )
