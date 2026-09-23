# AGENT.md — imagine

本文件面向参与本仓库开发的 AI agent 与人类贡献者，约定项目目标、边界、架构与路线图。
修改代码前请先阅读本文件，保持模块边界与既有约定。

## 1. 项目目标

`imagine` 是一个**通用图像/视频生成 CLI**，为 AI agent 调用而设计。核心目标：

- **统一前端参数**：调用方只关心 prompt、尺寸、时长、首帧等通用参数，不关心后端差异。
- **按模型名路由后端**：通过 `-m <model>` 在配置中查到 `backend`，分发到对应实现。
- **多后端、可扩展**：新增模型 = 新增一个 body builder + 注册一行，不改动调用方。
- **内置视频能力**：Seedance（火山方舟）与 Gemini Omni（Interactions API）为编译进二进制的后端，
  同步/异步差异由后端声明的 flow 决定；密钥只从环境变量取（`ARK_API_KEY` / `GEMINI_API_KEY`）。
- **显式花钱边界**：会携带凭证的 provider 任务在派发前打印任务清单并要求 `--authorize-spend`
  （或 `IMAGINE_AUTHORIZE_SPEND=1`）；二进制里没有任何价格数据，所以只报"无法估价"，不猜价格。
- **同模型多端点并发**：一个模型可配置多个 `endpoints`（不同 URL/KEY），调度器并发分摊请求。
- **agent 友好**：`--json` 输出机器可解析结果；`--dry-run` 只打印请求体；退出码区分成功/失败/用法错误。
- **单一静态二进制**：纯 Zig + `std.http.Client`，不依赖 curl/jq/base64/ffmpeg 等外部命令。

## 2. 边界（不做什么）

- **不是**长驻服务 / HTTP server，也**不是**库；它是一次性 CLI 进程。
- **不做**图像/视频后处理（裁剪、放大、转码、拼接、加水印）——只负责"调用模型 → 落盘原始产物"。
- **不托管**回调：异步任务用轮询（`--poll-interval`/`--timeout`）等待，不注册 webhook。
- **不内置**模型权重或本地推理；只对接 HTTP 模型服务。本地模型（Qwen-Image-2.1、
  自托管 LTX-2）由 `integrations/` 下的独立 server 进程托管，二进制里没有任何模型代码。
- **不管理**密钥分发；密钥来自环境变量或配置文件，由调用环境负责。
- **不重试 / 不限流**（当前阶段）：失败即如实上报，重试策略交给调用方。详见路线图。
- **不内嵌价格表**：`--authorize-spend` 只确认"这些任务会调用带凭证的端点"，不做金额估算，
  也不因模型/时长不同而改变判定。

## 3. 架构（src/）

数据流（同步后端）：`main → config → backend(dispatch) → backends/* (build body) → http → 解析 → scheduler 落盘`

数据流（异步视频后端）：`... → POST 建任务 → parseCreate → 轮询 pollUrl → parsePoll → 下载 → scheduler 落盘`

