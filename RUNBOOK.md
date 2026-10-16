# Claude 使用资格、环境诊断与配置修复

**修订：2026-10-16。** 本仓历史名称为 claude-antiban；工具用于减少配置错误，没有防封保证。
旧文档中的“固定机房 IP 最优”“改美国时区”“无泄漏”“订阅 OAuth 接入 CPA”等结论已撤回。
历史机器日志只记录当时操作，不再作为安全或当前部署状态证明。

## 1. 注册或登录前先判断资格

先读 [Supported Regions Policy](https://www.anthropic.com/legal/supported-regions)、
[Consumer Terms](https://www.anthropic.com/legal/consumer-terms) 和
[Usage Policy](https://www.anthropic.com/legal/aup)。

- 按**实际所在地**与主体的注册地、总部及控制关系判断资格，不能用代理的所在地替换。
  中国大陆不在本次核对的支持名单；实际仍在中国大陆的个人，不应据此工具开始注册或登录。
  若官方政策或实际情况改变，重新核对；授权云渠道也有自己的准入条件，并不自动消除地区限制。
- 使用真实、准确且本人有权使用的账号和付款信息，按当前官方验证流程办理。
  不购买来历不明账号、借用身份、用接码或换号规避限制；不共享订阅凭据。
- 误判、停用或拒绝访问时保存脱敏错误、时间和请求 ID，通过
  [官方警告与申诉说明](https://support.claude.com/en/articles/8241253-safeguards-warnings-and-appeals)
  处理；不通过清设备标识或新号重试来验证“是否解封”。

本地预检输出 `ELIGIBILITY=not-determined`，不会根据 IP 自动签发“允许使用”结论。
两个分支的具体动作见第 8 节：资格不成立时停在本地准备，资格成立后按合规口径使用。

## 2. 每个环境要检查什么

| 环境 | 建议与检查 | 证据边界 |
| --- | --- | --- |
| Windows 系统 | 使用真实日常语言、时区；保持系统、官方客户端及证书更新 | 修改区域设置不取得资格；不需要伪装“美国机器” |
| 指纹 | 不安装所谓防检测浏览器或指纹清洗工具，不伪造 device ID、UA 或会话状态 | 没有官方公开的安全指纹阈值，社区个案不能提供防封参数 |
| 代理/TLS | 明确每个进程的代理来源，保留 TLS 验证，排查旧端点和异常重试 | 稳定连接只减少网络错误；固定/住宅 IP、第三方评分不保证安全 |
| 浏览器 | 官方站点和正常浏览器；可用独立 profile 隔离工作数据，扩展按实际需要最小化 | profile 是数据隔离；不能证明 DNS、IPv6、WebRTC 全部无泄漏 |
| Claude Code | 官方发行和认证流程；区分订阅、API key、网关凭据，检查配置作用域 | 变量存在不等于生效，更不等于账号获准使用 |
| Claude Desktop | 区分普通聊天、Code 标签页、Cowork 与 provider 连接模式 | 不能把 CLI 的 shell 环境或 apiKeyHelper 规则套到整个 Desktop |
| 远端 CPA | 保持现有部署边界，不导入个人 Claude 订阅 OAuth | 本仓不部署、登录、修改或重启远端 |

### 代理与配置作用域

[Claude Code 网络配置](https://code.claude.com/docs/en/network-config)：
CLI 支持 HTTP/HTTPS 代理，不支持 SOCKS 代理。不要把 SOCKS 端口误填为 HTTP；
不要通过关闭证书验证来“修复”TLS。代理 URI 不写用户名、密码或 token。

分别核对 Process / User / Machine 的 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY、NO_PROXY，
以及 managed、user、project、local settings 和实际启动器。旧终端、GUI 或后台进程
可能保留原环境；端口监听和一次 PowerShell 请求不能证明 CLI 的实际路由。
预检对相关路由/认证/请求覆盖变量仅报告 user settings 与 Process / User / Machine 各作用域的
存在性，不读取或打印值；某作用域不可读时明确输出 unavailable。这不覆盖全部设置层级，
也不能证明某个 Claude 进程实际继承了哪个值。

避免网络故障期间无意义的重复发送和并发；遇到 429 遵守产品限额与 Retry-After，
不承诺固定几小时自动恢复。认证拒绝或明确停用时停止账号探测，先辨别错误并走官方支持。

对于 **Desktop 管理 provider 连接的会话**（如某些第三方 provider Code 标签页和 Cowork），
官方规定 Code 仅从 managed settings 与 `~/.claude/settings.json` 读取代理及相关 TLS 变量。
不能认为 shell export、项目设置或系统代理必然覆盖这些会话。
普通 Desktop 聊天的网络行为应单独核对，不把 CLI 的 apiKeyHelper 视作其配置入口。

### 订阅与网关的区别

[Claude Code 合规说明](https://code.claude.com/docs/en/legal-and-compliance)限制第三方代持、
中转 Claude.ai 订阅凭据；本部署不采纳 CPA 代持 Free/Pro/Max OAuth 给其他客户端的路径。

[Subscriptions and gateways](https://code.claude.com/docs/en/llm-gateway#subscriptions-and-gateways)
同时说明：仅设置 ANTHROPIC_BASE_URL 不会替换已保存的官方 Code 订阅认证；
网关凭据或 apiKeyHelper 生效后则改用该凭据，订阅额度不适用。
不能仅因 BASE_URL 非空就断言凭据共享，也不能据此认为 CPA 代持令牌被认可。

## 3. 本仓工具：默认不联网、不改配置

所有 PowerShell 命令使用 PS7（最低 7.3），在本仓目录执行。

```powershell
# 只读：当前时区、用户设置有效性、敏感配置键存在性；不登录、不调用模型
pwsh -NoProfile -File .\prep-registration.ps1

# 可选：仅诊断指定 HTTP 代理的出口，会联系第三方 api.ipify.org
pwsh -NoProfile -File .\hooks\check-exit-ip.ps1 -CheckExitIp -Proxy http://127.0.0.1:10808
# 需要比对时由操作者显式提供 -ExpectedIp，不预设“安全出口”
```

诊断返回值：观察/比对成功 `0`；与指定 IP 不同 `2`；失败、无效响应或参数不足 `3`。
未传 CheckExitIp 时 `0 / NOT_CHECKED`，**不代表检查通过**。
预检的旧 `-Restore` 参数仅提示退出，不修改或恢复时区。
若旧脚本曾改过时区，请在 Windows 设置中人工核对并按真实日常使用需求恢复；
新脚本不猜测原值。

`Get-SurfaceReport.ps1` 把第三方评分常见的扣分项归到本机事实，默认不联网、不写任何文件：

```powershell
pwsh -NoProfile -File .\Get-SurfaceReport.ps1
# 需要出口诊断时显式给出 HTTP 代理；其余参数与 check-exit-ip.ps1 相同
pwsh -NoProfile -File .\Get-SurfaceReport.ps1 -CheckExitIp -Proxy http://127.0.0.1:10808
```

输出只报状态与来源，不打印系统代理取值，也不写 `machine-journal.md`；
解读口径见第 5 节。它不是评分工具，也不改变第 1 节的资格判断。

`start-claude-chrome.cmd` 只启动官方 Chrome 的独立 `chrome-data/`；
继承浏览器正常网络配置，不强设代理、语言、时区或 WebRTC。
启动前先判断使用资格。已有 profile 继续保留，回滚不得删除 cookie 或会话数据。

## 4. 配置修复：预览、备份、读回

`install.ps1` 不再注册任何自动 hook。官方
[hooks 文档](https://code.claude.com/docs/en/hooks)规定 SessionStart 的 exit 2
为非阻断错误，会话仍可继续；旧 hook 不是请求防火墙，故不升级为其他自动 hook。

安装器要求官方客户端已有有效 JSON 用户设置；不会创建账号或初始化凭据。
一次只运行一个写入器；避免客户端、配置同步工具同时保存同一文件。
仅处理本仓已知命令形式和精确脚本绝对路径，未知 wrapper、参数、相对路径或其他路径一律保留供人工核对。

```powershell
# 移除旧 SessionStart action；默认仅预览
pwsh -NoProfile -File .\install.ps1 -RemoveLegacyHook
pwsh -NoProfile -File .\install.ps1 -RemoveLegacyHook -Apply

# 可选：操作者明确选择代理时，补齐两个缺失 env 键；不改遥测
pwsh -NoProfile -File .\install.ps1 -ConfigureProxy -Proxy http://127.0.0.1:10808
# 确认预览后，同命令加 -Apply
```

已有代理值不同或同名键出现多种大小写时拒绝写入；相同值保留原键名。
其他 env、permissions、hook action/group/event 全部保留；空的本仓 hook 容器才移除。
无修改则不写文件、不建备份、不写日志，也不联网。

Apply 将候选 JSON 写入同目录临时文件，校验后原子替换；
`settings.json.bak-claude-env-<GUID>` 保存被替换文件的原始字节。
`machine-journal.md` 记录操作、备份路径、前后 SHA256 与准备/读回阶段。
出现 prepared 但没有 applied-readback-verified 时必须检查现场，不能把 prepared 当成功。
替换前检查漂移，替换后校验实际备份和读回；这不等于跨进程 CAS。
检测到并发或发布后错误时保留备份并报错，不自动覆盖更新的设置。

### 精确回滚

先从本次 APPLIED 输出/日志取备份路径和 after_sha256；当前文件如已变化则拒绝恢复。

```powershell
pwsh -NoProfile -File .\install.ps1 -RollbackBackup '<本次备份绝对路径>' -ExpectedCurrentHash '<本次 after_sha256>'
# 确认预览后，同命令加 -Apply；恢复本身也创建新备份和日志
```

备份含用户配置，应限制在本机并按自己的备份策略保管。
不要删除整个 hooks 键，不要批量清理凭据或直接覆盖后来修改。

### Claude Code lane 切换（中继 ↔ 官方）

`Set-ClaudeLane.ps1` 管理 `~/.claude/settings.json` 在已识别中继形态（env 含
`ANTHROPIC_BASE_URL`）与本仓模板 `settings.official-anthropic.json` 之间的整文件切换。
无参数调用只输出只读 status：`current_lane=relay` 表示用户设置含 `ANTHROPIC_BASE_URL`，
`official` 表示字节与当前模板投影结果完全一致，`custom` 表示其他有效设置（也可能是精确的上一版仓库模板），
`missing` 表示文件缺失，`invalid` 表示文件存在但不是有效 JSON 对象；status 分类本身不授权写入。
写入路径只接受识别出的 relay、当前模板（不变时返回 `NO_CHANGE`）或哈希精确匹配的上一版模板；其他配置拒绝整文件替换。
status 只分类设置文件，不证明进程实际路由或账号资格；lane 切换是本机配置管理，不影响第 1 节的资格判断。
status 同时返回 `process_overrides_present`（仅变量名）及 `route_verified=false`；
即使 `current_lane=official`，父进程的中继环境仍可能影响普通启动的 Claude。

- 默认仅预览，输出会明确标记 `full-file-replacement=true` 和 `extra-settings=not-preserved`；`-Apply` 才写文件。
  整文件切换不保留模板之外的键，模板修改在仓内进行并随 Git 提交。
- 模板用 `%USERPROFILE%` 表示当前用户目录，写入时替换为实际路径；模板本身不含用户名，可直接跨机使用。
- ToOfficial 仅接受已识别 relay 形态、与当前模板一致，或规范化 USERPROFILE 并将换行统一为 LF 后 SHA256 等于仓库已知上一版模板摘要的现状；未识别配置直接拒绝，保留人工审查。
- ToRelay 用 `-RelayVariant` 指向一份**仓外**自备的 relay 设置文件，把它投影成新的机器设置；工具只是切换器，
  既不生成、不保存、也不回显其中任何取值，journal 只记动作名与哈希。源文件同样支持 `%USERPROFILE%` 占位。
  源文件是**完整的机器设置**（整文件替换）：以当前官方模板为底、只追加一个 `env` 块；写成最小文件会丢掉权限模板、deny 列表与 Manual 设置。
- ToRelay 只从官方模板现状或已识别 relay 现状整文件切换（后者用于改指端点）；源文件必须含 `env.ANTHROPIC_BASE_URL`，
  且不得含 `apiKeyHelper` 或 `hooks`；其他现状先 `-ToOfficial` 再切。文件放在仓库外本机目录，命名含 `token`/`credentials`
  可落入模板 deny 列表的读取拦截范围。
- 中继识别目前只检查用户设置的 `env.ANTHROPIC_BASE_URL` 是否存在。命中后，`ToOfficial` 会整文件替换，
  即使原文件还有模板外设置也不会保留；预览会显式提示该替换范围。执行前先确认不需保留这些键；除精确匹配上一版模板的已识别迁移外，其他 `custom` 形态 fail-closed。
- 确需增加权限约束时，应先在仓内更新模板并验证，再按新模板投影，避免模板与机器设置漂移。
- 当前官方模板采用默认逐项确认权限模式，不预先授权宽泛工具列表，并禁用 Auto / bypass 权限模式。它不内置代理端点、附加项目目录或本机状态栏脚本。
- 权限键按 [Claude Code 官方权限文档](https://code.claude.com/docs/en/permissions) 设置；具体执行仍受客户端版本、managed settings 与当前会话状态影响。
- 移除的是 settings 文件内的固定代理配置；继承的 Process / User / Machine 环境代理仍可能影响实际路由，预检只报告存在性，不会替操作者删除或改写。
- install.ps1 与 Set-ClaudeLane.ps1 均在预览或写入前检查 cc-switch 进程；检测到运行即停止，不改设置或日志。
- 备份为 settings.json 同目录 `settings.json.bak-claude-lane-<GUID>` 原字节；
  回滚与上一节同款哈希钉死流程。
- 回滚只接受本工具在设置文件旁创建、文件名以 `<设置文件名>.bak-claude-lane-` 开头的备份；
  人工另存的备份不满足该判据，需按人工恢复处理并留痕。回滚预览显示
  `scope=restore-backup-file` 与 `backup-bytes=restored`；当前文件必须与 `ExpectedCurrentHash` 相符。

```powershell
pwsh -NoProfile -File .\Set-ClaudeLane.ps1                      # 只读 status
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -ToOfficial          # 预览
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -ToOfficial -Apply   # 切换 + 备份 + 日志
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -ToRelay -RelayVariant '<仓外 relay 源文件绝对路径>'          # 预览
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -ToRelay -RelayVariant '<仓外 relay 源文件绝对路径>' -Apply   # 切换 + 备份 + 日志
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -RollbackBackup '<APPLIED 输出的备份绝对路径>' -ExpectedCurrentHash '<after_sha256>'
```

relay 源文件由操作者自备并在本机保管；本仓不提供网关端点、凭据，也不因切换 lane 而改变第 1 节与
第 8 节的资格判断或第三方通道授权结论。

### 隔离官方 Claude Code 的启动环境

已确认实际资格后，使用现有入口准备官方 CLI 环境：

```powershell
# 只读、不联网：验证模板，并在隔离子进程内运行预检
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -OfficialPreflight
# 明确要打开客户端时运行；本仓自动验收不执行此命令
pwsh -NoProfile -File .\Set-ClaudeLane.ps1 -LaunchOfficial
```

两种动作均要求设置与模板字节一致，拒绝模板中的认证 helper、路由覆盖和运行中的
CC Switch。子进程移除 `ANTHROPIC_*`、`CLAUDE_CONFIG_DIR`、订阅 token 环境变量、Bedrock/Vertex/Foundry
选择开关、已知模型/请求覆盖（含 `MAX_THINKING_TOKENS`、`CLAUDE_CODE_EXTRA_BODY`、`MAX_MCP_OUTPUT_TOKENS`）、登录等命令锁定及 `NODE_TLS_REJECT_UNAUTHORIZED`。
父进程、User/Machine 环境、凭据文件均不改写；HTTP/HTTPS/ALL_PROXY/NO_PROXY、
自定义 CA 与隐私偏好原样保留，不预设应当直连。

显式启动会打开新的无 profile PowerShell，从用户目录运行
`claude --setting-sources user`，避免当前仓库的 project/local 配置覆盖；managed settings
仍然适用。预检只验证新 PowerShell 的环境隔离，不能证明 CLI 已加载、Desktop 路由、
凭据选择、出口或账号获准使用。CC Switch 后续切换仍会重写用户设置，下次启动前重新预检。
此处没有后台监控或跨进程锁，不提供对其他写入器的永久阻断。
`CLAUDE_CONFIG_DIR` 会改变 user settings、会话和凭据的目录，见官方
[环境变量说明](https://code.claude.com/docs/en/env-vars)；清除仅作用于新进程，managed settings 仍可能重新指定它。

历史注记：2026-10-16 前本工具曾以机器侧副本（`~/.claude/scripts/Set-ClaudeLane.ps1`、
`~/.claude/settings.official-anthropic.json` 与桌面快捷方式）运行；现已收编入仓并退役
机器副本，专用浏览器统一为 `start-claude-chrome.cmd`。旧 `~/.claude/settings-backups/`
内 `bak-lane-*` 是退役工具的历史字节备份，仅人工核对使用，不纳入本工具回滚。

### 第三方写入器（CC Switch）

CC Switch（`~/.cc-switch/cc-switch.db`）切换 provider 时会重写 `~/.claude/settings.json`，
其库内 `common_config_claude` 合并模板是随切换生效的第二条写入通道。CC Switch 运行期间
不要手工编辑 settings.json，也不要并行启动其他写入器。

2026-10-15 深夜本机一次人工修复（未走本仓写入器，动作/备份/验证/回滚见
machine-journal 同日补记）：删除 claude-desktop 分组 3 个中继 provider 及其 endpoint；
同批清洗 `common_config_claude` 模板中 DISABLE_LOGIN/LOGOUT/UPGRADE/EXTRA_USAGE_COMMAND
锁定键、NONSTREAMING_FALLBACK/ATTRIBUTION_HEADER/MAX_OUTPUT_TOKENS/EFFORT_LEVEL 与顶层
model 钉定。日后经 CC Switch 重建任何 claude 分组条目前，先核对条目与模板不含
`ANTHROPIC_BASE_URL` 等中继 env，也不含上述锁定键；装 Claude Desktop 前同样检查其
claude-desktop 分组与模板现状，不要凭旧结论假设仍为已清空状态。

修复第二条写入通道时，须同时核对数据库 provider、`common_config_claude` 和
CC Switch 用户设置中的当前 provider 指针；不能仅修改 Claude 的 settings 文件。
公共模板属于多个 provider 的共同输入，清理前先确认其他用途是否依赖这些键。
并发操作已经改动数据库时，按最新现场重新核对，不能使用先前预览的哈希或自行恢复已删除条目。

## 5. 社区反馈如何采用

需要参考社区来找症状、版本差异与复现线索；官方政策、源码行为、个案推断分开记录。
issue 关闭不证明修复；403、TLS 错误、ECONNRESET、429 也不直接等于封号。

- [Claude Code #71581](https://github.com/anthropics/claude-code/issues/71581)：
  Windows 内置运行时 TLS 症状，系统工具成功不证明客户端连接正常。
- [Claude Code #87424](https://github.com/anthropics/claude-code/issues/87424)：
  连接重置报告，可用于排障，不证明账号处罚。
- [CPA #2211](https://github.com/router-for-me/CLIProxyAPI/issues/2211)：
  用户报告订阅账号被禁用；不能据此归因于 IP、指纹或精确频率。
- [CPA #5343](https://github.com/router-for-me/CLIProxyAPI/issues/5343)：
  提问不足以证明因果或封号率。
- CPA #2983 / #1803 / #1814 属 Google/Antigravity 语境，不外推为 Anthropic 规则。
- [CPA #6395](https://github.com/router-for-me/CLIProxyAPI/issues/6395) 的代理说明须结合部署版本；
  CPA 不以环境代理为受支持配置入口，管理请求与模型请求规则见下方部署文档。

旧文档关于 .cn 域名、WAF 检测机制、号码地区、付款金额、养号等待期等说法缺少可靠因果证据，
不再转化为操作建议。第三方“风险评分”网站不得收集账号凭据，其评分不作为资格或安全验收。

### 第三方风险评分怎么读

第三方站点（例如 `checkcc.org`）的百分比是启发式评分，不是 Anthropic 的资格、安全或账号验收，
也不构成提供账号凭据的理由。这类评分通常把“画像内部矛盾”记作风险：出口在一个国家，
而系统时区、区域内设置与已安装字体指向另一个国家。先归因，再决定是否值得处理：

| 常见扣分项 | 事实来源 | 本仓口径 |
| --- | --- | --- |
| 系统时区、`Intl`/区域设置、Emoji 渲染风格 | Windows 区域设置与系统安装 | 不伪装；改区域不取得资格（第 8 节 A） |
| 厂商/东亚字体、设备与操作系统特征 | Windows 字体与硬件 | 不安装指纹清洗工具，不伪造设备标识或 UA |
| WebRTC 公网 IP、DNS 与出口一致性 | 浏览器默认策略与本地 DNS | 只记为边界；不把“无泄漏”当作已验证结论（第 2 节） |
| 出口国家、数据中心/云厂商、IP 情报一致性 | 代理出口本身 | 固定或住宅出口、第三方评分不保证安全（第 2 节） |
| 浏览器语言、UA/Client Hints | 浏览器 profile 与版本 | 独立 profile 只隔离数据；不为评分改语言或 UA |

`Get-SurfaceReport.ps1` 输出上表“事实来源”一列对应的本机事实：它不访问评分站点，
不打印系统代理取值，也不改变任何设置。降低分数不是本仓目标。

## 6. 归宿与最低验收

- 通用资格/环境/工具：本仓。skills-manager 中的通用管理功能继续由原项目维护。
- CPA 运行代码和部署判据：相邻检出的
  [CPA 接入风险](../vps-ssh-launcher/docs/runbooks/cpa-claude-account-risk.md)、
  [CPA 网关](../vps-ssh-launcher/docs/runbooks/cpa-gateway.md)；不存在相邻仓时按所属项目单独查阅。
- 不整仓复制，不复制浏览器数据、凭据、第三方源码或 CPA 运行实现。

```powershell
pwsh -NoProfile -File .\qa\test-tools.ps1
git diff --check
```

fixture 验证权限模板、配置保护、CC Switch fail-closed、日志路径脱敏、作用域诊断仅报存在性、退出码及回滚，完全不访问外网。
源码和 fixture 为 repo_verified；真实设置备份/读回仅为 filesystem_projected。
本次不启动 Claude 新会话、不注册/登录、不发模型请求、不部署/重启 VPS。
host_loaded 与 live_accepted 均需独立证据；在资格未解决前不通过真实账号试验来补齐。
官方引用在 2026-10-15 核对，2026-10-16 再核对地区、网络、网关和 hook 关键行为；
政策变化或出现具体新故障时再按对应症状复核社区，不安排无依据的压力试验。

## 7. 本机留痕与新机迁移

### 哪些内容随项目保存

| 内容 | 保存位置与迁移方式 |
| --- | --- |
| 修复代码、配置意图、适用边界、验证和回滚方法 | 本仓脚本、本文和 Git 提交，随项目迁移 |
| 已发生的机器配置变更 | `machine-journal.md` 按机器伪名和时间追加；自动写入含动作、脱敏备份路径、前后 SHA256 与读回阶段 |
| 实际 settings、原字节备份、凭据、浏览器会话、代理订阅 | 各机器本地保管；不作为项目配置模板，不随代码投影 |
| 客户端、系统代理、证书等安装器范围外状态 | 按新机实际情况核对；如人工修改，脱敏补记动作、验证、回滚及执行来源，不能冒称安装器已完成 |

项目保存可复用方法和可追溯历史；每台机器的当前状态从现场读取。
旧日志中的路径、端口、哈希及通过记录只对应原机器、原时点，不能继承为新机结论。
日志不记录密码、token、cookie、授权 URL 或订阅地址，也不要记录出口 IP、浏览器/WebRTC
环境结论、系统代理注册表状态等本机基建信息。机器标识写伪名 `<HOST-xxxxxxxx>`
（机器名小写后的 SHA256 前 4 字节，`install.ps1` / `Set-ClaudeLane.ps1` 自动生成），
备份路径中的用户名写 `%USERPROFILE%`，真实主机名、用户名与用户路径不入库。
标准 `~/.claude/settings.json` 路径保留 `%USERPROFILE%` 占位符和 `.claude/settings.json` 相对结构；
Windows 日志使用反斜杠；
非标准设置路径只写 `<SETTINGS-DIR>\<SETTINGS-FILE>` 占位符，完整备份路径只出现在本机 APPLIED 输出。
实际备份可能含敏感配置，仅留原机器。已跟踪内容不含上述标识；2026-10-16 推送公开远端前
已改用脱敏副本重建单根历史，早期完整历史（含 2026-10-15 的出口 IP、代理链路与部署拓扑）
在核对公开树与旧末态一致后已删除，不留副本；此后每次推送前仍须按本节核对新增 diff。
append-only 指操作历史而言：历史条目里已经出现的凭据、订阅地址或本机基建信息，
在对任何远端推送或对外分享前必须就地脱敏为 `<redacted>` 并在同条注明脱敏时间；
这是唯一允许改写历史条目的情形。

### 新机操作顺序

1. 使用 Git 检出或离线 Git bundle 传递已跟踪代码；不要直接复制含 ignored 文件的整棵工作目录。
   `chrome-data/`、`qa/throwaway/`、旧机用户目录及运行态文件不作为迁移输入。
   新机目录和用户名可以不同，脚本通过自身目录和当前用户目录定位；本文命令均在新机项目根执行。
2. 安装 PowerShell 7.3+ 及需要的官方客户端，核对实际使用资格。
   重新核对新机代理软件、HTTP 端口、配置作用域和证书；不沿用旧机端口或出口的成功结论。
   本地准备不要求注册、登录或发送模型请求。
3. 先运行只读预检与无网 fixture：

   ```powershell
   pwsh -NoProfile -File .\prep-registration.ps1
   pwsh -NoProfile -File .\Get-SurfaceReport.ps1
   pwsh -NoProfile -File .\qa\test-tools.ps1
   ```

4. 按新机实际需求决定是否投影。全新机器没有旧 hook、也不需要配置代理时，**可以不写任何设置**。
   需要代理时明确提供新机实际 HTTP/HTTPS 地址，先预览，再对相同参数加 `-Apply`：

   ```powershell
   # 示例端口须换成新机已核实的 HTTP 代理端口
   pwsh -NoProfile -File .\install.ps1 -ConfigureProxy -Proxy http://127.0.0.1:10808
   # 确认预览后执行，自动备份并追加该机器的新记录
   pwsh -NoProfile -File .\install.ps1 -ConfigureProxy -Proxy http://127.0.0.1:10808 -Apply
   ```

   安装器要求目标已有有效 JSON 用户设置；缺失时停止，先按官方支持的设置方式建立，
   不通过复制旧机 settings、凭据或登录状态来满足前置条件。
   若新机是系统克隆或项目换过目录，遗留 hook 可能指向旧绝对路径；安装器不会猜测其归属，
   应先核对精确命令再人工处理。不要将整份 hooks 删除作为迁移步骤。
5. 对实际写入检查新机日志的 `applied-readback-verified`、备份及 SHA256，
   确认仅预期键变化；重复同一命令应返回 `NO_CHANGE`，不再写日志或备份。
   回滚只能使用该新机此次写入的备份和当前哈希，不能使用旧机日志中的恢复参数。
6. 文件读回只记为 `filesystem_projected`；客户端实际加载及真实使用分别验收。
   资格未解决时停在本地准备，不通过真实账号试验来取得通过结论。

仅迁移代码不代表完成新机投影，也不代表必须重做每项修改。
本仓不会自动配置 Windows 系统代理、代理客户端、Desktop、凭据或远端 CPA；
需要这些变更时先明确该机器的实际差异、操作范围和回滚方式。

## 8. 两个分支：资格不成立时停止，资格成立后按合规口径使用

本仓只区分下面两个分支，不存在“先把本地环境处理好再注册”的第三条路径：
Windows 系统设置、指纹、代理出口、浏览器、Claude Code/Desktop 与远端 CPA 的配置
都不能改变第 1 节的资格判断。本节政策引用于 2026-10-16 线上核对原文。

### A. 资格不成立（当前默认分支）

- 停在本地准备：只运行第 3、4 节的只读预检与可选配置修复，不注册、不登录、不发模型请求。
- 不实施、本仓也不实现这些动作：改时区或区域设置伪装所在地；安装防检测浏览器或指纹清洗工具；
  伪造 device ID、UA 或会话状态；用代理、住宅出口或 VPS 把所在地替换为受支持地区；
  用 CPA 或其他网关代持、中转订阅凭据；创建多账号或换号；以“测试风险”为目的注册账号后再观察。
- 与上述边界相关的 Usage Policy `Do Not Abuse Our Platform` 条款包括：
  “Access, facilitate, or provide others (including end users) with access to our products or
  services in violation of our Supported Regions Policy”；
  “Intentionally bypass or interfere with capabilities, restrictions, or guardrails established
  within our products, including by circumvention of the account sign-up or log-in process…”；
  “Utilize automation in account creation or to engage in spammy behavior”；
  “Circumvent a ban through the use of a different account…”；
  “Resell, proxy, or otherwise provide access to Claude through unauthorized means, including
  services that route requests through consumer subscriptions or misrepresent the product or
  client being used”。这些条款说明地区违规、绕过注册限制、换号和未授权中转的
  政策风险；不能据此推断每次操作是否被检测、记录，或必然影响后续申诉结果。
- 政策或实际情况变化时重新核对原文，不凭旧结论沿用：
  [Supported Regions Policy](https://www.anthropic.com/legal/supported-regions)、
  [Usage Policy](https://www.anthropic.com/legal/aup)、
  [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)。

### B. 资格成立后（实际所在地与主体均在受支持范围）

资格成立后，按官方口径使用并减少配置错误；这仍不保证不会遇到账号误判、
服务限制或停用，也没有可验证的“防封技巧”：

- 账户：使用真实、准确、本人有权使用的信息；不共享账户登录信息、凭据或 API key
  （Consumer Terms 第 2 节）。误判或停用时保存脱敏错误与时间，通过
  [官方警告与申诉说明](https://support.claude.com/en/articles/8241253-safeguards-warnings-and-appeals)
  处理，不靠清标识或新号试探“是否解封”。
- 付款：使用本人有权使用的真实付款方式，不借助来历不明的账号或渠道。
- 客户端：官方发行版本与官方认证流程，保持系统、工具与证书更新。第三方客户端不得伪装成
  Claude Code，也不得代持订阅凭据（[Claude Code 合规说明](https://code.claude.com/docs/en/legal-and-compliance)）。
- 网络：单账号使用稳定出口。Claude Code 用 HTTP/HTTPS 代理并保留 TLS 验证，不支持 SOCKS；
  分别核对 Process / User / Machine 与各 settings 层级的实际继承，不靠一次请求推断路由。
- 用量：按产品限额与 Retry-After 正常使用，避免无意义并发与重复发送。
- 网关：官方 API 与授权云通道按各自合同使用；授权云通道仍受地区政策约束，不构成绕过。

两个分支都不改变第 6 节的证据分层：本地只读检查与 fixture 为 repo_verified，
本机设置读回为 filesystem_projected；客户端实际加载与真实使用需各自独立证据，
在资格未解决前不通过真实账号试验补齐。
