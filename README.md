# DSH Control · iOS 客户端（M2：左侧栏同步 + 实时联动 + 真实审批）

DeepSeek Harness 的手机总控台：一台 iPhone 同时看三台电脑上各自的 agent，切换机器、看会话、发消息、处理审批与提问、看历史、切模型。

M2 目标：手机左侧栏和电脑 DSH 左侧栏**完全同步**——同样的工作区、同样的分组顺序、同样的会话与历史；电脑上新建/改名/归档，手机跟着变；审批与提问来自真实 `$events`，不再是 Mock。

## 生成与构建

```sh
cd ios
xcodegen generate
xcodebuild -scheme DSHControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath .derivedData build
```

- iOS 18+，Swift 6（`SWIFT_STRICT_CONCURRENCY = complete`），零第三方依赖。
- 单元测试：`xcodebuild … test`（需可创建 PTY 的环境；本沙箱不行，用 `build-for-testing` 验证可编译）。
- 沙箱内 `~/Library/Developer/Xcode/DerivedData` 不可写，命令统一带 `-derivedDataPath .derivedData`（已在 `.gitignore`）。

## 添加机器（零鉴权）

设置 → 添加机器（粘贴地址）：填 `https://<machine>.<tailnet>.ts.net` 或 `http://127.0.0.1:8787`，可选访问密钥留空即可。`GET /v1/hello` 成功即视为连接，随后自动拉 `workspace/follow`、`session/list`、`session/modelCatalog`，并常驻 `/v1/events`。

深链：`dshcontrol://add?host=<url>[&key=<key>]`（旧 `pair` 链接仍兼容，只取 host）。

自动化联调：`xcrun simctl launch booted dev.dsh.control --live --bridge http://127.0.0.1:8787`

## 左侧栏同步（workspace/follow）

- `BridgeClient.workspaceStream`：`WS /v1/stream` → `open endpoint=workspace/follow, args={}`（**必须是空对象**，传 `_request` 会 400）。
- 帧：`{type:"baseline", value:{items, archivedSessionIds, pinnedSessionIds}}`、`{type:"upsert", value:workspace}`、`{type:"order", value:{workspaceIds}}`；未知 type 静默。
- 分组规则（`AppModel.sidebarGroups`）：
  1. 工作区之间按 `order.workspaceIds` 排序，组标题用 `workspace.title`；
  2. 会话归属：先看 `workspace.sessionIds`，再看会话 `cwd` 是否在工作区 `path` 下（按路径段，`/code` 不吞 `/code2`）；
  3. 都不属于 → 「未归类」；
  4. `archivedSessionIds` 默认隐藏（会话列表右上角菜单可开「显示已归档」）；
  5. 同一工作区内 `pinnedSessionIds` 排最前（行内图钉），其余按 `updatedAt` 倒序。
- 机器筛选、搜索、新建会话保留。

## 实时联动（/v1/events）

- 连接后常驻事件通道；`ready` 时校准一次会话列表（不随每条事件全量刷新）。
- `emit` 的 `api-session/added|removed|status|activity` → 防抖 500ms 刷新 `session/list`；`api-session/status` 同时更新列表状态与已打开会话的顶部状态。
- `request`（`approval/request` / `user-questions/request`）→ 收件箱卡片（未读圆点）；`cancel` → 撤回并提示「已在电脑上处理」。
- `settings/document-updated`、`agent-preset/selected` 忽略。

## 真实审批 / 提问

- 审批应答：`{"op":"result","eventId":…,"outcome":{"kind":"result","value":"allowed-once"|"rejected"}}`。
- 提问应答：`value` 是答案数组 `[{"id":…,"selected":["<label>"],"custom"?:…}]`（多选支持）；跳过用 `{"kind":"next"}`。
- 卡片支持：工具名、原因、命令预览、原始 JSON 兜底、单选/多选/自定义文本、提交/跳过；从收件箱可跳到对应会话。
- 演示模式仍用 Mock 数据展示卡片样式；真机模式完全由事件驱动。

## 会话详情（执行体验对齐电脑）