| 模块 | 职责 | 不应该做的事 |
|------|------|--------------|
| `version.zig` | 版本常量 | — |
| `types.zig` | 核心解耦类型：`GenRequest`/`InputImage`/`Endpoint`/`ModelConfig`/`BackendKind`/`AuthScheme`，以及后端路由元数据（`media()`/`flow()`/`defaultKeyEnv()`/`assetNeedsAuth()`） | 不含 IO / 网络 |
| `util.zig` | base64 编解码、MIME 推断、`~` 展开、扩展名、时间戳、key 脱敏、路径数字后缀 | 不含业务逻辑 |
| `config.zig` | 解析 TOML/JSON 配置、解析路径、`template`、`Env` 接口、从 env 取 key、挂载内置 presets | 不直接读 `std.process`（通过 `Env` vtable 注入，便于测试） |
| `presets.zig` | 内置模型预设（Ark Seedream/Seedance、Gemini Omni 的 URL + model id + 凭证 env），纯数据 | 不含逻辑；配置同名模型优先 |
| `wire.zig` | 共享 wire 辅助：异步任务结果类型（`TaskOutcome`/`PollOutcome`）、错误信封解析（`rootObject`/`apiError`，兼容数组包裹） | 不含 provider 语义、不做 IO（让 `backends/*` 不必反向依赖 `backend.zig`） |
| `http.zig` | `std.http.Client` 薄封装：`post`/`get` → `Response{status,body}` | 不懂任何模型语义 |
| `backends/openai_image.zig` | OpenAI-compatible `/v1/images/generations` 请求体（`size` 字符串） | 只构造 body，不发请求 |
| `backends/azure_flux.zig` | Azure FLUX 请求体（`width`/`height`，可选 `seed`） | 同上 |
| `backends/qwen_image.zig` | Qwen-Image 请求体（`size` 像素串或原生比例 token、`steps`、`seed`），调本地/自托管 server | 同上 |
| `backends/volcengine_image.zig` | 火山方舟 Seedream 请求体（`size` 档位或像素、`watermark`、`image` 参考图；无 `n`/`seed`） | 同上 |
| `backends/seedance.zig` | 火山方舟 Seedance 建任务体 + `parseCreate`/`pollUrl`/`parsePoll`（`content[]`、`status` 终态判定） | 不发起请求、不下载 |
| `backends/gemini_video.zig` | Gemini Interactions API（Omni）建任务体 + 三个解析器（`steps[].content[].uri`、Files `state`、下载 URL） | 同上 |
| `backends/ltx2_video.zig` | 自托管 LTX-2 服务建任务体（`prompt`/`duration`/`resolution`/`ratio`/`seed`/内联首帧）+ 三个解析器（契约见 `integrations/ltx2/`） | 不发起请求、不下载、不跑模型 |
| `backend.zig` | 后端注册 + `generate()` 编排（同步 / 异步建任务-轮询-下载）+ 共享响应解析（b64_json / url 回退 / error）+ 凭证头 | 不解析 CLI、不写文件 |
| `scheduler.zig` | 并发任务执行（`std.Thread` 原子认领）、落盘、进度上报、异步任务的 poll/timeout 传递 | 不构造请求体、不解析 CLI |
| `cli.zig` | 参数解析 + help 文本 | 不发网络请求 |
| `main.zig` | 入口 `main(init: std.process.Init)`、子命令分发、`--image` 读盘/下载、结果渲染、spend 授权边界（`authorizeSpend`） | 业务细节下沉到各模块 |

**唯一做进程级 IO（env/args/stdout）的是 `main.zig`**；其余模块通过参数/接口注入依赖，保持可测试、可解耦。

### 新增一个后端的步骤
1. 在 `types.zig` 的 `BackendKind` 增加变体（及 `fromString` 别名），并补齐路由元数据：
   `media()`、`flow()`、`defaultKeyEnv()`、`assetNeedsAuth()`、`inputImageStyle()`
   （`unsupported` 表示该后端不接受 `--image`，CLI 会直接报用法错误而不是静默忽略）。
2. 在 `src/backends/` 新增 `your_provider.zig`，实现 `buildBody(allocator, req) ![]u8`
   （异步后端这里就是"建任务"体）。
3. 在 `backend.zig` 的 `buildBody` dispatch 增加一个 switch 分支；
   若是异步后端，再在 `asyncImpl` 里登记 `parseCreate`/`pollUrl`/`parsePoll`
   （两处 switch 都是穷尽式，漏了编译不过）。
4. 同步后端若响应结构不同，扩展 `parseResponse`（当前支持 `data[].b64_json` 与
   `data[].url`，Seedream 复用同一形状）；异步后端在 `parsePoll` 里把终态映射成
   `done`/`api_error`，注意"HTTP 200 + status=failed"这类 provider 语义。
   解析器返回 `wire.TaskOutcome`/`wire.PollOutcome`，错误文案统一走 `wire.apiError`
   （它能识别 `{error:{…}}` 与 `[{error:{…}}]` 两种信封）。
5. 加单元测试（body 形状 + 解析器：pending/done/error 三条路径）；
   更新 `config.template`、`config.example.toml` 与 README/SKILL 文档。
