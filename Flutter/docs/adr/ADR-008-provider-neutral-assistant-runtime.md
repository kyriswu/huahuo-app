# ADR-008：Provider-neutral Assistant Runtime

- 状态：Proposed
- 日期：2026-10-02
- 适用范围：Flutter 移动端、桌面端、共享 Dart 包，以及项目后端的接口边界

## 背景

客户端当前通过项目自己的 `/api/v1/chat/*` 和 `/api/v1/agent/*` 接口工作。
源码没有发现 Flutter 直接调用 OpenClaw、Coze 或 Dify 的证据。当前的
`Page → Controller → Repository → API Client` 方向是正确的，但聊天领域契约
仍暴露 `agentProfileId`、`agentRunId`、`AgentRunSnapshot`、SSE 事件和当前
后端的幂等结果类型。若继续把这些类型提升为业务层长期接口，之后切换上游
工作流会迫使页面、Controller 和测试一起改动。

## 决策

保留项目自己的聊天 API 作为 Flutter 的稳定边界，并在客户端增加一个只表达
产品语义的助手运行端口。上游 Provider 的选择和映射放在项目后端，不进入
Flutter 页面、Controller、Repository 或共享业务模型。

目标依赖关系：

```text
Page
  ↓
ChatController
  ↓
AssistantConversationRepository
  ↓
Provider-neutral Assistant Runtime Port
  ↓
Project Chat API Client
  ↓
项目后端 Provider Adapter
  ├── OpenClaw
  ├── Coze Workflow
  └── Dify Workflow
```

客户端长期使用的概念限定为：

- `Conversation`、`ConversationTurn`
- `TurnHandle` 或 `AssistantRunHandle`
- `AssistantRunStatus`
- `AssistantStreamEvent`
- `AssistantOutput`
- `AssistantFailure`
- `AssistantCapability`

`agentProfileId`、`agentRunId`、`workflowRunId`、厂商 SSE 字段、输入 JSON
和厂商 SDK 类型只能存在于对应的协议适配器或映射代码中。若产品确实需要
选择一种业务能力，使用稳定的产品能力标识，由后端将它映射到具体 Provider
配置；客户端不传厂商 Bot ID、Workflow ID 或 Agent ID。

## 不变的职责

- `ProjectChatClient` 只负责项目后端的 HTTP、SSE、轮询、认证、超时、取消
  和线协议解析。
- `RemoteProjectChatRepository` 将项目后端 DTO 映射为中立业务
  模型，并组合缓存、重试和结果回读。
- `ChatController` 只编排页面状态、取消、恢复和用户输入，不解析厂商字段。
- 图片下载器、录音上传和签名资源访问是独立媒体适配器，不被塞入助手运行
  接口；它们只接收资源句柄或媒体能力。

## 迁移规则

1. 先定义中立领域契约和 fake provider contract tests。
2. 将现有聊天远程实现命名为 `RemoteProjectChatRepository`，迁移消费者后
   删除 `ChatApi` 兼容入口。
3. 将 `AgentRunSnapshot`、当前 SSE payload 和 `ApiResult` 留在 data/协议层，
   由 Repository 做映射；不在本批次改变服务端字段、认证或同步行为。
4. 迁移 tracker、poller 和 onboarding 的运行状态，使它们消费中立事件。
5. 只有在中立契约覆盖流式增量、轮询回退、取消、幂等、未知结果、最终结果
   回读、需要用户输入和 Provider 错误映射后，才删除兼容类型。

## 结果

切换 OpenClaw、Coze 或 Dify 时，主要变化位于项目后端 Provider Adapter；
Flutter 的页面、Controller 和多数 Repository 不需要重写。代价是需要明确
中立事件语义，并为不同 Provider 无法支持的能力返回显式 capability 或
`unsupported`，不能用隐式字段兼容。

这份 ADR 不证明任何 Provider 已经接通，也不授权修改服务器或现有协议。
