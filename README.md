# voice2text

一个基于 FastAPI + 阿里云百炼（DashScope）ASR 的批量音频转录服务（当前版本不含说话人分离）。

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

创建 `.env`（启动时自动加载）或在 shell 中设置：

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

- 输出目录是 `data/outputs/`（不是 `output/`）。
- `POST /batches` 返回后任务通常仍在排队；需轮询 `GET /batches/{batch_id}`，待 `succeeded` 后再下载。
- 若出现 `ASR input URL is local file://`，请配置 `OSS_*`（推荐）或 `PUBLIC_FILE_BASE_URL`。
- 若报 `404`（模型不可用）或地域相关错误，请核对 `DASHSCOPE_ASR_MODEL`、`DASHSCOPE_BASE_URL`、`DASHSCOPE_API_KEY` 是否匹配。
- 若任务长时间 `running`，可先将 `DASHSCOPE_TASK_POLL_TIMEOUT_SECONDS` 调小，快速定位错误原因。
