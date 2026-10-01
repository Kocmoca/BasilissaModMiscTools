# 已验证接口清单（API Verification Status）

本文件记录 Mod Misc Tool 开发过程中**实际在设备上测过**的接口与方法，以及每一条的结论。
标记含义：

* `[已验证可用]` —— 设备实测通过，可以放心直接调用（本 mod 内部不再做存在性探测）。
* `[已验证失败]` —— 设备实测**明确不可用**，代码里保留同名注释，避免以后重复踩坑。
* `[部分可用]` —— 有明确边界条件，必须按备注里的方式使用。
* `[未验证]` —— 尚未实测，仅按原版实现推断。

> 失败条目的原始证据都来自 `Lua.log`（日志前缀 `[ModMiscTool]`）；
> 原生崩溃看 tombstone backtrace。

---

## 1. 玩家对象与幽灵池（Gameplay 层）

| # | 接口 / 方法 | 状态 | 证据与备注 |
|---|---|---|---|
| 1 | `PlayerManager():AddPlayer()` 运行时新增玩家 | `[已验证失败]` | **原生闪退** `signal 11 SIGSEGV … GameCore::AI::Diplomatic::GetDiplomaticStateIndex(PlayerTypes) const+12`。运行时加玩家会让 AI 外交子系统空指针；此后也绝不能传 `-1` 玩家 id。 |
| 2 | `PlayerConfigurations[slot]` 的 `SetCivilizationTypeName` / `SetLeaderTypeName` / `SetIsMinorCiv` / `SetSlotStatus` | `[部分可用]` | 调用成功、**回读也正确**，但引擎**不会**因此生成玩家对象（见第 3 条）。仅能改“配置”，不能造“玩家”。 |
| 3 | `Players[slot]:StartCityState()`（运行时补建槽位，抄 EXera 的 `CreateCityStatePlayer`） | `[已验证失败]` | 日志 `slot N configured but not created by engine`：`Players[slot]` 恒为 `nil`。城邦、主要文明两条路都试过，结论一致。EXera 里 `CreateCityStatePlayer` / `ReuseExistingCityState` **全工程零调用点（死代码）**，它真正在用的是 `ConvertCityToCityState`（转换已有玩家的城市，从不创建玩家）。 |
| 4 | `UnitManager.InitUnit(playerID, 'UNIT_SETTLER', -1, -1)` 造地图外单位 | `[已验证可用]` | 日志 `offMapSettlerCreated=true`；幽灵玩家全程有单位，不会被判灭亡。 |
| 5 | `UnitManager.Kill(unit, false)` 清掉图上单位 | `[已验证可用]` | 日志 `killed=3`（城邦）/`killed=2`（主要文明）。 |
| 6 | `UnitManager.PlaceUnit(unit, -1, -1)` 把单位“挪”到地图外 | `[已验证失败]` | 调用不报错，但引擎随后把单位**拉回地图**，幽灵重新落地建城（表现为“所有玩家都不是幽灵”）。搬离地图只能用第 4+5 条的组合。 |
| 7 | 搬离顺序：先 `Kill` 再 `InitUnit` | `[已验证失败]` | 中间存在“零单位”瞬间，引擎判定玩家灭亡，幽灵直接死掉。**必须 `InitUnit` 在前、`Kill` 在后**。 |
| 8 | `Game:SetProperty` / `Game:GetProperty` 存幽灵池 | `[已验证可用]` | 池子随存档保存，读档后仍可读回。 |
| 9 | `player:IsMajor()` / `IsBarbarian()` / `GetCapitalCity()` / `GetUnits()` | `[已验证可用]` | gameplay 层判定与筛选正常。 |
| 10 | `player:IsMinor()` | `[已验证失败]` | gameplay 层调用报 `function expected instead of nil`（该 API 只有 UI 层有）。城邦候选列表因此改由 UI 层算好、经 `ExposedMembers` 交给 gameplay。 |
| 11 | `Game.GetLocalPlayer()` / `GameDefines.MAX_PLAYERS`（=64） | `[已验证可用]` | 用于跳过本机玩家、遍历槽位。 |
| 12 | 引擎能创建的城邦玩家数量 | `[已验证可用]` | 与请求值无关，**实测上限 = 数据库里的城邦文明条数**：请求 62 → 实际 36。 |

