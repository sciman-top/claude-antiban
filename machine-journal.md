# 机器投影审计留痕（append-only）

> 当前自动留痕范围为 `install.ps1 -Apply` 与 `Set-ClaudeLane.ps1 -Apply` 对用户设置的精确修复；范围与操作方法见 RUNBOOK.md。每台机器追加自己的动作、脱敏备份路径、前后 SHA256 与读回结果；预览和 NO_CHANGE 不写日志。非标准设置路径使用占位符，不记录绝对路径。以下历史操作保留，不能作为其他机器的配置模板或验收证据。
>
> 2026-10-15 的两条历史条目由早期写入器产生，记录了本机出口 IP、浏览器/系统代理环境结论等基建信息，只描述当时本机状态，不是使用资格或账号安全的证据；按 RUNBOOK.md 第 7 节，这类信息在对任何远端推送或对外分享前必须脱敏。脱敏必须覆盖 Git 历史：只改工作树不会把内容从提交历史里移除，所以对外传递要用脱敏后的副本，或先改写历史再推送。
>
> 机器标识一律写伪名 `<HOST-xxxxxxxx>`（机器名小写后的 SHA256 前 4 字节），由 `install.ps1` / `Set-ClaudeLane.ps1` 自动生成；备份路径中的用户名写 `%USERPROFILE%`。上述历史条目已按同一约定就地脱敏。

## 2026-10-15 | <HOST-f7563cc1>（补记：投影器之前的初始人工动作）
- 动作: hook 首次注册（python 直写 settings.json）；env 五键为本机既有配置（非本项目写入）
- 备份: settings.json.bak-20261015-exit-ip-guard
- 验证: hook 三分支独立测试过（正常 0/漂移 2/不可达 0）；settings reparse + diff 仅增 hooks 键
- 当日环境验证: <redacted>（2026-10-16 脱敏：原记录含出口 IP 与浏览器/系统代理环境结论）

## 2026-10-15 23:46 | <HOST-f7563cc1>
- 动作: env 新增[] / hook: noop-已注册 / env 异值跳过 0 项
- 预检出口: <redacted>（2026-10-16 脱敏）
- 冒烟: 
exit=0（期望 0）

## 2026-10-15 23:52 | <HOST-f7563cc1>
- 动作: env 新增[] / hook: noop-已注册 / env 异值跳过 0 项
- 预检出口: <redacted>（2026-10-16 脱敏）
- 冒烟: 
exit=0（期望 0）

## 2026-10-16 | 说明修正（不改写上述历史操作）
- 当前写入范围以 install.ps1 / RUNBOOK.md 为准：精确移除本仓历史 SessionStart action，或操作者显式选择后补齐 HTTP_PROXY/HTTPS_PROXY；不再注册 hook，不改遥测、时区、指纹、凭据或系统代理。
- 历史“出口/无告警/不可达 exit 0”等记录不证明使用资格、客户端实际路由或账号安全；SessionStart 不提供请求阻断。
- 后续写入使用 GUID 原字节备份、前后 SHA256、prepared 与 applied-readback-verified 阶段；只有 prepared 不代表成功。

## 2026-10-16T00:17:46.3962674+08:00 |
- phase: prepared
- actions: remove-legacy-session-start-action
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-env-4a139b3c86874f25abe447ab0c19de18
- before_sha256: 9ecbeb352342960745247f8e8d7e20d9b95e4cd394f677a950e594a1bb70726b
- after_sha256: 8853ec5323d956f23a60d8bf685d90fd41c131fef374f4872eeb53c44b0c2028
- phase: applied-readback-verified
- metadata_correction: COMPUTERNAME 环境变量为空导致原日志缺少机器名；后续版本改用 Environment.MachineName。
- machine_name_readback: <HOST-f7563cc1>（主代理通过 Environment.MachineName 读回，按本文件头注写的伪名脱敏）
- execution_boundary: 独立复核等待期间检测到本任务已授权的 hook 移除已提前执行，执行来源未确认；主代理已中断相关复核会话，独立核对备份/当前哈希与完整 JSON 语义差异，仅删除该 action，其余设置保留。此记录不构成独立复核通过、host_loaded / live_accepted。
- idempotence_readback: 主代理再次运行 -RemoveLegacyHook -Apply 返回 NO_CHANGE；settings 与 journal 哈希均保持不变。

