# T3 Code 长会话性能架构研究：给 Bubble 的 60 FPS 路线

> 调研日期：2026-08-27  
> T3 Code 基线：[`33b650a5b3b27382b35d2182dec6b22438c3da56`](https://github.com/pingdotgg/t3code/commit/33b650a5b3b27382b35d2182dec6b22438c3da56)  
> 证据范围：T3 Code 官方仓库的当前源码、测试与提交历史；没有使用第三方文章或二手解读。  
> Bubble 范围：研究结论已用于本轮实现与基准验证；页级本地持久化仍作为后续演进项。

## 结论先行

T3 Code 的长会话流畅度不是由某一个“神奇列表组件”提供，而是一条贯穿服务端、缓存和 UI 的限量管线：

```text
最近 10 个用户回合首屏
  → 需要时显式加载更早 20 回合
  → 只合并不重叠的旧页，并用序列水位拒绝陈旧结果
  → LegendList 只挂载可见行
  → 不变行保持对象 identity，避免流式更新击穿 memo
  → 用户一离开底部就停止自动跟随
  → 完成后的代码高亮才进入有容量上限的缓存
  → 活跃回合不写 IndexedDB，结束后再持久化
```

Bubble 已经具备其中不少关键能力：长列表按阈值切 `LazyVStack`、稳定 row ID / render key、只重建流式尾部、按显示脉冲合并流式更新、用户离底后停止跟随、活跃流不写盘、解析缓存有容量上限。因此，**不建议把 SwiftUI 列表机械替换成 T3 Code 的 React/LegendList 方案**。

Bubble 当前最值得移植的不是列表组件，而是以下三件事：

1. **持久化和水合真正窗口化**：首屏只解码最近一小段，旧历史分页加载；本轮先把整份 JSON 读取/解码移出 UI 线程、只发布最近窗口，超长 session 的总解码成本仍随历史线性增长。
2. **把全局观察拆成行级快照**：用稳定对象 identity 与结构共享，确保一条流式尾消息的变化不会使所有已完成行重新求值。
3. **把 60 FPS 变成可执行的帧预算门禁**：60 Hz 的主线程预算是 16.67 ms。Bubble 现有滚动基准允许 p95 20 ms，不能证明“所有操作反馈高于 60 帧”；T3 Code 自身也没有公开这种证明。

## 一、T3 Code 实际如何处理长 session

### 1. 数据源先做“用户回合窗口”，而不是把整段历史交给虚拟列表

T3 Code 当前首屏只请求最近 **10 个 user-anchored turns**，点击“load earlier”每次再取 **20 个**。子代理/扇出回合随所属用户回合一起返回。源码注释说明，这组值来自最重线程首屏约 100 KB gzip、而中位线程可以一次加载完整的经验取舍；它不是一份公开基准报告。[`threads.ts#L43-L50`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threads.ts#L43-L50)

分页协议不是 offset：`beforeCursor` 是不透明、排他的游标，下一页必须是相邻且不重叠的旧区间。返回值同时带全局 `snapshotSequence` 和本线程的 `threadSequence`；后者用于保证旧页不会领先于实时订阅，否则页面中的流式文本可能和随后到达的事件重复叠加。[`orchestration.ts#L617-L653`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/contracts/src/orchestration.ts#L617-L653)

服务端使用 `(requested_at, turn_id)` 的 keyset pagination，先在 CTE 内做 `LIMIT` 再运行窗口函数，并依赖复合索引；这避免为取最近一页而物化整条线程。为防止一个用户回合下异常大的子代理扇出，单页另设 **150 个 raw turns** 的硬上限；窗口解析与快照序列读取在同一事务内完成。[`ProjectionSnapshotQuery.ts#L1125-L1208`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProjectionSnapshotQuery.ts#L1125-L1208) [`ProjectionSnapshotQuery.ts#L2700-L2838`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProjectionSnapshotQuery.ts#L2700-L2838)

客户端合并旧页时，对 messages、activities、plans、checkpoints 分别按稳定 ID 去重后前插。请求前记录 `historyEpoch`，与实时事件共用 `applyLock`；如果线程发生 revert / deletion / snapshot replacement，或旧页序列落后，就丢弃页面。若页面的线程水位领先，则先暂存，等实时订阅追平再合并。[`threads.ts#L408-L460`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threads.ts#L408-L460) [`threads.ts#L464-L530`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threads.ts#L464-L530)

当前 Web UI 不是滚到顶部自动拉取，而是列表 header 中的显式 “Load earlier” 控件。[`MessagesTimeline.tsx#L581-L618`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L581-L618)

历史背景也支持这一选择：早期实现曾因无界 thread activity 读取物化数百 MB、把 Node 进程推到 heap OOM，随后先加了边界与分页；当前 turn-window 设计是更完整的后继方案。[提交 `9382e90`](https://github.com/pingdotgg/t3code/commit/9382e9024c8ee1a948d4b415f4b3d7d2850f52f9)

**可复用原则**：列表虚拟化只能减少“已加载数据的挂载成本”，不能解决整份 session 的数据库查询、JSON 解码、对象分配和状态合并成本；窗口化必须进入持久化协议和水合流程。

### 2. 列表虚拟化：稳定 key、行类型、估算高度和结构共享缺一不可

桌面 Web/Electron 的消息时间线使用 `@legendapp/list` 的 `LegendList`，提供：

- 稳定 `keyExtractor` 与 `getItemType`；
- `estimatedItemSize={90}`；
- 初次打开直接在末尾；
- `maintainVisibleContentPosition`；
- 只有在确实处于 live-follow 状态时才 `maintainScrollAtEnd`；
- CSS 关闭浏览器自身的 `overflow-anchor`，避免两套锚定机制互相打架。

对应实现见 [`MessagesTimeline.tsx#L559-L605`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L559-L605)。依赖版本固定为 `@legendapp/list 3.3.5`，因此这里描述的是该版本上的具体行为，而不是对所有虚拟列表库的泛化。[`pnpm-workspace.yaml#L136-L142`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/pnpm-workspace.yaml#L136-L142)

虚拟化之上又做了一层结构共享：每次派生新 rows 后，以 ID 找上一次的 row，按 row variant 做浅字段比较；未变化则复用旧对象引用，整份结果也可在完全不变时复用。这样流式工具进度只让真正变化的行穿过 memo 边界。[`MessagesTimeline.tsx#L407-L433`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L407-L433) [`MessagesTimeline.logic.ts#L1043-L1064`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.logic.ts#L1043-L1064)

`renderItem` 本身故意保持零依赖；共享回调和少量跨行状态通过拆开的 context 传递，计时型 `nowIso` 被排除在列表 context 外，避免一个自更新时间击穿所有行。[`MessagesTimeline.tsx#L127-L161`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L127-L161) [`MessagesTimeline.tsx#L559-L568`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L559-L568)

工具工作日志默认只露出最近 **1** 条，其余折叠为组，减少长 agent turn 的可见行数和布局噪声。[`MessagesTimeline.logic.ts#L1-L17`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.logic.ts#L1-L17)

**限制**：T3 Code 的父视图仍会读取整条 thread；它不是“每一行完全独立订阅”。当前收益主要来自窗口化、列表只挂载视区、稳定行引用和拆开的 detail slice，不能把它描述成完美的 row-local store。

### 3. 状态订阅：按线程、按 slice 分 atom，并在闲置后释放

T3 Code 为每个 thread 建立 atom family，再把 detail、status、error、messages、activities、plans、checkpoints、session、latest turn 等拆成独立派生 atom。派生值按 source identity memoize，避免源对象未变却产生新数组引用；stream-backed state 空闲 **5 分钟**后释放，兼顾移动端路由短暂卸载和不能永久保留所有曾打开线程的内存边界。[`threadDetail.ts#L70-L177`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threadDetail.ts#L70-L177) [`threadRetention.ts`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threadRetention.ts)

这与结构共享配套：granular subscription 防止无关 UI 被全局状态唤醒，stable row identity 防止同一数组中新对象让已完成行误判为变化。单做一边都不完整。

### 4. 流式更新：默认不是 token-by-token 渲染，而是服务端缓冲到语义边界

一个容易误读的事实是：T3 Code 当前默认关闭 legacy token streaming；旧配置会被丢弃，默认采用 buffered 模式。[`settings.ts#L618-L628`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/contracts/src/settings.ts#L618-L628)

服务端把 assistant 文本累计在内存中：

- 正常情况下，在 assistant 完成或 turn 完成时一次性落入 projection；
- 遇到 approval / user-input request 时先 flush，保证请求之前的回答可见；
- 缓冲超过 **24,000 字符**时作为安全阀 spill 一次完整文本；
- 只有显式开启 legacy 模式才逐 delta dispatch。

实现见 [`ProviderRuntimeIngestion.ts#L89-L101`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.ts#L89-L101)、[`ProviderRuntimeIngestion.ts#L1085-L1103`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.ts#L1085-L1103)、[`ProviderRuntimeIngestion.ts#L1670-L1748`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.ts#L1670-L1748) 和 [`ProviderRuntimeIngestion.ts#L1760-L1905`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.ts#L1760-L1905)。对应测试明确断言 delta 中途不出现 message、完成后才出现完整 message，并覆盖 approval flush 和超限 spill。[`ProviderRuntimeIngestion.test.ts#L1910-L1990`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/server/src/orchestration/Layers/ProviderRuntimeIngestion.test.ts#L1910-L1990)

因此，不能把 T3 Code 的流畅全部归因于 React 优化：**它默认就移除了最昂贵的“每个 token 重新投影、重新 Markdown、重新布局”路径**。一次官方性能审计也明确记录了“默认关闭 streaming、活跃 turn 避免 IndexedDB encode、时间线 row 稳定、Shiki 修复”等措施。[提交 `bc23ec5`](https://github.com/pingdotgg/t3code/commit/bc23ec507316e7e2b1aeff396b645255f4bedada)

**不应直接照搬到 Bubble**：Bubble 的交互目标包含实时生成反馈，整段回答完成后才显示会让“首个反馈”明显变差。应借鉴的是“聚合原始 delta、在受控边界提交 UI、完成块才做重渲染”，不是隐藏整个生成过程。

### 5. 滚动跟随：live edge 是一个显式状态，不是每次数据变化就滚到底

T3 Code 把重新进入 live-follow 的边界收窄到距真实底部 **40 px**。源码说明 LegendList 默认“半个 viewport 内算 near end”会在用户阅读历史时过早重启跟随，下一次 stream chunk 就把用户拽回底部。[`MessagesTimeline.logic.ts#L40-L65`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.logic.ts#L40-L65)

当前策略是：

- 用户确实在 live edge 才维持末尾；
- 用户离开底部后，新增内容保持当前可见位置；
- 折叠/展开 disclosure 时，暂停 end maintenance 两个 animation frames，并以被切换行作锚，避免高度突变把视区弹走；
- 发送新 turn 时可用 anchored-end space 把自己的消息放在稳定视觉位置；
- 不再在每次 data change 上手写双 `requestAnimationFrame + scrollToEnd`。

实现见 [`MessagesTimeline.tsx#L295-L345`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L295-L345) 与 [`MessagesTimeline.tsx#L581-L605`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/chat/MessagesTimeline.tsx#L581-L605)；迁移理由记录于 [提交 `f73d17c`](https://github.com/pingdotgg/t3code/commit/f73d17c7a16c4240f0294db78442dabe6320b734)。

### 6. Markdown / 代码渲染：异步降级、只缓存完成态、缓存有内存上限

T3 Code 的代码块通过 React `Suspense` 异步获取 Shiki highlighter，等待或异常时直接回退到普通 `<pre>`；不让高亮资源阻断整条消息显示。[`ChatMarkdown.tsx#L2181-L2207`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/ChatMarkdown.tsx#L2181-L2207)

高亮结果使用 LRU，限制为 **500 项 / 50 MB**。key 包含 code、language、theme；只有 `!isStreaming` 的完成态才读写缓存，防止不断增长的中间代码污染缓存。Shiki 失败则降级为 text grammar。[`ChatMarkdown.tsx#L183-L206`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/ChatMarkdown.tsx#L183-L206) [`ChatMarkdown.tsx#L829-L908`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/ChatMarkdown.tsx#L829-L908) [`syntaxHighlighting.ts#L9-L29`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/lib/syntaxHighlighting.ts#L9-L29)

Markdown 图片使用原生 `loading="lazy"`；整个 `ChatMarkdown` 组件用 `memo` 包装。[`ChatMarkdown.tsx#L2149-L2162`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/ChatMarkdown.tsx#L2149-L2162) [`ChatMarkdown.tsx#L2239-L2262`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/components/ChatMarkdown.tsx#L2239-L2262)

**边界**：如果重新打开 legacy token streaming，一个持续增长的 fenced code block 仍会重复高亮，而且中间态不会命中完成态缓存；T3 Code 主要靠默认服务端缓冲绕开该热路径，而不是实现了真正的增量 Markdown AST / 增量 Shiki。

### 7. Session 水合和持久化：先显缓存，HTTP 补快照，活跃期不编码

客户端启动 thread state 时先读取 IndexedDB 缓存，立即用缓存内容和分页游标创建可渲染状态，并以缓存的 `snapshotSequence` 作为实时追赶起点；因此 warm resume 不需要重下整条 thread。[`threads.ts#L135-L167`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threads.ts#L135-L167)

远端快照通过 gzip 友好的 HTTP 拉取而非塞进 WebSocket，设置 6 秒超时；只有服务端声明 pagination capability 才发送窗口参数。[`threadSnapshotHttp.ts#L19-L75`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threadSnapshotHttp.ts#L19-L75)

缓存写入用容量 1 的 sliding queue 和 **500 ms debounce**。活跃线程可能每秒更新多次且包含大 tool payload，所以 active turn 期间不持久化，以服务端为真源，settled 后才写一次；已扩大窗口的分页边界和内容一起保存，避免恢复后把 partial snapshot 误当完整历史。[`threads.ts#L188-L210`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threads.ts#L188-L210) [`threads.ts#L255-L285`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/packages/client-runtime/src/state/threads.ts#L255-L285) [`storage.ts#L38-L64`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/connection/storage.ts#L38-L64)

## 二、T3 Code 到底证明了多少性能

### 有一条可量化的 CPU 测试

T3 Code 的 session logic 测试构造 **20,000 条有序 tool activities**，要求更新在 **100 ms** 内完成，并验证不变 work entries 保持引用相等。这能证明结构共享算法没有退化到明显的二次复杂度，但它是单元测试的 CPU 阈值，**不是**渲染、滚动或输入的 FPS 证明。[`session-logic.test.ts#L2240-L2300`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/apps/web/src/session-logic.test.ts#L2240-L2300)

### 没有找到的证据

截至上述 SHA，官方仓库没有公开以下材料：

- 长 session 的 React Profiler trace；
- macOS Electron 的 frame-time 分布；
- click-to-first-paint / key-to-paint 指标；
- “所有操作稳定 60 FPS”的 CI 门禁；
- 初始 100 KB 取样的完整数据集和测量方法。

所以 T3 Code 可以作为架构样本，不能作为 Bubble 60 FPS 目标已被外部方案证明的依据。README 也仍将项目定位为早期版本并提示 bugs / rough edges。[`README.md#L1-L11`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/README.md#L1-L11) [`README.md#L68-L72`](https://github.com/pingdotgg/t3code/blob/33b650a5b3b27382b35d2182dec6b22438c3da56/README.md#L68-L72)

## 三、与 Bubble 当前实现的逐项对照

| 维度 | T3 Code 当前方案 | Bubble 当前方案 | 判断 |
|---|---|---|---|
| 数据窗口 | 最近 10 user turns；旧页每次 20；服务端 keyset cursor | UI 首屏最近 10 user turns、旧页每次 20；后台仍解码最多 4,000 项的本地 projection | **主线程风险已解除；页级持久化仍待完成** |
| UI 虚拟化 | LegendList + key/type + estimated size | 小/中 transcript 用稳定 `VStack`，超过 180 rows/source items 才用 `LazyVStack` | Bubble 是针对 SwiftUI 的合理策略，不应机械照搬 |
| 行稳定性 | row variant 浅比较，复用对象 identity | stable row ID、`mainRowRenderKey`、`EquatableSection`；assistant 文本拆成稳定 render units，只重建 live tail | 方向一致；仍需验证全局 `ChatStore` observation 是否击穿行边界 |
| 流式提交 | 默认整段缓冲；24K 字符 safety spill | 原始 chunk 聚合到显示脉冲；随 rendered bytes 从 120/60 降到 30/20 Hz | Bubble 保留实时反馈更好，但大输出更新频率本身低于 60 Hz |
| 自动跟随 | 40 px strict live-edge；MVCP；折叠切换临时冻结 | `TranscriptFollowState` 区分 following/free scrolling；observer 保持可见锚；busy 才随 revision | 方向一致，需加入 prepend / disclosure 的回归门禁 |
| 富文本 | Suspense plain fallback；完成态 LRU 500/50 MB | prose parse/chunk cache 256/12 MB；代码、Mermaid、Math 另有渲染路径 | 应为所有富渲染建立统一“live cheap / settled rich / bounded cache”规则 |
| 持久化 | 活跃时不写；settled 后 500ms debounce；缓存携带 page metadata | active stream 不写；约 0.4s debounce；异步保存和后台整份恢复 | 主线程原则一致；Bubble 尚缺 page metadata 与按页 decode |
| 状态生命周期 | thread/slice atom family，闲置 5 分钟释放 | 单个 `ChatStore` 承担 transcript、session、streaming 和较多 UI 状态 | 建议拆出 transcript projection / row snapshot store |
| 性能证据 | 20K activities <100ms CPU test；无 FPS SLO | 600-turn 滚动 fixture；p95 ≤17ms、p99 ≤18ms；Session tab selection ≤220/260ms | Bubble 已建立 60 Hz 核心滚动门禁；仍需扩展重富文本组合 |

Bubble 对照文件：

- [`Sources/Bubble/OverlayView.swift`](../../Sources/Bubble/OverlayView.swift)：`ScrollView`、VStack/LazyVStack 选择、stable row ID / equatable row、下一 display pulse 合并跟随请求。
- [`Sources/Bubble/TranscriptInteractionPolicy.swift`](../../Sources/Bubble/TranscriptInteractionPolicy.swift)：`lazyRowThreshold = 180`、显式 follow 状态机、visible-content anchor。
- [`Sources/Bubble/TranscriptRenderPlan.swift`](../../Sources/Bubble/TranscriptRenderPlan.swift)：4,000 项持久化保护线、assistant paragraph/chunk 稳定 render units、只重建 live tail。
- [`Sources/Bubble/OverlayRenderPolicy.swift`](../../Sources/Bubble/OverlayRenderPolicy.swift)：按 64K / 256K / 768K rendered bytes 调节到 120 / 60 / 30 / 20 Hz，active stream 不落盘。
- [`Sources/Bubble/ChatStore.swift`](../../Sources/Bubble/ChatStore.swift)：流式 chunk 缓冲、显示脉冲提交、settled 后异步持久化、session projection 读取与解码。
- [`Sources/Bubble/TranscriptProse.swift`](../../Sources/Bubble/TranscriptProse.swift)：语义解析缓存 256 项 / 12 MB。
- [`scripts/run_transcript_scroll_benchmark.sh`](../../scripts/run_transcript_scroll_benchmark.sh)：当前滚动门禁。
- [`scripts/run_session_switch_benchmark.sh`](../../scripts/run_session_switch_benchmark.sh)：当前 session 切换门禁。

## 四、应用到 Bubble 的实施路线

### P0：先定义“操作反馈高于 60 帧”究竟测什么

帧率和操作延迟不是同一个指标。建议把目标拆成三条可审计 SLO：

1. **连续交互流畅度**：滚轮/拖动滚动、展开折叠、窗口 resize、流式到达同时滚动时，60 Hz 设备主线程 frame p95 ≤ 16.67 ms，p99 ≤ 33.3 ms，空白连续帧为 0。
2. **离散操作首反馈**：点击、键入、Session tab selection 到第一帧视觉确认 ≤ 16.67 ms；完整内容可以后续渐进呈现。
3. **内容可用延迟**：Session tab 首个缓存窗口出现单独计时，不伪装成 FPS。当前 220/260 ms 的 Session tab selection 阈值应保留为阶段指标，再按窗口水合结果收紧。

若“全部高于 60 帧”按字面要求任何一帧都不超过 16.67 ms，应新增 max-frame 门禁；但后台调度、录屏和 CI 噪声会使它比 p95 门禁脆弱，应在隔离性能机上执行，不能只靠普通 CI。

现有 `run_transcript_scroll_benchmark.sh` 的 p95 20 ms 约等于 50 FPS，必须先降到 16.67 ms 以下，才可对 60 FPS 作合格声明。

### P0：将 session projection 改为可分页的本地格式

推荐数据契约：

```text
SessionManifest
  sessionID
  generation / sequence
  newestPageID
  isHistoryComplete

TranscriptPage
  pageID
  sessionID
  generation / sequence
  beforeCursor
  hasMore
  ordered stable item IDs
  items
```

实施要点：

- 首屏读取最近 10–20 个用户回合，不是固定行数；tool fan-out 随回合归组。
- 旧页每次 20 回合，使用排他的稳定 cursor，不用 offset。
- page decode 放后台 executor；主线程只原子发布已解码的 immutable row snapshots。
- Conversation branch change/revert/delete 提升 generation；旧 generation 的在途页不得合并。
- live tail 和旧页都携带 sequence；旧页领先时等待 tail 追平，落后时丢弃并重拉。
- manifest 明确 `hasMore/isHistoryComplete`，partial cache 永远不能被旧版本或恢复路径误认成完整 transcript。
- 迁移期保留旧 JSON 只读导入：后台切页写新格式，成功后原子切 manifest；不要在首个打开动作里同步完成全量迁移。

这一步会同时降低 Session tab selection 的磁盘读取、JSON decode、对象创建和 SwiftUI 初始 diff，而不仅是“屏幕上少画几行”。

### P1：把 transcript observation 从 `ChatStore` 全局变化中隔离

目标形态：

- `SessionChromeState`：模型、权限、busy、composer、side stage 等；
- `TranscriptProjectionState`：当前窗口的 row IDs、分页状态、live-tail ID；
- `TranscriptRowSnapshot`：按 ID 读取的不可变行快照；
- 只有 live tail / tool progress 对应 snapshot 变化，completed rows 保持对象 identity。

派生 plan 使用“上次 ID → snapshot”映射做 variant-specific 浅比较，完全不变时复用整份 rows 数组；定时器、hover、composer 输入不能进入每行共享依赖。这是 T3 Code 结构共享模式在 SwiftUI Observation 上的等价实现，而不是照抄 React context。

### P1：流式 Markdown 使用“可见尾部便宜、已完成块丰富”

保留 Bubble 的实时反馈，不采用 T3 Code 默认整段隐藏。建议：

- 原始 delta 在 actor/后台累积；主线程最多每个 display pulse 提交一次。
- 未闭合、仍增长的 Markdown/code/mermaid 区域用 plain/live-tail 视图；完成段落或 closed fence 才解析并富渲染。
- 完成段的 AST/highlight/layout 结果按 content hash + theme + width bucket 缓存；所有缓存同时限制 count 与 estimated bytes。
- 不支持的 code language、过大 Mermaid、渲染异常都必须立即降级为 plain text，而不是阻塞整条消息。
- 大输出下可以降低“文本内容更新频率”，但点击、滚动、hover、停止按钮等操作反馈仍需每帧可用；性能报告必须区分这两者。

当前 30/20 Hz 大文本刷新策略是一项明确的吞吐取舍。它可以保证 UI 仍以 60 FPS 滚动，却不能声称“生成文字每秒更新 60 次”。若产品目标要求文字也 ≥60 Hz，需要先把 live path 降成 O(delta 或 tail)，不能只把 interval 强行改成 1/60。

### P1：保留现有滚动状态机，补足锚定的可测边界

Bubble 已有正确骨架，建议补齐以下自动化断言：

- 用户离开底部一个很小但明确的阈值后，流式 chunk 不改变 visible origin；
- 回到底部阈值内才重新 live-follow；
- prepend 旧页前后，首个完全可见 row 与像素 offset 保持不变；
- 展开/收起长 tool group 或 Mermaid 时，以触发行作锚，不能跳到底；
- programmatic follow 产生的 AppKit scroll event 不得误判为用户中断；
- Session tab selection 后旧 Session tab 的 delayed follow / page response 被 generation token 丢弃。

40 px 是 T3 Code 针对 Web 列表的经验值，Bubble 应基于 Mac 滚轮、触控板和现有 `TranscriptScrollObserver` 校准，而不是直接复制数值。

### P2：把性能 fixture 扩到“系统最坏组合”

建议至少形成以下矩阵：

| 场景 | 数据量 | 同时操作 | 必测指标 |
|---|---:|---|---|
| 普通长会话 | 600 turns | 物理滚轮连续滚动 | frame p50/p95/p99、blank frames、mounted anchors |
| 持久化上限 | 4,000 items | 首次打开 + 快速切 Session tab | first feedback、first window、full settle、主线程 stall |
| 重富文本 | 多个 100KB code/table/mermaid | 展开折叠 + resize | frame time、parse/highlight time、cache bytes |
| 活跃长回答 | >768KB rendered text | streaming + 历史滚动 | 操作 FPS、文字 commit Hz、tail rebuild cost |
| 分页竞争 | 多页 + live stream | 连续 load earlier + revert/switch | 锚定误差、重复/丢失 IDs、stale merge 数 |
| 内存回收 | 打开 20+ sessions | 来回切换、闲置 | retained rows、cache bytes、RSS 回落 |

除了脚本合成事件，发布验收还应采一条真实 macOS HID/触控板路径，配合 `CADisplayLink`/signpost 和主线程采样；否则只能证明 reducer 或模拟 layout 快，不能证明用户手下的物理反馈。

## 五、建议的验收门

完成以下条件后，才建议对外宣称 Bubble 的目标交互达到 60 FPS：

- [x] 最近窗口独立发布，打开 4,000-item session 不在 UI 线程同步解码整份 transcript。
- [ ] load earlier 在 live stream、Conversation branch revert/change、Session tab selection 竞争下无重复、无丢失、无陈旧合并。
- [ ] completed rows 在 live-tail 更新中保持 identity，性能日志显示每 pulse 只重算尾部。
- [ ] 600-turn 与 4,000-item 物理滚动的 frame p95 ≤16.67 ms，连续空白帧为 0。
- [ ] streaming + scroll、展开重代码、Mermaid、resize 各自通过相同帧预算。
- [ ] click/key/Session tab selection 的第一帧视觉确认 ≤16.67 ms。
- [ ] 缓存同时有 count/bytes 上限，打开多 session 后 RSS 可回收。
- [ ] 性能记录同时报告 animation FPS、text commit Hz 和 content-ready latency，不把三者混成一个数字。

## 最终判断

T3 Code 最有价值的设计不是“用了虚拟列表”，而是把长会话当成**可增量加载、可校验合并、可回收的状态流**。Bubble 的渲染层已经吸收了大部分正确思想；下一阶段的主要瓶颈更可能位于整份 session 水合、全局 observation 扇出，以及流式富文本仍按增长前缀重复工作的路径。

按优先级，应先做窗口化 projection 和真实 16.67 ms 门禁，再做 row-store 拆分和 live-rich-render 两阶段化。完成这些前，最多可以说“Bubble 已有面向长会话的渲染优化”，还不能严谨地说“全部操作反馈稳定高于 60 帧”。

## 六、本次落地与实测结果

本次研究后已在 Bubble 落地第一阶段，而不是停留在路线建议：

- 主 transcript 首屏投影最近 10 个 user turns，顶部显式 “Load earlier”，每次扩展 20 turns；完整 `items`、持久化内容和 Pi session 上下文不被截断。
- `EquatableSection` 改为保存延迟 row builder。此前 builder 在等值门判断前就构造完整 `mainTranscriptRow`，主线程采样显示 `NSHostingView.layout → AttributeGraph → ForEachChild.updateValue` 是主要热栈。
- session transcript 的文件读取、JSON decode 和清理转到后台队列，UI 线程只原子发布当前 10-turn 窗口并预热该窗口；切换或新建 Session tab 会用 generation 丢弃陈旧恢复结果。
- legacy replay 修复从“每条 assistant 扫描所有此前完整回复”的二次增长路径，收敛为每条仅做 self-repeat、只让最终 assistant 检查旧回复；600-turn 首窗就绪从约 4.74s 降到 307ms（含基准固定 300ms 等待）。恢复完成前冻结持久化，避免 setup 更新覆盖尚未合并的历史。
- 滚动门禁从 p95 20 ms / p99 34 ms 收紧到 p95 17 ms / p99 18 ms；外接 DELL U2719DC 当前为 60 Hz，实测 vsync 间隔约 16.67 ms。
- 600-turn fixture 的未修改基线为 p95 78.15 ms / p99 84.73 ms；落地后首屏 10 turns 为 p95 16.74 ms / p99 16.82 ms，展开到 30 turns 为 16.72 / 16.84 ms，展开到 50 turns 为 16.72 / 17.28 ms，三组 blank frames 均为 0。
- 最终打包产物的 4,054-item / 4.73MB fixture 为 p95 16.75ms / p99 16.80ms、blank frames 0；600 次随机挂载审计无空白且 anchor error 0px，Session tab selection 总耗时 83.25ms。
- 物理 UI 滚动到分页边界后点击 “Load earlier”，history rail 从 10 变为 30 turns，Turn 590 的屏幕位置保持不变；随机挂载审计 600 samples 的 anchor error 为 0 px。

这证明当前长会话的核心滚动路径在 60 Hz 显示器上不再持续丢帧。它仍不等于“所有 Bubble 操作在所有机器上永远没有单帧调度尖峰”，也尚未完成上述 P0 的页级磁盘格式迁移；后续应继续用本节门禁约束 session 水合、流式富文本和重型 Mermaid/代码展开。
