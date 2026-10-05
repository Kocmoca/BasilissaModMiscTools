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
| 8 | `Game:SetProperty` / `Game:GetProperty` 存幽灵池 | `[已验证可用]` | 池子随存档保存，读档后仍可读回。**gameplay 专用：UI 端不可用**（授权者确认）—— 所以“对局内存数据”在 gameplay 侧用这一对，在 UI 侧只能用 `WriteCustomData`/`ReadCustomData`。<br>**能力边界（授权者既有 mod 制作经验，2026-10-04 确认）：✅ 随存档落盘；❌ 不可跨存档** —— 数据属于那一份存档，别的档与新开的一局都读不到。所以它是“本档内的持久存储”，**不是**跨局/跨存档的传递通道。跨存档目前唯一走得通的只有前端那条（写 → 存配置档 → 下次启动前端读回）。 |
| 9 | `player:IsMajor()` / `IsBarbarian()` / `GetCapitalCity()` / `GetUnits()` | `[已验证可用]` | gameplay 层判定与筛选正常。 |
| 10 | `player:IsMinor()` | `[已验证失败]` | gameplay 层调用报 `function expected instead of nil`（该 API 只有 UI 层有）。城邦候选列表因此改由 UI 层算好、经 `ExposedMembers` 交给 gameplay。 |
| 11 | `Game.GetLocalPlayer()` / `GameDefines.MAX_PLAYERS`（=64） | `[已验证可用]` | 用于跳过本机玩家、遍历槽位。 |
| 12 | 引擎能创建的城邦玩家数量 | `[已验证可用]` | 与请求值无关，**实测上限 = 数据库里的城邦文明条数**：请求 62 → 实际 36。 |

## 2. 扩容路线（“抬上限”是唯一走得通的路）

| # | 接口 / 方法 | 状态 | 证据与备注 |
|---|---|---|---|
| 13 | `MapSizes.MaxCityStates` / `MapSizes.MaxPlayers`（DB 抬上限） | `[✅ 已验证可用·必须抬]` | 抬上限后设置界面可选范围变大。**但不要再一律抬到 62**：引擎在**地图生成阶段**就要给所有这些玩家找出生点，小图上塞不下会开局失败（授权者实机：小概率加载失败，疑似出生位置重叠）。现改为**按尺寸分档**（`GhostPlayers_MapSizes.sql`，每档绝对赋值所以可重复加载）：城邦上限 DUEL 14 / TINY 18 / SMALL 22 / STANDARD 26 / LARGE 30 / HUGE 32（原版各为 6/10/14/18/22/24），主要文明 = 原版 +2；非标准地图脚本（Earth/Balance 等自带 Domain 的）再按**它自己的** `MaxPlayers + 6` 收一道。开局日志 `poll: CITY_STATE_COUNT=n maxMinor=<本档上限>` 可直接核对生效值。 |<br>**2026-10-04 回滚**：不再用 SQL 改 MapSizes（`GhostPlayers_MapSizes.sql` 已删除）。抬上限会让引擎在地图生成阶段塞下远超原版容量的玩家，与加载失败/闪退相关。改为**纯 Lua 配置表** `GHOST_MAX_CITY_STATES_BY_MAP_SIZE`（`UI/Replacements/Civ6Common.lua`）：按地图尺寸给出**城邦最大数量**（请求创建的城邦玩家总数），`幽灵池 = 城邦最大数量 − 玩家选择的城邦数`，请求值不再夹到原版上限，只受引擎硬上限 62 与「不低于玩家选择」两条约束。<br>2026-10-04 授权者实机：**这样配置没有加载问题**；并给出分档口径 —— 小图按原版量级（DUEL 6 / TINY 10 / SMALL 14 / STANDARD 18），**大地图与巨大地图吃满最高档 62**。（最初把这张表命名成“幽灵数量”是语义错误，已改正。） |<br>**2026-10-04 结论（走过一轮弯路）**：抬上限是**必须的** —— 只靠 Lua 设 `CITY_STATE_COUNT` 顶不上去，实测引擎仍按原版值（HUGE=24）创建，幽灵池上不去。于是恢复 SQL（`GhostPlayers_MapSizes.sql`），按尺寸分档：城邦 DUEL 16 / TINY 28 / SMALL 40 / STANDARD 52 / LARGE 62 / HUGE 62（原版 6/10/14/18/22/24），主要文明 8/12/16/24/32/40；非标准地图脚本按自身 `MaxPlayers + 12` 收口。<br>分工：**数据库 = 天花板**（同时决定创建游戏界面能选多少），Lua 侧 `GHOST_CITY_STATE_CAP_BY_MAP_SIZE` = **可选安全阀**（留空即跟随数据库，只想单独压某个尺寸时才写一个更小的数），请求值再受硬上限 62 与“不低于玩家选择”约束。<br>历史注记：中途曾因闪退把 SQL 整个撤掉，后来查明闪退是**空槽位上的 `InitUnit`**（第 13c 条），与上限无关。 |<br>**2026-10-04 最终状态（实机全绿）**：`GhostPlayers_MapSizes.sql`（老版方法：前端 `UpdateDatabase` + 两条 `UPDATE … WHERE < 62`，不设 LoadOrder）+ modinfo 两处登记，实机 `dbCeiling=62`、`maxMinor=62` ✅。<br>分档交给 Lua：`GHOST_CITY_STATE_BY_MAP_SIZE`（TINY 28 / DUEL 16 / HUGE 62 …），实机 `mapSize=MAPSIZE_TINY/DUEL/HUGE` 全部识别成功、`tableValue` 与表一致、幽灵池 22/13/44 ✅。<br>排查中踩过的坑依次是：把 `.sql` 同时登记进 `<AddGameplayScripts>`（第 13d 条）、诊断函数前向引用了后声明的模块级 local 导致主逻辑被带崩（第 13e 条）。诊断现已改为 `MODMISC_MAPSIZE_DIAG_ENABLED` 开关（默认关）。 |
| 13b | **幽灵 pass 的执行时机** | `[已验证失败]`（原来挂在加载过渡上） | 授权者确认：加载失败是**加入幽灵机制之后**才出现的。原来挂在 `Events.LoadGameViewStateDone` —— 那是**加载过渡阶段**，本项目此前就在同一个事件上踩过坑（循环给 20+ 玩家换领袖/文明 → 开局直接挂，日志停在 `LoadScreen: OnLoadGameViewStateDone`）。幽灵 pass 要在这一个事件里对 ~50 个玩家各做 `InitUnit` + `Kill`×3，同一量级的操作压在同一个时刻，小概率挂掉说得通。<br>**改法已备好但暂未启用**（授权者要求先按现状测一轮）：把注册换成 `Events.LocalPlayerTurnBegin`（第 1 回合、本地玩家回合开始）即可 —— 开局已完成、AI 还没动、城邦手里还是开拓者尚未建城 —— 逻辑等价，但不再压在加载过渡上。**当前仍挂 LoadGameViewStateDone**。开局日志新增一行 `[Ghost] pass start trigger=LocalPlayerTurnBegin ...` 便于定位。<br>配套：玩家数量也按地图尺寸分档压过一轮（见第 13 条），两条一起上。 |
| 13c | **空槽位上的 `UnitManager.InitUnit`** | `[疑似·待新证据]` | **100% 复现的原生崩溃**：`signal 11 SIGSEGV`，backtrace `GameCore::Lua::IUnitManager::lInitUnit(lua_State*)+24`，`x0=0`（空指针）。<br>根因：**空槽位的 `Players[id]` 不是 nil** —— 是个内部对象为空的桩，`IsMajor()` 返回 `false`、既无城市也无单位，于是幽灵 pass 的筛选条件全部通过，接着对它 `InitUnit` 就闪退。<br>**为什么以前只是“小概率”**：上限抬到 62 时引擎真建出 ~58 个城邦，槽位基本占满，偶尔才踩空；按地图尺寸压到 26 后槽位 30..61 全空 → 每次必踩。**是压上限暴露了潜伏 bug，不是压上限导致。**<br>**2026-10-04 追加**：加了防护后授权者反馈**问题依旧**，且指出两者是不同症状 —— 最初的加载失败是**弹窗报错**（不闪退），闪退是后来才出现的。<br>修法（保留，属独立正确性修复）：`PlayerSlotHasPlayer()` 用**正向信号**（有单位或有城市）判定槽位是否真有玩家；`MovePlayerOffMap` 与扫描阶段都先过滤，`ghost pass done` 日志新增 `emptySlots=N`。<br>⚠️ 顺带踩到本文件记录过的坑：`CallOrNil` 是**文件后段**的 local function，在它之前定义/调用的函数里不能用（会静默变全局 nil）—— 已在 `PlayerSlotHasPlayer` 里改用直接 `pcall`。 |
| 13d | **同一个文件被登记进不同类型的动作** | `[已验证失败]`（结构性错误） | `GhostPlayers_MapSizes.sql` 一度被同时登记进 FrontEndActions 的 `<UpdateDatabase>` 与 InGameActions 的 `<AddGameplayScripts>`（把它当 gameplay 脚本加载）—— 结果那条 SQL 的 UPDATE **完全没生效**（诊断探针打出来的 MapSizes 全是原版值）。删掉误登记后恢复老版方法即可。<br>**教训**：往 modinfo 里加 `<File>` 时别用“空格数不同的子串”做匹配 —— 8 空格的 `<File>X</File>` 是 12 空格那行的子串，会插错块（本项目已经栽过三次）。 |
| 13e | **诊断逻辑把主逻辑带崩** | `[已验证失败]`（自作自受） | 为了排查尺寸识别加的诊断函数里，引用了**声明在它后面**的模块级 local (`GHOST_MAP_SIZE_TEXT_BY_KEY`) → Lua 5.1 解析成全局 nil → `pairs(nil)` 报错 → 异常冒泡把 `ApplyGhostCityStates` 整个中止 ⇒ **“设置 CITY_STATE_COUNT”这一步根本没跑**，表现为“城邦上限没生效”（日志里只有 `poll:` 没有 `city states ->`）。<br>两条教训：① 诊断/观察代码一律 `pcall` 包住，它绝不能影响主流程；② 静态自查要覆盖**模块级 local 变量**，不只 `local function` —— 这次就是漏在这。 |
| 14 | `GameConfiguration.SetValue("CITY_STATE_COUNT", maxMinor)`（前端） | `[已验证可用]` | 玩家选 6 → 引擎开局建 **36** 个城邦（原来只有 6）。 |
| 15 | `GameConfiguration.SetParticipatingPlayerCount()` + `MapConfiguration.GetMaxMajorPlayers()`（前端） | `[已验证可用]` | 玩家选 4 → 引擎开局建 **26** 个主要文明（槽位 0..25）。 |
| 16 | `MapConfiguration.GetMaxMinorPlayers()` / `GetHiddenPlayerCount()` | `[已验证可用]` | 预算计算用；`n = 目标 + hidden` 口径要一致。 |
| 17 | 槽位预算（主要文明与城邦抢同一批槽位） | `[已验证可用]` | 实测 26 主要文明 + 36 城邦 = 62，正好吃满 `MAX_PLAYERS(64) - 野蛮人 - 自由城市`；给城邦预留 36 个才不会把城邦挤没。 |
| 18 | “从槽位 id 大的那头开始搬” | `[已验证可用]` | 引擎先排主要文明（0 起）再排城邦。玩家选 4 主要文明 + 6 城邦时，搬走 4..25 与 32..61，图上剩 0..3 与 26..31 —— 正是玩家自己选的那批。 |

## 3. 前端 / UI 层