## 2026-10-16T08:03:44.7780044+08:00 | <HOST-f7563cc1>
- phase: manual-entry
- actions: retire-machine-side-lane-copies
- detail: 2026-10-15 会话部署的机器侧副本已退役（~/.claude/scripts/Set-ClaudeLane.ps1、~/.claude/settings.official-anthropic.json、Desktop/Chrome-Claude-Dedicated.lnk）；真源收编为本仓 Set-ClaudeLane.ps1 + settings.official-anthropic.json，专用浏览器统一 start-claude-chrome.cmd
- verification: qa/test-tools.ps1 14/14 PASS；本仓 Set-ClaudeLane status=current_lane=official/variant_ready=true/cc_switch_running=false；settings.json 哈希未变
- rollback: git revert 本次提交可撤销仓内工具；机器侧副本与仓内提交字节一致（变体 sha256 06341df3 开头）可随时重建；旧 ~/.claude/settings-backups/bak-lane-* 历史备份保留未动

## 2026-10-16 | <HOST-f7563cc1>（补记：CC Switch 分组与合并模板修复）
- 动作: 人工 sqlite 事务（非本仓写入器）——删除 cc-switch.db 中 claude-desktop 分组 3 个 provider 及其 3 条 endpoint；同批清洗 settings 表 common_config_claude 模板：移除 DISABLE_LOGIN_COMMAND/DISABLE_LOGOUT_COMMAND/DISABLE_UPGRADE_COMMAND/DISABLE_EXTRA_USAGE_COMMAND、CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK/CLAUDE_CODE_ATTRIBUTION_HEADER/CLAUDE_CODE_MAX_OUTPUT_TOKENS/CLAUDE_CODE_EFFORT_LEVEL 八键与顶层 model 钉定
- 备份: ~/.cc-switch/backups/manual-pre-claude-official-clean-20261015-212133.db（操作前 sqlite backup API 全量快照）
- 验证: 事务后读回——providers/provider_endpoints 按 app_type 计数 claude-desktop=0 且其余分组计数不变；模板重解析 JSON 合法且零锁定键
- 回滚: 关闭 CC Switch 后用该快照整库恢复
- 执行来源: 相邻 vps-ssh-launcher 会话主代理（用户授权的修复事务）

## 2026-10-16T08:46:10+08:00 | <HOST-f7563cc1>
- 动作: 删除单根历史改写前保存的完整历史 bundle（D:\CODE\claude-antiban-history-private-20261016.bundle）以及本机隔离克隆暂存
- 依据: 公开远端 origin/main 已含全部 16 个跟踪文件；旧末态与公开树的内容差异只有 LICENSE、本文件措辞与脱敏检查脚本，无独有内容；本机 .git 已不含旧对象
- 验证: git rev-list origin/main = 4；旧 tip 对象在本机 git cat-file 已不可取；已推送历史对出口 IP、主机名、用户路径与端口的扫描 0 命中
- 回滚: 不可逆；公开远端只保留脱敏后的单根历史，旧提交序列不再保留副本

