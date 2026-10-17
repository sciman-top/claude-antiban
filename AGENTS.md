# AGENTS.md - claude-antiban
**项目契约**: 2.0
**全局规则复核**: 9.87
**最后更新**: 2026-10-16

## 1. 落点与真源
- 本仓保留历史目录名，负责 Claude 使用资格说明、只读环境诊断与可选用户配置修复，不保证防封。操作说明真源为 `RUNBOOK.md`，运行行为以脚本为准。
- 七个入口：`prep-registration.ps1`（只读预检）、`Get-SurfaceReport.ps1`（只读环境画像；默认不联网、不写文件，出口检查须显式给出 HTTP 代理）、`hooks/check-exit-ip.ps1`（手动出口诊断）、`start-claude-chrome.cmd`（普通独立 profile）、`start-claude-chrome-leakless.cmd`（同一 profile，额外封堵 WebRTC 非代理 UDP）、`install.ps1`（默认预览的配置修复）、`Set-ClaudeLane.ps1`（默认只读 status；切换默认预览；ToRelay 按操作者自备的仓外源文件切换；OfficialPreflight 隔离预检、LaunchOfficial 显式启动）。
- CPA 部署、目录、运行防护与远端维护保留在 `D:\CODE\vps-ssh-launcher`；skills-manager 保留通用技能/MCP 管理，不复制为本仓运行代码。

## A. 不变量
- 实际所在地与主体资格按官方政策核对；代理出口、时区、语言、指纹或检测分数不代替资格。不自动注册、登录、调用模型或改动时区、凭据及设备标识；不为评分或规避伪装身份（不改区域、字体、UA、device ID 或会话数据）。启动器只允许封堵非代理 UDP 泄漏：默认入口不含身份或网络强制参数，唯一例外是显式可选入口 `start-claude-chrome-leakless.cmd`，逐条由 `qa/test-tools.ps1` 断言。
- 无固定出口默认值；出口检查须显式选择 HTTP/HTTPS 代理，只证明诊断请求当时的出口，不证明其他客户端、账号或未来路由。
- 不注册自动 hook；SessionStart 的 exit 2 不阻断会话或模型请求。历史 hook 只按精确路径与已知命令形式移除，保留未知命令及其他配置。
- 官方进程入口只清理其子进程中的认证、配置目录、provider、模型覆盖和 TLS 验证关闭变量，保留代理/CA 与父进程；启动前须匹配官方模板、无 key helper 且 CC Switch 未运行。CLI 仅加载 user settings，managed 设置仍生效；不把此隔离外推到 Desktop 或真实出口。
- 机器写入入口一 `install.ps1 -Apply`：仅精确移除本仓历史 SessionStart action，或显式补齐 HTTP_PROXY/HTTPS_PROXY；既有异值拒绝，大小写不重复写，遥测配置不改。
- 机器写入入口二 `Set-ClaudeLane.ps1 -Apply`：仅 `-ToOfficial`（整文件切换到本仓 `settings.official-anthropic.json`，只接受已识别 relay 形态或哈希识别的上一版仓库模板）、`-ToRelay -RelayVariant`（整文件投影操作者自备的仓外 relay 源文件；源文件须含 `env.ANTHROPIC_BASE_URL`、无 key helper 与 hooks，现状须为官方模板或已识别 relay；本仓不保存凭据，输出与 journal 不回显其中取值）或 `-RollbackBackup`（哈希钉死回滚）；install/lane 均在预览及写入前拒绝运行中的 CC Switch；GUID 原字节备份 + 前后 SHA256 + journal 阶段留痕同 install.ps1。
- 每次机器写入必须创建原字节备份并 append `machine-journal.md`（准备/读回阶段及哈希）；恢复必须绑定当前哈希，保留后续修改。运行安装器时避免其他客户端/工具同时写配置。
- `chrome-data/`、`qa/throwaway/` 永不入库；不得为回滚删除会话数据。机器配置与凭据只留本机。
- 公开远端仅接受脱敏内容：推送前按 RUNBOOK.md 第 7 节核对；2026-10-16 起公开远端以脱敏副本单根历史维护，早期完整历史在核对末态一致后删除、不留副本。新增条目不得引入出口 IP、代理供应商、端点域名、部署拓扑、真实主机名或用户路径。

## B. 最低门禁
- 脚本改动运行 `pwsh -NoProfile -File qa/test-tools.ps1`：临时配置验证权限模板、lane 状态分类、旧模板精确迁移、预览、精确删除、备份/回滚、配置保留、代理冲突、CC Switch 竞争、日志路径脱敏、作用域诊断与网络失败分支；禁止用真实账号或网络请求替代 fixture。
- 脚本语法使用 PowerShell Parser，文档/路径修改用 `git diff --check` 与引用核对。浏览器启动不属于自动化 fixture。
- 本地投影后 fresh read 设置并证明仅预期语义差异；文件读回不证明 host_loaded 或 live_accepted。

## C. 回滚与收口
- 代码用精确提交 revert；机器用安装器的 `-RollbackBackup / -ExpectedCurrentHash` 预览后显式 Apply，禁止直接恢复整份旧文件覆盖后来修改。

## D. Git profile
- Git profile: baseline=main upstream=origin/main; push only to the established public remote, keep public content sanitized, and preserve concurrent changes.