| # | 接口 / 方法 | 状态 | 证据与备注 |
|---|---|---|---|
| 19 | `Events.SystemUpdateUI` 在“创建游戏”界面监听 | `[已验证失败]` | 该事件在设置界面**根本不触发**（只有分辨率变化/恢复 UI/触摸输入），hook 完全静默。改用 `ContextPtr:SetRefreshHandler` + `RequestRefresh()` 轮询。 |
| 20 | `MapSize_ValueChanged ~= nil` 判定“创建游戏”上下文 | `[部分可用]` | 安卓实测可用：该上下文 include 过 `GameSetupLogic`；对局内没有这个全局函数，因此不会误改对局内设置。<br>**PC 上这个判据不够**：PC 的城邦选择器 / 领袖选择器子上下文同样 include 了 `PlayerSetupLogic`，判据在那边也成立 → 见 §11。 |
| 21 | `WriteCustomData` / `ReadCustomData` | `[部分可用]` | **同进程有效**：设置界面写 → 对局内读得到（幽灵流程即依赖此）。**跨启动无效**：完全退出进程后重开新局读不到（两次启动探针都是 `VERDICT=first-write`）。可当“设置界面 → 对局内”的传递通道，**不能当持久化存储**。<br>**补充（2026-10-04，面板 payload 带随机数的那组实验）**：它其实是**绑在存档上**的 —— 存档时刻的快照随存档一起序列化，读该档时原样还原（读回的是“存档前那次写入”的值，存档后的改写会丢）；同进程里的**新局**不继承（读到空）。所以“进程内”这个说法不准确，准确说法是“随局/随档”。 |
| 22 | `AddUserInterfaces` 创建的上下文默认隐藏 | `[已验证可用]` | 必须 `ChangeParent(ContextPtr:LookUpControl("/InGame"))` + `ReprocessAnchoring()`，不要用 `ContextPtr:SetHide`。 |
| 23 | 面板上下文直接访问另一个 context 的全局 | `[已验证失败]` | 报 `attempt to index a nil value`；每个 context 有独立脚本全局，跨 context 只能走 `ExposedMembers` / `LuaEvents`。 |
| 24 | `ExposedMembers` 跨 context 多返回值 | `[部分可用]` | 单返回值可靠；多返回值不可依赖，失败原因改用 getter（`GetLastGhostCreateDiagnostics`）。 |
| 25 | `Locale.Lookup(key, arg1, arg2)` | `[已验证可用]` | 面板文案带参数正常；所有文案 EN + zh_Hans_CN 成对。 |
| 32 | 前端 `Network.SaveGame{FileType=GAME_CONFIGURATION}` | `[已验证可用]` | 主界面/创建游戏界面实测都能存：`Events.SaveComplete` 收到，复查 `UI.QuerySaveGameList` 列表里确实出现 `ModMiscFrontEndProbe.Civ6Cfg`（`VERDICT=fe-save-ok-confirmed`）。`Type` 取 `Network.GetGameConfigurationSaveType()`。安卓上「高级选项」页会横向溢出（LoadConfig/SaveConfig 与 StartButton 挤在同一个向右生长的 `ButtonStack` 里），但存配置档**不需要**那个界面。 |
| 33 | 前端 `Network.LoadGame{FileType=GAME_CONFIGURATION}`（绕过菜单直调） | `[部分可用]` | 调用返回 `true`、前端不被顶掉。**但必须自己补跑收尾**：走菜单时由 `LoadGameMenu.OnLoadComplete` 执行 `SetToPreGame()` + `RegenerateSeeds()` + 清玩家领袖/文明选择（源码注释：*Reset the seeds and leader selection when loading a config so that configs are more usable*），而那段外面套着 `if ContextPtr:IsVisible()` —— 绕过菜单就拿不到。后果：配置档把**地图/游戏种子**一起存进来且**不回滚**，表现是“同一领袖 + 不改设置 → 每次开局都是同一张地图”。本 mod 的探针自己挂 `Events.LoadComplete` 补跑这套收尾。 |
| 34 | `UI.QuerySaveGameList` + `LuaEvents.FileListQueryResults` 查存档列表 | `[已验证可用]` | 前端与**对局内**都可用（回传 `(fileList, 请求号)`）。⚠️ 列表里的 `Name` **带扩展名**（配置档是 `xxx.Civ6Cfg`），拿它跟不带扩展名的目标做等值比较会**永远判“不在”** —— 必须先剥扩展名再比。这个假阴性害得探针连跑两次“创建”分支。 |
| 35 | `UI.GetLastSaveName()` 当“已落盘”证据 | `[已验证失败]` | 配置档保存后回读是**空串**，判断不了文件是否写成功；改用 `UI.QuerySaveGameList` 复查列表。 |
| 36 | 对局内 `Network.LoadGame{FileType=GAME_CONFIGURATION}` | `[已验证失败]` | **直接卡死**。日志证据（2026-10-04 18:16 那份）：面板自检通过（`Config save found: ModMiscFrontEndProbe; listed=ModMiscFrontEndProbe.Civ6Cfg`）→ 发出 `Requested load of front-end configuration save: … (FileType=GAME_CONFIGURATION)` → **Lua.log 到此为止，之后一行都没有**（无 Runtime Error、无任何后续 UI 日志），进程挂死。<br>对照：**档不存在时**同一个调用是静默无操作（不报错、不返回 false、不打断当前局，已实测两次）⇒ 卡死发生在“真的去读这个档”的那一下。配置档是给前端设置态用的类型，对局内喂它会把引擎挂住。**此路不通，对局内别碰配置档。**<br>面板入口已按授权者决定**删除**（按钮 + 回调一起删）。 |
| 37 | `Events.LoadComplete`（前端，回传 `(eResult, eType, eOptions, eFileType)`） | `[部分可用]` | 可用来补跑配置档读入后的收尾：配置档 `eFileType = SaveFileTypes.GAME_CONFIGURATION`，成功时 `eResult = 0`。⚠️ 它**广播给每个前端上下文** —— 每个上下文各挂一次就会各跑一遍收尾（实测 Options / HostGame / StagingRoom / MainMenu / AdvancedSetup 五个都打了日志）。只让“真正发起这次读档的那个上下文”处理（本 mod 用 `m_LoadIssued` 标记）。 |
| 39 | **用「前端配置档」当中转站，把 CustomData 跨存档带回来** | `[已验证失败]` | 两组独立实验（`Lua1.log`/`Lua2.log`，各含主菜单 + 创建游戏两个上下文）结论一致：读配置档**之前** step1 刚写过一份带 `t=`/`r=` 的 payload，读完**再读一次** CustomData —— **四次全部读到「本次刚写的那份」**，一次都没读到配置档存档时刻的旧值 ⇒ **配置档不带 CustomData**。<br>旁证：`Lua2` 里主菜单读档完成之后，下一个上下文（创建游戏）读到的仍是本轮主菜单写的那份，说明不是“读得太早”，是压根没还原。<br>对照 —— 同一份**普通存档（GAME_STATE）**却能把 CustomData 带回来（早前 `…794` 那组证据），前端 → 同一进程内接着开的那一局也能带（幽灵城邦数）。⇒ CustomData 的载体是**进程/存档**，不是配置档。<br>**总结论：目前没有可用的跨存档通道**（CustomData 不落盘、配置档不带它、对局内读配置档卡死）。唯一还没查的是「mod 自己往磁盘写文件」，见 `[IOProbe]`。 |
| 38 | 对局内 `Network.LoadGame`（普通存档，`SaveTypes.SINGLE_PLAYER`） | `[部分可用]` | 本身**能读**：发请求后 `LoadScreen: true` → 整局重载 → `OnLoadGameViewStateDone`（实测那次读回来的 CustomData 是**存档时刻**的快照，存档之后的写入会丢）。但它是**显式读档**、会把当前局顶掉，工具面板不再提供这个入口 —— 按授权者决定已删除按钮与回调，要读档走游戏自己的「载入游戏」菜单。 |

> 第 32-37 条来自前端存读档探针（`UI/FrontEnd_SaveProbe.lua`）。该探针**默认关闭** ——
> 开关 `MODMISC_FRONT_END_PROBE_ENABLED`（`UI/Replacements/Civ6Common.lua` 顶部）。
> 关掉的原因：前端这条路虽然通，但每次开机都会动一遍配置（读档后按游戏菜单语义
> **清空领袖/文明选择**）。要再跑实验就把开关改成 `true`。

**跨存档通道候选（2026-10-04 独立排查，均待实机验证）**

授权者提供线索：有人实现过跨存档数据、且不愿开源，原理可能是利用普通存档。
不动别人的代码，自己把原版翻了一遍，能用得上的通道就下面几条：