## 2026-10-16T09:07:28+08:00 | <HOST-f7563cc1>
- 动作: 公开远端可达历史二次脱敏——`settings.official-anthropic.json` 在旧提交 9dff6e7 / 6c1e04c / 3d50ded / 9baf94d 中仍含本机用户名绝对路径（RUNBOOK 第 7 节与 qa 脱敏回归检查均判定为 user-path 泄漏）；已把该文件的历史版本统一替换为本仓当前的 `%USERPROFILE%` 占位版并 force-push
- 依据: AGENTS.md §A「新增条目不得引入出口 IP、代理供应商、端点域名、部署拓扑、真实主机名或用户路径」；改写前后 tip 树一致，差异仅为路径占位
- 验证: 改写前后 tip tree 同为 3dfa2a01a8e62d599a200f97e70b1f64800e41a9；全量对象扫描（23 blob）对用户路径 0 命中；fresh clone 复核 0 命中；远端 main 由 089d9708 前移到 2bd5f7a5（force-with-lease 期望值 089d9708）；本机执行 `reflog expire --expire=now --all` 与 `gc --prune=now` 后旧对象已不可取
- 修正: 2026-10-16T08:46:10 记录里的「用户路径 0 命中」只覆盖了当时 tip 树，未覆盖可达历史；本次脱敏后该结论对全部可达历史成立
- 残留: GitHub 服务端未引用对象在其 GC 前仍可按已知 SHA 取回（已实测 089d9708 与旧 blob 均可 fetch）；删除重建仓库是唯一可保证清除的路径
- 回滚: 无独立副本；若需恢复旧历史，只能在 GitHub 端尚未 GC 时按 SHA 取回
- 执行来源: 当前 claude-antiban 会话主代理（用户授权“按推荐连续执行修复”）

## 2026-10-16T09:16:30.6466319+08:00 | <HOST-99e0671a>
- phase: prepared
- actions: switch-lane-to-official
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-lane-52df5a17ff934cea8e062599858afb2d
- before_sha256: bdcf9b00a2d66066ee0ac94a86f8aba7514a3724424e45eb4ccf714f8b125899
- after_sha256: 8853ec5323d956f23a60d8bf685d90fd41c131fef374f4872eeb53c44b0c2028
- phase: applied-readback-verified

## 2026-10-16T11:43:15.8199207+08:00 | <HOST-99e0671a>
- phase: prepared
- actions: refresh-known-official-template
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-lane-189fc1b1163f4a81816053b462a8a7fc
- before_sha256: 8853ec5323d956f23a60d8bf685d90fd41c131fef374f4872eeb53c44b0c2028
- after_sha256: bdba811e17f28c59c9aa2bb9d52b4feb89d5b9d1547dccad827aa55d50d5f697
- phase: applied-readback-verified

## 2026-10-16 | <HOST-99e0671a>（补记：CC Switch claude 分组与合并模板修复）
- 动作: 人工 sqlite 事务（非本仓写入器）——删除 cc-switch.db 中 claude 分组 3 个中继 provider 及其 3 条 endpoint（均含 ANTHROPIC_BASE_URL，其一为当前激活项）；同批清洗 settings 表 common_config_claude 模板：移除 DISABLE_LOGIN_COMMAND/DISABLE_LOGOUT_COMMAND/DISABLE_UPGRADE_COMMAND/DISABLE_EXTRA_USAGE_COMMAND、CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK/CLAUDE_CODE_ATTRIBUTION_HEADER/CLAUDE_CODE_MAX_OUTPUT_TOKENS/CLAUDE_CODE_EFFORT_LEVEL 八键与顶层 model 钉定
- 备份: %USERPROFILE%\.cc-switch\backups\manual-pre-claude-official-clean-20261016-150847.db（操作前 sqlite backup API 全量快照）
- 验证: 事务后读回——providers/provider_endpoints 按 app_type 计数 claude=0 且其余分组（codex/gemini）计数不变；模板重解析 JSON 合法且零锁定键、无顶层 model
- 回滚: 关闭 CC Switch 后用该快照整库恢复
- 执行来源: claude-antiban 会话主代理（用户授权"按推荐连续执行修复和优化"）；与 <HOST-f7563cc1> 2026-10-16 同型修复对齐。本机 ~/.claude/settings.json 未受影响（CC Switch 全程未运行），lane 保持 official