6. 若是第一方 provider 的常用模型，在 `presets.zig` 加一条预设（纯数据，无新代码路径）。
7. 若后端依赖自托管服务（如 `qwen_image`），在 `integrations/<backend>/` 放
   server + 安装脚本 + README：服务端契约、安装、硬件要求与排障集中一处说明。

## 4. 配置 schema（`~/.imagine/config.toml`）

路径优先级：`--config <path>` > `$IMAGINE_CONFIG` > `~/.imagine/config.toml`；默认 TOML 不存在时兼容读取旧版 `~/.imagine/config.json`。

```toml
output_dir = "~/.imagine/outputs"
concurrency = 0 # 0=按端点数自动；>0 固定并发
poll_interval = 5 # 异步（视频）任务轮询间隔秒数
task_timeout = 600 # 单个异步任务的等待上限秒数

# 表键即 -m 的逻辑名，可自由增删改；逻辑名不写死在二进制里。
[models."<model-name>"]
backend = "openai_image" # openai_image | azure_flux | qwen_image
                         # | volcengine_image | seedance | gemini_video
                         # | ltx2_video（azure_image 为兼容别名）
api_model = "传给 API 的真实 model 字段"

[[models."<model-name>".endpoints]]
base_url = "https://.../images/generations" # 异步后端填"建任务"URL
api_key_env = "AZURE_OPENAI_APIKEY" # 从环境变量取 key
api_key = "可选：直接写死 key（优先于 env）"
auth = "bearer" # bearer | api-key | google_api_key | none（none = 本地无鉴权端点）

[models."<model-name>".defaults]
size = "1024x1024"
width = 1024
height = 1024
output_format = "png"
output_compression = 100
quality = "high"
steps = 40 # qwen_image：num_inference_steps
duration = 5 # 视频：秒
resolution = "720p" # 视频：480p | 720p | 1080p | 4k
ratio = "16:9" # 视频：宽高比 token
watermark = false # 火山方舟：图像默认 true，视频默认 false
```

参数优先级：**CLI 选项 > 模型 `defaults` > 内置缺省**。
密钥优先级：端点 `api_key` > 端点 `api_key_env` 指向的环境变量。
异步任务等待优先级：`--poll-interval`/`--timeout` > `poll_interval`/`task_timeout` > 内置缺省。

### 后端路由元数据（写在 `types.zig` 的 `BackendKind` 上）

| 方法 | 含义 |
|------|------|
| `media()` | `image` / `video`：决定默认扩展名（png/mp4）与 `--json` 落到哪个数组 |
| `flow()` | `sync`（一次请求出结果）/ `async_task`（建任务→轮询→下载） |
| `defaultKeyEnv()` | ephemeral 模式未指定 `IMAGINE_API_KEY_ENV` 时的凭证 env（Ark→`ARK_API_KEY`、Gemini→`GEMINI_API_KEY`、LTX-2→`LTX2_API_KEY`，其余→`AZURE_OPENAI_APIKEY`） |
| `assetNeedsAuth()` | 产物 URL 是否必须带凭证下载（Gemini Files 需要；Ark/Azure 的预签名 URL 不能带，Azure 会因 SAS + Authorization 同时出现而拒绝；本地 LTX-2 服务不需要） |
| `inputImageStyle()` | 统一 `--image` 如何传给 provider：`url_or_data_url` / `bytes_base64` |

### 内置 presets（`presets.zig`）

`ARK_API_KEY` / `GEMINI_API_KEY` 就位后，无需任何配置文件即可调用内置模型
（`imagine models` 里 `source = "preset"`）：Seedance 视频 3 个、Seedream 图像 2 个、
Gemini Omni 视频 1 个。规则：

- 配置文件里同名模型**永远优先**（可覆盖 URL / `api_model` / defaults / 多端点）；
- 预设只提供 URL、model id、凭证 env，不提供 defaults，也不含任何密钥；
- provider 的 model id 会过期，预设按"当前可用"维护，不做历史兼容；
- 无配置文件且无 ephemeral env 时，配置来源标记为 `source = "preset"`。

### 无配置文件（ephemeral）