| 通道 | 机制（原版依据） | 现状 |
|---|---|---|
| **A** `Options.SetUserOption` / `GetUserOption` | 基座 UI 层在用，**对局内 UI 也在用**（`ActionPanel` / `CameraManager` / `DiplomacyRibbon`）。关键证据：`UI/FrontEnd/Multiplayer/PBCNotifyRemind.lua` 往 `("Interface", "PlayByCloudNotifyRemind")` 写，这个键**没在任何 XML 里声明**，却要在 `Lobby.lua` 里跨会话读回来 ⇒ **自定义键能存**。落盘在用户选项文件 ⇒ 天然跨存档/跨启动。 | 探针已埋（`[UserOptionProbe]`），待实机 |
| **B** `io.open` 写自己的文件 | 若 Lua 环境带 io 库，直接写数据文件最干净（位置可用 `UI.GetSaveLocationPath()` 定位） | `[IOProbe]` 待实机 |
| **C** 存档名编码 | 写：`Network.SaveGame{Name=…}`（前端不需要运行中的对局即可写配置档）；读：`UI.QuerySaveGameList` 的 `Name`（不需读档、前后端都能用）。**这就是“利用普通存档”那条路**。 | ✅ **`[已验证可用]`（2026-10-04 实机）**：写一轮 `ms=1;t=1791112827;r=811157` → 杀进程 → 下一轮读回**逐字一致**；旧档按 key 自动清理，列表里始终只有一个存储档。<br>代价：文件名禁 `%` `"` `<` `>` `|` `/` `\` `*` `?` `:` 与控制字符（用 hex 绕开）；一个 key 一个档。已封装为 `UI/ModMiscStore.lua`（`Save/Get/GetAll/Refresh/OnReady`）。 |
| **D** 存档元数据注入 | ❌ 排除：`EnabledMods` / `RequiredMods` / `SavedByVersion` / `TunerActive` 等字段全由引擎填；`UI.GetSaveGameMetaData()` 只能读“正在加载的那个档”，没有任意档读取接口 | — |
| **B′** | `io` 库（mod 自己写文件） | `[已验证失败]` | 实机 `[IOProbe] io=n io.open=n os=y` —— **安卓端 Lua 没有 io 库**，这条路直接断。 |
| **A′** | `Options.SetUserOption` 存自定义键 | `[已验证失败]` | 实机：`写入失败 -> [ModMiscTool] CrossSaveProbe is not a registered option.` 引擎会校验选项是否注册；而注册表在引擎内部（`PlayByCloudNotifyRemind` 这类键在**全部数据文件里都搜不到声明**），mod 注册不了新选项 ⇒ 不通。<br>顺带发现：Civ6 里 **`pcall` 挡不住日志** —— 被捕获的错误照样打 `Runtime Error` + traceback。 |

**跨存档存储的对外接口（`UI/ModMiscStore.lua`，已实机验证）**

```lua
-- 本 mod 内直接调 ModMiscStore.*；外部 mod 走 ExposedMembers.ModMiscToolUI.*
RefreshData()          -- 扫存档列表（异步）
IsDataReady()          -- 首次扫描是否完成
OnDataReady(fn)        -- 扫描完成时回调（已就绪则立刻调用）
SaveData(key, value)   -- 写；值 ≤ 120 字节；先写新档、SaveComplete 后再删同 key 旧档
GetData(key)           -- 读（没存过 → nil）
GetAllData()           -- 整张表（副本）
RemoveData(key)        -- 删一个键及其档
RemoveAllData()        -- 清空整张存储（返回删掉的键数）
```

* 前端与**对局内 UI** 都能读写（各自的 context 各持一份内存表，跨 context 走 `ExposedMembers`）。
* gameplay 层拿不到（`Network.SaveGame` / `UI.QuerySaveGameList` 都是 UI 接口）。
* 实机证据（最终一轮，2026-10-04）：
  `selftest` / `ingame` 两条脚手架键被自动清理 → 存储清空；
  面板写入 `panel=panel=1;t=1791115952;r=481347` → 杀进程 → 下一轮读回**逐字一致**；
  「存储清空」`RemoveAll：已清空 1/1 个键` → 列表变 `(空)`。
  **状态：已交付**（写入 / 读取 / 删除 / 清空 / 退役键清理 全部实机通过）。
* 测试面板上有对应按钮：存储写入 / 存储读取 / 存储清空。
  写入显示刚写的那一行（`panel = …`），读取与清空显示整张清单，三者格式一致、可直接逐行对照；
  「存储清空」= `RemoveAllData()`，清空**整张**存储。
* 脚手架已退场：`selftest`（自检）与 `ingame`（对局内写测试）都关了，且列入退役键 ——
  扫描时若发现这两个键的档，直接清掉，免得正式用起来还躺着测试数据。

**跨存档存储踩过的两个坑（2026-10-04 实机，已修）**

| 现象 | 根因 | 修法 |
|---|---|---|
| 主菜单里突然报 `键值：(空)`，`非存储档=[quicksave.Civ6Save, AutoSave_0001.Civ6Save]` | `LuaEvents.FileListQueryResults` 是**全局广播** —— 游戏自己的存档菜单（继续游戏 / 载入 / 自动存档）每次查列表都会发这个事件，被我们的扫描回调当成自己的结果，**把内存表清空了** | 严格对号请求号（`requestId == 自己的 id` 才处理），处理完立刻 `Remove` 退订；`Refresh(onDone)` 提供“本次扫描完成”回调 |
| 面板读回来「和写进去的不一样」、清空后「看着没变化」 | **`Locale.Lookup` 的参数里出现 `\|` 会把后面内容整段吃掉**：分隔符用了 `" \| "`，面板只显示第一项。数据其实是对的（`panel=…` 原样读回、`已删除 [panel]` 也真删了） | 分隔符换成 `", "`；同时把全量内容 `print` 进日志兜底 |
| 连按两次「存储读取」显示旧数据 | `OnReady` + `Refresh()` 的写法：已就绪时 `OnReady` 立刻回调，拿的是上一次扫描的表 | 改用 `Refresh(onDone)`，只在**本次**扫描完成后回调；清空后也自动重扫再显示 |

**观察者视角（AutoplayManager）与 UI 消失（2026-10-04 实机 + 源码核对）**

| 项 | 结论 |
|---|---|
| `AutoplayManager.SetObserveAsPlayer(id)` + `SetActive(true)` | `[部分可用]` —— 只能**看**，不能接管。观察期间被观察文明由 **AI 操作**，本地玩家是观众；Civ6 单人局没有“把控制权交给某 AI 文明”的机制（`Game.GetLocalPlayer()` 一局内固定，热座/多人是另一套）。所以“切视角后以该玩家身份操作”这个预期不成立。 |
| 切视角后点**城市 banner** → UI 全部消失 | `[原版缺陷，已给兜底]`。`InGame.lua` 的 `BulkHide` 是**引用计数**（`m_bulkHideTracker`）：某次 `BulkHide(true, x)` 的配对 `false` 没跑到（报错 / 上下文被顶掉），计数卡在 ≥1，`WorldViewControls / HUD / PartialScreens / Screens / TopLevelHUD` **五大组永久隐藏**。原版为此留了调试热键 **Shift+Alt+B**（`InGame.lua` “DEBUG: Force unhiding”）——**安卓没键盘，等于没有**。 |
| 兜底 | 本 mod 提供 `ExposedMembers.ModMiscToolUI.RestoreInGameUI()`，把五大组强制 `SetHide(false)`（就是 BulkHide 内部做的同一件事，只是不碰那个跨 context 拿不到的计数器）；测试面板上有「**恢复 UI**」按钮。 |

**资产预览与永久放置（2026-10-04 实机）**

| 项 | 状态 | 说明 |
|---|---|---|
| `AssetPreview.Spoof*At` / `Clear*` / `Destroy*`（UI 层） | `[已验证可用]` | 实机：能在任意地块摆出城市/区域/建筑/地标/单位模型，也能按地块或整体清除。**纯视觉**，不改变游戏状态。 |
| 预览能否随存档保留 | `[已验证失败]` | 预览不进存档 —— 重新读档后模型全部消失。 |
| 本 mod 的永久放置（`UI/ModMiscAssetStore.lua`） | `[已验证可用]`（写入/读取链路） | 把**已解析好的 AssetPreview 调用**（`{fn, args}`）记进 CustomData。CustomData 随普通存档序列化、读档还原（第 21 条），开局由 `Support_UI` 重放一次。注意顺序：**先放置、再存档**（记的是存档那一刻的快照）。 |

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
  幽灵池随之变大；**不抬主要文明数量**（`GHOST_RAISE_MAJOR_CAP = false`，但会记下玩家
  设定的人数用于算边界），因此没有主要文明幽灵、没有外交副作用、也不需要城邦化改造。
* **幽灵判定 = 按 playerID 划范围**（授权者定，简单确定，不再做多回合扫描）：
  主要文明占 `0..majorCount-1`，玩家设定的城邦占 `majorCount..majorCount+cityCount-1`，
  边界之后（跳过 62/63 自由城市与蛮族）的城邦槽位**全部变幽灵**，开局跑一次即可。
  开局时所有玩家都还没建城，所以不用考虑城市的影响。
* 复制城邦的机制走 Atelier 同款“选项控制数据库加载”（`Parameters` 行 + `<ActionCriteria>`
  + 带 `<Criteria>` 的 `UpdateDatabase`），开关关掉时 SQL 完全不加载。
  涉及表（全部在 gameplay 库）：Types / Civilizations / TypeProperties / Leaders /
  CivilizationLeaders / LeaderTraits / CityNames。
* **不复制配色**：`PlayerColors`（ColorManager 库）是独立数据库，跟 gameplay 库不互通，
  SQL 里访问不到；而且相同 RGBA 值同时出场时会让其中一方回退到默认颜色。
  复制体沿用引擎默认配色即可。
* **图标要逐个定义，且用 XML 而不是 SQL**：`Icons` / `IconDefinitions`（IconManager 库）
  是独立库，不能用 SQL 批量 `INSERT ... SELECT`；把 **base 的 24 个城邦**图标逐条写死
  （`GhostPlayers_CityStateIcons.xml`，复制体照抄原城邦的 Atlas/Index，外观一致），
  挂在 `<UpdateIcons>` 上、同一个选项判据、不设 LoadOrder。
* **图标动作必须设 LoadOrder**：复制体要引用 XP1/XP2/DLC 的图集
  （`ICON_ATLAS_EXPANSION_*` / `ICON_ATLAS_VIKINGSLANDMARKS_*`），
  这些图集由官方图标动作加载；本动作若排在前面，引用会因图集尚不存在而**报数据库错**，
  而且**报错会中断图标库构建**，把后面本该加载的官方图标（实测：DLC 城邦 Palenque）
  一起丢掉。现设 `LoadOrder=9000`，排在官方之后。
* 复制范围是**运行时数据库里已有的城邦**：正常对局 = Base 24 + 资料片 11 + DLC 6 = 41
  （场景专属的不在其中），图标文件与这份清单一一对应。
  SQL 版实测**图标不生效**（`Index` 是保留字，加引号也未必被加载器的 SQL 方言接受），
  改用 XML 后与游戏自身图标文件同格式，最稳。
* **幽灵溢出到地图**：复制城邦后引擎会把更多城邦**直接落到图上**（有首都），
  这些不能回收（拆城＝玩家死亡）。因此 `InitializeGhostPlayers` 会先清点已落地的城邦，
  把它们占掉的名额从“保留数”里扣掉（`keepUnsettled = choice - settledOnMap`），
  保证地图上的城邦总数尽量贴近玩家选择；日志新增 `settledOnMap= / keepUnsettled=` 与
  已落地城邦的 id+文明类型清单，便于核对是不是复制体被落图。
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

## 9. 收尾状态（2026-10-01）

* **测试面板已取消注册**：`UI/WorldBuilderTestPanel.*` 不再挂到 `AddUserInterfaces`，
  不加载、左侧栏无入口；功能全部以 API 形式提供
  （`ExposedMembers.ModMiscToolScript.*`：幽灵池、WorldBuilder 接口等；
  `ExposedMembers.ModMiscToolUI.*`：左侧栏按钮注册、城邦判定辅助、账本等）。
  需要调试时把 modinfo 里注释掉的那段 `AddUserInterfaces` 加回来。
* 版本文案：`modinfo` 版本 1.53。

## 10. 待验证 / 尚未验证

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

---

## 11. 跨平台核对：Civ6 PC（2026-10-02，**静态核对，PC 端未实机**）

起因：`UI/Replacements/Civ6Common.lua` 里的「开局前拉满城邦上限」hook 是在安卓版上做出来的，
需要确认它对 **PC（Steam/Win64）** 是否同样有效。

核对方式：把两版游戏文件逐项对比 ——
PC = `Civ6PC/Base/Assets/…`，安卓 = `Civ6Data/Base/Assets/…`。
**没有在 PC 上实机跑过**，所以下面区分「静态可证」与「需实机确认」。

### 11.1 结论

**机制本身在 PC 上成立** —— 下面 9 条前提逐条对上，PC 与安卓在这些点上**逐字一致**。
但 PC 有两处安卓没有的界面结构，会在表现上露出差异（11.3 / 11.4）。

### 11.2 前提逐条核对

| # | 前提 | 安卓证据 | PC 证据 | 结论 |
|---|---|---|---|---|
| P1 | 前端会加载 `Civ6Common`（替换才生效） | `FrontEnd/PlayerSetupLogic.lua:5` 的 include 链 | 同一行、同一顺序 | 一致 |
| P2 | `GameSetupLogic` 先于 `Civ6Common` 被 include（否则 hook 判据为假） | `PlayerSetupLogic` 的 include 顺序：`InstanceManager → GameSetupLogic → SupportFunctions → Civ6Common` | 逐字一致 | 一致 |
| P3 | `MapSize_ValueChanged` 存在 | `GameSetupLogic.lua:670` | `GameSetupLogic.lua:786` | 存在 |
| P4 | `WriteCustomData` 定义在 `Civ6Common` | `Civ6Common.lua:722` | `Civ6Common.lua:722` | 同位置 |
| P5 | 参数 `CityStateCount` 绑定 `CITY_STATE_COUNT` | `SetupParameters.xml:18` | `SetupParameters.xml:18` | 定义完全相同（`ConfigurationGroup="Game" ConfigurationId="CITY_STATE_COUNT"`） |
| P6 | `MapConfiguration.GetMaxMinorPlayers()` | `GameSetupLogic.lua:662` | `GameSetupLogic.lua:778` | 存在 |
| P7 | `GameConfiguration.SetValue("CITY_STATE_COUNT", …)` | `GameSetupLogic.lua:699` | `GameSetupLogic.lua:815` | 存在 |
| P8 | 改地图尺寸会重置 `CITY_STATE_COUNT`（所以必须轮询、不能只写一次） | 同上 | 同上 | 一致 |
| P9 | `AdvancedSetup` 上下文没有自带刷新回调（hook 可以安全占用） | `SetRefreshHandler` 出现 0 次 | 0 次 | 安全 |

> P5 的含义值得单独说：参数与 `GameConfiguration` 是**同一个值的两个视图**
> （参数表里 `ConfigurationId` 直接指向 `CITY_STATE_COUNT`）。
> 所以安卓上 hook 直接写 `GameConfiguration`、PC 上玩家拖参数滑块，
> 改的是同一处 —— 两边不会各写各的。

### 11.3 PC 差异 A：城邦选择器子上下文也会装 hook（**表现差异，功能不坏**）

- PC 的 `AdvancedSetup.xml:333` 声明了安卓没有的子上下文：
  `<LuaContext ID="CityStatePicker" …/>` 与 `<LuaContext ID="LeaderPicker" …/>`；
- `CityStatePicker.lua` 的 include 链是 `InstanceManager → PlayerSetupLogic → Civ6Common`，
  所以 **`MapSize_ValueChanged ~= nil` 在它里面同样成立**，hook 会在该子上下文再装一份轮询；
- 该界面有 `CityStateCountSlider`（`CityStatePicker.lua:254~269`），拖动即写参数值；
  而 hook 的轮询条件是 `not ContextPtr:IsHidden()`，选择器一打开就每帧把
  `CITY_STATE_COUNT` 改回上限。

**表现**：PC 上打开城邦选择器拖动数量滑块，数值会被立刻弹回上限。
**影响**：功能不坏（hook 本来就要拉满），但滑块看起来“拖不动”。
安卓看不到这个现象 —— 安卓没有这个界面，也没有任何 UI 引用 `CityStateCount`。
**副作用可控**：hook 写 `CustomData` 是在拉满**之前**，所以玩家在滑块上选的数量
仍会被记下来交给幽灵模块，玩家实际得到的城邦数不变。

### 11.4 PC 差异 B：开局前多一道城邦数量校验（**可能每次开局弹警告**）

- PC：`AdvancedSetup.lua:1437 OnStartButton()` → `:1451 ShouldShowCityStatesWarning()`；
- 判据：`(CityStates 域成员数 − 玩家排除数) < CityStateCount` → 弹
  `LOC_CITY_STATE_PICKER_TOO_FEW_WARNING`；
- 安卓：`AdvancedSetup.lua:979 OnStartButton()` 直接 `Network.HostGame`（`:989/:994`），
  **没有这道校验**，安卓文件里也**没有** `LOC_CITY_STATE_PICKER_TOO_FEW_WARNING` 这条文案。

hook 把 `CityStateCount` 拉到 `MapSizes.MaxCityStates`（本 mod 抬到 62），
所以是否触发取决于「可用城邦文明数」：

| 复制城邦选项 | 域成员数（推断） | 是否触发 |
|---|---|---|
| 开（默认） | ~41 × 2 = 82 ≥ 62 | 不触发 |
| 关 | ~41 < 62 | **每次开局弹一次** |

⚠️ 41 / 82 是**推断值**（来自本 mod 注释里“Base 24 + 资料片 11 + DLC 6 = 41”与
`Civ6PC` 数据里的城邦文明行数），**必须实机确认**。

**不是阻断**：`ShowCityStateWarning` 走的是 `ShowOkCancelDialog(…, HostGame)`，
点 OK 照样开局 —— 但每次开局都弹一下很显眼。

### 11.5 建议改法：把上下文判据收紧一行

现在只靠 `MapSize_ValueChanged`，PC 上分不出主界面与选择器子上下文。
**不能**用 `SupportFunctions` 之类的存在性来分辨 —— `PlayerSetupLogic` 也 include 了它，
四个上下文里都有。

可用 `StartButton`：主设置界面（创建游戏 / 创建场景）有，选择器子上下文没有，
而且 **PC 与安卓都有**：

| 上下文 | `ID="StartButton"` |
|---|---|
| `AdvancedSetup.xml` | PC 1 / 安卓 1 |
| `ScenarioSetup.xml` | PC 1 / 安卓 1 |
| `CityStatePicker.xml`（PC 独有） | 0 |
| `LeaderPicker.xml`（PC 独有） | 0 |

```lua
local function ModMiscToolIsGameSetupContext()
	-- 主设置界面（创建游戏 / 创建场景）才有 StartButton。
	-- PC 的城邦/领袖选择器子上下文也会 include 本文件，且同样满足
	-- MapSize_ValueChanged ~= nil，只靠那一条分辨不出来。
	return MapSize_ValueChanged ~= nil and Controls.StartButton ~= nil
