<p align="center">
  <img src="./assets/readme/hero.zh-CN.svg" width="100%" alt="Gemini in Chrome Doctor 从 Chrome 资格检查追踪到内嵌 Gemini 网络路径">
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  一个只读优先的 macOS 诊断 CLI，用来找出<br>
  <em>“Gemini in Chrome isn't available”</em> 真正失败在哪一层。
</p>

> [!IMPORTANT]
> 这是独立诊断工具，不是 Google 官方项目，也不是地区绕过工具。只有当前
> 公网出口国家与目标国家完全一致时，脚本才允许修复地区缓存。

## 看见真正失败的层级

运行一个命令：

```bash
./gemini-chrome-doctor.sh diagnose
```

得到不含敏感信息的诊断轨迹，而不是猜测：

```text
== Gemini in Chrome / Glic ==
Rollout eligible: true
Ready state: 2 (Ready)

== Variations country cache ==
Current country: us
Permanent country: us

== Network ==
Glic status API      success=3 failure=0
Gemini web           success=3 failure=0
Google accounts      success=3 failure=0
```

脚本只输出布尔值、枚举、国家码、版本、窗口/标签数量和端点成功率；不会输出
邮箱、账号 ID、标签页网址、历史、Cookie、令牌或 Gemini 对话。

## 一个症状，三个层级

Gemini in Chrome 不只是一个 `gemini.google.com` 标签页。Chromium 把其原生
宿主称为 **Glic**：宿主先检查资格，再加载 Google 的内嵌 Web 客户端。

| 层级 | 证据 | 典型下一步 |
|---|---|---|
| Chrome / Glic | `ready_state`、灰度、策略、账号、国家 | 只修复明确失败的资格检查 |
| 内嵌客户端 | `Ready` 后出现 “Something went wrong” | 分别测试 Glic API 与 Gemini 内容域名 |
| 网络路径 | 多次端点成功/失败统计 | 切换路由或网络，不要清空整个配置 |

### Glic 就绪状态

| 数值 | 状态 | 含义 |
|---:|---|---|
| 0 | `UnknownError` | 未知原生宿主错误 |
| 1 | `SignInRequired` | Chrome 需要登录 |
| 2 | `Ready` | 原生资格检查通过 |
| 3 | `Ineligible` | 通用资格检查失败 |
| 4 | `DisabledByAdmin` | 被管理员策略禁用 |
| 5 | `LocationMismatch` | 国家过滤失败 |
| 6 | `IneligibleAccount` | 账号不符合资格 |

## 快速开始

### 环境要求

- macOS 与 Google Chrome；
- Bash 3.2 或更高版本；
- `jq`；
- `curl`、`osascript`、`shasum`、`dig`（macOS 自带）。

项目不会自动安装依赖。

### 诊断

```bash
git clone https://github.com/alloevil/gemini-in-chrome-doctor.git
cd gemini-in-chrome-doctor
chmod +x gemini-chrome-doctor.sh
./gemini-chrome-doctor.sh diagnose
```

常用变体：

```bash
# 增加网络采样次数
./gemini-chrome-doctor.sh diagnose --trials 8

# 只读取本地状态，不访问外部网络
./gemini-chrome-doctor.sh diagnose --skip-network-tests
```

## 修复过期的地区缓存

仅当下面三项同时成立时使用：

1. 界面提示地区不可用；
2. `ready_state = 5 (LocationMismatch)`；
3. Chrome 缓存国家与工具检测到的公网国家不同，而且真实公网国家受 Google
   官方支持。

```bash
./gemini-chrome-doctor.sh repair-location \
  --country us \
  --apply \
  --restart
```

> [!WARNING]
> `--restart` 会关闭 Chrome。请先保存未提交的表单、编辑器内容和上传任务。

### 安全门控

