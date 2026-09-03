# json-render 在 Bubble 原生 Agentic UI 中的复用评估

日期：2026-09-03
研究对象：[`vercel-labs/json-render`](https://github.com/vercel-labs/json-render)
上游快照：[`ea3326046f57138671a238f7b1110ce5de015778`](https://github.com/vercel-labs/json-render/commit/ea3326046f57138671a238f7b1110ce5de015778)

## 结论

可以复用，但不应该把现成的 `@json-render/react` 或 `@json-render/shadcn` 直接嵌进 Bubble。

Bubble 是 SwiftUI/AppKit 原生 macOS 应用，而 json-render 当前没有 Swift、SwiftUI 或 AppKit renderer。直接使用现成 renderer 只能在 `WKWebView` 中运行 React 页面，这会把字体、滚动、文本选择、无障碍、窗口材质和现有 transcript 虚拟化切成两套系统，不符合“原生 Agentic UI”的目标。

推荐方案是：

1. 兼容 json-render 的核心思想与 wire format：`Catalog + Spec + SpecStream`。
2. 在 Bubble 内实现一个小而严格的 Swift `Codable` 协议层和 SwiftUI renderer。
3. 图表使用 Apple 的 [Swift Charts](https://developer.apple.com/documentation/charts)，而不是 WebView/Recharts。
4. 第一版只允许无副作用的展示组件；交互 action 后续按明确白名单、用户确认和审计逐项开放。
5. 让同一条 assistant message 同时持有 Markdown 文本和若干原生 UI block，UI patch 按 session/message/block 三层隔离并持久化。

这不是“重写整个 json-render”。真正需要原生实现的 MVP 很小：约十种 value type、三种 patch 操作、一个 catalog validator、一棵稳定 ID 的扁平树和约十个 SwiftUI 组件。上游的 React 状态管理、DOM renderer、shadcn、Tailwind、devtools 等都不需要带进来。

## 上游现状

### 版本、许可与维护快照

截至本次检查：

- `main` HEAD 是 [`ea3326046f57138671a238f7b1110ce5de015778`](https://github.com/vercel-labs/json-render/commit/ea3326046f57138671a238f7b1110ce5de015778)，提交时间为 2026-08-30，主题为 `fix(react): stabilize streaming renders (#325)`。
- 最新 release 是 [`v0.20.0`](https://github.com/vercel-labs/json-render/releases/tag/v0.20.0)，发布时间为 2026-08-18；HEAD 已包含 release 之后的变更。
- 当前 package manifest 的版本为 `0.20.0`，例如 [`@json-render/core`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/package.json)、[`@json-render/react`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/react/package.json) 和 [`@json-render/shadcn`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/shadcn/package.json) 均如此。
- License 是 [Apache-2.0](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/LICENSE)。如果复制或翻译上游实现代码，需要保留许可和修改声明；只采用 RFC 6902 wire format 和独立实现 Swift 代码，耦合更低。

### 平台与运行时依赖

json-render 是 TypeScript/JavaScript monorepo：

- 仓库开发环境要求 Node `>=24`、pnpm `>=11`，见[根 `package.json`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/package.json)。
- `@json-render/core` 的运行依赖是 Zod 4，见 [`packages/core/package.json`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/package.json#L29-L62)。
- `@json-render/react` 要求 React `^19.2.3`，见 [`packages/react/package.json`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/react/package.json#L52-L65)。
- `@json-render/shadcn` 还要求 React DOM、Tailwind CSS 4、Zod 4，并依赖 Radix、Vaul 等 Web UI 库，见 [`packages/shadcn/package.json`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/shadcn/package.json)。
- React Native renderer 仍是 React Native runtime，不是 macOS SwiftUI renderer；其 peer dependencies 见 [`packages/react-native/package.json`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/react-native/package.json#L58-L74)。
- 官方仓库没有 Swift source、`Package.swift`、SwiftUI 或 AppKit renderer。

Bubble 自身是 macOS 26 Swift Package，UI 直接链接 AppKit/SwiftUI/WebKit，当前依赖中没有 JS UI runtime，见 [`Package.swift`](../../Package.swift)。因此，把 React renderer 搬进来意味着新引入一个网页应用和双向 bridge，而不是复用一个原生库。

## json-render 的核心协议

### Spec：由稳定 key 组成的扁平 UI 树

核心 `Spec` 是：

```ts
interface Spec {
  root: string
  elements: Record<string, UIElement>
  state?: Record<string, unknown>
}
```

官方定义见 [`packages/core/src/types.ts#L172-L183`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/types.ts#L172-L183)。每个 `UIElement` 含 `type`、`props`、`children`，并可带 named slots、条件可见性、事件 action、repeat 和 state watcher，见 [`types.ts#L53-L81`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/types.ts#L53-L81)。

扁平树对 Bubble 有两个直接好处：

- 元素 key 可以进入 transcript 的 `contentVersion`/fingerprint，避免每个 token 重建整棵 SwiftUI 树。
- patch 只触碰一个 element 时，可以只让对应 AppKit row host 重新测量，而不是让整段回答重新排版。

### Catalog：模型可用的组件与 action 白名单

Catalog 同时承担三个职责：

- 给模型生成组件、props、action 说明；
- 生成 JSON Schema/Zod schema；
- 在运行前验证 component type 和 props。

官方 `defineCatalog`/`catalog.validate()` 的实现见 [`packages/core/src/schema.ts#L420-L473`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/schema.ts#L420-L473)。这才是“Agentic UI 可控”的核心：模型选择宿主预先定义的积木，而不是生成并执行代码。

### SpecStream：逐行 RFC 6902 JSON Patch

SpecStream 是 JSONL，每行一个 [RFC 6902 JSON Patch](https://datatracker.ietf.org/doc/html/rfc6902)：

```jsonl
{"op":"add","path":"/root","value":"summary"}
{"op":"add","path":"/elements/summary","value":{"type":"Stack","props":{"spacing":12},"children":["metric","chart"]}}
{"op":"add","path":"/elements/metric","value":{"type":"Metric","props":{"label":"P95","value":"23 ms"},"children":[]}}
{"op":"add","path":"/elements/chart","value":{"type":"BarChart","props":{"title":"Latency","points":[{"label":"A","value":12},{"label":"B","value":23}]},"children":[]}}
```

上游支持 `add/remove/replace/move/copy/test` 六种 operation。compiler 会缓存半行，在完整换行到达时 apply patch 并返回新的顶层引用，见 [`packages/core/src/types.ts#L577-L935`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/types.ts#L577-L935)。官方生成 prompt 建议先写 `/root`，再交错输出 `/elements` 与 `/state`，见 [`packages/core/src/schema.ts#L628-L765`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/schema.ts#L628-L765)。

本次还对 npm 发布的 `@json-render/core@0.20.0` 做了隔离 smoke test：把两个分片依次送入 `createSpecStreamCompiler`，它分别产出一个 patch，最终得到 `root=chart` 的完整 `BarChart` Spec。这说明协议编译器确实可以独立于 React 工作；但把它跨 JavaScriptCore bridge 调进 Swift 的收益小于直接实现同等的 Swift patch reducer。

### 文本与 UI 混合流

上游也支持聊天型 mixed stream：普通文本与 fenced `spec` JSONL 分流，随后可转换成 AI SDK 的 `data-spec` part。实现见 [mixed stream parser](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/types.ts#L943-L1042) 和 [`data-spec` wire type](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/types.ts#L1304-L1335)。

Bubble 可以兼容这种格式作为调试/降级入口，但生产路径不应长期依赖在 Markdown 中找 fence。fence 可能被模型错误闭合、被代码示例误触发，也会污染复制与历史记录。生产协议应使用明确的 Bubble vendor event 或专用 tool result，把 prose 与 UI patch 在 transport 层区分。

## 图表能力的真实情况

json-render 的核心包并没有现成的 `Chart`。`@json-render/shadcn` 的标准组件也没有直接提供图表 renderer。

图表出现在官方示例自己的 catalog 中：

- chat 示例自行定义 `BarChart`、`LineChart` 和 `PieChart` props，见 [`examples/chat/lib/render/catalog.ts#L119-L146`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/chat/lib/render/catalog.ts#L119-L146) 与 [`#L212-L222`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/chat/lib/render/catalog.ts#L212-L222)。
- renderer 自行 import Recharts，见 [`examples/chat/lib/render/registry.tsx#L3-L22`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/chat/lib/render/registry.tsx#L3-L22)，柱/线/饼图的具体实现位于同文件 [`#L348-L480`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/chat/lib/render/registry.tsx#L348-L480) 和 [`#L589-L648`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/chat/lib/render/registry.tsx#L589-L648)。
- Recharts `^2.15.4` 是示例应用自己的 dependency，见 [`examples/chat/package.json#L14-L39`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/chat/package.json#L14-L39)。
- 官方 harness-chat 示例则使用更窄的 `{label, value}` 数据 schema，并自行画 SVG，见其 [catalog](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/harness-chat/lib/render/catalog.ts#L177-L223) 和 [registry](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/examples/harness-chat/lib/render/registry.tsx#L330-L465)。

所以“调用 json-render 就自动得到图表”并不成立。它提供的是让模型选择 `BarChart` 的协议和约束；真正把数据画出来仍由宿主实现。

Bubble 应采用 harness-chat 那种窄数据结构，并映射到 Swift Charts。Apple 的 Swift Charts 原生提供 `BarMark`、`LineMark`、`SectorMark` 等 mark，覆盖柱状、折线以及饼/环图，见 [Swift Charts 官方文档](https://developer.apple.com/documentation/charts)。这样能自然继承 macOS 字体、深浅色、VoiceOver、缩放和窗口渲染，不再引入 WebView 字体/像素对齐问题。

## 直接复用与协议复用比较

| 方案 | 能否工作 | 是否原生 | 代价与结论 |
| --- | --- | --- | --- |
| `WKWebView + @json-render/react + shadcn` | 能 | 否 | 最快看到 demo，但带入 React/DOM/Tailwind、JS bridge、另一套滚动与无障碍；不建议进入 Bubble transcript |
| JavaScriptCore 调 `@json-render/core`，SwiftUI 负责画 | 理论可行 | UI 原生 | 只为 JSONL patch/validation 引入 JS/Zod bridge，错误和数据还要二次映射；不划算 |
| 直接移植上游 core 源码 | 能 | 是 | Apache-2.0 允许，但会追随快速演进的 TS API；MVP 没必要完整移植 |
| 兼容 Spec/SpecStream，独立 Swift runtime | 能 | 是 | 推荐；保留生态语义，按 Bubble 需要实现更小、更严的子集 |

## 推荐的 Bubble 原生架构

```text
Pi model
  -> bubble_render tool / Bubble vendor ACP event
  -> AgenticUIStreamRouter (按 session + message + block 隔离)
  -> SpecStreamDecoder (JSONL framing)
  -> PatchPolicy + CatalogValidator + ResourceLimits
  -> AgenticUISpecStore (Codable canonical spec + revision)
  -> AgenticUIRowHost
  -> SwiftUI component registry
  -> Swift Charts / native controls
```

### 1. 数据模型

建议新增独立模块 `BubbleAgenticUI`，不把动态 JSON 塞回 `MessageBody`：

```swift
struct AgenticUISpec: Codable, Equatable, Sendable {
    var root: String
    var elements: [String: AgenticUIElement]
    var state: [String: JSONValue]?
}

struct AgenticUIElement: Codable, Equatable, Sendable {
    var type: AgenticUIComponentType
    var props: [String: JSONValue]
    var children: [String]
}

struct AgenticUIBlock: Codable, Equatable, Sendable {
    var id: String
    var spec: AgenticUISpec
    var revision: UInt64
    var status: Status // streaming, complete, invalid
}
```

`ChatItem` 应增加 `[AgenticUIBlock]?` 或更一般的 ordered content blocks，而不是只增加一个 `agenticUISpec` 字符串。已有 assistant 图片已经证明回答需要保持文本与非文本内容的相对位置；UI block 也应记录 `textOffset` 或使用统一的 ordered block model。

### 2. MVP catalog

第一阶段建议仅开放：

| 组件 | 原生实现 | 说明 |
| --- | --- | --- |
| `Stack` | `VStack` / `HStack` | axis、spacing、alignment 使用 enum，不接受任意 CSS |
| `Grid` | `Grid` / `LazyVGrid` | 限制最大列数 |
| `Card` | Bubble 现有 surface/token | title、subtitle、children |
| `Text` / `Heading` | `Text` / `MessageBody` | 使用有限 style enum；不允许字体路径或 HTML |
| `Callout` | 原生 label + SF Symbol | info/warning/success/error enum |
| `Metric` | 原生 VStack | label、value、可选 trend |
| `Table` | `Grid` 或自定义 lazy rows | 固定 columns，限制行/列数 |
| `BarChart` | Swift Charts `BarMark` | `{label, value, series?}` points |
| `LineChart` | Swift Charts `LineMark` | 有序 `{label, value, series?}` points |
| `DonutChart` | Swift Charts `SectorMark` | `{label, value}` points，禁止负数 |

对于“回答里涉及图表就直接展示”，这个 catalog 已够用。不要在 MVP 复制上游任意 `xKey/yKey + [String: unknown]` 的自由结构；明确的 `ChartPoint` 更容易验证、格式化和做 VoiceOver summary。

### 3. 生成与 transport

推荐添加一个由 Bubble/Pi extension 暴露给模型的 `bubble_render` tool：

- tool description 包含 catalog 和例子；模型只在数据适合可视化时调用。
- 参数包含 `blockID` 与完整 Spec，后续可升级为 patch stream。
- Pi extension 把它转成明确的 `_bubble/agentic_ui_snapshot` 或 `_bubble/agentic_ui_patch` session update。
- 普通解释文字仍走 `agent_message_chunk`；UI 不出现在复制出来的 Markdown 中。
- 每个 UI event 必须携带 `sessionId + assistantEntryId + blockId + sequence`，防止 session 切换、重放或乱序更新污染别的回答。

为什么优先 tool/vendor event：Bubble 当前 ACP assistant content 只解析 `text` 和 `image`，见 [`AssistantMessageContent.swift`](../../Sources/Bubble/AssistantMessageContent.swift)；`ChatStore.applyUpdate` 在 `agent_message_chunk` 和 `tool_call(_update)` 处分流，见 [`ChatStore.swift`](../../Sources/Bubble/ChatStore.swift)。而 [`BubblePiAcpPatch.swift`](../../Sources/Bubble/BubblePiAcpPatch.swift) 已经有 Bubble 私有 RPC、自定义 message 转发、实时与 replay 双路径，可作为新增 vendor event 的现成落点。

可保留 fenced `spec` mixed stream 作为开发者选项与模型兼容 fallback，但解析失败时必须原样显示文字/代码，不能让回答静默消失。

### 4. 流式 reducer

为了降低攻击面，Bubble v1 不必实现全部 RFC 6902：

- 只接受 `add`、`replace`、`remove`；
- path 只允许 `/root`、`/elements/<escaped-key>`、`/state/<escaped-key>`；
- 禁止修改 block 外部、禁止空 key，严格实现 RFC 6901 的 `~0`/`~1` unescape；
- 每条 patch 先做 shape/path/size 校验，再复制应用，成功后原子替换当前 spec；
- patch 带单调 sequence；重复包幂等丢弃，缺口先缓存并设超时，不能猜顺序；
- streaming 阶段允许 root/children 暂时不完整，但只渲染从 root 可达且依赖齐全的子树；complete 时必须全量校验。

上游的 `parseSpecStreamLine` 只做宽松的 `op/path` 形状检查，compiler 也没有 payload、元素数或深度限制，见其[解析和 apply 实现](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/types.ts#L587-L655)。这些限制必须由 Bubble 自己提供。

### 5. 验证与资源限制

建议在三个阶段验证：

1. **Patch envelope**：合法 operation、path、sequence、JSON 类型和 byte limit。
2. **Catalog**：component type 必须在 allowlist；props 必须完全匹配类型；拒绝未知字段，不做宽松 coercion。
3. **Graph**：root 存在、child 存在、无环、从 root 可达、深度/宽度/总节点受限。

建议初始上限：

- 每个 UI block 最多 64 KiB JSON、128 个 patches、64 个 elements；
- tree depth 最多 8；每个 element 最多 32 个 children；
- table 最多 100 行 × 12 列；chart 最多 500 points、最多 8 series；
- 单字符串最多 8 KiB；title/label 更低；
- 每条 assistant message 最多 4 个 UI blocks；
- 每个 session 的 streaming UI memory 和缓存都设总量上限。

上游另有结构校验器检查缺 root、悬空 child、错误 visible/repeat 和孤儿节点，见 [`packages/core/src/spec-validator.ts#L9-L216`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/spec-validator.ts#L9-L216)。Bubble 应采用同类检查，但不能把它当作资源限制或权限系统。

### 6. Actions 与权限

上游 action binding 支持 params、确认、成功/失败链，真正执行由宿主提供的 handler 完成，见 [`packages/core/src/actions.ts#L5-L126`](https://github.com/vercel-labs/json-render/blob/ea3326046f57138671a238f7b1110ce5de015778/packages/core/src/actions.ts#L5-L126)。这适合作为 Bubble 的概念模型，但模型输出不等于用户授权。

分阶段开放：

- v1：只读，没有 action。
- v1.1：本地无副作用 action：`copyText`、`setLocalState`、`toggleDisclosure`。
- v2：有限宿主 action：`openURL`、`insertPrompt`；URL 做 `https` scheme/domain policy，离开应用前确认。
- v3：`sendPrompt`、文件或 agent tool 等有副作用 action，必须显示人类可读参数并逐次确认；不要提供任意 shell、任意路径读写或任意 RPC action。

action handler 应重新验证名称和 typed params，只从注册表查找；未知 action、未知 event、递归 action chain 超限都拒绝。每次执行记录 `session/message/block/element/action/result` 审计信息，但不记录 secret 或完整敏感数据。

### 7. 渲染与无障碍

- UI block 是 transcript 中独立的稳定 row，内部 SwiftUI view 使用 stable element key。
- 图表必须提供标题、轴/单位以及可读 summary；VoiceOver 能逐点或按 series 阅读，数据为空时显示明确 fallback。
- 色彩来自 Bubble semantic palette，同时用形状/label 区分 series，不能只依赖颜色。
- 高度变化走现有 `requestTranscriptRowMeasurement`/AppKit host measurement，不允许 UI streaming 触发 transcript 全量重建。
- 完成后的 Spec 进入内容 hash；状态变化只更新 block revision，不修改其他 assistant prose row。
- 导出/复制默认复制 prose 加可读数据摘要，而不是复制原始控制 JSON。

## Bubble 的具体接入点

下列位置均是当前工作区代码，不是猜测的模块名：

| 位置 | 现状 | 建议改动 |
| --- | --- | --- |
| [`Sources/Bubble/ChatStore.swift`](../../Sources/Bubble/ChatStore.swift) `ChatItem` | `Codable`，已有 text/tool/images/placements | 增加 ordered `.agenticUI` block；保留 canonical spec 和状态 |
| 同文件 `applyUpdate` | 在 `agent_message_chunk`、thought、tool update 之间路由 | 新增 `_bubble/agentic_ui_snapshot/patch/complete` 分支，按 session/message/block/sequence 聚合 |
| 同文件 `queueStreamFlush` / `flushStreamChunks` | 对文本 token 做节流 UI flush | UI patch 使用独立 coalescer，每帧最多发布一次 block revision |
| 同文件 `persist` / `loadTranscript` | JSONEncoder/Decoder 保存 `ChatItem` 并按 session 恢复 | 让完成 Spec 可恢复；未完成 stream 要么标 invalid，要么只保留最后验证通过的 snapshot |
| [`Sources/Bubble/AssistantMessageContent.swift`](../../Sources/Bubble/AssistantMessageContent.swift) | 只支持 text/image，并维护相对 placement | 抽象统一 ordered block，或为 Agentic UI 增加 placement；不要只拼到 text |
| [`Sources/Bubble/OverlayView.swift`](../../Sources/Bubble/OverlayView.swift) `transcriptRenderSeed` | 区分 assistant/tool/media，使用 content version | `hasMedia` 扩展为 rich block；fingerprint 加 UI block revision |
| 同文件 `mainTranscriptRow` / `assistantOrderedContent` | SwiftUI row host 渲染 Markdown 和图片 | 增加 `AgenticUIHost`，把 block registry 渲染成原生 SwiftUI/Charts |
| [`Sources/Bubble/AppKitTranscriptSurface.swift`](../../Sources/Bubble/AppKitTranscriptSurface.swift) | stable row reuse、Fenwick 高度索引、NSHostingView seam | 把 UI block 当稳定 row 或 assistant row 内稳定子树；patch 后只 invalidate 对应 host measurement |
| [`Sources/Bubble/BubblePiAcpPatch.swift`](../../Sources/Bubble/BubblePiAcpPatch.swift) | 已 patch `pi-acp@0.0.33`，支持 Bubble 私有 RPC 和 custom image realtime/replay | 增加 `bubble_render` tool/custom entry 和 UI event 的 realtime/replay 对称转发 |
| [`Sources/Bubble/ConversationTree.swift`](../../Sources/Bubble/ConversationTree.swift) | 从 Pi entry 重建分支历史 | 识别 UI custom entry/details，确保 `/resume`、branch、session switch 后原样恢复 |
| [`Package.swift`](../../Package.swift) | 已有 AppKit/SwiftUI/WebKit；未链接 Charts | 新模块依赖 Apple `Charts` framework，不增加 Web runtime |

尤其要避免复发刚修过的 session 切换问题：不能用一个全局 Spec compiler。compiler/store key 必须至少是 `(runtimeID, sessionID, assistantEntryID, blockID)`；session authoritative snapshot 到达时切换对应 store，旧 session 的迟到 patch 必须丢弃。

## 分阶段实施

### Phase 0：协议 spike（1–2 天）

- 新建纯 Swift `BubbleAgenticUI` target。
- 实现 `JSONValue`、窄版 Spec、`add/replace/remove` reducer、catalog validator 与资源上限。
- 用官方 SpecStream 示例和本报告中的 chart spec 做 fixture。
- 单元测试覆盖分块 JSONL、乱序/重复 sequence、无效 path、环、缺 child、未知 component、超限 payload。
- 暂不接模型、不改 transcript。

验收：同一 Spec 的完整 JSON 和任意 chunk boundary JSONL 得到相同 canonical result；无效输入不会 crash、卡主线程或产生部分越权状态。

### Phase 1：只读原生图表 MVP（3–5 天）

- 实现 `Stack/Card/Text/Heading/Metric/Table/BarChart/LineChart/DonutChart`。
- 使用 Swift Charts，做 light/dark、VoiceOver、窗口窄宽和 500 points 性能检查。
- `ChatItem`/persistence/renderer 支持 agentic UI block。
- 先通过本地 fixture 或隐藏 debug command 注入，验证 transcript 虚拟化、选择、滚动、session 切换和恢复。

验收：包含图表的回答原生显示；切换 session、滚走再回来、重启 Bubble、分支恢复后均一致；普通 Markdown 回答零回归。

### Phase 2：模型自动生成（3–5 天）

- 在 Pi extension 注册 `bubble_render`，注入 MVP catalog 和使用规则。
- `BubblePiAcpPatch` 转发 snapshot/patch/complete，实时和 replay 使用同一数据模型。
- 普通 prose 与 UI block 按顺序展示；生成/验证失败时展示 prose + 简短可诊断 fallback，不显示裸 JSON。
- 为“适合图表”的提示集做 deterministic fixture/eval：时间序列、分类比较、占比、没有数据、数据过多、恶意 props。

验收：模型在适当问题上生成图表，不适当问题不强行图表；取消、重试、steer、branch、resume 都不会串 block。

### Phase 3：增量 streaming 与动作（后续）

- snapshot 工具调用先跑通，再按实际感知收益增加 patch streaming；避免为了“逐 token 动图”先扩大协议复杂度。
- 开放本地 state、toggle/copy，再评估需要确认的 `openURL`/`sendPrompt`。
- 加 UI block 调试导出、校验错误计数和渲染耗时指标，不暴露原始 reasoning 或敏感 tool payload。

## 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 上游仍快速演进 | 直接 port 容易追版本 | 固定 `bubble-agentic-ui/v1` 子集；fixture 验证兼容，不承诺完整 json-render API |
| 模型生成无效/过大 Spec | 白屏、卡顿、内存增长 | 三层验证、严格上限、最后有效 snapshot、可读 fallback |
| streaming 频繁改变高度 | transcript 抖动、滚动锚点漂移 | frame coalescing、stable IDs、对应 row 局部 measurement、完成后冻结 |
| session/branch/replay 串流 | UI 出现在错误回答 | 四元组 key、sequence、generation token、authoritative snapshot、迟到包丢弃 |
| action 被模型滥用 | 外链、文件、agent 操作越权 | 默认只读；typed allowlist；副作用逐次确认和审计 |
| 图表语义错误 | “看起来对”但数据含义错误 | title/unit/series 必填规则、有限 chart schemas、同时提供数据摘要、eval fixtures |
| Web 与原生视觉割裂 | 再次出现字体模糊、选择/滚动问题 | 不嵌 Web renderer；SwiftUI + Swift Charts + Bubble tokens |
| 历史格式升级 | 老 transcript 解码失败 | 所有新字段 optional；协议带 version；未知 block 降级为可读摘要 |

## 最终建议

立项，但把目标定义为“json-render-compatible 的 Bubble Native Agentic UI”，而不是“把 json-render React 库塞进 Bubble”。

优先做 Phase 0 + Phase 1：先证明一份受限 Spec 可以在 Bubble transcript 中稳定、原生地显示 `Metric/Table/Bar/Line/Donut`，并经受 session 切换、滚动虚拟化和重启恢复。随后通过 `bubble_render` tool 接模型。这样最快交付用户能看到的图表能力，同时避免 WebView 和任意 action 把刚稳定下来的原生 transcript 重新复杂化。
