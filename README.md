# claude-antiban

Claude 使用资格说明、只读环境诊断与可选用户配置修复。**不保证防封**：实际所在地与
主体资格以官方政策为准，代理出口、时区、语言、指纹或检测分数都不代替资格。

## 五个入口

| 入口 | 作用 | 默认行为 |
| --- | --- | --- |
| `prep-registration.ps1` | 只读预检 | 不登录、不调用模型 |
| `hooks/check-exit-ip.ps1` | 手动出口诊断 | 须显式给出预期出口与代理 |
| `start-claude-chrome.cmd` | 普通独立 profile 启动专用浏览器 | 继承正常网络配置 |
| `install.ps1` | 用户配置修复 | 默认预览，`-Apply` 才写机器 |
| `Set-ClaudeLane.ps1` | Claude 配置 lane 切换 | 默认只读 status |

## 文档

- 操作说明真源：[RUNBOOK.md](RUNBOOK.md)（资格判断、环境检查、配置修复与回滚、新机迁移）
- 跨宿主协作契约：[AGENTS.md](AGENTS.md)
- 机器写入留痕：`machine-journal.md`（append-only，机器标识写伪名 `<HOST-xxxxxxxx>`）

## 边界

- 本仓工具默认不联网、不改配置；机器写入有原字节备份、前后 SHA256 与读回验证，可精确回滚。
- `chrome-data/`、`qa/throwaway/`、凭据、浏览器会话与实际代理配置不入库、不上传。
- 仓库内容已脱敏（2026-10-16）：不含出口 IP、代理供应商、端点域名与部署拓扑；
  早期完整历史仅存本机备份，不在任何远端。
