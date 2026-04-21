# voice2text

一个基于 FastAPI + 阿里云百炼（DashScope）ASR 的批量音频转录服务（当前版本不含说话人分离）。

> 元数据存储支持 `memory`（默认）和 `sqlite` 两种后端；生产建议使用 `sqlite` 或自行扩展到外部数据库。

## 功能

- 批量上传多个音频并转录
- 查询 batch/job 状态
- 查询与下载转录文本（单文件 / 成功结果 ZIP）
- 下载的 txt 会在头部附带“整理提炼”（摘要/关键点/TODO/标签），正文保留原始转录文本
- 本地保存上传文件与输出文本

## 目录

```text
app/
data/
  uploads/
  outputs/
requirements.txt
```

## 环境变量

可先复制模板：`cp .env.example .env`，再按需修改（启动时自动加载）；或直接在 shell 中设置：

```bash
export DASHSCOPE_API_KEY="<你的 API Key>"
export DASHSCOPE_ASR_MODEL="fun-asr"                              # 可选
export DASHSCOPE_BASE_URL="https://dashscope.aliyuncs.com/api/v1" # 可选
export DASHSCOPE_TASK_POLL_INTERVAL_SECONDS="2"                   # 可选
export DASHSCOPE_TASK_POLL_TIMEOUT_SECONDS="120"                  # 可选

# 推荐：配置 OSS，让 ASR 拉取临时签名 URL
export OSS_ENDPOINT="https://oss-cn-hangzhou.aliyuncs.com"
export OSS_BUCKET="<bucket>"
export OSS_ACCESS_KEY_ID="<ak>"
export OSS_ACCESS_KEY_SECRET="<sk>"
export OSS_PREFIX="voice2text/uploads"                            # 可选
export OSS_SIGNED_URL_EXPIRE_SECONDS="3600"                       # 可选
export OSS_DELETE_TEMP_AFTER_ASR="true"                           # 可选

# 备选：提供公网可访问的上传目录地址
export PUBLIC_FILE_BASE_URL="https://<你的域名>/public/uploads"


# 存储后端（batch/job 元数据）
export STORE_BACKEND="memory"                                  # 可选：memory / sqlite
export STORE_SQLITE_DB_PATH="/abs/path/to/data/metadata.db"    # STORE_BACKEND=sqlite 时生效

# 本地目录（可选）
export UPLOAD_ROOT_DIR="/abs/path/to/data/uploads"
export OUTPUT_ROOT_DIR="/abs/path/to/data/outputs"
```

## 启动

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

访问：`http://127.0.0.1:8000/`

## API

- `POST /batches`：批量上传并创建任务（表单字段 `files`）
- `GET /batches/{batch_id}`：查询 batch 状态
- `GET /jobs/{job_id}`：查询单文件结果
- `POST /organize`：对转写文本做结构化梳理（摘要/关键点/TODO/标签）
- `GET /jobs/{job_id}/download`：下载单文件 txt
- `GET /batches/{batch_id}/download-succeeded-zip`：下载成功结果 ZIP

示例：

```bash
curl -X POST "http://127.0.0.1:8000/batches" \
  -F "files=@/path/to/a.mp3" \
  -F "files=@/path/to/b.m4a"

curl -X POST "http://127.0.0.1:8000/organize" \
  -H "Content-Type: application/json" \
  -d '{
    "transcript": "今天我们讨论车载域控制器，先验证成本，再排期两周内做PoC",
    "occurred_at": "2026-04-11T09:30:00Z"
  }'
```

## 常见问题（精简）

- 当前内置 `memory` 与 `sqlite` 两种元数据存储。`memory` 重启会丢数据，仅适合本地 demo。
- 若要具备基础可恢复能力，请设置 `STORE_BACKEND=sqlite`，并持久化 `STORE_SQLITE_DB_PATH` 指向的文件。
- 输出目录是 `data/outputs/`（不是 `output/`）。
- `POST /batches` 返回后任务通常仍在排队；需轮询 `GET /batches/{batch_id}`，待 `succeeded` 后再下载。
- 上传原始音频会保留在 `data/uploads/<batch_id>/`（或 `UPLOAD_ROOT_DIR` 指定目录）下，便于回溯。
- 若出现 `ASR input URL is local file://`，请配置 `OSS_*`（推荐）或 `PUBLIC_FILE_BASE_URL`。
- 若报 `404`（模型不可用）或地域相关错误，请核对 `DASHSCOPE_ASR_MODEL`、`DASHSCOPE_BASE_URL`、`DASHSCOPE_API_KEY` 是否匹配。
- 若任务长时间 `running`，可先将 `DASHSCOPE_TASK_POLL_TIMEOUT_SECONDS` 调小，快速定位错误原因。

## 上线前安全与隐私检查清单（建议逐项确认）

- **密钥管理**
  - 确认生产环境仅通过环境变量注入 `DASHSCOPE_API_KEY`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`。
  - 确认 `.env` 不会被提交（当前 `.gitignore` 已忽略 `.env`）。
- **数据最小暴露**
  - 接口响应不应返回服务端本地绝对路径（例如 `/data/uploads/...`），避免泄露服务器目录结构。
  - 如需开放下载接口，建议增加鉴权（API Key / JWT / Session）和权限校验。
- **上传文件风险控制**
  - 上传文件名需做路径净化（仅保留 basename），防止路径穿越。
  - 建议限制单文件大小、总批次大小与可接受 MIME 类型，防止滥用。
- **日志与错误信息**
  - 生产环境避免将完整第三方响应原文直接回传给前端，防止敏感字段外泄。
  - 记录日志时避免打印原始转写全文（可能包含个人敏感信息）。
- **存储与生命周期**
  - `data/uploads/` 与 `data/outputs/` 保存的是原始音频/转写文本，属于敏感数据，建议设置自动清理策略（例如 7/30 天）。
  - 如使用 OSS 临时对象，建议保持 `OSS_DELETE_TEMP_AFTER_ASR=true`。
- **公开部署注意事项**
  - 当前示例服务默认无鉴权，**不建议直接暴露到公网**；至少应加网关鉴权与限流。
  - 建议启用 HTTPS，防止传输过程泄露音频与文本内容。
