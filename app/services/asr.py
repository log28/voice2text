"""ASR service wrapper using DashScope native transcription API."""

from __future__ import annotations

import os
import json
import time
import importlib.util
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

import oss2
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

        self.api_key = api_key
        self.base_url = (base_url or os.getenv("DASHSCOPE_BASE_URL", "https://dashscope.aliyuncs.com/api/v1")).rstrip("/")
        # 默认模型使用 fun-asr，可通过环境变量覆盖。
        self.model = model or os.getenv("DASHSCOPE_ASR_MODEL", "fun-asr")
        # 优先方案：上传到阿里云 OSS，再给 ASR 传签名 URL。
        self.oss_endpoint = os.getenv("OSS_ENDPOINT", "").strip()
        self.oss_bucket_name = os.getenv("OSS_BUCKET", "").strip()
        self.oss_access_key_id = os.getenv("OSS_ACCESS_KEY_ID", "").strip()
        self.oss_access_key_secret = os.getenv("OSS_ACCESS_KEY_SECRET", "").strip()
        self.oss_prefix = os.getenv("OSS_PREFIX", "voice2text/uploads").strip().strip("/")
        self.oss_signed_url_expire_seconds = int(os.getenv("OSS_SIGNED_URL_EXPIRE_SECONDS", "3600"))
        self._oss_bucket = None
        # 如果配置了对外可访问的上传目录 URL，则优先提交公网 URL（推荐）。
        self.public_file_base_url = os.getenv("PUBLIC_FILE_BASE_URL", "").rstrip("/")
        default_upload_root = Path(__file__).resolve().parents[2] / "data" / "uploads"
        self.upload_root = Path(os.getenv("UPLOAD_ROOT_DIR", str(default_upload_root))).resolve()
        # 轮询参数可按需通过环境变量调整。
        self.poll_interval_seconds = float(os.getenv("DASHSCOPE_TASK_POLL_INTERVAL_SECONDS", "2"))
        self.poll_timeout_seconds = float(os.getenv("DASHSCOPE_TASK_POLL_TIMEOUT_SECONDS", "120"))

    def transcribe(self, file_path: Path) -> str:
        """将单个本地音频文件转录为文本。"""
        source_url = self._build_input_url(file_path)
        task_id = self._submit_task(source_url)
        result_payload = self._wait_task(task_id)
        return self._extract_text(result_payload)

    def _build_input_url(self, file_path: Path) -> str:
        resolved = file_path.resolve()
        if self._oss_enabled():
            return self._upload_to_oss_and_sign_url(resolved)
        if self.public_file_base_url:
            try:
                relative = resolved.relative_to(self.upload_root)
            except ValueError:
                # 仅当文件在上传目录下时才拼接公网 URL，否则回退 file://。
                return resolved.as_uri()
            relative_url = quote(relative.as_posix(), safe="/")
            return f"{self.public_file_base_url}/{relative_url}"
        # 未配置公网地址时只能用本地 file://（很多云端 ASR 服务不可访问，建议配置 PUBLIC_FILE_BASE_URL）。
        return resolved.as_uri()

    def _oss_enabled(self) -> bool:
        return all(
            [
                self.oss_endpoint,
                self.oss_bucket_name,
                self.oss_access_key_id,
                self.oss_access_key_secret,
            ]
        )

    def _get_oss_bucket(self):
        if self._oss_bucket is not None:
            return self._oss_bucket
        if importlib.util.find_spec("oss2") is None:
            raise RuntimeError(
                "OSS is configured but dependency 'oss2' is not installed. "
                "Please run: pip install -r requirements.txt"
            )
        import oss2
        auth = oss2.Auth(self.oss_access_key_id, self.oss_access_key_secret)
        self._oss_bucket = oss2.Bucket(auth, self.oss_endpoint, self.oss_bucket_name)
        return self._oss_bucket

    def _upload_to_oss_and_sign_url(self, file_path: Path) -> str:
        bucket = self._get_oss_bucket()
        object_key = self._build_oss_object_key(file_path)
        with file_path.open("rb") as fp:
            bucket.put_object(object_key, fp)
        # 通过签名 URL 给 DashScope 拉取，避免把 bucket 设成公网读。
        return bucket.sign_url("GET", object_key, self.oss_signed_url_expire_seconds)

    def _build_oss_object_key(self, file_path: Path) -> str:
        try:
            relative_path = file_path.relative_to(self.upload_root).as_posix()
        except ValueError:
            relative_path = file_path.name
        encoded_path = "/".join(quote(part, safe=".-_") for part in relative_path.split("/"))
        if self.oss_prefix:
            return f"{self.oss_prefix}/{encoded_path}"
        return encoded_path

    def _submit_task(self, local_uri: str) -> str:
        # DashScope ASR transcription endpoint expects file URLs in `input.file_urls`.
        payload = {"model": self.model, "input": {"file_urls": [local_uri]}}
        response = self._request_json(
            "POST",
            f"{self.base_url}/services/audio/asr/transcription",
            payload=payload,
        )
        output = response.get("output") if isinstance(response, dict) else None
        task_id = output.get("task_id") if isinstance(output, dict) else None
        if not task_id:
            raise RuntimeError(f"ASR submit missing task_id. response='{response}'")
        return str(task_id)

    def _wait_task(self, task_id: str) -> dict:
        start = time.monotonic()
        terminal_succeeded = "SUCCEEDED"
        terminal_failed = {"FAILED", "CANCELED"}
        polling_statuses = {"RUNNING", "QUEUED", "PENDING"}
        last_response: dict | None = None

        while True:
            response = self._request_json("GET", f"{self.base_url}/tasks/{task_id}")
            last_response = response
            output = response.get("output") if isinstance(response, dict) else None
            status = output.get("task_status") if isinstance(output, dict) else None
            status_text = str(status or "").upper()

            if status_text == terminal_succeeded:
                return response
            if status_text in terminal_failed:
                raise RuntimeError(
                    "ASR task failed. "
                    f"task_id='{task_id}', status='{status_text}', response='{response}'. "
                    "Hint: prefer OSS signed URL (OSS_* env) or PUBLIC_FILE_BASE_URL instead of local file://."
                )

            elapsed = time.monotonic() - start
            if elapsed >= self.poll_timeout_seconds:
                raise RuntimeError(
                    "ASR task timeout. "
                    f"task_id='{task_id}', elapsed_seconds={elapsed:.1f}, "
                    f"last_status='{status_text}', response='{last_response}'. "
                    "Hint: if you submitted a local `file://` path, make sure your DashScope account/endpoint "
                    "supports that input mode; otherwise prefer OSS signed URL or a publicly accessible HTTP URL."
                )

            # 未知状态也继续轮询，避免临时状态变化导致误判失败。
            if status_text in polling_statuses or status_text:
                time.sleep(self.poll_interval_seconds)
                continue

            raise RuntimeError(f"ASR task status missing. task_id='{task_id}', response='{response}'")

    def _request_json(self, method: str, url: str, payload: dict | None = None) -> dict:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = Request(url, data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.api_key}")
        request.add_header("Content-Type", "application/json")
        # 百炼 ASR 推荐使用异步任务模式；部分账号不支持同步调用（会返回 AccessDenied）。
        # 该请求头会强制服务端走异步任务，随后通过 /tasks/{task_id} 轮询结果。
        if method.upper() == "POST" and "/services/audio/asr/transcription" in url:
            request.add_header("X-DashScope-Async", "enable")
        try:
            with urlopen(request, timeout=120) as response:  # noqa: S310
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"DashScope request failed: method='{method}', url='{url}', status={exc.code}, detail='{detail}'"
            ) from exc
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(f"DashScope request failed: method='{method}', url='{url}', detail='{exc}'") from exc

    @staticmethod
    def _extract_text(transcription_response: dict) -> str:
        output = transcription_response.get("output")
        results = []
        if isinstance(output, dict):
            results = output.get("results") or []

        texts: list[str] = []
        for item in results:
            transcription_url = None
            if isinstance(item, dict):
                transcription_url = item.get("transcription_url")
            if not transcription_url:
                continue
            with urlopen(transcription_url) as response:  # noqa: S310
                payload = json.loads(response.read().decode("utf-8"))
            sentence_list = payload.get("transcripts", [])
            for sentence in sentence_list:
                text = sentence.get("text")
                if text:
                    texts.append(str(text))

        if not texts:
            raise RuntimeError(f"ASR completed but empty transcript: {transcription_response}")
        return "\n".join(texts)
