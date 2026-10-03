# 录音上传与语音转写修复及测试报告

日期：2026-08-01

## 最终结论

原始真机错误发生在第一步 `POST /api/v1/media/upload-token`，101 返回
`401 UNAUTHORIZED`。根因不是音频、对象存储或腾讯 ASR，而是 App 使用 39 主站
Token 调用独立认证域的 101 服务。

本轮已完成服务端和客户端修复：

- 101 不再复制或持有 39 的 HS256 签名密钥。
- 仅 Media、Recording、ASR、录音卡、实时 ASR、声纹路由允许使用主站身份校验。
- 101 收到无法本地验证的 Token 后，通过
  `https://chuda.cc/api/v1/me/status` 校验原 Token；返回的 `userId`、
  `tenantId` 必须与 Token 的 `sub`、`tid` 一致，Workspace 必须为 `ready`。
- 校验成功后，101 只镜像不透明的用户/租户/Workspace ID，以满足录音表外键；
  Home、Chat、热点、Agent、Work AI、Feed AI 等普通路由仍拒绝该 Token。
- `recording.chuda.cc` 在 39 上终止 TLS，再通过同 VPC 内网
  `172.18.102.94:18080` 转发到 101。Flutter 不再访问明文 IP。
- 101 公网 80 已关闭；仅保留内网 API 监听。Work AI/Feed AI 未接入、未调用。

## 原始错误证据

真机 App Data Container 中的新上传草稿在 17:20 至 17:42 共五次停在
`requestingToken/tokenFailed`，错误均为 `UNAUTHORIZED`，没有生成 uploadId、
resourceId、recordingId 或 asrTaskId。101 `request_logs` 中存在时间对应的五条
`POST /api/v1/media/upload-token` 401，且请求带 Authorization 和幂等键。

`origin/Flutter-ASR` 的 Auth、上传和 ASR 原本都指向 101；合并后 Auth 留在 39，
只迁移了录音地址，导致跨部署 Token 无法验证。

## 修复架构

```text
iPhone
  -> HTTPS recording.chuda.cc (39 Nginx, Let's Encrypt)
  -> VPC HTTP 172.18.102.94:18080 (101 API)
  -> 本地 Token 验证失败时，仅录音路由调用 HTTPS chuda.cc/me/status
  -> 校验 sub/tid/ready Workspace
  -> 101 本地录音身份镜像、上传、Recording、ASR Worker
  -> Tencent recording-file ASR
```

安全边界：

- 不共享主站签名密钥，不接受任意 Bearer，不读取客户端身份 Header。
- 上游校验 URL 必须为 HTTPS、固定 `/api/v1/me/status`，禁止 user-info、query、
  fragment 和重定向。
- 上游 401、超时、非 200、损坏响应、身份不一致、过期 Token、非 ready
  Workspace 均在业务 Handler 前失败。
- 录音写请求仍按认证用户隔离幂等键，不会落入 anonymous 作用域。
- Flutter iOS 已删除 `NSAllowsArbitraryLoads`；Android Main/Debug 均删除
  `101.201.70.18` 明文例外。

## 真实服务端全链路测试

测试音频：本机合成中文 WAV，16 kHz、单声道、约 11.99 秒、387,738 字节。

| 顺序 | 接口/步骤 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | `POST /api/v1/auth/login`（101 隔离测试身份） | PASS | HTTPS 登录成功；Token 未输出 |
| 2 | `POST /api/v1/media/upload-token` | PASS | HTTP 200，返回 HTTPS 上传 URL |
| 3 | `PUT /internal/object-upload` | PASS | HTTP 200，写入 387,738 字节 |
| 4 | `POST /api/v1/media/uploads/{uploadId}/complete` | PASS | HTTP 200，ResourceIndex 完成 |
| 5 | `POST /api/v1/recordings` | PASS | HTTP 200，生成 Recording 和 ASR Task |
| 6 | `GET /api/v1/asr-tasks/{asrTaskId}` | PASS | `queued -> transcribing -> transcribed` |
| 7 | `GET /api/v1/recordings/{recordingId}` | PASS | HTTP 200，返回 speaker segment |
| 8 | 数据库事实 | PASS | Recording=`transcribed`，ASR=`transcribed`，attempt=1，provider=`tencent_file_asr` |

