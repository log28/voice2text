"""应用配置与路径管理。"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

# 启动时自动加载项目根目录 .env，便于本地开发。
load_dotenv()

# 固定数据目录到项目根路径，避免因启动目录不同导致文件写到意外位置。
PROJECT_ROOT = Path(__file__).resolve().parents[2]
DATA_ROOT = PROJECT_ROOT / "data"
UPLOAD_ROOT = Path(os.getenv("UPLOAD_ROOT_DIR", str(DATA_ROOT / "uploads"))).resolve()
OUTPUT_ROOT = Path(os.getenv("OUTPUT_ROOT_DIR", str(DATA_ROOT / "outputs"))).resolve()
STORE_BACKEND = os.getenv("STORE_BACKEND", "memory").lower()
SQLITE_DB_PATH = os.getenv("STORE_SQLITE_DB_PATH", str(DATA_ROOT / "metadata" / "voice2text.db"))

UPLOAD_ROOT.mkdir(parents=True, exist_ok=True)
OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
