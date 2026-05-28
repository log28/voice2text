# 🎙️ Voice2Text

一个基于 **FastAPI + DashScope ASR** 的批量语音转文本服务，支持多文件上传、异步处理、文本整理与结果下载，适合个人效率工具和轻量服务原型。

---

## ✨ Features

* 🎧 **多音频批量转写**（支持并发处理）
* ⚡ **异步任务机制**（避免阻塞）
* 🧠 **自动文本整理**（支持单文件分别整理 / 多文件合并整理）
* 📦 **结果打包下载**（TXT / ZIP）
* 🌐 **简单 Web UI**（可直接体验）
* ☁️ **支持 OSS 存储**（适配云场景）

---

## 🚀 Demo（核心流程）

```text
Upload Audio → Batch Processing → ASR → Text Organize → Download Results
```

Web 页面上传时可以选择两种整理方式：

* **每个音频分别概要整理**：每个音频生成一个独立 Markdown。
* **多个音频合并概要整理**：每个音频先生成原始转录 Markdown，全部转录后额外生成 `combined-summary.md`。

---

## 🧩 Architecture

```text
                ┌──────────────┐
                │   Web UI     │
                └──────┬───────┘
                       │
                ┌──────▼───────┐
                │  FastAPI API │
                └──────┬───────┘
                       │
        ┌──────────────┼──────────────┐
        │                              │
┌───────▼────────┐           ┌────────▼────────┐
│ BatchProcessor │           │   InMemoryStore │
└───────┬────────┘           └────────┬────────┘
        │                              │
┌───────▼────────┐           ┌────────▼────────┐
│   AsrService   │           │ TranscriptOrgan │
└────────────────┘           └─────────────────┘
```

---

## 🛠️ Quick Start（5分钟跑起来）

### 1. 克隆项目

```bash
git clone https://github.com/yourname/voice2text.git
cd voice2text
```

---

### 2. 安装依赖

```bash
pip install -r requirements.txt
```

---

### 3. 配置环境变量

复制示例文件：

```bash
cp .env.example .env
```

填写关键配置：

```bash
DASHSCOPE_API_KEY=your_api_key
```

---

### 4. 启动服务

```bash
uvicorn app.main:app --reload
```

---

### 5. 打开页面

👉 http://127.0.0.1:8000

---

## 📡 API 示例

### 创建批处理任务

```bash
curl -X POST "http://127.0.0.1:8000/batches" \
  -F "organize_mode=combined" \
  -F "files=@meeting-1.m4a" \
  -F "files=@meeting-2.m4a"
```

---

### 查询任务状态

```bash
GET /batches/{batch_id}
```

---

### 下载结果

```bash
GET /batches/{batch_id}/download-succeeded-zip
GET /batches/{batch_id}/download-combined
```

---

## ⚙️ Configuration

| Key                             | Description                                   |
| ------------------------------- | --------------------------------------------- |
| DASHSCOPE_API_KEY               | 阿里云语音识别 API Key                         |
| OSS_ENDPOINT                    | OSS 地址，例如 `https://oss-cn-beijing.aliyuncs.com` |
| OSS_BUCKET                      | OSS Bucket 名称                                |
| OSS_ACCESS_KEY_ID               | OSS AccessKey ID                              |
| OSS_ACCESS_KEY_SECRET           | OSS AccessKey Secret                          |
| OSS_UPLOAD_RETRIES              | OSS 上传失败后的最大尝试次数，默认 `3`          |
| OSS_CONNECT_TIMEOUT_SECONDS     | OSS 连接超时时间，默认 `30` 秒                 |
| OSS_MULTIPART_THRESHOLD_BYTES   | 超过该大小后使用分片上传，默认 `8388608`        |
| OSS_PART_SIZE_BYTES             | 分片大小，默认 `8388608`                       |
| OSS_UPLOAD_THREADS              | 分片上传线程数，默认 `3`                       |
| UPLOAD_ROOT_DIR                 | 本地上传目录                                   |
| OUTPUT_ROOT_DIR                 | 输出目录                                      |

---

## ⚠️ Limitations

当前版本为轻量实现：

* 使用 `InMemoryStore`（服务重启后状态丢失）
* 使用 FastAPI `BackgroundTasks`（无任务持久化 / 重试）
* 适合单机 / 小规模场景

---

## 📄 License

This project is licensed under the MIT License.