end
```

`Controls.StartButton` 在两版的 `AdvancedSetup.lua` 里都被直接使用
（PC 1261 行 / 安卓 803 行），说明该控件在 Lua 侧确实可用；
但**在 include 阶段（本 hook 执行时）`Controls` 是否已经绑定好，需要实机确认** ——
若拿不到，退路是改成“第一次轮询时再判定并安装”。

### 11.6 PC 端待实机确认清单

1. 进「创建游戏」后看 `Lua.log`：是否出现
   `[ModMiscTool][Ghost] setup hook installed (refresh handler)`（出现 = hook 装上了）；
2. 接着看有没有 `city states -> max 62 (player choice N saved)`；
3. 开局前是否弹出「城邦数量不足」警告对话框（对应 11.4，注意复制城邦选项的开/关）；
4. 打开城邦选择器拖数量滑块，数值是否被弹回（对应 11.3）；
5. 进游戏后城邦数量是否确实**多于**玩家选择的数量（安卓实测是 36，PC 待测）。

---

## 12. 对局内创建新局 / 换地图（2026-10-05 实机：RestartGame 可用，HostGame 不可用）

**动机**：如果能**在对局内**调起 ScenarioSetup 那套「创建游戏」，再配上已验证的对局内读档
（第 38 条），就能模拟“游戏中切换地图”：切图前先存档 → 就地按新地图建一局 →（要回去就）读档。

**验证入口**：Automation 测试面板（本轮**重新注册**，见 modinfo）底部新增的
「创建新局 / 换地图」区；接口封装与判定协议全在 `UI/ModMiscCreateGame.lua`。

### 12.1 静态核对（都来自游戏自带代码，不是推断）

| # | 事实 | 出处 | 对本次验证的意义 |
|---|---|---|---|
| a | `Network.RestartGame()` 是引擎自带的**对局内**重开，注释写着「Start a fresh game using the existing game configuration.」 | `Base/Assets/UI/Menus/InGameTopOptionsMenu.lua:78` | 对局内建新局有官方路径，拿它当对照组 |
| b | 该按钮的可用条件是 `not GameConfiguration.IsAnyMultiplayer()`（热座还要“不是读来的档”），并且 `WorldBuilder` 激活时禁用 | 同上 `:316~:323`、`:378` | 单机普通局应当可重开；面板日志会打出这几个门槛值 |
| c | `GameConfiguration` 在**对局内 UI 上下文**可用（同一文件在读 `IsAnyMultiplayer` / `GetGameSpeedType` / `IsSavedGame`） | 同上 `:316`、`:439~:447` | 配置对象本身不是问题 |
| d | `MapConfiguration` 在**对局内代码里一个调用点都没有** | 全仓库 grep（只有 FrontEnd / Automation 在用） | 可用性未知 ⇒ 必须靠面板探测（这是换图能不能成立的关键） |
| e | 引擎自己的 Automation 要求 HostGame 必须站在主菜单：「We must be at the Main Menu to do this test」，不在就 `Events.ExitToMainMenu()` | `Automation_StandardTests.lua:489`、`Automation_DailySmokeTest.lua:96` | 对局内直调 `HostGame` **大概率不被支持**；验证它就是为了把结论钉死 |
| f | 配置键：`Map` 组 `MAP_SCRIPT`（值是**地图脚本文件名**，如 `Pangaea.lua`）/ `MAP_SIZE`；`Game` 组 `RULESET` / `GAME_HANDICAP` / `GAME_SPEED_TYPE` / `CITY_STATE_COUNT` | `Base/Assets/Configuration/Data/SetupParameters.xml:5/9/15/18/21/23` | 面板「应用地图配置」写的就是这几个键 |
| g | 地图清单（含 DLC/资料片）在前端的来源是 Configuration 库 `Maps` 表：`SELECT File, Image, StaticMap from Maps where Domain = ?` | `AdvancedSetup.lua:182` | 面板用它生成「目标地图」下拉；对局内查不到就用模块内置兜底表 |
| h | 前端参数系统对“游戏已开始”的限制（`ChangeableAfterGameStart` / `GAMESTATE_PREGAME`）只在 `SetupParameters:Config_CanWriteParameter` 里 | `SetupParameters.lua:535`、`:1505` | 面板是**直接写配置对象**、绕过参数系统 ⇒ 这套拦截不适用，能不能写只能实测 |

### 12.2 待实机验证的条目

| # | 接口 / 方法 | 状态 | 备注与判定 |
|---|---|---|---|
| 40 | 对局内 `MapConfiguration` 及其 `SetScript` / `SetValue("MAP_SCRIPT")` | `[未验证]` | 探测行 `api: MapConfiguration=y MapConfiguration.SetScript=y …`（`y/y` = 可用）。**这是换图能否成立的关键**：若为 `n`，换图只能退回「改配置走 WorldBuilder 那条（gameplay 侧）」或「退主菜单再建」。 |
| 41 | 对局内写地图配置并回读生效 | `[已验证失败]`（就“换图”而言） | 面板「应用地图配置」会把 4 条路径逐条记进 `routes[...]`：`MapConfiguration.SetScript` / `MapConfiguration.SetValue` / `GameConfiguration.SetValue` / `WorldBuilder.ConfigurationManager():SetMapValue`，并回读 `applied=`。<br>**实机（2026-10-05）**：授权者结论 —— **地图配置没有成功**：写进去的配置既不被接下来的重开采纳（第 46 条），也**没能活到前端**（见第 44 条的探针结果）⇒ **换地图脚本这条路彻底关闭**，只剩“重启换种子”。 |
| 42 | 对局内 `Network.RestartGame()` | `[✅ 已验证可用]` | 授权者实机：**对局内重开可用** —— 这就是「重启换图」的实现基础。日志形态：`即将调用 Network.RestartGame()` → `调用已返回（没卡死）` → 新局里出现 `after-create: VERDICT=new-game`。 |
| 43 | **对局内 `Events.SetGameEntryMethod` + `Network.HostGame(ServerType.SERVER_TYPE_NONE)`**（ScenarioSetup.OnStartButton 的普通分支） | `[已验证失败]` | 授权者实机：**调用返回、进程不崩，但没有建出新局**（静默空操作）——与引擎自己的 Automation 要求一致（`Automation_StandardTests.lua:489`：HostGame 必须站在主菜单，不在就 `Events.ExitToMainMenu()`）。<br>⇒ 面板按钮与 `ExposedMembers.ModMiscToolUI.HostGameInGame` 已移除；`ModMiscCreateGame.HostGame()` 保留在代码里只为把“试过什么、结论是什么”钉住（调用点只剩它自己）。 |
| 44 | 对局内 `Events.ExitToMainMenu()` + “对局内写的配置能不能活到前端” | `[已验证可用]`（退出）／`[已验证失败]`（配置留存） | 授权者实机：退回主菜单后进创建游戏界面，前端探针 `[ModMiscTool][MapConfigProbe]` 打出来的**还是原来那张图** ⇒ 配置在离开对局时就被重置，**“退主菜单再创建”也带不走对局内写的 MAP_SCRIPT**。<br>含义：**换地图脚本这条路彻底走不通**；退出到主菜单本身仍然可用（当作兜底/回发布态入口）。 |
| 45 | 对局内普通存档（`Network.SaveGame{Type=SINGLE_PLAYER, FileType=GAME_STATE}`） | `[未验证]` | 「切换前存档」按钮。前端配置档（第 32 条）与对局内配置档写入都已验证；普通档这条**没单独验过**，面板会等 `Events.SaveComplete` 回执。 |
| 46 | 对局内改的配置**会不会被新局采用** | `[已验证失败]`（对 RestartGame） | 授权者实机：**配置没被采纳**，但**重开会更换地图生成种子** ⇒ 现实可得的换图能力是「同一张地图脚本重新生成一张新图」，不是「换成另一张地图脚本」。<br>与 RestartGame 的注释吻合：「The restart mechanic uses the game configuration **prior to the very beginning of the game**」（InGameTopOptionsMenu.lua:317，TTP 34989）—— 它读的是开局前那份配置，对局内的改动不算数。<br>结论：**换脚本**只剩「退主菜单 → 在创建游戏界面重新开局」这条路，能否带走在写入的配置 → 见前端探针（第 44 条）。 |

### 12.3 面板操作顺序（按风险从低到高）

1. **探测创建接口** —— 只读，安全。把 `api:` / `routes:` / `now:` 三行记下来；
2. **目标地图**（下拉）选一张与当前不同的图，例如 `Pangaea.lua`；
3. **应用地图配置** —— 看 `applied=true/false` 与 `routes[...]`，这一步不动当前局；
4. **写切换标记**（可选，手动路径用：想用游戏自带的「重新开始 / 载入游戏」菜单测同一套判定时先点它）；
5. **切换前存档** —— 想再回到这一局就点（等 `SaveComplete` 回执）；
6. **重开新局**（`Network.RestartGame`）—— 对照组；
7. **HostGame 建新局**（验证目标，等价 ScenarioSetup 的开始按钮）；
8. **退回主菜单** —— 兜底路径。

> 想换回旧地图 / 旧进度：走游戏自己的「载入游戏」菜单读那个 `ModMiscCreateGame~switch-backup` 档
> （对局内直调 `Network.LoadGame` 已验证可用，但会顶掉当前局，所以面板不提供按钮，见第 38 条）。

### 12.4 Lua.log 判定表（前缀 `[ModMiscTool][CreateGame]`）

> 2026-10-05 实机已按此表跑过：结论见 12.5。下表保留，供后续复测（例如换地图脚本那条路）。

| 日志表现 | 结论 |
|---|---|
| 最后一行是 `即将调用 …`，之后什么都没有 | 调用把进程干掉了；取 tombstone 看 backtrace（参考第 13c 条的 SIGSEGV 排查法） |
| `即将调用 …` 后跟 `调用已返回（没卡死）；现在是：…`，但之后没有 `LoadScreen` / 开局探针 | 调用是**空操作**：引擎接受了调用但没建新局 |
| 出现 `after-create: VERDICT=new-game` | **新局建出来了**（CustomData 不跨新局 ⇒ 标记读不到） |
| 出现 `after-create: VERDICT=marker-present` | 没进新局：要么还在原来那一局，要么是读回了「存档之后」的旧档 |
| 新局的 `now: …script=<目标图>…` | 对局内改的地图配置**被采纳** ⇒ 换图成功 |
| 新局的 `now: …script=<原图>…` | 建了新局但用的还是旧地图配置（对应第 46 条） |

**证据链怎么连起来的**：`ArmMarker` 先把「切换前快照」（act/nonce/turn/script/size/grid/players）
写进 CustomData；而 CustomData 是**随局随档**的（第 21/39 条），新局不继承 ⇒
“标记读不到”就是“这是个全新的局”的直接证据；再拿新局的指纹和快照里的 script/grid 一比，
就知道地图到底换没换。整个过程只依赖 Lua.log，不需要面板一直开着。

### 12.5 实机结论小结（2026-10-05，授权者）

* **能用的只有 `Network.RestartGame()`**：对局内立刻重开一局，**地图重新生成、换种子**，
  但地图脚本仍是原来那张（对局内写的 `MAP_SCRIPT` 不被采纳）。
* **`Network.HostGame` 在对局内是静默空操作**（返回、不崩、不建局）⇒ 按钮已移除。
* 因此“切换地图”目前的实现口径是：**重启游戏 + 跨存档数据搬运 + （待验证的）回合/年代写回**，
  即“同一张地图脚本的新图 + 把状态搬过去”，不是“换成另一张地图脚本”。
* **换地图脚本没有任何就地办法**（第 41/44 条实测）：对局内写的配置既不进重开，也活不到前端；
  想换脚本只能退主菜单、在**创建游戏界面**由玩家自己重新选图开局（那已经不是“对局内切换”了）。
* 面板收尾（授权者 2026-10-05 定）：`AutomationTestPanel` **继续注册**（留着当调试入口），
  只把已经证伪的试写按钮（HostGame、回合/年代）删掉；代码与结论留在模块头注释与本文档里。

---

## 13. 回合数 / 年代显示（2026-10-05 实机：**写接口全部无效**，只留读）

**动机**：重启换图（第 12 节：`Network.RestartGame` 可用）之后，新局回到**第 1 回合、远古时代**。
要假装“只是换了张图”，就得把回合与年代**写回去** —— 数据由跨存档通道带过来（那条已通）。
这一段先回答两件事：

1. 有没有能**写回合数**的接口？
2. 有没有能**写年代**的接口？年份显示又是怎么跟着变的？

验证入口：Automation 面板第 2 页签「**重开与时间线**」（页签按钮在面板头部）；
接口封装在 `UI/ModMiscTurnEra.lua`（UI 层）与 `ModTool_TurnEraAPI.lua`（gameplay 层）。

### 13.1 静态核对（都来自游戏自带代码，不是推断）

| # | 事实 | 出处 | 意义 |
|---|---|---|---|
| a | 回合写**只有一个候选**：`Game.SetCurrentGameTurn(n)` | `DLC/PolandScenario/Scripts/PolandScenario.lua:63`（`<AddGameplayScripts>` 注册的 gameplay 脚本，且那行**被注释掉**，旁边写着 `-- NEED A FINAL APPROACH TO TURN AND YEAR`） | 唯一希望，但作者自己都没用成 ⇒ 必须实测 |
| b | 全库 `Game.*` 里与回合/时间有关的方法：`GetCurrentGameTurn` / `GetCurrentTurnSegment` / `GetGameEndTurn` / `GetMaxGameTurns` / `GetEras` / **`SetCurrentGameTurn`** | 全库 grep | 没有第二个写接口 |
| c | 回合显示口径：`turn = Game.GetCurrentGameTurn()`；有 `CAPABILITY_DISPLAY_NORMALIZED_TURN` 时先 `turn = turn - GetStartTurn() + 1` | `Base/Assets/UI/TopPanel.lua:387~391` | 顶栏回合数有时会按“开局回合”归一化 |
| d | **年份是回合的纯函数**：`Calendar.MakeYearStr(turn)`（TopPanel 用它）；完整写法 `Calendar.MakeDateStr(turn, 历法, 速度, false)`，历法/速度取自 `GameConfiguration.GetCalendarType/GetGameSpeedType` | `TopPanel.lua:407`、`ARXManager.lua:253`、`GreatWorksSupport.lua:20` | ⇒ **改回合 = 改年份显示**，不需要单独的“年份”接口 |
| e | 年代读：`Players[id]:GetEra()`（**0 基**）+ `GameInfo.Eras[idx]`；全局：`Game.GetEras():GetCurrentEra()` | `ActionPanel.lua:353`、`PortraitSupport.lua:27` | 判定写没写进去就看它 |
| f | `Game.GetEras()` 上**只有读方法**：`GetCurrentEra` / `GetCurrentEraStartTurn` / `GetNextEraCountdown` / `GetPlayerNumAllowedCommemorations` | 全库 grep | **没有全局时代 setter** |
| g | 年代写只有 `WorldBuilder.PlayerManager():SetPlayerEra(playerID, eraType)`（**gameplay 层**；地图编辑器的时代下拉框就是调它） | `WorldBuilderPlayerEditor.lua:1282`；本 mod `WorldBuilderAPI.SetPlayerEra` | 通道本身已 [已验证可用]，但**普通对局里改有没有效果**没验过 |
| h | 下一局的开始年代：配置键 `Game` 组 `GAME_START_ERA`（`Hash="1"` ⇒ 存哈希）；引擎 Automation 用 `GameConfiguration.SetStartEra(...)` | `SetupParameters.xml:10`、`Automation_StandardTests.lua:213`、`AssignStartingPlots.lua:1961`（`GameInfo.Eras[GetStartEra()]`） | 重启换图时最适合复位的旋钮（**下一局生效**） |
| i | 下一局回合上限：`GameConfiguration.SetMaxTurns(n)` + `SetTurnLimitType(TurnLimitTypes.CUSTOM)` | `Automation_StandardTests.lua:219` | 备选旋钮（本轮未做按钮） |
| j | 年代变化有事件可当证据：`Events.PlayerEraChanged(playerIndex, currentEra)` | `EraCompletePopup.lua:193`、`Automation_NarrationManager.lua:221` | 改了年代若真生效，这个事件会来 |
| k | 回合推进的**合法**路径（已可用）：`AutoplayManager.SetTurns/SetActive`（面板「自动播回合」就是它） | `Automation_HighValue_APIs.md`；本 mod 面板已实测 | 写回合若失败，只能靠自动播“往前推” |

### 13.2 待实机验证的条目

| # | 接口 / 方法 | 状态 | 判定与备注 |
|---|---|---|---|
| 47 | `Game.SetCurrentGameTurn(n)`（**UI 直调 → gameplay 兜底**） | `[已验证失败]` | 授权者实机：**改回合没成功** —— 调用不报错、回合数不变（面板试写返回 `applied=false`，回读值不动）。UI 层没有这个函数时会自动转 gameplay 的 `ExposedMembers.ModMiscToolScript.TurnEraAPI`，两条路都没写进去。 |
| 48 | `WorldBuilder.PlayerManager():SetPlayerEra(playerID, eraType)` 在**普通对局**里改年代 | `[已验证失败]` | 授权者实机：**改年代没成功**。通道本身可用（地图编辑器在用，属 [已验证可用] 接口），但普通对局里改了不生效 ⇒ “编辑器能改”≠“对局内能改”。 |
| 49 | 年代改了之后**显示**跟不跟着变 | `[已验证失败]`（前提不成立） | 第 48 条就没写进去，显示自然没动；面板临时挂的 `Events.PlayerEraChanged` 监听也没收到由它触发的事件（该监听已随试写按钮一起移除）。 |
| 50 | 年份显示随回合变 | `[失效]`（依赖第 47 条） | 年份 = `Calendar.MakeYearStr(turn)` 仍是纯函数（第 d 条），但回合写不进去 ⇒ 年份也就改不了。**读**年份没问题（`GetDateString` 可用）。 |
| 51 | `GameConfiguration.SetStartEra(hash)`（**下一局**的开始年代） | `[已验证失败]` | 授权者实机：写配置没有成功 —— 重开后的新局并未按它开局。 |
| 52 | `GameConfiguration.SetMaxTurns(n)` + `SetTurnLimitType`（**下一局**回合上限） | `[未验证·已搁置]` | 引擎 Automation 在用；既然第 51 条（同一类“下一局配置”）都不生效，这条**暂不投入**，需要时再单独验。 |

### 13.3 面板操作 —— **试写按钮已按授权者要求移除**

本轮验证用的按钮（探测回合/年代、回合 ±10、年代 ±1、开始年代 +1）连同对应文案都已删除
（2026-10-05，第 13.5 节结论出来后）；要复测时按第 13.6 节的办法来。当前第 2 页签只保留
「目标地图 / 探测创建接口 / 应用地图配置 / 写切换标记 / 切换前存档 / 重开新局 / 退回主菜单」。

### 13.4 Lua.log 判定表（前缀 `[ModMiscTool][TurnEra]`；本轮已按此跑过，结论见 13.5）

| 日志表现 | 结论 |
|---|---|
| `SetTurn: applied=true route=ui …` | **UI 层就能写回合** ⇒ 复位回合可行 |
| `SetTurn: applied=true route=gameplay …` | UI 层不行、**gameplay 行** ⇒ 由 gameplay 侧封装提供 |
| `SetTurn: applied=false … routes[ui=… gameplay=…]` | 两条路都写不进去 ⇒ 回合只能靠自动播往前推 |
| `SetPlayerEra: applied=true … before=… after=…` | 玩家年代可写 ⇒ 复位年代可行 |
| `SetPlayerEra: applied=false …` | 引擎不接受写（或目标时代不存在）⇒ 年代只能用「下一局开始年代」（第 51 条）兜 |
| `SetStartEra: applied=true …` | 下一局开始年代写成功；重开后看 `after-load: … playerEra=` 是否变 |
| `after-load: turn=… date=… playerEra=… gameEra=…` | 每次进游戏一行现状 —— **重开前后各看一次**就知道回合/年代有没有被复位 |

### 13.5 实机结论（2026-10-05，授权者）

**回合、年代、下一局开始年代 —— 三个写方向全部无效。** 授权者的评定：这些属于
「增强沉浸感的边角料」，核心机制（重启换图 + 跨存档搬运）已经到手，不再投入。

由此确定的口径：

* 重启换图后，新局**就是第 1 回合、远古时代**，没法“拨回去”；
* 想要回合/年代连续，只剩**合法但慢**的一条：`AutoplayManager` 往前推回合（能顺带把年代推上去），
  代价是每换一次图都要空跑一遍回合；
* 年份显示（`Calendar.MakeYearStr`）本来就是回合的函数，随着回合走 —— **读**没问题，**改**不了。

### 13.6 要复测怎么做

试写按钮已删；复测不用恢复界面，直接在任意 UI 上下文（或经 `ExposedMembers.ModMiscToolUI`）调：

```lua
-- 现状（读，仍可用）：turn / date / startTurn / endTurn / maxTurns / playerEra / gameEra
print(ModMiscTurnEra.DescribeFingerprint())
-- 试写（已验证失败，留档）：会打 [ModMiscTool][TurnEra] 日志并把 ok/applied 返回给你
ModMiscTurnEra.AdjustTurn(10)                 -- Game.SetCurrentGameTurn（UI → gameplay 兜底）
ModMiscTurnEra.AdjustPlayerEra(0, 1)          -- WorldBuilder SetPlayerEra
ModMiscTurnEra.SetStartEra("ERA_MEDIEVAL")    -- 下一局开始年代（GAME_START_ERA）
```

该模块的写函数与 gameplay 后端 `ExposedMembers.ModMiscToolScript.TurnEraAPI` 都**保留在代码里**
（头部写明“实测无效”），UI 层对外只暴露读接口。

---

## 14. 成品：存档关系（主线 / 分支）+ 换图（2026-10-05，**待实机**）

**成品口径**（基于第 12、13 节的实机结论）：换图 = 「先存原档 → 同一地图脚本重新生成（换种子）
→ 新局算这条记录的分支」。回合 / 年代 / 地图脚本都改不动（第 12、13 节），所以这套存档机制
是换图功能能落地的前提：**原档必须存得住、找得回，关系必须看得见**。

实现：`UI/ModMiscSaveGraph.lua`（逻辑）+ `UI/ModMiscSavePanel.lua/.xml`（左侧栏「存档与换图」面板），
格式与流程见 `API_Documentation.txt` 3.13。

### 14.1 设计要点（都建立在已验证通道上）

| 需要什么 | 用什么 | 依据 |
|---|---|---|
| 关系信息跨存档保留 | **存档文件名**（`MMT~id~parent~kind~T回合~地图~时间`） | 通道 C（第 34 条 / 通道表）是唯一实测可用的跨存档通道 |
| 知道“本局是哪个节点” | 存档前把节点身份写进 **CustomData**，随档序列化、读档还原 | 第 21 条（CustomData 随档、不跨新局） |
| 换图后的父子关系带过去 | **跨存档存储**键 `sg_pending`（`ModMiscStore`） | 重开后 CustomData 不继承，只有存储通道能过去（第 39/21 条） |
| 主线头 | 存储键 `sg_head` | 同上 |
| 落盘确认 | `Events.SaveComplete` + `UI.QuerySaveGameList` 复查 | 第 32/34 条；存档菜单自己也在用 `SaveComplete` 等待 |
| 换图动作 | `Network.RestartGame()` | 第 42 条 `[✅ 已验证可用]` |

### 14.2 待实机验证的条目

| # | 接口 / 方法 | 状态 | 判定与备注 |
|---|---|---|---|
| 53 | 对局内 `Network.SaveGame{Type=SINGLE_PLAYER, FileType=GAME_STATE, Directory=SaveDirectories.DEFAULT, Name=<MMT 格式>}` 真的落盘 | `[✅ 已验证可用]`（2026-10-05 实机） | 面板「存档」→ 状态行出现「确认落盘」（= `SaveComplete` 之后复查 `UI.QuerySaveGameList` 列表里有这个档），日志 `落盘复查：节点 … 已在存档列表里`。**这是整条链路的地基**：不成立则关系树没有节点。 |
| 54 | 本 mod 格式的档名能在存档列表里原样保留（含 `~`、点、连字符） | `[✅ 已验证可用]`（2026-10-05 实机） | 扫描后节点数 > 0 即成立；日志 `扫描完成：列表 N 档，其中本 mod 关系档 M 档`。 |
| 55 | 读自己的档之后能认出“我在哪个节点” | `[✅ 已验证可用]`（2026-10-05 实机） | 读档 → 开局探针 `after-load: current=<id>`，且面板关系树里那一条带「本局」标记。依赖 CustomData 随档还原（第 21 条已验证，但这条链路没端到端跑过）。 |
| 56 | 换图全流程：存原档 → 落盘确认 → 重开 → 新局首档成为**分支** | `[✅ 已验证可用]`（两步式，2026-10-05 实机，见 14.2f） | 授权者实测：**能按格式存档**，但新局把自己当成了树根（分支身份丢失）⇒ 已按 14.2b 修（存储就绪门 + 开局固化）。**待复测**：点「换图（先存原档）」→ 日志应为 `待接分支已写入存储` → `落盘复查：节点 … 已在存档列表里` → `待接分支已确认落盘` → `Network.RestartGame 调用已返回` → 新局 `本局接手待接分支：parent=<原档id>` → 新局点「存档」→ 面板信息行「来源」有值、关系树里新档标 `[B]` 挂在原档下。 |
| 57 | SL 场景：读旧档继续 → 新档算分支、主线头不动 | `[未验证]` | 读一档旧档 → 存档 → 新档 `[B]`、父是旧档；面板信息行「主线头」不变。 |

### 14.2b 实机反馈与修复（2026-10-05）：分支不知道自己是谁

授权者实机：「分支创建测试完成，可以按格式存档，但**分支似乎不知道自己是分支**」。

**根因（两处，都已修）**：

1. `ModMiscStore` 的内存表是**每个 UI context 各一份**：换图重开后面板是新上下文，
   那张表**是空的**，不先 `Refresh()` 就读不到 `sg_head` / `sg_pending`
   ⇒ 新局第一次存档判成“树根 + 主线”，分支身份丢失；
2. 即便扫过，也存在“还没扫完就点了存档”的时间窗 —— 拿空数据做决定。

**修法**：

* `EnsureStoreReady(callback)`：凡是要依据主线头/待接分支做决定的动作（存档、换图、开局探针），
  一律先过这道门 —— 已就绪立即回调；没就绪就挂 `OnReady` + 触发 `Refresh`，扫完再决定；
  存储真的用不了（扫描起不来）才带警告继续，绝不把动作挂死；
* **开局固化**：新局启动的探针读到待接分支后，立刻把“本局来源（parent + kind）”写进
  **CustomData**（随档保存），并把存储里那条消费掉。这样：
  ① 之后存档只依赖 CustomData，不再看存储的扫描状态（跨 context 必然可见）；
  ② 玩家之后退回主菜单另开新局，也不会被陈旧的 pending 误挂成分支；
* 判定过程打成一行日志，下次不对一眼就能看出是哪个输入缺了：
  `判定：current=… incoming=… head=… pending=… 来源=current|incoming|pending|root => parent=… kind=…`
* 面板信息行加「来源」，直接显示“我挂在谁下面、算什么”。

**回归**：桩环境新增两组用例 —— ⑩开局固化（探针把 pending 写进 CustomData 并消费存储条目）、
⑪面板 context 完全没扫过存储时存档仍判为 `[B] parent=原档`（修复前这里正是当树根）。

### 14.2c 实机第二轮反馈与修复（2026-10-05）：换图不跳转 / 退出后新开档被认成分支

授权者实机：
1. **「保存后点切换没有自动跳转」**；
2. **「退出到主界面新开存档被识别为分支」**。

两个现象是**同一条因果链**，另有各自独立的一处设计问题：

| # | 根因 | 修法 |
|---|---|---|
| 1 | 换图流程里串了**第二层异步门**：`SaveComplete` → 扫存档列表 → 复查存储 pending → 才重开。任何一环不回包，换图就永远不发生（第一层是 `OnSaved` 也在扫描回调里） | ① `OnSaved` 改成 **SaveComplete 一到就回调**（found 传 nil 表示“还没复查”）；② `SwitchMap` 收到回执**直接 `RestartGame`**，落盘复查只打日志、不拦路；③ 面板另挂 **10 秒兜底计时器**（`ContextPtr:SetRefreshHandler`），到点还没跳就 `ForceSwitch` 强制重开（`m_SwitchIssued` 防重复） |
| 2 | 换图没跳成 ⇒ `sg_pending` 留在跨存档存储里；玩家退出到主菜单另开新局时，开局探针把这条**陈旧**的关系认成了本局来源 ⇒ 新档挂成分支 | ① 挂 `Events.ExitToMainMenu` → 退出即 `ClearPendingBranch("退出到主菜单")`；② pending 载荷带写入时间戳，超过 **900 秒**判过期并丢弃；③ 新局开局固化后立刻消费掉 pending（上一轮已有） |
| 3 | `SaveComplete` 一旦丢失，`m_SavePending` 永远非空 ⇒ 之后每次存档/换图都被“上一笔还在等回执”拒掉 | `SaveNode` 加自愈：等回执超过 **60 秒**就丢弃旧状态继续（日志写明） |

另外按授权者提议接入**第三条通道**：

* **`Game:SetProperty`（gameplay 侧单向通道）** —— 存档时把「本局节点身份」同时写进
  `CustomData` 与 `Game:SetProperty`（用现成的 `ModMiscToolData` 封装，经 ExposedMembers 调用）。
  它随档保存、读档还原、**新局不继承**，且**只在 gameplay 可读、前端拿不到**；
  `GetCurrentNodeId()` 以 CustomData 优先、property 兜底，两条互为交叉校验。
  日志：`节点身份已写入：customdata=ok property=true`，探测行 `current=<id>(customdata|property) property=<id>`。

**回归**：新增 `sg2_harness`（面板问题专用）四组用例 ——
① 扫描永不回包时换图仍跳转；② `SaveComplete` 不来时 `ForceSwitch` 兜底且不重复跳；
③ 过期 pending 被丢弃、新档回到树根；④ 退出清理生效；⑤ CustomData 读不到时靠 property 认出本局节点。

### 14.2d 实机第三轮（2026-10-05）：仍然无法切换 —— 改成**按帧回调驱动的状态机**

授权者：「点击切换按键后仍然无法切换，可能是没有检测到本地的主存档」。

排查结论：**换图不该把任何一步挂在引擎事件上**。上一版虽然去掉了“扫描确认”那层门，
但仍然把后续动作放在 `Events.SaveComplete` 回调里，而且：

* `SaveComplete` 是否送到面板这个 context、什么时候送，都不由我们控制；
* 一旦它不来，`m_SavePending` 与状态机就干等（虽然有 10 秒兜底，但那个兜底本身也依赖
  `ContextPtr:SetRefreshHandler` 的回调被正确挂上并持续 `RequestRefresh`）；
* 更关键的是：**从存档事件回调里调 `Network.RestartGame()` 与“点按钮重开”不是同一类调用上下文** ——
  而“点按钮重开”是唯一被实机证明可行的那条路（第 42 条）。

**改法（v1.61）**：换图改成**按帧回调推进的状态机**，`SwitchMap()` 只负责开局：

    SwitchMap()            面板按钮回调：登记状态机（阶段 = 等存储），触发一次存储扫描即返回
    TickSwitch()           面板按帧回调里调用，返回阶段串：
      waiting-store  等存储就绪（上限 5 秒，超时带警告继续）
      saving         算节点 → 先写 pending → Network.SaveGame → 等回执（上限 12 秒）
      restarting     从**按帧回调**里发出 Network.RestartGame()（记录返回值）
      retrying       发出后我们的代码还在跑 ⇒ 没生效，隔 8 秒重试（最多 3 次）
      failed         3 次都没生效：日志写明“原档已保存、关系已记，可用游戏菜单的「重新开始」”，
                     并结束状态机（不再挂住；玩家再点一次「换图」= 手动重试）
    ForceSwitch(reason)    跳过等待立刻发重开（换图进行中再点按钮 = 手动重试）

要点：
* `SaveComplete` 只当**提前量**（置个标志早点走），不是必经之路；
* 重开**只在按帧回调里发出** —— 与“点按钮重开”同一类上下文；
* 每一步都有超时，任何一环不回包都不会卡死；
* 发出重开后能**自我检测**（代码还在跑 = 没生效）并重试、最后给出明确出路；
* 面板状态行按阶段显示五条文案（PHASE_STORE/SAVING/RESTARTING/RETRYING/FAILED）。

**回归**：`sg2_harness` 重写为可控时钟 + 状态机驱动，七组用例全过 ——
①最坏情况（扫描不回包 + SaveComplete 不来）仍换图；②正常路径回执一到就换；
③重开不生效 → 自动重试 3 次后收尾不挂住；④进行中再点 = 手动重试；
⑤过期 pending 丢弃；⑥退出清理；⑦只靠 property 认出本局节点。

### 14.2e 实机第四轮（2026-10-05）：改成**两步式换图**，并把重开放回按钮回调

授权者：「现在的面板以及原版 UI 都可以在存储完成后刷新，问题出在哪一步」。

这条信息很关键：**存档管线与事件都是好的**（我们的关系树会刷新、原版存档列表也会刷新），
所以可疑环节只剩「重开是怎么被调用的」。回顾四轮：

| 版本 | 重开是从哪里发出的 | 结果 |
|---|---|---|
| 1.58 | `SaveComplete` 事件回调 → 扫列表 → 复查存储 → 重开 | 不跳 |
| 1.60 | `SaveComplete` 事件回调里直接重开（列表复查降级为日志） | 不跳 |
| 1.61 | 面板**按帧回调**驱动的状态机里重开 | 不跳 |
| 1.62 | 同上 + 时钟可缺省 | （未单独测） |
| **1.63** | **第二步按钮的按钮回调里直接 `Network.RestartGame()`** | 待测 |

唯一被实机证明可行的调用方式，是**按钮回调里直接调**（第 42 条：Automation 面板那次）。
所以 1.63 把流程改成两步，把重开放回按钮回调：

    「换图（两步）」第一次点击  PrepareSwitch()：算节点 → **先写待接分支** → Network.SaveGame
                                 状态行：「原档 <id> 已写。再点一次『换图』就重启到新地图。」
    「换图（两步）」第二次点击  SwitchNow()：**按钮回调里**直接 Network.RestartGame()
                                 （若原档还在写，面板会先拦一下，等落盘后再点）

好处：
* 不再依赖 `SaveComplete`、不再依赖按帧回调、不再依赖时钟 —— 这条路上没有任何“也许会不来”的环节；
* 关系（待接分支）在存档**之前**就写好，所以哪怕存档回执全丢，新局的父子关系照样成立；
* 重开时的环境一并打日志（`anyMultiplayer / savedGame / worldBuilder / isGameHost / turn`），
  万一引擎还是不吃，日志能直接说明是不是门槛问题。

**同时修掉一个真 bug（桩环境抓到）**：`sg_pending` 的载荷在 1.61 加了第 4 段（写入时间戳），
而解析用的是固定 4 段的 Lua 模式 `^a|b|c|d$` —— **少一段就整条匹配失败**，
于是旧版写的 3 段 pending 会被静默读成 nil（新局把自己当树根）。
现在改成按 `|` 切字段（`SplitFields`），3 段/4 段都认；`Game:SetProperty` 的身份载荷同样处理。

### 14.2f 实机第五轮（2026-10-05）：**两步式换图跑通** ✅ + 抓到一个隐藏 bug

授权者：「测试成功，日志已拉取」。日志（`Lua.log`，前缀 `[ModMiscTool][SaveGraph]`）关键序列：

```
判定：current=tmew2la0 … 来源=current            => parent=tmew2la0 kind=M      ← 第二步之前本局节点
换图[1/2]：待接分支已写入存储（parent=tmew2owf，新局算分支）
即将调用 Network.SaveGame（switch） name=MMT~tmew2owf~tmew2la0~M~T001~Continents~20261005-0956
[面板] Original save tmew2owf written. Press "Switch map" once more …
[面板] The original save is still being written - wait a moment, then press again.   ← 提前点被拦住
换图[2/2]：即将调用 Network.RestartGame()（原因=面板按钮（第二次点击））
          环境：anyMultiplayer=false savedGame=false worldBuilder=false isGameHost=true turn=1
