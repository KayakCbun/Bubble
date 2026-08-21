# fx 能否接自定义模型提供商 / 端点

结论先说：**官方产品路径绑死 Vercel AI Gateway。** 不能在 `~/.fx/settings.json` 里填自定义 `base_url` / provider。有两条绕路，都不等于「随便配一个 HTTPS 端点」。

## 官方认证和模型从哪来

[Authentication](https://fx.sh/docs/getting-started/authentication.md) 只认三种凭证：

1. `fx login`（Vercel OAuth，存在 `~/.fx/auth.json`）
2. `AI_GATEWAY_API_KEY` / `fx setup`（Vercel AI Gateway API key）
3. `VERCEL_OIDC_TOKEN`（Vercel 运行时）

[Configuration](https://fx.sh/docs/configure-fx/configuration.md) 的 profile 字段里，模型是 **Gateway model ID**（默认 `zai/glm-5.2-fast`），没有 provider、endpoint、base URL。凭证来源只能是 `vercel_oidc_token` / `ai_gateway_api_key` / `fx_login` / `stored_key`。

[Models](https://fx.sh/docs/configure-fx/models.md) 写明：fx 使用 **Vercel AI Gateway catalog**。`FX_MODEL` 只覆盖 ID，不换网关。

初始化失败文案也写死了：`Fx needs access to Vercel AI Gateway.`（[Troubleshooting](https://fx.sh/docs/using-fx/troubleshooting.md)）

## 流量怎么走

[Data and privacy](https://fx.sh/docs/using-fx/data-and-privacy.md)：请求按 [AI SDK Language Model Specification](https://ai-sdk.dev/docs/foundations/providers-and-models) 发出，**AI Gateway 收到后再路由到具体模型商**。

本机 `fx` 二进制（v0.0.4）里硬编码默认推理 URL：

```text
https://ai-gateway.vercel.sh/v3/ai/language-model
```

这是 AI SDK LM spec v3，不是 OpenAI `/v1/chat/completions`。

## 能做的绕路

### 1. Gateway BYOK（仍然过 Vercel）

[Vercel BYOK](https://vercel.com/docs/ai-gateway/authentication-and-byok/byok)：在 Vercel 团队里塞 Anthropic/OpenAI/Azure/Vertex/Bedrock 的 key。Gateway 用你的 key 打供应商，**请求仍要先认证进 Vercel**。付费档；失败会回落到系统凭证并计费。这解决的是「用自己的供应商合同」，不是「自己的 endpoint」。

### 2. 本机 loopback 网关（唯一能换 base URL 的口子）

同一份隐私文档写了：fx 可以用 **compatible loopback endpoints** 做模型发现和生成，用于 hermetic / 本地推理。

二进制里有未写入公开配置表的环境变量：

| 变量 | 行为 |
| --- | --- |
| `FX_GATEWAY_BASE_URL` | 覆盖 Gateway base。非 loopback HTTP 会被丢掉：`ignoring FX_GATEWAY_BASE_URL: not loopback http` |
| `FX_GATEWAY_CHAT_URL` | 另有 chat URL 覆盖（同样未文档化） |

因此可以：

```bash
# 本机起一个讲 AI SDK LM spec 的代理，再转你们的 OpenAI-compatible / 内部网关
FX_GATEWAY_BASE_URL=http://127.0.0.1:8787 fx acp --model local/whatever
```

不能：

```bash
FX_GATEWAY_BASE_URL=https://api.deepseek.com
FX_GATEWAY_BASE_URL=https://your-corp-gateway.example
```

HTTPS 远程、非 loopback 一律忽略。要把公司网关接进来，得在本机起 HTTP 反代（`127.0.0.1`），并实现 Gateway 那套 `/v3/ai/language-model`（以及很可能 `/coding-agent/v1/models`、`/coding-agent/v1/credits`），不能假设 Ollama 的 `/v1/chat/completions` 能直接用。

这是给本地模型 / 封闭网络准备的，不是一等公民的多供应商配置。

## Overlay 层面改不掉这个限制

`fx-overlay` 只是 ACP 客户端：拉起 `fx acp`，发 `session/prompt`。推理供应商在 **fx 进程内部** 决定。Overlay 里换环境变量只能走上面的 loopback 口子，不能给 fx 加上任意 HTTPS provider。

## 如果目标是「任意提供商 + 任意端点」

fx 不是合适的 Agent Core。ACP 本身不绑 Vercel；换一个支持自定义 base URL 的 ACP server（或自写一层）即可，overlay 协议不用推倒。候选方向：

- 继续用 fx，只接 **Gateway 上已有的模型 / BYOK**
- 本机 loopback 代理，把内部 OpenAI-compatible 端点伪装成 Gateway
- 换 Agent Core（Claude Code ACP、Codex、pi、自研），overlay 继续当 UI

## 来源

- https://fx.sh/docs/getting-started/authentication.md
- https://fx.sh/docs/configure-fx/configuration.md
- https://fx.sh/docs/configure-fx/models.md
- https://fx.sh/docs/using-fx/data-and-privacy.md
- https://fx.sh/docs/using-fx/troubleshooting.md
- https://vercel.com/docs/ai-gateway/authentication-and-byok
- https://vercel.com/docs/ai-gateway/authentication-and-byok/byok
- 本机 `fx` v0.0.4 二进制字符串：`FX_GATEWAY_BASE_URL`、`ignoring FX_GATEWAY_BASE_URL: not loopback http`、`https://ai-gateway.vercel.sh/v3/ai/language-model`
