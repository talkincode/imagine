# AGENT.md — imagine

本文件面向参与本仓库开发的 AI agent 与人类贡献者，约定项目目标、边界、架构与路线图。
修改代码前请先阅读本文件，保持模块边界与既有约定。

## 1. 项目目标

`imagine` 是一个**通用图像生成 CLI**，为 AI agent 调用而设计。核心目标：

- **统一前端参数**：调用方只关心 prompt、尺寸、数量等通用参数，不关心后端差异。
- **按模型名路由后端**：通过 `-m <model>` 在配置中查到 `backend`，分发到对应实现。
- **多后端、可扩展**：新增模型 = 新增一个 body builder + 注册一行，不改动调用方。
- **同模型多端点并发**：一个模型可配置多个 `endpoints`（不同 URL/KEY），调度器并发分摊请求。
- **agent 友好**：`--json` 输出机器可解析结果；`--dry-run` 只打印请求体；退出码区分成功/失败/用法错误。
- **单一静态二进制**：纯 Zig + `std.http.Client`，不依赖 curl/jq/base64 等外部命令。

## 2. 边界（不做什么）

- **不是**长驻服务 / HTTP server，也**不是**库；它是一次性 CLI 进程。
- **不做**图像后处理（裁剪、放大、格式转换链路）——只负责"调用模型 → 落盘原图"。
- **不内置**模型权重或本地推理；只对接远程模型 API。
- **不管理**密钥分发；密钥来自环境变量或配置文件，由调用环境负责。
- **不重试 / 不限流**（当前阶段）：失败即如实上报，重试策略交给调用方。详见路线图。

## 3. 架构（src/）

数据流：`main → config → backend(dispatch) → backends/* (build body) → http → 解析 → scheduler 落盘`

| 模块 | 职责 | 不应该做的事 |
|------|------|--------------|
| `version.zig` | 版本常量 | — |
| `types.zig` | 核心解耦类型：`ImageRequest`/`Endpoint`/`ModelConfig`/`BackendKind`/`AuthScheme` | 不含 IO / 网络 |
| `util.zig` | base64 解码、`~` 展开、扩展名、时间戳、key 脱敏、路径数字后缀 | 不含业务逻辑 |
| `config.zig` | 解析 JSON 配置、解析路径、`template`、`Env` 接口、从 env 取 key | 不直接读 `std.process`（通过 `Env` vtable 注入，便于测试） |
| `http.zig` | `std.http.Client` 薄封装：`post`/`get` → `Response{status,body}` | 不懂任何模型语义 |
| `backends/openai_image.zig` | OpenAI-compatible `/v1/images/generations` 请求体（`size` 字符串） | 只构造 body，不发请求 |
| `backends/azure_flux.zig` | Azure FLUX 请求体（`width`/`height`，可选 `seed`） | 同上 |
| `backend.zig` | 后端注册 + `generate()` 编排 + 共享响应解析（b64_json / url 回退 / error） | 不解析 CLI、不写文件 |
| `scheduler.zig` | 并发任务执行（`std.Thread` 原子认领）、落盘、进度上报 | 不构造请求体、不解析 CLI |
| `cli.zig` | 参数解析 + help 文本 | 不发网络请求 |
| `main.zig` | 入口 `main(init: std.process.Init)`、子命令分发、结果渲染 | 业务细节下沉到各模块 |

**唯一做进程级 IO（env/args/stdout）的是 `main.zig`**；其余模块通过参数/接口注入依赖，保持可测试、可解耦。

### 新增一个后端的步骤
1. 在 `types.zig` 的 `BackendKind` 增加变体（及 `fromString` 别名）。
2. 在 `src/backends/` 新增 `your_provider.zig`，实现 `buildBody(arena, req, api_model) ![]u8`。
3. 在 `backend.zig` 的 `buildBody` dispatch 增加一个 switch 分支。
4. 若响应结构不同，扩展 `parseResponse`（当前支持 `data[].b64_json` 与 `data[].url`）。
5. 加单元测试（body 形状）；更新 `config.template` 与 README/SKILL 文档。

## 4. 配置 schema（`~/.imagine/config.toml`）

路径优先级：`--config <path>` > `$IMAGINE_CONFIG` > `~/.imagine/config.toml`；默认 TOML 不存在时兼容读取旧版 `~/.imagine/config.json`。