## 2. 扩容路线（“抬上限”是唯一走得通的路）

| # | 接口 / 方法 | 状态 | 证据与备注 |
|---|---|---|---|
| 13 | `MapSizes.MaxCityStates` / `MapSizes.MaxPlayers`（DB 抬上限） | `[已验证可用]` | 抬到 62 后设置界面可选范围变大。 |
| 14 | `GameConfiguration.SetValue("CITY_STATE_COUNT", maxMinor)`（前端） | `[已验证可用]` | 玩家选 6 → 引擎开局建 **36** 个城邦（原来只有 6）。 |
| 15 | `GameConfiguration.SetParticipatingPlayerCount()` + `MapConfiguration.GetMaxMajorPlayers()`（前端） | `[已验证可用]` | 玩家选 4 → 引擎开局建 **26** 个主要文明（槽位 0..25）。 |
| 16 | `MapConfiguration.GetMaxMinorPlayers()` / `GetHiddenPlayerCount()` | `[已验证可用]` | 预算计算用；`n = 目标 + hidden` 口径要一致。 |
| 17 | 槽位预算（主要文明与城邦抢同一批槽位） | `[已验证可用]` | 实测 26 主要文明 + 36 城邦 = 62，正好吃满 `MAX_PLAYERS(64) - 野蛮人 - 自由城市`；给城邦预留 36 个才不会把城邦挤没。 |
| 18 | “从槽位 id 大的那头开始搬” | `[已验证可用]` | 引擎先排主要文明（0 起）再排城邦。玩家选 4 主要文明 + 6 城邦时，搬走 4..25 与 32..61，图上剩 0..3 与 26..31 —— 正是玩家自己选的那批。 |

## 3. 前端 / UI 层

| # | 接口 / 方法 | 状态 | 证据与备注 |
|---|---|---|---|
| 19 | `Events.SystemUpdateUI` 在“创建游戏”界面监听 | `[已验证失败]` | 该事件在设置界面**根本不触发**（只有分辨率变化/恢复 UI/触摸输入），hook 完全静默。改用 `ContextPtr:SetRefreshHandler` + `RequestRefresh()` 轮询。 |
| 20 | `MapSize_ValueChanged ~= nil` 判定“创建游戏”上下文 | `[已验证可用]` | 该上下文 include 过 `GameSetupLogic`；对局内没有这个全局函数，因此不会误改对局内设置。 |
| 21 | `WriteCustomData` / `ReadCustomData` | `[部分可用]` | **同进程有效**：设置界面写 → 对局内读得到（幽灵流程即依赖此）。**跨启动无效**：完全退出进程后重开新局读不到（两次启动探针都是 `VERDICT=first-write`）。可当“设置界面 → 对局内”的传递通道，**不能当持久化存储**。 |
| 22 | `AddUserInterfaces` 创建的上下文默认隐藏 | `[已验证可用]` | 必须 `ChangeParent(ContextPtr:LookUpControl("/InGame"))` + `ReprocessAnchoring()`，不要用 `ContextPtr:SetHide`。 |
| 23 | 面板上下文直接访问另一个 context 的全局 | `[已验证失败]` | 报 `attempt to index a nil value`；每个 context 有独立脚本全局，跨 context 只能走 `ExposedMembers` / `LuaEvents`。 |
| 24 | `ExposedMembers` 跨 context 多返回值 | `[部分可用]` | 单返回值可靠；多返回值不可依赖，失败原因改用 getter（`GetLastGhostCreateDiagnostics`）。 |
| 25 | `Locale.Lookup(key, arg1, arg2)` | `[已验证可用]` | 面板文案带参数正常；所有文案 EN + zh_Hans_CN 成对。 |