换图[2/2]：调用已返回 result=true
———（之后是新局上下文重新加载：面板 loading / Support_UI 探针）———
after-load(store=true/ready): current=nil head=tmew2la0 pending=tmew2owf
本局接手待接分支：parent=tmew2owf kind=B（已固化到本局身份，存储里那条已消费）
判定：current=nil incoming=tmew2owf head=tmew2la0 pending=nil 来源=incoming => parent=tmew2owf kind=B consumePending=true
即将调用 Network.SaveGame（manual） name=MMT~tmew4qln~tmew2owf~B~T001~Continents~20261005-0958
落盘复查：节点 tmew4qln 已在存档列表里
```

得到的关系树：主线头 `tmew2la0`（M）← 原档 `tmew2owf`（M，换图前存的那一档）
← 新局首档 `tmew4qln`（**B**，挂在原档下）—— 与 14.2 的设计完全一致。
另外还看到过期保护生效：`待接分支已过期（… 2979 秒前 > 900 秒）→ 丢弃`（旧版本留下的陈旧 pending）。

**结论：换图 = 两步式（先存原档 → 再点一次直接重开）成立。** 1.58~1.61 的三次失败都源于
把重开从“按钮回调”挪到了事件回调 / 按帧回调里。

**同时抓到一个隐藏 bug（已修）**：日志里 `节点身份已写入：customdata=ok **property=false（gameplay SetData 不可用）**`
—— 顺藤摸到：

```
Runtime Error: …/ModTool.lua:579: attempt to index a nil value
```

`ModTool.lua` 暴露 `ModMiscToolData.Set` 时**从没 include 过 `ModTool_DataStore.lua`**（该文件只在
modinfo 的 ImportFiles 里登记了），于是 `ModMiscToolData` 是 nil → 这一行报错 →
**`Initialize()` 当场中断**，后面所有暴露（`WorldBuilderAPI`、`TurnEraAPI`…）全部静默失效。
影响面比“属性通道用不了”大得多：任何依赖这些暴露的 mod 都拿不到接口。

修法：
1. `ModTool.lua` 补上 `include('ModTool_DataStore.lua')`；
2. 暴露段改成**逐组 pcall**（DataStore / WorldBuilderAPI / TurnEraAPI 各一组），
   某一组缺模块只打一行 `暴露 X 失败 -> …（只影响这一组，其余继续）`，
   再也不会把整个 Initialize 带走 —— 这类“漏 include 静默废掉一半 API”的坑就此封死。

> **教训（值得记进全局规范）**：把文件登记进 modinfo 的 `<ImportFiles>` **不等于**它被 `include` 了；
> 而 game LUA 里一个 nil 索引就会中断整个初始化函数 —— 排查时要看 Initialize 后半段的暴露是否还在。

### 14.3 Lua.log 判定表

| 日志表现 | 结论 |
|---|---|
| `即将调用 Network.SaveGame（manual/switch） name=MMT~…` | 存档请求已发出（参数齐全） |
| `SaveComplete 回执：… （节点 x）` | 引擎回执到了 |
| `落盘复查：节点 x 已在存档列表里` | **文件真的在盘上**（第 53 条成立） |
| `落盘复查：节点 x 没在列表里` | 没写完或写失败 ⇒ 换图流程会照样重开但关系可能丢 |
| `扫描完成：列表 N 档，其中本 mod 关系档 M 档` | 档名格式被完整保留（第 54 条） |
| `after-load: current=<id>` | 读档认出了节点（第 55 条） |
| `after-load(store=…): pending=<id>` | 待接分支跨过重开活下来了 |
| `本局接手待接分支：parent=<id> kind=B（已固化到本局身份…）` | 开局已把来源写进 CustomData，之后存档不再依赖存储扫描 |
| `判定：current=… incoming=… head=… pending=… 来源=incoming => parent=<id> kind=B` | 这次存档把自己认成了**分支**（修复后的正常形态） |
| `判定：… 来源=root => parent=nil kind=M` | 认成了树根（新装 / 老档 / 换图关系没带过来时才会这样） |
| `已消费待接分支（本局第一次存档，父=<id>）` | 分支挂上去了（第 56 条收尾） |
| `警告：跨存档存储不可用（…），存档照旧但关系可能判错` | 存储用不了时的降级路径（不拦玩家） |
| `换图[1/2]：待接分支已写入存储（parent=<id>，新局算分支）` | 第一步：关系先记好了（v1.63 起） |
| `换图[1/2]：原档已回执（<id>），等玩家点第二次` | 原档写完；等第二次点击 |
| `换图[2/2]：即将调用 Network.RestartGame()（原因=面板按钮（第二次点击））环境：anyMultiplayer=… savedGame=… worldBuilder=… isGameHost=… turn=…` | 第二步：**按钮回调里**直接重开，并把门槛值一起打出来 |
| `换图[2/2]：调用已返回 result=…（若之后还打得出日志，说明引擎没真的重开）` | 调用返回了；之后还有日志 = 引擎没真重开 |
| `换图[2/2] 警告：存储里没有待接分支（…），照样重开` | 没有关系凭据时仍然照玩家意愿重开 |
| `待接分支已过期（… 秒前 > 900 秒）→ 丢弃，避免误判分支` | 陈旧 pending 被清掉（新开档不会再被认成分支） |
| `清除待接分支（退出到主菜单）` | 退出即清，另开新局不会被误挂 |
| `节点身份已写入：customdata=ok property=true` | 两条“随档走”的通道都写成功 |
| `警告：上一笔存档等回执已超时 N 秒，丢弃该状态继续` | 回执丢失后的自愈 |

---

## 15. 读档 / 回合同步（逻辑）/ 跨存档事件（2026-10-05，**待实机**）

三块一起做的，都建立在已经跑通的关系树之上：**从树里读档**、**逻辑回合同步**、**给某个存档发事件**。

### 15.1 从关系树读档

| # | 接口 / 方法 | 状态 | 备注 |
|---|---|---|---|
| 58 | 对局内 `Network.LoadGame(<存档列表条目>, ServerType.SERVER_TYPE_NONE)` | `[待实机]`（接口本身见第 38 条 `[部分可用]`） | 原版载入菜单就是 `m_thisLoadFile = g_FileList[i]` 然后 `Network.LoadGame(m_thisLoadFile, serverType)`（`LoadGameMenu.lua:108/121`）—— 我们照做：把 `UI.QuerySaveGameList` 拿到的**原始条目**原样交回去。会把当前局整局顶掉，所以面板先弹 `ShowOkCancelDialog` 确认。 |

### 15.2 回合同步（**纯逻辑，不做硬同步** —— 授权者明确）

**定义**：主线在第 18 逻辑回合开分支 → 分支引擎第 1 回合 = 逻辑第 18 回合
⇒ 偏移 `offset = 18 - 1 = 17`，于是**分支引擎第 3 回合 = 逻辑第 20 回合**。

* `逻辑回合 = 引擎回合 + offset`；offset 在一局内是常数（两者 1:1 走），开局算一次就固化；
* 固化位置：`CustomData.Offset`（随档）与 `Game:SetProperty`（`turnevents_offset`，gameplay 侧）；
* 分支偏移的来源：换图时写进 pending 载荷的第 5 段（起点逻辑回合），新局开局固化成
  `CustomData.PendingLogical` 与 `Offset = 起点逻辑回合 - 1`；
* 节点身份也带上了逻辑回合：档名末尾可选 `~L<逻辑回合>`、身份载荷第 5/6 段（logical/offset）；
  **老档名没有这一段 → 解析容忍，显示 `-`**（不猜、不硬算）；
* **绝不改引擎回合**：第 47 条已证伪，这里只是换算与显示。

### 15.3 跨存档事件（核心**只做定时触发**，执行方式由处理器决定）

**信箱**：跨存档存储（通道 C）里的键 `ev_<目标节点id>_<序号>`，
值 `type|detail|amount|acceptTurn|fromNode|playerID|civ|stamp`（一个事件一个键，投递即删）。

```
发送方：面板选「目标玩家 / 事件类型 / 内容 / 接受回合」→ SendEvent(选中节点, event)
接收方：开局收件（Support_UI 探针 → ModMiscSaveGraph.IntakeEvents）
        → 交给 gameplay 的回合事件列表（Game:SetProperty，随档保存）
        → 每回合开始（Events.LocalPlayerTurnBegin）结算到点事件 → 执行 + 广播文本事件
