# Gemini in Chrome Doctor

一个面向 macOS 的只读优先诊断工具，用来区分并处理两类容易混淆的
Gemini in Chrome / Ask Gemini 故障：

1. Chrome 原生 Glic 宿主的资格或地区过滤失败；
2. 资格检查通过后，内嵌 Gemini Web 客户端的网络或加载失败。

> [!IMPORTANT]
> 本项目不是 Google 官方工具，也不用于绕过地区限制。地区修复命令只会在
> 当前公网出口国家与目标国家完全一致时运行，目的是修复 Chrome 中已经过期
> 或错误的 Variations 国家缓存。

## 为什么普通 Gemini 网页正常，Ask Gemini 仍可能失败

Gemini in Chrome 不是普通扩展，也不只是 `gemini.google.com` 标签页。它由
Chrome 原生宿主和内嵌 Web 客户端两层组成：

- Chromium 内部把原生宿主称为 **Glic**；
- Chrome 负责账号、策略、国家、语言和灰度资格检查；
- 通过资格检查后，宿主再加载 Google 提供的内嵌 Gemini 客户端；
- 因此“地区不可用”和“Something went wrong”通常来自不同层。

### 常见状态

Chromium 当前的 `ProfileReadyState` 定义如下：

| 数值 | 状态 | 含义 |
|---:|---|---|
| 0 | `UnknownError` | 未知错误 |
| 1 | `SignInRequired` | 需要登录 |
| 2 | `Ready` | 原生宿主资格检查通过 |
| 3 | `Ineligible` | 不符合通用资格 |
| 4 | `DisabledByAdmin` | 被管理员策略禁用 |
| 5 | `LocationMismatch` | 国家过滤失败 |
| 6 | `IneligibleAccount` | 账号不符合资格 |

源码参考：