- 打开会话即 `session/follow`，**`maxMessages = 60`**（大会话首屏不灌几 MB），用首帧 snapshot 整体替换窗口。
- 快照被截断时（最早 seq > 0 或 `hasMore`），消息列表顶部显示「加载更早的消息」；点击走 `session/page {request:{address,throughSeq:<当前最早 seq>,maxMessages:60}}`，返回的 records 去重后 prepend（`SessionFold.prepend` 用临时折叠器 + 重建索引，保持 seq 顺序），失败有错误提示 + 重试。
- 加载失败不再显示「还没有消息」：显示错误文案 + 「重试」按钮（重新打开 `session/follow`）。
- **导航身份稳定**：列表/总览/收件箱的 `NavigationLink` 用 `session.id`（String）驱动，`navigationDestination(for: String.self)` → `SessionDetailHost`；`api-session/*` 刷新、改名、归档都不会把详情页弹回，只有会话被删除才退回并提示。
- **流式跟随**：`SessionFold` 暴露递增 `revision`（每次 apply/chunk/本地改写 +1），详情页监听 `model.revision`；只有用户距底部 < 120pt 才自动滚到底（无动画、每次变化滚一次），往上滑后不抢滚动；不在底部时显示悬浮「回到底部 ↓」，有新内容时带小圆点。
- **折叠状态稳定**：思考过程 / 工具卡输出/diff 的展开状态存在 `SessionDetailModel.expandedItemIDs`（按条目 id），流式重绘不会重置；思考标题显示「思考过程（N 字）」并随增量增长。
- **顶部状态**：运行中显示「运行中」+ 停止按钮，走 `session/cancel {request:{sessionId}}`。
- 乐观发送：用户气泡用 `pending-<requestId>` 作 id，`session/prompt` 带同一个 `requestId`。
- WebSocket 大帧分块：桥把 >200KB 的帧拆成 `{"op":"chunk","chunkId","index","total","data"}`；`ChunkAssembler` 在 `/v1/stream`、`/v1/workspace`、`/v1/events` 三条接收循环里按 chunkId 收集、按 index 拼接、JSON 解析后走原分发逻辑，断开/重连清空缓存。
- 模型：`session/modelCatalog`（实测必须传 `{}`）→ 菜单显示 `projections.values.modelSelection`；`session/selectModel {request:{sessionId,provider,model,reasoningEffort?}}`；目录不可用时显示 `session/model-unavailable` 等错误，不静默失败。
- 发送消息带 `requestId`（幂等），mode `queue`/`steer`；标题为空时回退到 cwd 末级 / 工作区标题。

## 目录

```
Sources/
  App/          DSHControlApp、RootView（四 Tab）
  Models/       JSONValue、Machine、MachineRuntime、SessionSummary、Workspace、ModelOption、
                ConversationItem、FoldEvent、Approval、ProtocolTypes、DeepLink
  Connection/   BridgeClient（HTTP + WS：stream/workspace/events）、MachineStore + KeychainKeyStore、
                PushManager、MockData
  Store/        AppModel、SessionDetailModel、SessionFold
  UI/           Overview / SessionList / SessionDetail / Inbox / Settings / Components
Tests/          折叠去重/分块/翻页、重复消息去重、流式增量缓冲与快照一致、add 深链、多机合并、
                workspace 帧/归属、模型目录解析、revision 递增、折叠状态稳定性、usage/思考时间、附件 content
```

## 协议 v1 映射

| 协议 | 实现 | 状态 |
|---|---|---|
| `GET /v1/hello` | `BridgeClient.hello` | 已实现（添加机器校验） |
| `GET /v1/health` | `BridgeClient.health` | 已实现 |
| `POST /v1/rpc` | `BridgeClient.rpc` | `session/list`、`prompt`、`create`、`modelCatalog`、`selectModel` |
| `WS /v1/stream` + `session/follow` | `sessionStream` | 快照 + 事件 + assistant-stream |
| `WS /v1/stream` + `workspace/follow` | `workspaceStream` | baseline/upsert/order |
| `WS /v1/events` | `startEvents` / `answerEvent` / `closeEvents` | ready/emit/request/cancel → result/next |
| `POST /v1/push/register` | `registerPush` | 已实现，UI 未调用 |

## 本机联调实测（http://127.0.0.1:8787，零鉴权）

用与 App 相同的 Swift 源码（BridgeClient + SessionFold）跑的 CLI 校验：