```

| # | 行为 | 状态 | 备注 |
|---|---|---|---|
| 59 | 接受回合规则 | `[待实机]` | 接受回合 < 当前逻辑回合 ⇒ 标记 `Overdue` 并排到**下一回合**（授权者口径）；否则到那一回合触发。 |
| 60 | **处理器机制**：`TurnEvents.RegisterHandler(类型, fn, 优先级)` / `UnregisterHandler` / `ClearHandlers` / `GetHandlerTypes` | `[待实机]` | 核心触发时按**优先级降序**询问处理器（先具体类型，再 `"*"` 通配）；契约 `fn(event) → ("handled"|"defer"|"failed", detail)`；返回其它/nil = 这个处理器不管，继续问下一个；处理器自己报错按 `failed` 出队（不挂死队列）。<br>**没有任何处理器认领时事件留在队列里**（不静默丢），日志写明“等注册了处理器的 mod 接手”。 |
| 61 | 默认处理方式（`ModTool_TurnEventHandlers.lua`，**当前测试框架用**）—— 金币 | `[待实机]` | `ChangePlayerGoldAmount` / `player:GetTreasury():ChangeGoldBalance(n)`（游戏自带场景脚本在用）。 |
| 62 | 默认处理方式 —— 单位 | `[待实机]` | `UnitManager.InitUnit(playerID, unitType, x, y)` 落在**接收方首都**；没有首都 → 返回 `defer`（顺延到下一回合，事件不丢）。 |
| 63 | 默认处理方式 —— 资源 | `[待实机·两条通道]` | ① 库存通道 `player:GetResources():ChangeResourceAmount(idx, n)` —— **引擎里没有任何调用点/文档**，先探一手；② 不行就落到地图：`WorldBuilderAPI.SetResourceType(plot, idx, n)`（已封装、已验证通道），在首都附近找自己的陆地放。日志/文案里的 `处理=` 会写清楚走的哪条。 |
| 64 | 其它 mod 接管执行方式 | `[待实机]` | 两条路：① 注册更高优先级的处理器（默认是优先级 0，用 100 就能抢在前面）；② 先 `TurnEventHandlers.Disable()` 或 `TurnEvents.ClearHandlers("GOLD")` 再自己注册。整套默认处理器可用 `ExposedMembers.ModMiscToolScript.TurnEventHandlers.Enable/Disable()` 开关。 |
| 63 | 事件文本提示可由其它 mod 定义 | `[待实机]` | gameplay 侧每条执行完广播 `LuaEvents.ModMiscToolTurnEventFired(type, detail, amount, fromNode, overdue, toPlayerID, result)`，一批执行完再广播 `LuaEvents.ModMiscToolTurnEventBatch(count, logicalTurn)`；UI 侧（Support_UI）默认按类型组 LOC 文案并弹一条汇总弹窗，其它 mod 可用 `ExposedMembers.ModMiscToolUI.RegisterTurnEventTextResolver(fn)` 覆盖文案。 |

### 15.4 这一块的实现位置

| 文件 | 职责 |
|---|---|
| `UI/ModMiscSaveGraph.lua` | 逻辑回合换算、读档、事件发件/收件（信箱）、关系树 |
| `ModTool_TurnEvents.lua`（gameplay） | 回合事件列表（`Game:SetProperty`）、到点**触发**、处理器注册表、文本广播 |
| `ModTool_TurnEventHandlers.lua`（gameplay） | **默认处理方式**（金币/单位/资源）—— 当前测试框架用的实现，可关可换 |
| `UI/ModMiscSavePanel.lua` | 关系树选中、四个选择器（玩家/类型/内容/接受回合）、发送事件、载入选中 |
| `UI/Support_UI.lua` | 开局收件、文本解析器注册、默认文案 + 弹窗 |

### 15.5 实机第二轮（2026-10-05）：「事件没收到」的原因 + 自动换图 / 原地覆盖 / 收件入口

**日志证据**（`Lua.log`）：

```
ModMiscSavePanel: 发件：GOLD 50 x50 → 节点 tmf17exk（接受逻辑回合 1）key=ev_tmf17exk_… 结果=true
…
Support_UI: 收件跳过：本局还没有节点身份（第一次存档之后才会收到发给它的信箱）
Support_UI: [TurnEvent] 开局收件：0 条（no-node）
```

**结论：事件没丢，是“收件的那一局不是收件人”。**
信箱按**节点 id** 寻址，而那次进的是**换图后的新分支局**（还没有节点身份）——发给 `tmf17exk`
的信还在存储里，要**读到那一档**（或在那个节点里）才会被拉走。这是设计使然，不是丢件。

为此补了三处可用性改进：
1. 面板新增「**收件**」按钮（手动拉一次发给本局节点的信箱），并显示拉了几条；
2. **每次打开面板自动收一次件**（开局探针那次常常还没有节点身份，存档之后才有）；
3. 发件日志把目标写清楚，便于对照“我现在这一局是不是收件人”。

**另外三项按授权者要求改的**：

| # | 变更 | 说明 |
|---|---|---|
| 65 | 换图改成**自动进行** | 原档**落盘确认**后开始倒计时（默认 8 秒，状态行显示剩余秒数），到点自动 `Network.RestartGame()`；倒计时期间按「换图」可立刻重开；自动那次若没生效（代码还活着）10 秒后再试一次，两次都不行就交回手动并提示。 |
| 66 | 存档**原地覆盖** | 本局已有节点 ⇒ 沿用它的 id/父/类型，只更新内容与时间；**写成功后删掉旧文件**（`UI.DeleteSavedGame`，与 ModMiscStore 同一条已验证通道）。于是“一条线只有一个格式化档”，关系树不再被同一条线的一串快照刷屏。换图后的新局第一次存档仍建新节点（分支）。同名（同一分钟同一回合）时跳过删除，避免把刚写的档删掉。 |
| 67 | 面板新增「**删除选中存档**」 | 树里选中 → 确认弹窗 → `UI.DeleteSavedGame`（游戏内就能删，授权者提示的）。 |

### 15.6 跨存档存储为什么“不需要新生成普通存档”也能持久化

这是 `ModMiscStore`（通道 C）的实现方式，不是普通存档：

* 写：`Network.SaveGame{ FileType = SaveFileTypes.GAME_CONFIGURATION, Name = "ModMiscStore~<hex(key)>~<hex(value)>" }`
  —— 写的是一份**配置档（.Civ6Cfg）**，而且**数据就在文件名里**（hex 编码，绕开文件名禁用字符）；
* 读：`UI.QuerySaveGameList(..., SaveFileTypes.GAME_CONFIGURATION, ...)` 列出配置档，把文件名解码回 key/value
  —— **完全不需要加载任何存档**，前后端都可用；
* 因此一条键 = 一个小文件（值上限 120 字节）；改写就是写新文件 + 删旧文件（`UI.DeleteSavedGame`）；
* 2026-10-04 实机验证：写一轮 `ms=1;t=…` → 杀进程 → 下一轮读回**逐字一致**；
* 代价：会在玩家的「载入配置」列表里留下几个名字很奇怪的小档（一个 key 一个），
  所以适合存**少量、短**的协调数据（主线头、待接分支、事件信箱），不适合当大仓库。

### 15.7 大表格怎么跨存档（2026-10-05，授权者：「这种跨存档方式似乎不支持大型表格」）

**确实不支持 —— 病根是文件名长度，不是通道本身。** 配置档名编码通道的文件名是
`ModMiscStore~<hex(key)>~<hex(value)>.Civ6Cfg`，而文件名（一个路径分量）在 Android 上
只有 **255 字节**；hex 会把每个字节变成两个字符。反推：

```
13（前缀） + 1（分隔符） + 9（.Civ6Cfg） + 2*len(key) + 2*len(value) ≤ 240(留余量)
⇒ value 上限 = floor((217 - 2*len(key)) / 2)
   键 8 字节 → 100 字节；键 15 字节 → 93 字节；键 28 字节 → 84 字节