- [ProfileReadyState generated enum](https://source.chromium.org/chromium/chromium/src/+/main:out/mac-Debug/gen/chrome/browser/glic/host/glic_webui.mojom-data-view.h)
- [Glic country filtering](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/glic/public/glic_enabling.cc)
- [Default enabled countries](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/glic/public/glic_enabling.h)
- [Temporary country override switch](https://source.chromium.org/chromium/chromium/src/+/main:components/variations/variations_switches.cc)
- [Google availability documentation](https://support.google.com/chrome/answer/17140089?co=GENIE.Platform%3DDesktop)

## 一个实际故障的排查路径

下面的顺序来自一次真实排障，但所有个人信息、账号标识、路径和 IP 都已移除。

### 第一阶段：地区限制

界面显示：

```text
Gemini in Chrome isn't available everywhere
Gemini in Chrome is expanding to different locations ...
```

本地状态显示：

```text
glic_rollout_eligibility = true
last_ready_state = 5
```

Chromium 源码确认 `5 = LocationMismatch`。进一步发现：

- 当前公网出口位于受支持国家；
- Chrome Variations 的当前/永久国家仍保存为另一个不受支持国家；
- 修复缓存并使用官方的临时运行时国家覆盖后，状态变为 `2 = Ready`。

### 第二阶段：内嵌客户端加载失败

地区页消失后，界面变为：

```text
Something went wrong
Gemini isn't available right now. Try again later.
```

这时 `ready_state = 2`，说明 Chrome 原生宿主已经通过资格检查。多次网络测试发现：

- Glic 状态 API 稳定；
- Google 登录稳定；
- `gemini.google.com` 的 TLS 连接随机失败；
- HTTP/1.1、HTTP/2、固定 IP 和不同 DNS 都无法消除失败。

切换到稳定网络后，内嵌 Gemini 客户端恢复正常。

## 安装要求

- macOS；
- Google Chrome；
- Bash 3.2 或更高版本；
- `jq`；
- `curl`、`osascript`、`shasum`、`dig`（macOS 自带）。

如果缺少 `jq`，可自行通过你信任的软件包管理方式安装。脚本不会自动安装依赖。

## 使用方法

```bash
chmod +x gemini-chrome-doctor.sh
./gemini-chrome-doctor.sh diagnose
```

诊断是默认操作，因此也可以直接运行：

```bash
./gemini-chrome-doctor.sh
```

调整网络重试次数：

```bash
./gemini-chrome-doctor.sh diagnose --trials 8
```

跳过外部网络测试，只读取本地非敏感状态：

```bash
./gemini-chrome-doctor.sh diagnose --skip-network-tests
```

### 修复错误的地区缓存

> [!WARNING]
> `repair-location` 会关闭并重启 Chrome。先保存尚未提交的网页表单、编辑器
> 内容和上传任务。

例如，当前公网出口确实是美国，而 Chrome 仍错误保存其他国家时：

```bash
./gemini-chrome-doctor.sh repair-location \
  --country us \
  --apply \
  --restart
```

安全限制：

- 没有 `--apply` 时拒绝修改；
- 当前公网出口与 `--country` 不一致时拒绝修改；
- Chrome 无法正常退出时拒绝修改；
- 写入前自动创建带时间戳的 `Local State` 备份；
- 只修改三个 Variations 国家字段；
- 非目标 JSON 结构发生变化时拒绝写入；
- 使用临时文件校验后原子替换；
- `--restart` 会用 `--restore-last-session` 恢复会话；
- `--variations-override-country` 只对本次启动生效，不会跨会话持久化。

脚本修改的字段是：

```text
variations_country
variations_permanent_consistency_country[1]
variations_safe_seed_session_consistency_country
```

它不会修改 Cookie、账号、密码、书签、历史、扩展、Chrome Sync 或 Gemini
对话。

## 如何解读诊断结果

### `ready_state = 5`，且页面提示地区不可用

1. 查看脚本输出的公网出口国家；
2. 对比 Chrome 当前/永久 Variations 国家；
3. 如果两者不同，而且公网出口是 Google 官方支持的地区，才考虑运行
   `repair-location`；
4. 如果公网出口本身不受支持，不要改缓存。应使用服务实际支持的网络和地区。

### `ready_state = 2`，但显示 “Something went wrong”

这通常不再是资格或地区错误。查看网络稳定性统计：

- `Glic status API` 稳定而 `Gemini web` 失败：重点检查通往
  `gemini.google.com` 的网络路径；
- 多个 Google 域名都失败：检查本地网络、透明代理、过滤器或上游链路；
- 更换 DNS 返回同一地址且仍失败：DNS 通常不是根因；
- 切换到另一条稳定网络后直接点击 **Try again**。

### `ready_state = 1` 或 `6`

- `1`：在同一 Chrome 配置中重新完成 Google 登录；
- `6`：检查账号年龄、监督状态、Workspace 管理策略和 Gemini 账号资格。

## 回滚

修复命令会输出备份的完整路径。要回滚：

1. 正常退出 Chrome；
2. 确认 Chrome 主进程完全结束；
3. 用备份覆盖 `Local State`；
4. 重新启动 Chrome。

示例中的路径仅用于说明，请替换为脚本实际输出的备份路径：

```bash
cp -p \
  "$HOME/Library/Application Support/Google/Chrome/Local State.codex-backup-YYYYMMDD-HHMMSS" \
  "$HOME/Library/Application Support/Google/Chrome/Local State"
```

## 隐私与安全

- 诊断只输出布尔值、枚举、国家码、版本、窗口/标签数量和网络成功率；
- 不输出邮箱、账号 ID、标签页网址、浏览历史、Cookie 或令牌；
- 网络国家检查使用 Cloudflare trace，只读取两位国家码，不打印公网 IP；
- 网络稳定性测试不携带 Chrome Cookie 或 OAuth 令牌；
- 仓库不应提交 `Local State`、Chrome Preferences 或任何备份。

## 局限

- Chromium 内部实现和字段名可能随版本变化；脚本会在结构不符合预期时停止；
- `ready_state` 是最后一次观察到的状态，可能需要重新点击 Ask Gemini 才更新；
- 运行时国家覆盖只用于确认 Chrome 的地区判断，不是长期解决方案；
- 服务端故障、账号限制和企业策略不能通过本地缓存修复。

## 测试

```bash
./tests/test.sh
```

## License

[MIT](LICENSE)