- 没有 `--apply` 就不写入；
- 公网国家与 `--country` 不一致就不写入；
- Chrome 无法正常退出时不强制结束；
- 每次写入前创建带时间戳的 `Local State` 备份；
- 用结构哈希拒绝任何非目标 JSON 变化；
- 临时文件验证后再原子替换；
- 用 `--restore-last-session` 恢复会话；
- 运行时国家覆盖只作用于新启动的 Chrome 进程。

脚本只修改：

```text
variations_country
variations_permanent_consistency_country[1]
variations_safe_seed_session_consistency_country
```

Cookie、账号、密码、书签、历史、扩展、Chrome Sync 和 Gemini 对话都保持不变。

## 读状态，不只看标题

### `5 · LocationMismatch`

对比公网国家与 Chrome 的当前/永久 Variations 国家。只修复过期的不一致；
如果公网网络本身不受支持，不要修改缓存。

### `2 · Ready` + “Something went wrong”

原生宿主已经通过。查看端点采样：

- Glic API 稳定、Gemini Web 不稳定 → 检查到 `gemini.google.com` 的路径；
- 多个 Google 端点都不稳定 → 检查网络、透明代理、过滤软件或上游路由；
- 不同 DNS 返回相同端点 → DNS 通常不是根因；
- 切换到稳定网络后，先点击 **Try again**，不要清空浏览器数据。

### `1 · SignInRequired` 或 `6 · IneligibleAccount`

- `1`：在同一个 Chrome 配置中重新完成 Google 登录；
- `6`：检查年龄、监督状态、Workspace 管理策略和 Gemini 账号资格。

<details>
<summary><strong>真实故障阶梯：地区缓存 → TLS 路径</strong></summary>

一次匿名化排查从下面的提示开始：

```text
Gemini in Chrome isn't available everywhere
```

账号已获得灰度资格，但 `ready_state = 5`。Chromium 源码把它映射为
`LocationMismatch`；公网网络受支持，而 Chrome Variations 国家已经过期。
修复缓存并使用 Chromium 的临时运行时国家覆盖后，状态变为 `2 = Ready`。

随后界面变为：

```text
Something went wrong
Gemini isn't available right now. Try again later.
```

Glic 状态与 Google Accounts 稳定，但 `gemini.google.com` 的 TLS 连接在
HTTP/1.1、HTTP/2、固定 IP 和多 DNS 测试中都随机失败。切换到稳定网络路径后，
内嵌客户端恢复。

</details>

## 回滚

修复命令会输出备份路径。要恢复：

1. 正常退出 Chrome，并确认主进程停止；
2. 用输出的备份覆盖 `Local State`；
3. 重新启动 Chrome。

```bash
cp -p \
  "$HOME/Library/Application Support/Google/Chrome/Local State.gemini-chrome-doctor-backup-YYYYMMDD-HHMMSS" \
  "$HOME/Library/Application Support/Google/Chrome/Local State"
```

## 信任边界

- Cloudflare trace 只用于读取两位公网国家码；不会打印公网 IP；
- 端点采样不携带 Chrome Cookie 或 OAuth 令牌；
- 运行时国家覆盖是诊断手段，不是持久地区绕过方案；
- 服务端故障、账号限制和企业策略不能通过修改本地缓存解决；
- Chromium 字段可能变化；结构不符合预期时脚本会安全停止，而不是尝试写入。

## 资料来源

- [ProfileReadyState 枚举](https://source.chromium.org/chromium/chromium/src/+/main:out/mac-Debug/gen/chrome/browser/glic/host/glic_webui.mojom-data-view.h)
- [Glic 国家过滤](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/glic/public/glic_enabling.cc)
- [默认支持国家](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/glic/public/glic_enabling.h)
- [临时国家覆盖参数](https://source.chromium.org/chromium/chromium/src/+/main:components/variations/variations_switches.cc)
- [Google 可用性文档](https://support.google.com/chrome/answer/17140089?co=GENIE.Platform%3DDesktop)

## 测试

```bash
./tests/test.sh
```

## License

[MIT](LICENSE)