## 2026-10-16T15:17:47 | <HOST-b23a6a84>
- operation: cc-switch-official-profile
- phase: prepared
- backup: %USERPROFILE%/.cc-switch/claude-official-repair-581e510c5a01410782cc245fb6a63524
- before_sha256: 20de04799cdd0e7781ef544973763a12aca57b2d044629cfd49846ce8a125d41,7cb03bf9ad286a6a955a97dae0780eed65b7943bc1c7c31617020549adc7504f

## 2026-10-16T15:17:47 | <HOST-b23a6a84>
- operation: cc-switch-official-profile
- phase: applied-readback-verified
- backup: %USERPROFILE%/.cc-switch/claude-official-repair-581e510c5a01410782cc245fb6a63524
- after_sha256: 2d02423eefbe8e86f7e05baf43016bd53b297972a614c5b5897b7213179b269b,845e345641c1a2e5379635995f1fc6c0cd19ed73a30a36371d07c10705b7e684
- verification: accepted empty Claude group retained; other app groups and credentials preserved; no client launched
- actions: accepted the concurrent empty Claude provider group; removed orphan currentProviderClaude and residual CLAUDE_CODE_SUBAGENT_MODEL only
- rollback: close CC Switch; run repair.py beside receipt.json with --rollback <this backup directory> and --expected <both after hashes>; preview before --apply; changed current or backup hashes are refused
- evidence: raw database and preferences backups verified; fixture covered no-op, drift refusal, exact rollback and concurrent-provider refusal; real client launch and account acceptance not performed
- rollback-scope: earlier full-database snapshot instructions are historical only; do not overwrite subsequent changes. The hash-bound repair.py rollback restores only this supplemental repair and does not recreate the deleted providers.

## 2026-10-16T20:32:43.6801662+08:00 | <HOST-f7563cc1>
- phase: prepared
- actions: refresh-known-official-template
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-lane-2b34c8ee7a5d49898c0be23c8061d92d
- before_sha256: 8853ec5323d956f23a60d8bf685d90fd41c131fef374f4872eeb53c44b0c2028
- after_sha256: bdba811e17f28c59c9aa2bb9d52b4feb89d5b9d1547dccad827aa55d50d5f697
- phase: applied-readback-verified

## 2026-10-16T21:18:07.3779328+08:00 | <HOST-f7563cc1>
- phase: prepared
- actions: switch-lane-to-relay
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-lane-9bc96591a1b349c2bcfe17532a1bd7cd
- before_sha256: bdba811e17f28c59c9aa2bb9d52b4feb89d5b9d1547dccad827aa55d50d5f697
- after_sha256: 70e7edc85f88a28b671c8f81f2607a4b478b838f9ff6a5f1256d133b75b7d688
- phase: applied-readback-verified

## 2026-10-17T01:29:23.2394355+08:00 | <HOST-f7563cc1>
- phase: prepared
- actions: switch-lane-to-official
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-lane-e78c0358295d42f1b95c7f7075d191a8
- before_sha256: 70e7edc85f88a28b671c8f81f2607a4b478b838f9ff6a5f1256d133b75b7d688
- after_sha256: bdba811e17f28c59c9aa2bb9d52b4feb89d5b9d1547dccad827aa55d50d5f697
- phase: applied-readback-verified

## 2026-10-17T01:31:01.6462854+08:00 | <HOST-f7563cc1>
- operation: cc-switch-orphan-pointer-repair
- phase: prepared
- actions: currentProviderClaude,currentProviderClaudeDesktop
- backup: %USERPROFILE%\.cc-switch\backups\claude-pointer-repair-20261017-4c5738cda61d4ebd9f24f447a3fda831\settings.before.json
- before_sha256: 41802a83f48b0a6d8ee01b8c88cb5c4ba6cb0578d6d2302c71c1d8d074db74c8
- after_sha256: 781d6c3d2e523496eecee050e86ae21cefbcdb99cf30527e0a6468a959954f86
- database: read-only; no provider, endpoint or credential changes
- phase: applied-readback-verified