## 4. WorldBuilder（地图编辑器）接口

| # | 接口 / 方法 | 状态 | 证据与备注 |
|---|---|---|---|
| 26 | `WorldBuilder.IsActive()` / `WorldBuilder.<X>Manager():Method()`（gameplay 层直调） | `[已验证可用]` | 参数顺序与原版一致；`ModTool_WorldBuilderAPI.lua` 里 82 个封装全部直调，不做探测。 |
| 27 | 在 UI 层做 WorldBuilder API 存在性探测 | `[已验证失败]` | 早期误判的根源：UI 层看不到这些接口，于是“探测不到 → 以为不可用”。已全部移除。 |

## 5. 地图脚本

| # | 现象 | 状态 | 备注 |
|---|---|---|---|
| 28 | `Map Script: -- START FAILED MINOR --`（`Minor TotalPlots: 0`） | `[已验证可用]` | 抬 `CITY_STATE_COUNT` 后，地图放不下那么多城邦时的正常提示，不影响开局（引擎仍按实际上限创建）。 |

---

## 6. 当前可用的成品能力（基于上述已验证接口）

* **幽灵玩家池**：`ExposedMembers.ModMiscToolScript` 暴露 `GetGhostPlayers` / `ClaimAvailableGhostPlayer` /
  `ReleaseGhostPlayer` / `IsGhostPlayerAvailable` / `MovePlayerOffMap` / `InitializeGhostPlayers` /
  `InitializeGhostMajorPlayers` / `GetPlayerSlotSummary` 等，供其它 mod 复用这批“引擎认可的槽位”。
* **扩容结果**（玩家原本选 4 主要文明 + 6 城邦）：幽灵池 **52** 个玩家
  （30 城邦 + 22 主要文明），图上保留玩家原本的选择不变。
* **WorldBuilder 测试面板**：文明/领袖/玩家类型/放置范围四个下拉选择器 + 建城、建单位、
  放开拓者、清首都、设置时代、金币/信仰/显示地图等操作，全部走 gameplay 层接口。

## 7. 当前策略（2026-10-01 回退后）

* **扩容只扩城邦**：抬 `CITY_STATE_COUNT`（上限 62）+ **复制城邦文明**（每个城邦复制一份
  `_GHOST1`，可在创建游戏界面用选项关闭，默认开启）→ 引擎可创建的城邦数量翻倍，
  幽灵池随之变大；**不抬主要文明数量**（`GHOST_RAISE_MAJOR_CAP = false`），
  因此没有主要文明幽灵、没有外交副作用、也不需要城邦化改造。
* 复制城邦的机制走 Atelier 同款“选项控制数据库加载”（`Parameters` 行 + `<ActionCriteria>`
  + 带 `<Criteria>` 的 `UpdateDatabase`），开关关掉时 SQL 完全不加载。
  涉及表（全部在 gameplay 库）：Types / Civilizations / TypeProperties / Leaders /
  CivilizationLeaders / LeaderTraits / CityNames。
* **不复制配色与图标**：`PlayerColors`（ColorManager 库）与 `Icons`（IconManager 库）
  都是独立数据库，跟 gameplay 库不互通，SQL 里访问不到；而且相同 RGBA 值同时出场时
  会让其中一方回退到默认颜色。复制体沿用引擎默认配色即可。
* 运行时文件已回退到 2026-10-01 那次“可以进游戏”的构建（`9d6c291`），
  再叠加：主要文明上限开关（关）、构建标记（`MODMISC_BUILD_TAG`，版本 1.45）。
* 主要文明幽灵相关接口（`InitializeGhostMajorPlayers` / 城邦化）保留在代码里，
  但默认不参与开局流程；需要时再按 `API_Verification_Status.md` 第 29/31 条的结论开启。

## 8. Civ6 的多个数据库（踩过的坑）

