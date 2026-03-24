# voice2text

一个基于 FastAPI + OpenAI Whisper API 的批量音频转录服务（当前版本不包含说话人分离）。

## 功能

- 批量上传多个音频文件并转录
- 任务级状态查询（batch/job）
- 转录文本查询与下载
- 本地落盘保存上传文件和输出文本

## 目录

```text
app/
  main.py
  models/
  services/
data/
  uploads/
  outputs/
requirements.txt
```

## 环境变量

创建 `.env` 或在 shell 中设置：

```bash
export OPENAI_API_KEY="你的key"
```

## 启动

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

## API

### 1) 批量上传并创建任务

`POST /batches`

表单字段：`files`（可多文件）

```bash
curl -X POST "http://127.0.0.1:8000/batches" \
  -F "files=@/path/to/a.mp3" \
  -F "files=@/path/to/b.m4a"
```

### 2) 查询 batch 状态

`GET /batches/{batch_id}`

### 3) 查询单文件结果

`GET /jobs/{job_id}`

### 4) 下载单文件 txt

`GET /jobs/{job_id}/download`

## 说明

- 当前转录模型默认 `whisper-1`。
- 个人使用场景可先采用该版本，后续可扩展：SRT 导出、批量 zip 下载、失败重试、任务持久化数据库等。