## 2026-10-17T01:33:35.0426512+08:00 | <HOST-f7563cc1>
- operation: cc-switch-orphan-pointer-repair
- phase: prepared
- actions: restore-cc-switch-pointer-backup
- backup: %USERPROFILE%\.cc-switch\backups\claude-pointer-repair-20261017-4c5738cda61d4ebd9f24f447a3fda831\settings.before-rollback-1ea9aa6e0cc74003802abbe274a83e11.json
- before_sha256: 781d6c3d2e523496eecee050e86ae21cefbcdb99cf30527e0a6468a959954f86
- after_sha256: 41802a83f48b0a6d8ee01b8c88cb5c4ba6cb0578d6d2302c71c1d8d074db74c8
- database: read-only; no provider, endpoint or credential changes
- phase: applied-readback-verified

## 2026-10-17T01:33:54.2720819+08:00 | <HOST-f7563cc1>
- operation: cc-switch-orphan-pointer-repair
- phase: prepared
- actions: currentProviderClaude,currentProviderClaudeDesktop
- backup: %USERPROFILE%\.cc-switch\backups\claude-pointer-repair-20261017-4c5738cda61d4ebd9f24f447a3fda831-v2\settings.before.json
- before_sha256: 41802a83f48b0a6d8ee01b8c88cb5c4ba6cb0578d6d2302c71c1d8d074db74c8
- after_sha256: efd2b55b86761c89293a8d1b0f3606586adca2c52c31b86b181cec0d9c2de926
- database: read-only; no provider, endpoint or credential changes
- phase: applied-readback-verified
- verification: final settings differ semantically by exactly the two removed pointer keys; timestamp strings and all other fields preserved; database SHA256 unchanged; repeat returned NO_CHANGE
- recovery: the first serialization changed an unrelated timestamp format; hash-bound rollback restored original bytes before the corrected repair using DateKind String; only this final attempt has semantic acceptance
- rollback: run repair.ps1 beside this backup with -Rollback -ExpectedCurrentHash efd2b55b86761c89293a8d1b0f3606586adca2c52c31b86b181cec0d9c2de926; preview first, then -Apply; newer settings or database hashes are refused
- boundary: filesystem_projected; no client restart, OAuth login, token refresh or model request

## 2026-10-17T10:57:39.3412510+08:00 | <HOST-f7563cc1>
- phase: prepared
- actions: add-HTTP_PROXY,add-HTTPS_PROXY
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-env-51a1817f0fd8465e8a135b232265fdc4
- before_sha256: bdba811e17f28c59c9aa2bb9d52b4feb89d5b9d1547dccad827aa55d50d5f697
- after_sha256: 7dede29f26687ae2137c82cd9f92f4aa5c4969983f432baade182157012090ce
- phase: applied-readback-verified

## 2026-10-17T11:06:23.2269245+08:00 | <HOST-f7563cc1>
- phase: prepared
- actions: restore-unchanged-snapshot
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-env-a57cc62b47774d429fcdf461f4a9f6c2
- before_sha256: 7dede29f26687ae2137c82cd9f92f4aa5c4969983f432baade182157012090ce
- after_sha256: bdba811e17f28c59c9aa2bb9d52b4feb89d5b9d1547dccad827aa55d50d5f697
- phase: applied-readback-verified

## 2026-10-17T12:46:21+08:00 | <HOST-f7563cc1>
- operation: manual-env-cleanup
- phase: prepared
- actions: remove-machine-scope-HTTP_PROXY, remove-machine-scope-HTTPS_PROXY
- executor: user manual via elevated PowerShell; outside installer scope; recommended and verified by agent session
- note: old values not recorded per section 7; rollback requires operator-provided values
- phase: applied-readback-verified
- verification: Machine scope HTTP_PROXY/HTTPS_PROXY absent; User scope unchanged; ALL_PROXY unchanged and equal across scopes; NO_PROXY differs across scopes (values not recorded), left as operator policy
- boundary: filesystem_projected; sanitized manual-change record, not installer output