```toml
output_dir = "~/.imagine/outputs"
concurrency = 0 # 0=按端点数自动；>0 固定并发

# 表键即 -m 的逻辑名，可自由增删改；模型名不写死在二进制里。
[models."<model-name>"]
backend = "openai_image" # openai_image | azure_flux（azure_image 为兼容别名）
api_model = "传给 API 的真实 model 字段"

[[models."<model-name>".endpoints]]
base_url = "https://.../images/generations"
api_key_env = "AZURE_OPENAI_APIKEY" # 从环境变量取 key
api_key = "可选：直接写死 key（优先于 env）"
auth = "bearer" # bearer | api-key，默认 bearer

[models."<model-name>".defaults]
size = "1024x1024"
width = 1024
height = 1024
output_format = "png"
output_compression = 100
quality = "high"
```

参数优先级：**CLI 选项 > 模型 `defaults` > 内置缺省**。
密钥优先级：端点 `api_key` > 端点 `api_key_env` 指向的环境变量。

### 无配置文件（ephemeral）

当 `--config` / `$IMAGINE_CONFIG` / 默认 toml / legacy json **均不存在**时，可从 env 合成单模型：

| 变量 | 含义 |
|------|------|
| `IMAGINE_BASE_URL` | 必填，images endpoint |
| `IMAGINE_MODEL` | 必填，逻辑名（兼默认 api_model） |
| `AZURE_OPENAI_APIKEY` / `IMAGINE_API_KEY` / `IMAGINE_API_KEY_ENV` | 凭证 |
| `IMAGINE_BACKEND` / `IMAGINE_AUTH` / `IMAGINE_API_MODEL` / `IMAGINE_SIZE`… | 可选 |

`imagine models` / `config show` 的 `source` 为 `ephemeral` 或 `file`。仅一个模型时可省略 `-m`。多模型/多端点仍用配置文件。

## 5. CLI 契约（对 agent 稳定）

```
imagine generate -m <model> -p <prompt> [-o -n -s --width --height \
        --format --compression --quality --seed -c --config --json --dry-run -q]
imagine batch <manifest.json> [-c --json]
imagine models [--json]
imagine config path | init [--force] | show
imagine version | help
```

- 退出码：`0` 成功；`1` 运行失败（含部分失败）；`2` 用法错误。
- `--json` 结果对象：`{ ok, model, backend, requested, succeeded, failed, images:[{path,bytes}], errors:[] }`。
- batch manifest：`{ "jobs": [ { "model","prompt","output","size","width","height","n","format","compression","quality","seed" } ] }`。
- 多张图（`-n N` 或单端点）→ 文件名自动加 `-1 -2 …` 数字后缀。

## 6. 路线图

**已完成**
- 核心架构（types/config/http/backend/scheduler/cli/main）与单元测试。
- OpenAI 兼容 `openai_image`（`/v1/images/generations`）与 Azure `azure_flux`。
- 模型名由配置动态声明；`imagine models` 发现可用模型。默认密钥 env：`AZURE_OPENAI_APIKEY`。
- **Ephemeral 无配置文件模式**：无文件时用 `IMAGINE_BASE_URL` + `IMAGINE_MODEL` + 凭证合成单模型；`source` 标注；单模型可省略 `-m`。
- 同模型多端点并发调度；`--json`/`--dry-run`/batch；config init/show/path。
- `install.sh`（curl 一键，OS 探测，下载预编译二进制并校验 SHA-256）、`Makefile`、`skills/imagine` 技能。
- CI（Linux/macOS/Windows 构建+测试+`zig fmt`）与 release 工作流：tag 触发，交叉编译
  Linux/macOS/Windows × `x86_64`/`arm64` 六个目标并发布 GitHub Release。

**近期**
- HTTP 超时与有界重试（指数退避，仅幂等失败）。
- 更多后端：Google Gemini 图像、Stability、Replicate。
- 图生图 / 编辑（input image、mask）参数通路。

**远期**
- 速率限制感知调度（按端点配额）、流式进度、结构化日志。

## 7. 开发约定

- 目标 Zig 版本：见 `build.zig.zon` 的 `minimum_zig_version`（当前 **0.16.0**）。
- 常用命令：`make build` / `make test` / `make run` / `make install` / `make fmt`。
- 提交前：`zig build test` 必须通过；`zig fmt src/*.zig` 保持格式。
- 保持模块单一职责与上表边界；新增后端遵循 §3 步骤。
- 注释只解释"为什么"，不复述"做什么"。

### 发布流程

1. 改 `src/version.zig` 的 `string`（如 `0.2.0`），同步 `build.zig.zon` 的 `version`。
2. 提交后打 tag：`git tag v0.2.0 && git push origin v0.2.0`。
3. `.github/workflows/release.yml` 自动交叉编译六平台、打包技能与 `SHA256SUMS`、创建 Release。
   tag 必须与 `src/version.zig` 一致，否则 workflow 报错中止。
4. 资产命名：`imagine-<os>-<arch>`（Windows 带 `.exe`），与 `install.sh` 下载路径一致。