```
1. hello: protocol=2 machine=ElonAlex auth="none"
2. workspace/follow: workspaces=2 [Documents, dsh-control] archived=0 pinned=0
3. session/list: 2 session(s)；title 为 null 时回退 cwd 末级
4. session/follow(maxMessages=200): 18 records → 2 items
   [user] 手机端联调：这是一条测试消息，请忽略
   [notice] llm-deepseek: no API key …（测试实例无模型 key，属预期）
5. modelCatalog: options=1 default=deepseek-flash
6. /v1/events: ready clientId=…
```

（runtime-context / time-context 注入消息已在折叠时过滤，不会污染对话。）

## 模型切换 / Token 用量 / 附件上传

- **模型目录**：`session/modelCatalog`（args `{}`）按真实形状解析——provider = `groups[].id`、显示名 = `groups[].name`、model = `models[].id`、label = `models[].name`、思考强度 = `models[].reasoning.efforts` + `defaultEffort`；当前选择取 `projections.values.modelSelection.next ?? lastUsed ?? catalog.default`。
- **模型选择器**：按 provider 分组的 sheet，先选模型再选思考强度（默认该模型 defaultEffort），「应用」一次性调 `session/selectModel {request:{sessionId,provider,model,reasoningEffort}}`；失败显示 `session/model-unavailable` / `gateway/arguments-invalid` 具体错误，不影响会话页。
- **紧凑模型条**：输入框上方 `[cpu] DeepSeek-V4.1-Flash · Max ▾`，切换中显示 spinner；没有可用模型显示「模型不可用」并禁用。
- **Token 用量**：会话头部显示 `↑340.2k · ↓301.9k · 缓存 139.4M`（`projections.values.tokenUsage`）；每条 assistant 消息底部显示 `data.usage`；菜单「会话统计」显示 turns/steps、模型用时、工具用时、平均 TTFT、TPS、缓存命中率。
- **思考时间**：流式期间输入区上方「深度求索中 · 12.3s」实时递增（assistant-stream start 起算）；单条消息用 reasoning 首块到正文首块的流式时间差，标题「思考过程（N 字）· 4.2s」；拿不到时间戳时只显示字数。持久事件的 `reasoning` 块已解析，重开历史不丢。
- **附件**：输入框「+」→ 相册（PhotosPicker 多选）或文件（fileImporter 任意类型）。图片读 Data → 单条 base64 内联（≤20MB/张、≤20 张）；其他文件先 `POST /v1/upload?sessionId=&name=`（原始字节 + URLSession 进度）换 receiptId，prompt 用 `{"type":"file","receiptId"}`。附件 chip 显示缩略图/文件名/上传百分比，失败可重试、可移除；上传中禁止发送；只有附件没有文字也能发；发送成功后清空。

## 体验优化（任务 9）

- **重复消息**：乐观条目 id=`pending-<requestId>`；落盘 `user/message` 先按 rpcId（有的话）原地替换，再按「id 以 pending- 开头 + trim 后同文本 + 30 秒内」兜底替换（真实事件没有 requestId），最后「连续两条同文本用户消息 <5 秒」只留一条。位置与顺序不变，id 换成服务端 id。
- **流式渲染合帧**：SessionDetailModel 内部照常累积 fold，对外 `revision` 最多 ~12Hz 发布（80ms 合帧 Task）；结构化事件（快照/消息/工具/结束时）立即发布。
- **列表拆分**：LazyVStack + 每行 `TranscriptRow`（Equatable，内容/折叠/usage 不变则跳过重建）；流式只重绘变化的那一行。
- **自动滚动**：只在正文增长（`FoldChangeKind.textStream`）或结构变化且用户距底部 <120pt 时跟随，无动画；**思考块增长不滚动、不亮「回到底部」提示点**；滚动频率即合帧频率（≤12Hz）。
- **上下文刷新**：`session/list` 结果按 sessionId 原地 patch（逐条比较，值没变不赋值；缺失才删除），不整体替换数组；详情页只 `updateSession` 同步元数据，fold/模型实例不重建。
- **模型选择器秒开**：AppModel 按 machine 缓存 `ModelCatalog`（5 分钟复用，打开会话时后台预热）；目录解析时预计算 `flatOptions`；选择器打开用缓存直接渲染，仅当缓存为空才请求；切换只改当前会话的 modelSelection，不触发列表全量刷新。