## 2026-10-17T13:43:47+08:00 | <HOST-f7563cc1>
- operation: manual-env-cleanup
- phase: prepared
- actions: remove-machine-scope-ALL_PROXY, remove-machine-scope-NO_PROXY
- executor: elevated PowerShell on user instruction (agent-executed via UAC); outside installer scope
- note: old values not recorded per section 7; rollback requires operator-provided values
- phase: applied-readback-verified
- verification: Machine scope has no proxy variables remaining (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY all absent); User scope all four present and unchanged; proxy policy single-sourced at user scope
- boundary: filesystem_projected; sanitized manual-change record, not installer output

## 2026-10-17T13:54:23.7426475+08:00 | <HOST-f7563cc1>
- operation: manual-machine-env-cleanup
- phase: prepared
- actions: remove-machine-scope-HTTP_PROXY,remove-machine-scope-HTTPS_PROXY
- executor: authorized UAC PowerShell 7
- backup: %LOCALAPPDATA%\claude-antiban\machine-env-backups\machine-proxy-2c3ff79d1bb24a85a83b0bc766400f09.bin (DPAPI CurrentUser encrypted)
- before_sha256: 85b692e35ed3d81c891d3abeb8ba550ca533128ce87046260ac9b25250e26ac8 (encrypted snapshot file)
- after_sha256: pending
- hash_basis: before is the protected backup file; final is the canonical target-absent state
- note: raw values omitted; User scope unchanged; Machine ALL_PROXY/NO_PROXY were present before this operation and were preserved within the authorized scope

- phase: applied-readback-verified
- after_sha256: a53e6b8589861e35b764fbed24cf915d339a3d239b2352e4bff47c4890cc9922
- verification: Machine HTTP_PROXY/HTTPS_PROXY absent; User scope unchanged; Machine ALL_PROXY/NO_PROXY still present and unchanged
- reconciliation: differs from the 2026-10-17T13:43:47 entry reporting all Machine proxy variables absent; reappearance source unresolved; direct Scheduled Task action and Run-key scan found no explicit environment writer
- rollback: restore from local DPAPI backup only if both target Machine values remain absent; preserve later values
- boundary: filesystem_projected; no process restart, login, token refresh, model request, or route probe

## 2026-10-17T14:09:06+08:00 | <HOST-f7563cc1>
- operation: desktop-direct-out-guard
- phase: prepared
- actions: create-outbound-block-rules(claude-desktop-direct-out-guard), remove-machine-scope-ALL_PROXY, remove-machine-scope-NO_PROXY
- executor: agent session via elevated pwsh payload (UAC approved); user authorized "按你的推荐/建议连续执行修复和优化"
- firewall: four outbound Block rules (TCP 80,443 + UDP 443 QUIC), two scoped to the Desktop MSIX Claude.exe image path, two to the package SID from AppContainer mappings; loopback proxy traffic is unfiltered so proxied egress is unaffected; package rules also cover in-package helper images; cowork-svc.exe direct outbound intentionally not blocked
- env correction: the 13:43:47 removal reported all Machine proxy variables absent but actually left ALL_PROXY/NO_PROXY as EMPTY-STRING registry values; pwsh coerces $null to an empty string when calling [Environment]::SetEnvironmentVariable; empty values read as absent under truthiness checks and present under null checks, which fully explains the 13:43 vs 13:54 discrepancy above; there was no reappearance and no hidden environment writer
- current env state: HKLM ALL_PROXY/NO_PROXY remain empty-string values, functionally inert because User scope defines both names and shadows Machine scope; a corrective Remove-ItemProperty payload was prepared but its UAC prompt was cancelled by the operator, so proper deletion is pending and reduces to: Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -Name ALL_PROXY,NO_PROXY
- phase: applied-readback-verified
- verification: elevated readback plus independent non-elevated readback agree on all four rules enabled=True direction=Outbound action=Block with expected protocols/ports; re-verified still present after this file's concurrent edits; no client restart; proxy-down failure path not live-tested (would require killing the local proxy mid-use)
- boundary: filesystem_projected
- rollback: Remove-NetFirewallRule -Name ClaudeDesktop-DirectOutGuard-TCP-Prog,ClaudeDesktop-DirectOutGuard-TCP-Pkg,ClaudeDesktop-DirectOutGuard-QUIC-Prog,ClaudeDesktop-DirectOutGuard-QUIC-Pkg; Machine env empty strings deletable with the command above
- residue: program-path rules stop matching after the Desktop package updates (versioned image path changes); re-create with the same payload then; package-SID rules intend to survive updates but matching of full-trust desktop-bridge processes is not live-verified