识别结果：

> 这是花火人工智能录音转写测试，今天是8月1日，我们正在验证录音上传、文件识别和文字转写的完整流程。

与合成语音原文语义和内容一致。当前返回 speaker segment；`finalTranscript` 在
用户完成说话人确认前保持空值，属于现有说话人标注流程，不是识别失败。

101 `request_logs` 对本次流程记录为：upload-token 200（28 ms）、complete 200
（41 ms）、recording create 200（17 ms）、ASR poll 4 次均 200、recording detail
200（5 ms）。另有一个故意发送的无效 Token 请求返回 401，证明 HTTPS 网关未绕过
认证。

## 自动化验证

Backend：

- 新增上游认证、路由隔离、损坏响应、身份不一致、过期、HTTP 配置、重定向、
  幂等用户作用域测试：PASS。
- 录音/上传相关 Integration 回归：PASS。
- `go test -race` 定向检查：PASS。
- Linux/amd64 静态 API 构建：PASS；已部署到 101。

Flutter：

- Provider、实时 ASR、Recording Upload/Recording API 定向测试：37 项 PASS。
- 修改文件 `flutter analyze`：0 issue。
- `dart run tool/scm_check.dart`：622 个有效映射 PASS。
- plist/XML 语法检查：PASS。

## 未完成与已知问题

### 1. 主站真实 Token 的最终真机复测暂未完成

真机为 `run的iPhone`（iPhone 11，iOS 26.5.2）。Xcode 在签名
`ScreenCaptureExtension.debug.dylib` 时返回 `errSecInternalComponent`。三个开发
证书的独立 `codesign` 探测均同样失败，登录钥匙串报告
`User interaction is not allowed`，根因是本机登录钥匙串/私钥访问未解锁，而不是
Flutter、链接符号或 API 代码。

需要在 Mac 的 Keychain Access 解锁“登录”钥匙串并允许 Xcode/codesign 访问开发
私钥，然后重新执行真机安装。当前主站 Token 联邦路径已有自动化外部签名 Token
测试，但在该钥匙串解锁前不能把“主站真实 Token + 真机失败草稿自动恢复”标记为
PASS。

### 2. 101 `/readyz` 仍为 503 degraded

数据库和迁移检查正常，实际 Tencent 文件 ASR 已成功。degraded 来自该测试部署仍按
完整 Backend 目录检查 SMS、Storage、Model、Hotspot 等非录音 Provider，显示
`missing_active_provider_credentials`。这是服务端部署/readiness 范围问题，本轮未用
Mock 掩盖，也未为通过测试而修改成健康。

### 3. Backend 脏分支既有失败

- `TestAuthRequiredRejectsArbitraryBearerAndSpoofedIdentity` 独立失败：
  `WORKSPACE_NOT_READY`。
- Material route 三项测试独立失败：`MATERIAL_PATH_INVALID`。

这些失败在普通 Auth/Material 基线中，与本次录音认证模式无关；本报告保留为后端
待办，不将其计入录音链路 PASS。

## 运维状态

- `recording.chuda.cc` TLS 证书有效至 2026-10-30，Certbot 已配置自动续期。
- 39 Nginx 负责公网 HTTPS；101 API 仅监听 VPC 地址
  `172.18.102.94:18080`。
- 101 `huahuo-asr-api.service`、`huahuo-asr-worker.service` 均为 active。
- 101 原 API 配置和二进制已有时间戳备份，可回滚。
- 对话、热点和其他主站 API 继续使用 `https://chuda.cc`，未被转发到 101。