```

旧版把这个上限**写死成 120 字节**，对稍长的键其实已经超了 —— 超长会被底层拒写，
表现就是“存大一点就存不进去”。现在改成**按文件名长度实时算**（`ComputeMaxValueBytes`），
超限时日志直接点名“大块数据请用 SaveBlob”。

**四条可用通道的能力对比**（按“要不要载入”排序）：

| 通道 | 载体 | 单份容量 | 怎么读 | 代价 |
|---|---|---|---|---|
| 配置档名编码（`ModMiscStore`） | 一个键一个小配置档 | **~70–103 字节 / 键** | 列目录解码文件名（**不用载入**） | 键多 → 小文件多 |
| **分片大对象（`SaveBlob`）** | N 个小配置档 | **任意**（N×~80 字节） | 同上（先读元数据再拼片） | 一个 blob 占 N 个小档 |
| CustomData / `Game:SetProperty` | 存档内部 | KB 级（无公开硬上限） | **载入该档之后**读 | 不跨新局；读要载入 |
| **载体存档（`ModMiscCarrier`）** | **一份普通存档** | KB 级（受 CustomData 上限） | **载入那份档**之后 `Read(name)` | 一份完整存档（几 MB） |
| ~~存档元数据注入~~ | — | ❌ 字段全由引擎填 | — | 已排除（通道 D） |
| ~~mod 自己写文件~~ | — | ❌ 安卓 Lua 没有 `io` | — | 已排除 |

选型建议：
* **少量短数据**（主线头、待接分支、事件头）→ 直接 `ModMiscStore.Save`；
* **中等表格（几 KB）** → `ModMiscStore.SaveBlob`（分片；不需要载入就能取）；
* **大表格（几十 KB 以上）且接收方反正要载入那一档** → `ModMiscCarrier.Write`（一份档带走整张表）；
* 两者可组合：分片存“索引/摘要”，整表走载体档。

新增接口（都在 `ExposedMembers.ModMiscToolUI` 下）：

    ModMiscStore.SaveBlob(key, text) / LoadBlob(key) / RemoveBlob(key) / GetBlobInfo(key)
    ModMiscStore.ComputeMaxValueBytes(key)          -- 这个键还能写多少字节
    Carrier.Write(name, text) / Read(name) / Peek() / Clear(name)
    Carrier.BuildCarrierName(name) / ParseCarrierName(rawName)   -- 载体档名 MMTBlob~<name>~<时间>
    （关系树只认 MMT~ 前缀 + 至少 7 段，所以载体档不会被误当成节点）

**事件的大载荷**：`SendEvent` 的 event 里加 `PayloadText` 就走分片（事件记录里只留
`blob` 引用），收件时自动拼回 `event.PayloadText`；投递时连分片一起清掉。

| # | 行为 | 状态 | 备注 |
|---|---|---|---|
| 68 | 分片大对象（`SaveBlob` / `LoadBlob` / `RemoveBlob`） | `[待实机]` | 片 ≤ min(80, `ComputeMaxValueBytes`)；**先写片、最后写元数据**，元数据在 = blob 完整；缺片时 `LoadBlob` **拒绝返回半截数据**并报 `missing-chunks`；改写更小时多余的旧片会被删掉。 |
| 69 | 键感知的长度上限 | `[待实机]` | 由文件名 255 字节反推，超限直接拒绝并提示用 `SaveBlob`（旧版写死 120 字节，长键必超）。 |
| 70 | 载体存档（`ModMiscCarrier`） | `[待实机]` | 写 CustomData + 存一份 `MMTBlob~<name>~<时间>` 普通档；读取要载入那份档。 |
| 71 | 事件大载荷（`PayloadText` → 分片） | `[待实机]` | 收件时自动拼回；投递时清分片（**先读值再删键**，反了的话分片会永久残留 —— 这里踩过一次）。 |
| 72 | `ModMiscStore.Save` 顺手记下“刚写的档” | `[待实机]` | 让同一个会话里马上 `Remove` 这个键也能删掉，不用等下一次扫描。 |