2026-10-17T16:05:12+08:00 | <HOST-f7563cc1>
- operation: manual-machine-env-cleanup
- phase: prepared
- actions: remove-machine-scope-ALL_PROXY,remove-machine-scope-NO_PROXY (captured entries were empty REG_SZ markers)
- executor: user-run protective command in elevated PowerShell 7
- backup: %LOCALAPPDATA%\claude-antiban\machine-env-backups\machine-empty-proxy-bfd2e9070de243c98ca300099c57383a.bin (DPAPI CurrentUser encrypted)
- backup_sha256: 1dfaa8fc3933a6656d540fb148c323070393523d7b02f5461e7c871ae635ee55
- before_sha256: 71fde2ba85c3af960a78d38190d4c5bc9bbff7c35f2c0c40e75af9b38d830b51
- after_sha256: ba5072ea520a1a797caba425297f206ea7e92db00558df8edf69b9c9c125483f
- hash_basis: canonical target-property state; raw values omitted; encrypted backup digest is separately recorded
- phase: applied-readback-verified
- verification: protected snapshot readback matched the before hash; post-run readback matched the recorded target hash; raw values omitted; User-scope values were outside the action scope
- rollback: restore only from this DPAPI backup if the target properties remain absent; preserve any later values
- boundary: filesystem_projected; no client restart, OAuth login, token refresh, model request, or route probe

## 2026-10-17T18:47:50.6204527+08:00 | <HOST-f7563cc1>
- phase: prepared
- actions: repair-permissions-defaultMode,repair-permissions-disableAutoMode,repair-permissions-disableBypassPermissionsMode
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-env-7a79b715f89f45b69cfe7db5448b0537
- before_sha256: a6091c378cb430aecebe4e01b3083823988f6270fc82f1953e5cedf2fe92e288
- after_sha256: d90a5b812e58eed2a4a5b265aa37fa3c5d40d2b791a75ab3d23262c5920378ca
- phase: applied-readback-verified

## 2026-10-17T19:44:16.8517805+08:00 | <HOST-f7563cc1>
- operation: authorized-permission-baseline-unlock
- phase: applied-readback-verified
- actions: set-permissions-defaultMode-bypassPermissions,remove-permissions-disableAutoMode,remove-permissions-disableBypassPermissionsMode
- executor: ZCode session; direct settings.json edit authorized by the operator; the earlier 17:0x unlock was reverted by the 18:47:50 repair, which this baseline change supersedes
- backup: %USERPROFILE%\.claude\settings.json.bak-claude-env-7a79b715f89f45b69cfe7db5448b0537 (pre-repair snapshot); the 18:47 repaired bytes remain recoverable via that entry after_sha256
- before_sha256: d90a5b812e58eed2a4a5b265aa37fa3c5d40d2b791a75ab3d23262c5920378ca
- after_sha256: b215173bc37893446fae9a42c82df84e40570e3ded22a3e29d4d241407c21423
- boundary: filesystem_projected; deny list preserved; no client restart; Desktop session restart still required for live acceptance
- followup: settings.official-anthropic.json template, install.ps1 repair boundary, qa assertions and RUNBOOK updated in this commit so -RepairPermissions enforces the new baseline instead of reverting it