当 `--config` / `$IMAGINE_CONFIG` / 默认 toml / legacy json **均不存在**时，可从 env 合成单模型：

| 变量 | 含义 |
|------|------|
| `IMAGINE_BASE_URL` | 必填，endpoint（异步后端填建任务 URL） |
| `IMAGINE_MODEL` | 必填，逻辑名（兼默认 api_model） |
| `AZURE_OPENAI_APIKEY` / `IMAGINE_API_KEY` / `IMAGINE_API_KEY_ENV` | 凭证；默认 env 随 `IMAGINE_BACKEND` 变化（Ark→`ARK_API_KEY`、Gemini→`GEMINI_API_KEY`） |
| `IMAGINE_BACKEND` / `IMAGINE_AUTH` / `IMAGINE_API_MODEL` / `IMAGINE_SIZE` / `IMAGINE_STEPS`… | 可选 |
| `IMAGINE_DURATION` / `IMAGINE_RESOLUTION` / `IMAGINE_RATIO` / `IMAGINE_WATERMARK` / `IMAGINE_POLL_INTERVAL` / `IMAGINE_TASK_TIMEOUT` | 可选（视频参数与异步等待） |

`IMAGINE_AUTH=none` 表示本地无鉴权端点（如 `qwen_image`），此时无需任何凭证。

`imagine models` / `config show` 的 `source` 为 `file`、`ephemeral` 或 `preset`。
仅一个模型时可省略 `-m`；多模型/多端点仍用配置文件。

### 完全无配置（preset-only）

配置文件与 ephemeral env 都不存在时，配置来源为 `preset`：`models` 为空、`presets` 为内置目录，
`-m <preset 名>` 仍可直接生成（凭证从 env 取）。这是"内置支持 + 密钥用 env"的最短路径：

```bash
ARK_API_KEY=... imagine generate -m doubao-seedance-2-5-260628 -p "a fox" -o fox.mp4
```

## 5. CLI 契约（对 agent 稳定）

```
imagine generate -m <model> -p <prompt> [-o -n -s --width --height \
        --format --compression --quality --seed --steps \
        --image --watermark/--no-watermark \
        --duration --resolution --ratio --poll-interval --timeout \
        -c --config --json --dry-run --authorize-spend -q]
imagine batch <manifest.json> [-c --poll-interval --timeout --json --authorize-spend]
imagine models [--json]
imagine config path | init [--force] | convert | show
imagine version | help
```

- 退出码：`0` 成功；`1` 运行失败（含部分失败）；`2` 用法错误。
- `--json` 结果对象：
  `{ ok, media, model, backend, requested, succeeded, failed, images:[{path,bytes}], videos:[{path,bytes}], errors:[] }`。
  `media` = `image` | `video`，产物落在对应数组，另一个恒为空数组（形状稳定，便于 agent 解析）。
- batch manifest 每个 job 额外支持 `duration`、`resolution`、`ratio`、`image`、`watermark`；
  `--json` 的 `tasks[]` 每项带 `media`。
- 多张图/多条视频 → 文件名自动加 `-1 -2 …` 数字后缀；`-n` 对视频是"发起 n 个 provider 任务"。
- 异步后端把 provider 的失败（HTTP 200 + `status: failed`）如实转成 `errors[]` 文案，
  例如 `task cgt-… failed: …`；超时报 `task <id> did not finish within <n>s`。
- **花钱授权边界**：任务清单里有"带凭证的端点"（`auth != "none"` 且 key 已解析）时，
  `generate` / `batch` 在发出任何 HTTP 请求前把计划打到 stderr（条数 + 每个任务的
  model/backend/size/duration/resolution/ratio，以及 `cost estimate: unavailable`），
  没有 `--authorize-spend` 或 `IMAGINE_AUTHORIZE_SPEND=1` 就以退出码 `2` 拒绝。
  本地无鉴权端点、以及缺凭证（本来就会失败）的任务不计入、也不被拦。
