# voice2text

一个基于 FastAPI + 阿里云百炼（DashScope）语音转写 API 的批量音频转录服务（当前版本不包含说话人分离）。

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

创建 `.env`（会自动加载）或在 shell 中设置：

```bash
export DASHSCOPE_API_KEY="你的阿里云百炼 API Key"
export DASHSCOPE_ASR_MODEL="fun-asr"  # 可选，不填默认 fun-asr
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

- 当前默认通过 OpenAI 兼容模式调用阿里云百炼语音模型，模型名默认 `fun-asr`，也可通过 `DASHSCOPE_ASR_MODEL` 覆盖。
- 默认 Base URL 为 `https://dashscope.aliyuncs.com/compatible-mode/v1`，如需国际站可按阿里云文档替换。
- 个人使用场景可先采用该版本，后续可扩展：SRT 导出、批量 zip 下载、失败重试、任务持久化数据库等。