| 库 | 典型表 | 说明 |
|---|---|---|
| Gameplay | `Types` / `Civilizations` / `Leaders` / `Traits` / `CityNames` … | 大部分 SQL 写这里 |
| Configuration | `Parameters`（创建游戏界面的选项） | 选项行写这里（FrontEndActions） |
| ColorManager | `PlayerColors` / `Colors` | 配色独立库，gameplay SQL 里访问不到 |
| IconManager | `Icons` / `IconDefinitions` | 图标独立库，同上 |
| Localization | `LocalizedText` | 文案独立库（UpdateText 写入） |

* 一个 SQL 文件**只能碰一个库**的表：混着写会在加载时报 no such table，
  数据库动作失败，严重时直接让开局挂掉。
* 校验 SQL 时也要**按库分别校验**：把所有 schema 拼进同一个临时库去跑，
  会把跨库引用误判成“通过”（本项目就发生过一次）。
* 复制文明时不要复制配色：相同 RGBA 同时出场会让一方回退默认颜色。

## 9. 待验证 / 尚未验证

| # | 接口 / 方法 | 状态 | 备注 |
|---|---|---|---|
| 29 | `ConvertGhostPlayerToCityState(playerID)`：在**游戏跑起来之后**给已存在的玩家换身份 | `[未验证]` | 起因：幽灵化的主要文明仍有外交行为。当前做法（授权者指定）：`WorldBuilderAPI.SetPlayerLeader(id, 城邦领袖, 城邦文明, 'CIVILIZATION_LEVEL_CITY_STATE')` —— 与面板「应用」同一个**[已验证可用]**接口；没生效再补 `SetIsMinorCiv(true)`。判定看 `player:IsMajor()` 是否变 false。开关 `GHOST_CONVERT_MAJOR_TO_CITY_STATE`。 |
| 31 | **在开局阶段（`LoadGameViewStateDone`）自动做城邦化** | `[已验证失败]` | **两次复现“游戏加载出错”**：把开关打开就挂、关掉就能进。两版实现（`StartCityState()` 版与 `SetPlayerLeader` 版）都挂 ⇒ **问题在时机，不在用哪个接口**：在加载过渡阶段改玩家身份会把开局搞挂（日志停在 `LoadScreen: OnLoadGameViewStateDone`，`InGame UI` 都没开始加载）。现改为进游戏后由面板按钮手动触发：`ConvertAllGhostMajorPlayersToCityState()`（一键全部）/ `ConvertGhostPlayerToCityState(id)`（单个）。<br>附带更正：此前把同一版本的失败归因于“mod 清单里的 `.md`”，属于**未定责的猜测**——`.md` 已移除后同样的开关仍然挂，故 `.md` 不是主因（继续留在清单外只是因为它对运行无用）。 |
| 30 | 把**已经建城**的玩家回收成幽灵（拆掉全部城市） | `[已验证失败]` | 授权者实机结论：**建城之后再移除全部城市 = 玩家直接死亡，手里有没有开拓者都一样**。因此回收路径已从代码里删除（原本的 `GhostifyPlayer` 入口撤销），`MovePlayerOffMap` 与 `ConvertGhostPlayerToCityState` 都对“有城市”的玩家直接拒绝（`GetGhostifyBlockReason`）。幽灵化只能作用于开局还没建城的玩家。 |


* 运行时补建玩家是否存在**其它**入口（目前只否证了 `PlayerManager():AddPlayer()` 与
  “给空槽位改 `PlayerConfigurations` + `StartCityState()`”两条；给**已存在玩家**换身份是
  另一条独立路径，见上表第 29 条）。
* `WriteCustomData` 在“存档 → 退出进程 → 读档”这条路径下是否随存档回来（探针已就位，
  读档日志里 `turn > 1` 时看 `VERDICT=` 即可判定）。
* `GhostPlayers_CityStates.sql`（数据库复制城邦）—— 脚本已写好并通过静态校验，但**未启用、未实测**。
