# Voice2TextMobile

这是 voice2text 的独立 iPhone App 版本。它不依赖 Mac 端 FastAPI 服务：音频文件会从 iPhone 直接上传到阿里云 OSS，再把 OSS 签名 URL 提交给 DashScope ASR，转写完成后可选调用 Qwen 整理文本，并把 Markdown 结果保存在手机本地。

## 能力

- 从 iPhone「文件」App / iCloud Drive 选择一个或多个音频文件。
- 从 iOS 分享菜单接收音频文件，例如从「语音备忘录」分享 `.m4a` 到 voice2text。
- 使用 OSS 签名 URL 上传音频，不需要把 Bucket 设为公网读。
- 调用 DashScope ASR 异步转写接口并轮询任务状态。
- 下载 DashScope 返回的转写 JSON 并合并文本。
- 可选调用 Qwen 生成摘要、关键点、待办和标签，支持逐个音频整理或多个音频合并整理。
- 在 iPhone 本地保存 Markdown，并通过系统分享面板导出。
- 在「文件」App 的「我的 iPhone > voice2text > Voice2Text Results」里查看 Markdown 结果。
- DashScope Key、OSS AccessKey、STS Token 保存在 iOS Keychain。

## 目录

```text
mobile/ios/Voice2TextMobile/
├── README.md
├── Voice2TextMobile.xcodeproj
└── Voice2TextMobile/
    ├── ContentView.swift
    ├── TranscriptionViewModel.swift
    ├── OSSClient.swift
    ├── DashScopeClient.swift
    ├── ConfigStore.swift
    ├── KeychainStore.swift
    └── Models.swift
```

## 安装到 iPhone

1. 用 Xcode 打开：

   ```bash
   open mobile/ios/Voice2TextMobile/Voice2TextMobile.xcodeproj
   ```

2. 在 Xcode 里选择 `Voice2TextMobile` Target，进入 `Signing & Capabilities`。
3. 选择你的 Apple Developer Team，并把 Bundle Identifier 改成你自己的唯一值，例如：

   ```text
   com.yourname.voice2textmobile
   ```

4. 连接 iPhone，选择真机作为运行目标。
5. 点击 Run。首次安装时，iPhone 可能需要在「设置 > 通用 > VPN 与设备管理」里信任开发者证书。

## App 内设置

首次打开 App 后，点右上角「设置」，填写：

- `DashScope API Key`
- `DashScope Base URL`：默认 `https://dashscope.aliyuncs.com/api/v1`
- `ASR 模型`：默认 `fun-asr`
- `整理模型`：默认 `qwen-plus`
- `OSS Endpoint`：例如 `https://oss-cn-beijing.aliyuncs.com`
- `OSS Bucket`
- `OSS AccessKey ID`
- `OSS AccessKey Secret`
- `STS Security Token`：可选
- `对象前缀`：默认 `voice2text/mobile`

建议使用权限收窄的 RAM 用户或 STS 临时凭证。最小权限应限制在目标 Bucket 的指定前缀，并只开放上传、读取签名对象和删除临时对象所需的动作。直接从手机访问云服务时，密钥不进入 Mac 端程序，但仍属于移动端凭证，丢机或越狱设备都需要按凭证泄露风险处理。

## 整理方式

主页面提供「合并整理」开关：

- 关闭：每个音频分别生成概要 Markdown。
- 打开：多个音频先分别转录，全部完成后再合并生成一份概要 Markdown。

## 从语音备忘录导入

安装 App 后，可以直接从 iPhone「语音备忘录」导入：

1. 打开「语音备忘录」。
2. 点开录音，选择「分享」。
3. 在分享菜单里选择 voice2text。如果第一屏没有出现，点「更多」查找。
4. voice2text 会自动打开，并把该音频加入任务列表。

Apple Watch 录音会先同步到 iPhone「语音备忘录」，同步完成后也按同样方式分享给 voice2text。

## 查找转写结果

转写完成后，每条任务会出现「分享 Markdown」按钮，可以直接用系统分享面板发到微信、邮件、备忘录、iCloud Drive 等位置。

如果打开「合并整理」，每个音频会先保存一份原始转录 Markdown；全部转录完成后，首页会出现「查看合并 Markdown」和「分享合并 Markdown」按钮，并保存一份 `合并整理.md`。

结果文件也会保存在 App 的 Documents 目录。重新安装这个版本后，可以在 iPhone 打开「文件」App：

```text
浏览 -> 我的 iPhone -> voice2text -> Voice2Text Results
```

如果你刚从旧版本升级，旧版本已经保存过的文件可能需要重新运行一次转写，或者先用 App 内的「分享 Markdown」导出。

## 云端流程

```text
iPhone 选择音频
  -> App 使用 OSS AccessKey 生成 PUT 签名 URL
  -> 上传音频到 OSS
  -> App 生成 GET 签名 URL
  -> 提交 DashScope ASR 异步任务
  -> 轮询 /tasks/{task_id}
  -> 下载 transcription_url JSON
  -> 可选逐个调用 Qwen 整理，或等待全部转录完成后合并调用 Qwen 整理
  -> 保存 Markdown 到 iPhone
```

## 注意

- 这个工程是独立移动端工程，不复用、不修改 Mac 端 FastAPI 路由或 README。
- 当前版本为纯客户端直连云服务。更安全的生产方案是用后端下发短期 STS 凭证，而不是在 App 内长期保存 AccessKey Secret。
- 如果 OSS Bucket 在中国内地地域，iPhone 当前网络需要能访问相应地域的 OSS 和 DashScope endpoint。
- 大文件上传目前走单文件 PUT，适合常见录音文件；超大音频后续可以加 OSS multipart upload。

## 参考

- DashScope ASR 使用 `/services/audio/asr/transcription` 和 `/tasks/{task_id}` 的异步任务流程。
- OSS 使用兼容 V1 的签名 URL：PUT 用于上传，GET 用于给 ASR 拉取音频，DELETE 用于清理临时对象。