- `imagine models --json` 每项为
  `{name, backend, media, api_model, endpoints, credential_status, availability, source}`：
  `credential_status` = `missing` | `partial` | `configured` | `not_required`（只说明凭证是否就位），
  `availability` 恒为 `unknown` —— 不发起付费调用就无法确认账号是否开通该模型，
  所以不再用 `ready` 暗示"可用"。

## 6. 路线图

**已完成**
- 核心架构（types/config/http/backend/scheduler/cli/main）与单元测试。
- OpenAI 兼容 `openai_image`（`/v1/images/generations`）与 Azure `azure_flux`。
- **视频生成（异步任务）**：`seedance`（火山方舟 `contents/generations/tasks`：建任务 →
  轮询 `status` → 下载 `content.video_url`）与 `gemini_video`（Gemini Interactions API /
  Omni：`steps[].content[].uri` → Files `state` → `:download?alt=media`）。统一参数
  `--duration/--resolution/--ratio/--image`，`--poll-interval/--timeout` 与
  `poll_interval/task_timeout` 控制等待；`media()`/`flow()` 元数据决定默认扩展名与 `--json` 形状。
- **火山方舟生图**：`volcengine_image`（Seedream：`size` 档位或像素、`watermark`、
  `image` 参考图；无 `n`/`seed`，响应复用 OpenAI `data[]` 形状）。
- **内置 presets**（`presets.zig`）：Ark Seedance ×3 / Seedream ×2、Gemini Omni ×1；
  仅凭 `ARK_API_KEY` / `GEMINI_API_KEY` 即可无配置文件调用，`imagine models` 标注 `source=preset`。
- 模型名由配置动态声明；`imagine models` 发现可用模型。默认密钥 env：`AZURE_OPENAI_APIKEY`。
- **Ephemeral 无配置文件模式**：无文件时用 `IMAGINE_BASE_URL` + `IMAGINE_MODEL` + 凭证合成单模型；`source` 标注；单模型可省略 `-m`。
- 同模型多端点并发调度；`--json`/`--dry-run`/batch；config init/show/path。
- `install.sh`（curl 一键，OS 探测，下载预编译二进制并校验 SHA-256）、`Makefile`、`skills/imagine` 技能。
- CI（Linux/macOS/Windows 构建+测试+`zig fmt`，另有 ubuntu 上的 `svg-overlay` 构建与
  冒烟测试）与 release 工作流：tag 触发，在原生 runner 上构建 Linux/macOS/Windows ×
  `x86_64`/`arm64` 六个目标并发布 GitHub Release。
- **发布二进制默认带 SVG 能力**：每个目标先在原生 runner 上 `cargo build -p resvg-capi`
  产出 `libresvg.a`（resvg 0.47.0，与 `vendor/resvg/resvg.h` 同版本），再以
  `-Dsvg-overlay=true -Dresvg-lib=…` 链接，并对产物跑 `svg render`/`text render`/`png compose`
  冒烟测试；唯一例外是 `imagine-windows-aarch64.exe`（无法交叉构建 resvg 静态库）。
- **自托管 LTX-2 视频**：`ltx2_video` 后端（建任务 → 轮询 → 下载，首帧内联 base64）+
  `integrations/ltx2/`（wire 契约文档 + 纯标准库参考服务，`--t2v-cmd/--i2v-cmd` 模板
  适配任意本地 runtime，`--mock` 可无权重联调）；权重与推理仍留在服务侧。
- **显式花钱授权**：`--authorize-spend` / `IMAGINE_AUTHORIZE_SPEND=1`，见 §5。
- **模型可用性语义修正**：`ready` 布尔值换成 `credential_status` + `availability=unknown`。
- **Qwen-Image-2.1 可选集成**：`qwen_image` 后端（统一参数 → `size`/`num_inference_steps`/
  `seed`/`output_format`）、`auth = "none"` 无鉴权端点、`--steps` 与 `IMAGINE_STEPS`，
  以及 `integrations/qwen-image/`（diffusers server + 安装脚本 + 文档）；同一契约也兼容
  vLLM-Omni 的 `/v1/images/generations`。

**近期**
- HTTP 超时与有界重试（指数退避，仅幂等失败）；异步任务当前"失败即上报、不重试"。
- Veo（`generateContent` + `:predictLongRunning`）——与 Omni 的 Interactions API 是两套
  协议，需要独立后端，暂未接入。
