# claude-antiban

Claude 使用资格说明、只读环境诊断与可选用户配置修复。**不保证防封**：实际所在地与
主体资格以官方政策为准，代理出口、时区、语言、指纹或检测分数都不代替资格。

## 边界声明（先读）

目录名 `claude-antiban` 是历史名称，不代表本仓提供防封能力，本仓也不提供任何规避手段。
以下动作不在本仓范围内，也不会降低风险：

- 改时区或区域设置伪装所在地；安装防检测浏览器或指纹清洗工具；伪造 device ID、UA 或会话状态。
- 用代理、住宅出口或 VPS 把所在地替换为受支持的地区。
- 用 CPA 或任何网关代持、中转 Free/Pro/Max 订阅凭据，或用第三方客户端伪装成 Claude Code。
- 创建多账号或换号规避封禁，或以“测试风险”为目的注册账号再观察是否被停用。

这些动作命中 Anthropic Usage Policy 的 `Do Not Abuse Our Platform` 段落。资格判断与
两个分支的具体动作见 [RUNBOOK.md](RUNBOOK.md) 第 1 节与第 8 节。

## 五个入口

| 入口 | 作用 | 默认行为 |
| --- | --- | --- |
| `prep-registration.ps1` | 只读预检 | 不登录、不调用模型 |
| `Get-SurfaceReport.ps1` | 只读环境画像报告（系统区域/字体/浏览器 profile/代理来源） | 默认不联网、不写文件；出口检查须显式给出 HTTP 代理 |
| `hooks/check-exit-ip.ps1` | 手动出口诊断 | 须显式给出预期出口与代理 |
| `start-claude-chrome.cmd` | 普通独立 profile 启动专用浏览器 | 继承正常网络配置 |
| `install.ps1` | 用户配置修复 | 默认预览，`-Apply` 才写机器 |
| `Set-ClaudeLane.ps1` | lane 切换、隔离的官方进程预检与显式启动 | 默认只读 status |

## 文档

- 操作说明真源：[RUNBOOK.md](RUNBOOK.md)（资格判断、环境检查、配置修复与回滚、新机迁移）
- 跨宿主协作契约：[AGENTS.md](AGENTS.md)
- 机器写入留痕：`machine-journal.md`（append-only，机器标识写伪名 `<HOST-xxxxxxxx>`）

## 边界

- 本仓工具默认不联网、不改配置；机器写入有原字节备份、前后 SHA256 与读回验证，可精确回滚。
- `-OfficialPreflight` 只在隔离子进程中检查；`-LaunchOfficial` 才显式打开 Claude Code。两者保留代理与可信 CA 配置，不证明实际路由或使用资格。
- `chrome-data/`、`qa/throwaway/`、凭据、浏览器会话与实际代理配置不入库、不上传。
- 仓库内容已脱敏（2026-10-16）：不含出口 IP、代理供应商、端点域名与部署拓扑；
  早期完整历史在核对末态一致后已删除，公开远端只保留脱敏后的单根历史。