## 性能优化（任务 10，CPU 104% → 目标 <40%）

- **流式增量缓冲**：`assistant-stream` 的 chunk 路径只把 delta `append` 到 `streamTextBuffer/streamReasoningBuffer`（O(1)），标记 dirty；不再每 chunk 取 previousText 拼接 + upsert。80ms 渲染 flush 时才 `joined()` 一次、只物化 dirty 的那条。事件路径（assistant/message、turn/end、快照）会先静默 flush 保证顺序。
- **长文本渲染减负**：流式气泡只渲染**尾部 3000 字符**（前加 `…`），完成后再切全文；单条 >20000 字符默认折叠「展开全文（N 字）」（状态在 `expandedItemIDs` 的 `full-<id>`）；思考块折叠时不渲染正文。
- **行视图 Equatable**：`TranscriptRow`（顶层、nonisolated）内容/折叠/usage 不变时 `.equatable()` 跳过重建；LazyVStack 保留。
- **sheet 期间冻结刷新**：打开模型/统计/会话信息 sheet 时 `setRenderPaused(true)`，暂停 80ms flush（以及批量刷新），关闭后立刻补一帧，保证 sheet 交互不被后台渲染拖住。
- **模型应用乐观更新**：点「应用」立即更新模型条/头部并 dismiss，`session/selectModel` 后台执行；失败回滚显示并报 `modelSelectionError`/toast。
- **修复 WebSocket 资源超时**：原先 `timeoutIntervalForResource = 30s` 会让 `session/follow` 长连接在 30 秒被 URLSession 杀掉（日志 -1001），表现为流停/像卡死；改为 3600s。
- 调试参数：`--open-session <sessionId>` 可在启动时直接打开会话（联调/性能测试用）。

## 真机流式卡顿修复（任务 11）：帧合并下沉后台 + 诊断

- **chunk 合并在 BridgeClient 后台接收循环完成**：连续 `assistant-stream.chunk` 的 text/reasoning 在字符串层拼接，最多每 100ms yield 一个合并帧（带最新 turn/step/time）；`start`/`end`/事件帧/快照立即 flush 后 yield，顺序不乱。主线程收到的流式帧从 ~100/s 降到 ~10/s，JSON 解析与字符串拼接都不在主线程。
- **sheet 期间完全停止会话工作**：`setRenderPaused(true)` 后到达的帧只进 `queuedFrames`（上限 2000，超限丢最旧 stream 帧），不做 fold.apply、不做 flush；关闭后按序一次性应用并补一帧。
- **诊断日志**：`Sources/Connection/Diagnostics.swift` 后台每 2s NSLog 一行固定格式：
  `[DSHDiag] frames=… applied=… lastFlushMs=… mainStallMaxMs=… stalls=…`
  主线程 stall 检测用后台 100ms 定时 ping 主队列，记录 >300ms 的延迟与次数。抓真机日志：`xcrun devicectl device process launch --console …`。
- 联调参数：`--open-session <id>` 可直接打开某个会话。

## 构建/测试环境备注

- 本沙箱 `xcodebuild test` 因 PTY 被禁失败；`simctl install/launch` 也挂起（CoreSimulator 写 `~/Library` 被拒），所以 UI 需在你那边用模拟器跑。
- 本环境 Swift 宏无法展开，未用 `@Observable`/`#Preview`，改用 `ObservableObject`/`@Published`（零宏依赖）。

## 未完成 / 缺口

1. `session/page` 向上翻页未做（当前 `maxMessages=200`，TODO 已注明）。
2. `/v1/push/register` 未从 UI 调用；推送深链、Live Activity 未做。
3. `/v1/file` 未接（图片/附件仍占位）。
4. 新建工作区（`workspace/create`）未接；新建会话仅能落在已有工作区的 cwd。
5. 多机同时只保持一台机器的实时流（列表可混合展示）。
6. 审批卡片里 `request` 的字段形状做了宽容解析；真实触发的审批尚未在测试实例上验证（实例无模型 key，跑不到工具审批）。
