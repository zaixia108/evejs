# EveJS 多人联机改造执行计划

> 分析日期：2026-07-19 | 目标版本：V9 | 目标客户端：24.01 build 3396210  
> 实施状态：阶段一 + 3-1/3-2 + PlayerConnect 一键联机已落地（见 `doc/MULTIPLAYER.md`）

---

## 总体结论

**架构底子比预期好得多——项目并非按"单机单玩家"设计。** 每条 TCP 连接有独立 session、服务调用每次显式传 session、世界状态按星系全局共享、PvP/Crimewatch/舰队/邮件/市场均已按多用户设计。同机开两个客户端用 `test` / `test2` 登录，今天大概率就能互见互打。

下面按优先级列出实施步骤。

---

## 阶段一：阻塞项（必修，修完局域网就能跑）

### 1-1 【致命】同账号双开导致 clientID 冲突 — DONE

- **根因**：`server/src/network/tcp/handshake.js` —— `clientID = 1000000 * account.id + proxyNodeId`，由**账号**派生而非由**连接**派生
- **后果**：`scene.sessions.set(session.clientID, session)` 同账号双开会互相覆盖；`sessionMatchesIdentity` 误判
- **已实施（方案 A）**：`SelectCharacterID` 在选角前通过 `sessionRegistry.findSessionsByUserID` 踢掉同账号其它活跃会话

### 1-2 【致命】远程客户端无法接入 — DONE

- 默认仍是 localhost-only（安全默认）
- **已实施**：
  - `StartMultiplayerHost.bat` / `tools/PlayerConnect/configure-multiplayer-host.js` 将 bind 改为 `0.0.0.0`，advertise 改为主机 IP
  - 导出 `_local/player-connect-bundle`（`Connect.bat` 一键改 start.ini、装 CA、启动客户端）
  - `Play.bat` 接受配置中的 `gameServerHost`，不再只允许 `127.0.0.1`
  - PlayerConnect health 返回 host/ports 信息
- 文档：`doc/MULTIPLAYER.md`

### 1-3 【安全】认证开关 — DONE（联机主机默认）

- 多人主机配置默认：`devAutoCreateAccounts=true`（好友首次登录建号）、`devSkipPasswordValidation=false`（禁止免密撞号）
- 可用 `--keep-dev-auth` 保留当前开发开关

---

## 阶段二：经济安全（应修，防止刷钱/回档）

### 2-1 市场下单跨 await 的 check-then-act

- **根因**：`services/market/marketProxyService.js` 的余额检查（:1206 `ensureCharacterHasFunds`）与扣款（:1223-1239 `debitCharacterWallet`）之间夹着 `await marketDaemonClient.call(...)`（:1817, :2357 等）
- **后果**：同一玩家双击下单或两人抢同一卖单可能透支钱包或重复成交
- **影响范围**：只有市场走 async + 外部 RPC 的交易流程有风险；其余服务均为同步调用，Node 单线程下安全
- **修改方案**：按 `characterID` 加互斥队列（一个 character 的经济操作串行化）

### 2-2 JSON 整表写回的持久化风险

- `server/src/newDatabase/index.js:364-390`：任何小写入 2 秒后整表 `JSON.stringify` 重写磁盘；崩溃最多丢 2 秒数据
- 热路径如 `itemStore.js:1489` 直接 `database.write(CHARACTERS_TABLE, "/", data)` 整表写
- 人多了以后 `items` / `characters` 表变大，写放大明显
- **修改方案**：中期换 SQLite；短期加定期主动 flush、提升 crash-safety

---

## 阶段三：多人体验完整化（宜补）

| # | 问题 | 位置 | 现状 | 修改方向 |
|---|---|---|---|---|
| 3-1 | 在线状态只返回自己 | `onlineStatusRuntime.js` | ~~互为 watchlist 才可见~~ | **DONE**：改为单向 watchlist 即可观察在线 |
| 3-2 | 登录页在线人数恒为配置值（默认 1） | `globalConfig.js` `serverStatusClusterUserCount` | 永远是假值 | **DONE**：`cluster_usercount` 使用 live session 数 |
| 3-3 | 重复登录只拒绝不踢旧会话 | `charService.js` + `loginTakeoverEnabled` | 旧 socket 僵尸化 | **DONE**（角色级 takeover + 账号级 eviction） |
| 3-4 | 舰队 Watchlist 伤害推送未实现 | `services/fleets/fleetRuntime.js` | 后勤"观察列表"窗口不更新血量 | 在 `broadcastDamageStateChange` 或 tick 里按 watchlist 推 | 3-5 | 舰队跃迁（fleet warp）只有开关没有执行 | `fleetObjectHandlerService.js:309` | 成员只能各自跃迁 | 补 `CmdFleetWarp` 路径 |
| 3-6 | 合同系统全是 stub | `_other/contractMgrService.js:69-83` | 创建/接受/完成/删除全返回 null | 从零实现 |

---

## 已知无需修改的部分（确认多用户就绪）

- 每 TCP 连接独立 ClientSession + 独立握手/加密上下文 ✅
- 服务调用每次显式传 session，无 `currentCharacter` 全局缓存 ✅
- 全局 sessionRegistry + `findSessionByCharacterID` 按角色寻址 ✅
- 世界状态按星系全局共享（`SolarSystemScene.sessions` 为 Map，广播遍历所有 session） ✅
- 玩家进入太空时带完整身份（characterID/corpID/securityStatus）；其他玩家可见 ✅
- PvP 锁定/攻击/伤害/Crimewatch/CONCORD 已实现 ✅
- NPC/Belt 鼠按星系共享，多玩家不重复刷 ✅
- 聊天本地频道按星系分组多用户 ✅
- 舰队系统按多用户设计（邀请/广播/广告/查找） ✅
- 邮件系统支持多收件人/公司/联盟 ✅
- 市场订单簿在独立 Rust 守护进程，任何玩家可见并成交 ✅
- 全局单 tick（`setInterval(() => this.tick(), 100)`），TiDi 按星系 ✅
- 无连接数上限 / maxClients 限制 ✅

---

## 建议验证路径

1. **阶段一完成后 — 同机双开**
   - 两个客户端用 `test` + `test2` 登录，进同一星系
   - 确认：互见飞船、local 聊天、互锁互射、组舰队

2. **阶段一完成后 — 局域网接入**
   - 一台机器跑服务器，另一台手工改 start.ini 后直接启动 exefile.exe
   - 确认：XMPP 聊天、图片加载、微服务/gateway 通联

3. **阶段二完成后 — 市场压力**
   - 多玩家同时对同一卖单下单，验证钱包/托管不出现负数

4. **整体压测**
   - `syncDynamicVisibilityForAllSessions`（`space/runtime.js:23206`）是 O（会话数 × 实体数）每 tick 全量重算，几十人同星系时监控 CPU
   - `server/tests/` 目录有 292 个测试文件（含双会话断言），改动后运行回归