- 更多后端：Google Gemini 图像、Stability、Replicate。
- 图生图 / 编辑（input image、mask）参数通路；`integrations/qwen-image` 的 server 已
  支持 `image`/`images`，CLI 参数补齐后即可直接接上 Qwen-Image-2.1 的编辑能力。
- 视频续写/编辑（Omni 的 `previous_interaction_id`、Seedance 的 `last_frame`）、
  异步任务的 webhook（`callback_url`）与本地任务缓存（同 id 断点续传）。

**远期**
- 速率限制感知调度（按端点配额）、流式进度、结构化日志。

## 7. 开发约定

- 目标 Zig 版本：见 `build.zig.zon` 的 `minimum_zig_version`（当前 **0.16.0**）。
- 常用命令：`make build` / `make test` / `make e2e` / `make run` / `make install` / `make fmt`。
- 提交前：`zig build test` 必须通过；`zig fmt src/*.zig` 保持格式。
- 单元测试覆盖 body 形状与解析器；**HTTP 编排（建任务→轮询→下载、落盘、`--json`）由
  `scripts/e2e.sh` 验证**，它用 `scripts/mock_providers.py`（Ark / Gemini 的本地替身，
  按文档 wire format 实现，只验证 imagine 侧）跑真实客户端路径，不需要网络与密钥。
- 保持模块单一职责与上表边界；新增后端遵循 §3 步骤。
- 注释只解释"为什么"，不复述"做什么"。

### 发布流程

> **仓库拓扑**：`talkincode/imagine`（fork）是**发布主仓库** —— `install.sh`、Homebrew tap
> 与 README 的下载地址都指向它；`jamiesun/imagine` 是**源仓库**，只做代码镜像（同步命令见
> 本节末尾）。发布只在 fork 上进行。
>
> **为什么用脚本**：`talkincode/imagine` 是 `jamiesun/imagine` 的 **fork**，而 GitHub
> 不为 fork 的 push 事件创建 workflow 运行（本仓库历史里 push 触发次数为 0，
> `workflow_dispatch` 正常；API 显式 enable workflow 后仍然如此）。也就是说
> `git push --tags` **不会**发版，必须显式把 tag 交给 workflow。
>
> 一条命令完成全部步骤（bump → 本地测试 → tag → push → 触发发布 → 跟随日志）：
>
> ```bash
> scripts/release.sh 0.4.0        # 发新版本
> scripts/release.sh --current    # 发当前 src/version.zig 里的版本
> scripts/release.sh 0.4.0 --no-watch
> ```
>
> 只想手动触发一次已有 tag 的发布：
> `gh workflow run release -R talkincode/imagine -f tag=vX.Y.Z`。

1. 改 `src/version.zig` 的 `string`（如 `0.2.0`），同步 `build.zig.zon` 的 `version`
   （`scripts/release.sh X.Y.Z` 会自动完成这一步并提交）。
2. 提交后打 tag 并推送：`git tag v0.2.0 && git push origin v0.2.0`
   （脚本会做，并额外 dispatch 一次 release workflow）。
3. `.github/workflows/release.yml` 自动构建六平台（原生 runner；带 SVG 的目标先构建
   `resvg-capi` 静态库再 `-Dsvg-overlay=true` 链接，并做 svg/text/compose 冒烟测试）、
   打包技能与 `SHA256SUMS`、创建 Release。
   tag 必须与 `src/version.zig` 一致，否则 workflow 报错中止。
4. 资产命名：`imagine-<os>-<arch>`（Windows 带 `.exe`），与 `install.sh` 下载路径一致。

### 同步代码到源仓库

fork 的 push 不触发 workflow，源仓库的 push 会（CI 在那边跑得起来）。代码镜像同步：

```bash
git remote add source git@github.com:jamiesun/imagine.git   # 只需一次
git push source main
```

**不要**把 tag 推到源仓库：那边的 `release` 工作流是 `on: push: tags`，会在两个仓库
各生成一份 Release（且与 fork 的产物重复）。
