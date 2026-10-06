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
| 73 | 前端（主界面）建立普通存档 `Network.SaveGame{FileType=GAME_STATE}` | `[已验证失败]` | **实机闪退**（授权者 2026-10-05）。前端没有对局、存档里没有游戏数据；探针 `FrontEnd_GameSaveProbe` 已按结论关回 `false`，想复现再打开（会闪退）。 |
| 74 | **游戏加载完成之前**（`Events.LoadScreenContentReady`，读到一半/建局一半）存档与读档 | `[待实机]` | 探针 `UI/LoadTime_SaveProbe.lua` 默认开；L4（载入期 `Network.SaveGame`）默认开、L5（载入期 `Network.LoadGame`）默认关。判据 `lt-l0-ok` / `lt-l2-written` / `lt-l4-save-*` / `lt-p2-marker-alive` / `lt-p2-probe-save-*` / `lt-p2-cleaned` / `lt-p1-missed`，协议见 §17。 |
| 75 | 载入界面上下文判据（安卓） | `[已静态修正]` | 安卓跑 `LoadScreen_PHONE.xml`，**没有** `PortraitContainer`（桌面版才有）——只看它会让阶段一永不执行。改成 `ContextPtr:GetID() == "LoadScreen"`（三个变体同名），控件只作退路。 |
| 76 | 「游戏加载完成之前」存档 / 读档（`Events.LoadScreenContentReady`） | `[已验证失败]` | **实机仍然闪退**（授权者 2026-10-05）。与游戏自己的注释一致：载入期不该做 Lua→引擎调用。探针已关（`MODMISC_LOAD_TIME_PROBE_ENABLED=false`）。另：载入界面判据在安卓上要认 `ContextPtr:GetID()`（见 75）。 |
| 77 | **通道 E：模组配置组名字**（`Modding.CreateModGroup` / `ModGroups.Name`） | `[实机可用·1MB 跨进程已验证]` | **实机（2026-10-05 第三轮）：1 MB = 1048576 B / 263 片，杀进程重开后读回逐字一致**；分片设 4000 字节/片时单条组名 **8024 字符**被引擎原样接受；此前 64 KB = 110 片、组名 1224 字符也已验证；`复查到=110 重复=0 缺=0 选中已恢复=true`。 **实机：写 29 B、读回 29 B、逐字一致** ⇒ 通道本身可用；`Modding` 组接口对局内 `available=true`。没有改名接口 ⇒ 改值 = 删旧建新。命名 `MMTSTORE~<hex(key)>~<序号>~<hex(片)>`。**坑（我已修）**：`CreateModGroup` 会把新组设为“当前选中”⇒ ① 玩家选择被改 ② 旧片因“正被选中”删不掉 ⇒ 同序号重复 ⇒ 读回报错；修法：写前记住选中、写完全部恢复，删选中组前先切走（照抄原版 `DeleteModGroup()`）。面板：自检 / 写入（尺寸可选到 1 MB、值保留）/ 读取 / 诊断 / 清理。 |
| 80 | 通道 F：`Options.SetUserOption` 存自定义键 | `[已验证失败]` | **实机：`MMTProbe is not a registered option.`** —— 引擎按注册表校验选项名，写不进去（`lSetUserOption` 直接报错）。除非能让引擎“注册”一个新选项，否则此路不通。 |
| 81 | 通道 G：`UserConfiguration.SetValue` 存自定义键 | `[已实机失败]` | 实机：写 4096 B **不报错**，但立刻读回是 `[没有这个键]` ⇒ 值没留下（`GetValue` 对未注册键返回 nil）。与通道 F 同因：引擎只认自己那套键。 |
| 83 | **通用数据协议 `ModMiscDataProtocol`**（生命周期/类型/通道/审计/GC） | `[已落地·桩测试全绿]` | 三条铁律：没登记不许写 / 永久数据必须写 Owner+Version / 用后即焚真的焚。信封 `MMT1|生命周期|版本|时间|类型|长度|负载`，值编码长度前缀（二进制安全），解码严格、绝不返回半截。`SaveTree` = 头记录指向分片。 |
| 84 | **数据登记表 `ModMiscDataRegistry`** | `[已落地]` | 现有 9 条数据集全部登记（`sg_head`/`sg_pending`/`ev_*`/`evb_*`/`blob*`/`carrier*`/`panel`/`probe`/`nameprobe`）。加新数据 = 加一行。 |
| 103 | 切换的执行必须落在**按钮回调**（确认=上膛，再点一次执行） | `[待实机]` | 弹窗回调里调 `RestartGame` 会“返回 true 但不重开”（第 42 条的约束）⇒ 改成两次点击式：第一次确认/上膛，第二次在按钮回调里存档+重开。 |
| 105 | **档名构造上唯一**（秒 + 随机尾巴）—— 因为引擎不接受同名存档 | `[已落地·断言]` | 时间戳 `%Y%m%d-%H%M%S` + 2 位 base36；同一秒连存两次名字也不同；写成功后按节点 id 清掉陈旧档（一条线只留一份）；v1.92 的“同名先删”留作兜底。 |
| 104 | 同名旧档**先删**再写（保证唯一性） | `[待实机]` | 采纳授权者建议；不同名旧档仍是“写成功后再删”。 |
| 102 | 三个实机报错（多返回值陷阱 / 跨上下文暴露未发布 / 弹窗上下文缺失） | `[已修]` | `tonumber((DataProtocol.Load(...)))` 括号截断；`ModTool.lua` 对 `ExposedMembers` 暴露函数做防御式调用；面板新增 `AskConfirm`（无弹窗时退化成“再点一次确认”）。 |
| 101 | **逻辑分支 = 占位记录**（不写真存档） | `[已落地·20 项断言]` | `sg_branch_<id>`（ephemeral/big，6 个短字段）；面板并进关系树并标「（逻辑占位）」；切换确认后**重开前移除占位**，由新局真存档接手；关系挂在占位所依附的线（占位的父）。 |
| 99 | 创建分支**不改本局身份**（`WriteIdentity=false`） | `[已修·断言]` | 上一版复用 SaveNode ⇒ 把分支身份写进本局，导致之后每次存档都被算成分支。现在分支档只写档、不写身份。 |
| 100 | 扫描后逐条列出关系档（id/kind/parent/T/map/L） | `[待实机]` | 用来区分“档没进列表”与“进了没渲染”。 |
| 97 | 文案键唯一性（重复 Tag 会让本地化整条坏掉） | `[已修]` | 新按钮的 `LOC_MODMISC_SAVEPANEL_SWITCH` 撞了旧键 ⇒ 改名 `_SWITCH_SELECTED`；校验里加“EN/CN 同名 Tag 数必须为 0”。 |
| 98 | **时间戳 / 过期时间可选 + 加载时自检** | `[已落地·桩测试全绿]` | 只有声明 TTL（或 `KeepStamp`）的数据集才写时间戳；新增 `DataProtocol.AutoGC`，在对局 `after-load` 与前端加载时各跑一次，只清到期的 ephemeral。 |
| 96 | **新流程：创建分支 / 切换 分开** | `[待实机]` | 「创建分支」= `CreateBranchNode()`（强制 B、父=当前节点，只落档不重开）；「切换到选中」= 弹窗确认 → `PrepareSwitch({TargetNodeId})`（交接单父=选中档）→ 发存档 → `SwitchNow`。自动倒计时已删。 |
| 95 | 保存后列表刷新 + 事件收件入口（19.14 简化时的两处误伤） | `[已修]` | 恢复“回执后扫列表 + OnChecked”（面板保存后立刻刷新）；去掉收件路径上多余的“等小通道扫描”门（收件只走大通道）；新增收件扫描诊断日志。 |
| 93 | 换图：未确认落盘时的**重发**与**显式覆盖** | `[已落地]` | 面板“按一次 = 再试一次”（>5 秒未确认就重发，最多两次）；两次都不行 ⇒ 提示「再点一次仍要切换」并用 `SwitchNow({Force=true})`；`SaveNode` 的等待窗口超时一律自愈，避免死锁。 |
| 94 | 存档落盘诊断（请求档名 / 引擎回显 / 列表前几条） | `[待实机]` | 用于定性“切换写的档为何不在列表里”：引擎改名、换目录、还是压根没写。 |
| 92 | **换图切换的判据 = 存档列表里查得到**（SaveComplete 不算数） | `[实机教训·已修]` | 旧流程错信全局 `SaveComplete` + 盲倒计时 ⇒ “声称留下存档、实际没落盘”。现在 `VerifySaveNow` 是唯一判据、`SwitchNow` 有硬门槛、失败只重发一次并老实报错；顺带删掉盲倒计时/多重试/超时自愈等补丁。 |
| 91 | **关键跨重启数据必须走 big 通道**（small 是排队异步写） | `[实机教训·已修]` | 换图时 `sg_pending` 在 small 上分 3 片，重开前只落盘 1 片 ⇒ 新局读不到交接单 ⇒ **分支识别失败**。修法：交接单与事件信箱 `ev_*` 都改走 big（同步、已验证）；small 溢出时明确警告“关键数据请改用 big”。 |
| 90 | **gameplay 侧存储（DataStore）走协议**：新增 `property` 通道（`Game:SetProperty`） | `[已落地·84 项全绿]` | `ds_*` 通配登记（persave/property/any）；`SetData/GetData` API 不变；探针载荷改成表；审计按登记项通道读，标「随档·UI」/「随档·gameplay」。 |
| 89 | **换图交接（地图间数据传输）走协议**：ephemeral 交接单 + ephemeral 大载荷 + persave 身份 | `[已落地·9 项断言全绿]` | 交接单 `sg_pending`（ephemeral/small，TTL 900s，带 FromMap/ToMap/PayloadKey）；载荷 `xmap_*`（ephemeral/big，读走即删）；身份 `sgnode`（persave）；换图**不新增永久数据**（断言盯住）。`OnMapHandoff` 可注册接收方，已挂 ExposedMembers。 |
| 88 | **存储调用全面迁移到协议**（旧的拼串/散键/回退链已删） | `[已落地·12 套桩测试全绿]` | 主线头/待接分支/事件信箱/事件大载荷/本局身份/资产记录/建局侧城邦数量/UI 数据/探针 全部走 `DataProtocol`；新增 `persave` 生命周期与 `save`(CustomData) 通道；小通道新增**自动溢出**（超单键上限自动分片，逻辑键不变）。 |
| 87 | 协议**保真**（混合表/精度/共享引用/环/元表类）与**检测**（误领/丢包/损坏） | `[已落地·75+58 项全绿]` | 数字用 `%.17g`；共享子表与环用引用还原成同一张表；元表只存类名、解码侧 `RegisterClass` 装回、没登记就明确报告；信封 v2 带**数据集名**（拦误领）与**校验和**（拦静默损坏）；v1 兼容读。 |
| 86 | 协议传输模拟器（devs 仓 `Tests/protocol_transport_sim.lua`） | `[已落地·58 项全绿]` | 本地模拟三条通道（含故障注入、真跨进程），直接跑 mod 真模块；抓出并修掉 GC/Audit 通配与半成品残留两个真 bug。 |
| 85 | 面板「数据协议」一行（登记表 / 审计 / GC / 清永久数据） | `[待实机]` | 审计列出每条盘上有没有、多大、多老、孤儿片；GC 清过期与孤儿；**清永久数据要点两次**。 |
| 82 | **大载荷门面 `ModMiscBigStore`**（优先配置组大通道、回退分片 blob） | `[待实机]` | 事件大载荷（`PayloadText`）已改走它：写优先配置组通道（1 MB 已验证），读**先大通道再回退 blob**（旧数据不用迁移），删两条都清。分片默认 4000 B（`SetChunkBytes` 可调）。 |
| 78 | 通道 F/G：引擎设置类键值存储（`Options.SetUserOption`+`SaveOptions` / `UserConfiguration.SetValue`+`SaveCheckpoint`） | `[待实机·本轮主测]` | 不占存档、不占文件名、**玩家界面看不见**。未知：引擎认不认自己不知道的键、值能多长。面板：**尺寸（64B→1MB）/ 写入（保留）/ 读取 / 自检 / 清理**；「写入（保留）+ 重启后读取」= 跨进程验证。 |
| 78b | 配置组（通道 E）的尺寸上限 | `[下一轮]` | 值落在 SQLite `TEXT` 列，数据库层没有 255 字节限制；但引擎/内存/字符串三关未验。“1G”那个说法要实测才认，且我们的需求是 KB–MB。面板的尺寸阶梯逻辑可复用到配置组那组按钮上。 |
| 79 | 原版「文件存取 / 名字设定」接口盘点 | `[已静态核对]` | 文件侧只有 `Network.SaveGame/LoadGame` + `UI.QuerySaveGameList/DeleteSavedGame/GetSaveGameMetaData/…`，**没有**打开文件读写的接口；运行时数据库只有 `DB.Query/ConfigurationQuery/ConfigurationChanges`，**全只读**。能持久化名字/键值的只有：存档名、模组配置组名、用户选项、UserConfiguration（见 §18.1）。 |

---

## 16. 前端能否建立 / 读取**普通存档**（2026-10-05 实机：**主界面直接闪退，此路不通**）

授权者提的方向：先试别的路子 —— 例如用一份**特别命名的普通存档**当载体，
关键是**能不能在前端（主界面）建立并读取普通存档**。前端没有正在进行的对局，
普通存档里没有游戏数据，**预期很可能失败，但值得一试**。

> **实机结论（2026-10-05，授权者）：主界面一调用就闪退 —— 这条路不可行。**
> 探针已按结论关回 `MODMISC_FRONT_END_GAMESAVE_PROBE_ENABLED = false`（想复现再打开，
> 会闪退）。于是换时机：**在游戏加载完成之前**（刚开始读档 / 创建游戏时）再试一次 ——
> 见下面的 §17。

### 16.1 探针（`UI/FrontEnd_GameSaveProbe.lua`，本轮默认开启）

由 `UI/Replacements/Civ6Common.lua` 那条**已有的**前端刷新回调每帧驱动（不自己再挂回调，
免得顶掉幽灵 hook），认「主界面 / 创建游戏 / 创建场景」三个界面；一次进入界面 = 一轮实验，
日志前缀 `[ModMiscTool][FeGameSaveProbe]`：

| 步骤 | 做什么 | 判定 |
|---|---|---|
| step0 recon | 自述界面 / 各接口可用性 / `GameConfiguration.GetGameState()`（前端应为 PREGAME）/ `UI.IsInFrontEnd()` | — |
| step1 write | 在 CustomData 写个探针标记，然后 `Network.SaveGame{ Type=SINGLE_PLAYER, FileType=GAME_STATE, Name=MMTGameSaveProbe~<时间> }` | `fe-gamesave-written` / `fe-gamesave-write-failed` |
| step2 wait | 等 `Events.SaveComplete`（最多 600 帧 ≈ 10 秒） | `fe-gamesave-no-complete` |
| step3 list | `UI.QuerySaveGameList(普通存档)`：我们的档在不在？**列表里到底能读到哪些字段**（把每条记录的所有字段打出来） | `fe-gamesave-listed` / `fe-gamesave-not-listed` |
| step4 load | 在前端试着 `Network.LoadGame(这份档, SERVER_TYPE_NONE)` —— 本次的核心问题 | `fe-gamesave-load-issued` / `fe-gamesave-load-call-failed` |
| step5 clean | 仍停在前端就删掉探针档（**只认 `MMTGameSaveProbe` 前缀**，绝不碰玩家自己的档）并复查（顺带清历史遗留） | `fe-gamesave-deleted` / `fe-gamesave-delete-failed` |

开关：`UI/Replacements/Civ6Common.lua` 顶部的 `MODMISC_FRONT_END_GAMESAVE_PROBE_ENABLED`
（本轮默认 **true**；测完改 false）。

### 16.2 怎么判读（三种结局都有用）

| 日志表现 | 含义 | 对“大表格载体”的意义 |
|---|---|---|
| `fe-gamesave-write-failed` / `no-complete` + `not-listed` | 前端**写不出**普通存档（预期结局） | 这条路不通，回到分片 blob / 载体存档（要先进对局） |
| `fe-gamesave-listed` 但 `load-issued` 之后没有 `LoadScreen` / 没进对局 | **能建、能列，但读不进去**（空壳档没有游戏数据） | 只能当“文件名的载体”（与配置档同一套限制，没有增益） |
| `fe-gamesave-listed` + 真进了对局（日志出现 `LoadScreen: true` / gameplay scripts loading） | 前端**能建也能读**普通存档 | 打开一条新路：可以在前端准备一份“数据档”，进对局后靠 CustomData 取回（容量按 CustomData 上限） |
| step3 打出的字段列表 | 不用载入能读到什么（`LeaderType` / `TurnCount` / `Type` / `FileType` … 都是引擎填的） | 若里面没有 mod 可控字段，就印证通道 D 的结论（元数据不可注入） |

### 16.3 已知风险

* 前端写普通存档可能**产出退化档**（没有游戏数据），留在玩家的「载入游戏」列表里会很难看 ——
  所以探针**成功后立刻删掉**，并只删自己的前缀；
* 前端 `Network.LoadGame` 万一真的开始加载，可能停在半路（黑屏/卡住）—— 探针把调用包在 pcall 里、
  调用前后各打一行日志，出事时能定位到具体哪一步（tombstone 里看 backtrace）；
* 这份探针与配置档探针（`FrontEnd_SaveProbe.lua`，默认关）是**两个独立实验**，只开一个更干净。

---

## 17. 「游戏加载完成之前」能不能存档 / 读档（2026-10-05 实机：**仍然闪退，此路不通**）

第 16 节那条路（前端主界面建普通存档）实机**闪退**。按授权者的方向换时机：
**刚开始读档 / 创建游戏、游戏还没加载完的时候**做存档读档操作，看会发生什么。

> **实机结论（2026-10-05，授权者）：仍然闪退 —— 这条路不行。**
> 与游戏自己那句注释完全吻合：`LoadScreen.lua` 里写着
> `-- Do not set input handler until content loading is done; otherwise engine will make
> LUA calls to engine during load (not recommended).`
> 探针已按结论关闭（`MODMISC_LOAD_TIME_PROBE_ENABLED = false`）；沿用它的诊断价值：
> 证实“**载入期做引擎调用 = 闪退**”，与前端主界面那次是同一类问题。
> 于是回到“能不能不依赖存档/文件”的思路上 —— 见第 18 节。

### 17.1 这个时机在哪（静态核对，都来自游戏自带文件）

| 事实 | 出处 |
|---|---|
| 载入界面会 `include( "Civ6Common" )` —— 本 mod 替换的就是这个文件，所以探针在载入界面里一定会被执行 | `Base/Assets/UI/FrontEnd/LoadScreen.lua:10`（`_PHONE` / `_TABLET` 同） |
| 引擎事件 `Events.LoadScreenContentReady` 的语义是「玩家信息可以填了」＝**游戏数据已就绪、游戏视图还没就绪** | `LoadScreen.lua:461` 注释 `-- Ready to show player info`；紧随其后才是 `Events.LoadGameViewStateDone`（`-- Ready to start game`） |
| 三个界面变体（`LoadScreen.xml` / `_PHONE.xml` / `_TABLET.xml`）根节点**都是** `<Context Name="LoadScreen">` | 三个 XML 第 3 行 |
| 游戏自己**刻意**避免在载入期做 Lua→引擎调用 | `LoadScreen.lua`：`-- Do not set input handler until content loading is done; otherwise engine will make LUA calls to engine during load (not recommended).` → **这是本次实验最大的风险来源，也是它值得测的原因** |
| 存档调用字段照抄游戏：`Name` / `Location` / `Type` / `FileType` | `Menus/SaveGameMenu.lua:53-64`；快速存档另用 `Network.GetGameConfigurationSaveType()` 当 `Type`（`InGameTopOptionsMenu_PHONE.lua:176-184`） |

**踩过的坑（静态核对抓到的，没上机就修掉了）**：一开始用
`Controls.PortraitContainer ~= nil` 当“我在载入界面”的判据 —— 那是**桌面版** `LoadScreen.xml`
的控件；安卓跑的是 `LoadScreen_PHONE.xml`，里面**没有** `PortraitContainer`（只有 `Portrait`），
于是判据在手机上恒为 `false`、阶段一永远不会跑。现在改成先认
`ContextPtr:GetID() == "LoadScreen"`（三个变体同名），控件只作拿不到 ID 时的退路。

### 17.2 探针做什么（`UI/LoadTime_SaveProbe.lua`，本轮默认开启）

`UI/Replacements/Civ6Common.lua` 里那条 include **不做前后端过滤**（载入界面与对局内都要跑到它），
`ModMiscLoadTimeSaveProbeLoaded` 做 include 幂等。日志前缀 `[ModMiscTool][LoadTimeProbe]`。

阶段一（`Events.LoadScreenContentReady`，**只有载入界面那个 context 会跑**）：

| 步骤 | 做什么 | 判定 |
|---|---|---|
| L0 recon | 自述 context 名 / `GameConfiguration.GetGameState()` / `UI.IsInFrontEnd()` / `Network.GetLocalPlayerID()` / `Game.GetCurrentGameTurn()` / 各接口可用性；`UI.GetSaveGameMetaData()`（**正在加载的那份档**的元数据，载入期能不能读） | `lt-l0-ok` |
| L1 read | `ReadCustomData` 现在读到什么（载入进行到这一步，存档快照还原了没有） | `lt-l1-customdata` |
| L2 write | 写一个加载期标记（进对局后看它活没活下来） | `lt-l2-written` |
| L3 list | `UI.QuerySaveGameList`（载入期能不能列存档列表） | — |
| L4 save | `Network.SaveGame` 一份普通存档 `MMTLoadProbe~load~<时间>` —— **本轮的核心问题** | `lt-l4-save-ok` / `lt-l4-save-failed` |
| L5 load | `Network.LoadGame`（载入期再发起一次读档，最容易把加载器搞乱） | **默认关**；`LOADTIME_LOAD_STEP_ENABLED` |

阶段二（进对局后的 `Events.LoadGameViewStateDone`）：

| 做法 | 判定 |
|---|---|
| 标记还在 ⇒ 加载期写的 CustomData 活下来了 | `lt-p2-marker-alive` / `lt-p2-marker-gone` |
| 查列表：探针档在不在（字段全打出来） | `lt-p2-probe-save-listed` / `lt-p2-probe-save-missing` |
| 删掉探针档（**只认 `MMTLoadProbe` 前缀**，绝不碰玩家自己的档） | `lt-p2-cleaned` |
| 从头到尾没看到加载期痕迹（阶段一没跑 / 标记没活下来 / **上一轮崩在半路**） | `lt-p1-missed` ＋ 顺手清掉遗留的探针档（只清理模式，不误报“没写成”） |

开关：`UI/LoadTime_SaveProbe.lua` 顶部 `LOADTIME_SAVE_STEP_ENABLED`（L4，默认 true）、
`LOADTIME_LOAD_STEP_ENABLED`（L5，默认 false）；总开关在 `Civ6Common.lua` 的
`MODMISC_LOAD_TIME_PROBE_ENABLED`。

**为什么两处都要 include**：载入界面那份负责阶段一；对局内那份（`Support_UI` 等也 include
`Civ6Common`）负责阶段二核对与清理。对局里 include 过 `Civ6Common` 的 context 有一堆、
都会收到 `LoadGameViewStateDone`，所以阶段二用 CustomData 写**一次性守卫**，只让第一个干活。

### 17.3 怎么判读（四种结局都有用）

| 日志表现 | 含义 | 下一步 |
|---|---|---|
| 连 `lt-l0-ok` 都没有（日志里完全没有 `[LoadTimeProbe]`） | 载入界面没跑到探针（include 时机/事件名不对） | 看 `lt-p1-missed` 与 `LoadScreen` 相关日志，改挂载点 |
| `lt-l0-ok` 之后**闪退** | 载入期做引擎调用会崩（与游戏自己那句“not recommended”一致） | 这条路不可行；把 `LOADTIME_SAVE_STEP_ENABLED` 关掉，只保留 L0/L1 侦察 |
| `lt-l4-save-failed` / `lt-l4-save-ok` 但 `lt-p2-probe-save-missing` | 调用能返回、但档写不出来（载入期的存档是空壳/被拒） | 与前端那次（闪退）相比仍是进步：**能不能写**有了明确边界 |
| `lt-l4-save-ok` + `lt-p2-probe-save-listed`（字段齐全） | **载入期能写出可用的普通存档** | 打开一条新路：换图前先落一份盘，不依赖“必须回到对局内才能存” |
| `lt-p2-marker-alive` | 载入期写的 CustomData 能活到对局里 | 说明载入窗口里 CustomData 已经是“这一局”的，可当跨存档通道用 |

已知风险：
* 载入期存档可能产出**退化档**（游戏数据只还原了一半）—— 探针进对局后**立刻删掉**，
  并且下次进对局时会用“只清理模式”清掉历史遗留；
* 万一崩在载入期，探针档会留在「载入游戏」列表里 —— 名字带 `MMTLoadProbe` 前缀，手动删也认得出来；
* L5（载入期再读档）默认关：它最可能把加载器搞乱，真要试先单独开、
  并且先确认 L4 的表现（`LOADTIME_LOAD_STEP_ENABLED = true`）。

---

## 18. 跨存档通道重新盘点：原版的「文件存取 / 名字设定」还有哪些能用（2026-10-05）

授权者方向：**重新检查原版里涉及文件存取以及名字设定的地方**；并提到
“有人提及 modgroupname 可以用作数据存储”。本轮把原版 Lua 里这两类接口全部拉出来对了一遍。

### 18.1 原版盘点（全部来自游戏自带文件，不是推断）

**A. 文件存取类**（都围着“存档文件”转，走不了别的路）：

| 接口 | 用途 | 备注 |
|---|---|---|
| `Network.SaveGame(saveFile)` | 写存档 / 配置档 | 字段 `Name` / `Location` / `Type` / `FileType`（`Menus/SaveGameMenu.lua:53`） |
| `Network.LoadGame(entry, serverType)` | 读档 | 对局内可用（已实机） |
| `UI.QuerySaveGameList(loc, type, opts, fileType, filter)` | 列存档（异步 → `LuaEvents.FileListQueryResults`） | **不用载入就能读元数据**（通道 A 的基础） |
| `UI.DeleteSavedGame` / `UI.GetSaveGameMetaData` / `UI.MakeSaveGameMetaData` / `UI.GetLastSaveName` / `UI.GetSaveLocationPath` / `UI.GetSaveGameModificationTimeRaw` / `UI.IsAtMaxSaveCount` | 删档 / 元数据 / 路径 / 时间 / 上限 | 仅此而已，**没有**“打开文件读写”的接口 |
| ~~`io.*`~~ | — | 安卓 Lua 无 `io`（已排除） |
| ~~运行时写数据库~~ | — | 原版 Lua 只有 `DB.Query` / `DB.ConfigurationQuery` / `DB.ConfigurationChanges` / `DB.MakeHash`，**全是只读** |

**B. 名字/键值设定类**（引擎自己会持久化、且与存档无关 —— 这才是能当通道的部分）：

| 位置 | 写 | 读 | 持久化到 | 玩家可见性 |
|---|---|---|---|---|
| **模组配置组名字** `ModGroups.Name` | `Modding.CreateModGroup(name, sourceGroup)` | `Modding.GetModGroups()` | 模组框架数据库（模组界面那份） | **看得见**（模组界面下拉框里多出条目） |
| **用户选项** | `Options.SetUserOption(cat, name, value)` + `Options.SaveOptions()` | `Options.GetUserOption(cat, name)` | 用户选项文件 | 看不见（只要分类/键不在选项界面上） |
| **UserConfiguration** | `UserConfiguration.SetValue(name, value)` + `UserConfiguration.SaveCheckpoint()` | `UserConfiguration.GetValue(name)` | 同上那套用户配置 | 看不见 |
| ~~存档元数据注入~~ | — | — | — | 已排除（字段全由引擎填，通道 D） |
| ~~`SystemSettings` 表（模组库里）~~ | 无 Lua 接口 | — | — | 已排除（`Modding.sql` 里没有任何存储过程碰它） |

数据库层证据（`Base/Assets/Database/Modding.sql`）：

```sql
CREATE TABLE ModGroups(
    'ModGroupRowId' INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    'Name'          TEXT NOT NULL,        -- 注释原文：the user-provided name of the group
    'CanDelete'     BOOLEAN DEFAULT 1,
    'Selected'      BOOLEAN DEFAULT 0,
    'SortIndex'     INTEGER DEFAULT 100);
INSERT INTO ModGroups VALUES (1, 'LOC_MODS_GROUP_DEFAULT_NAME', 0, 1, 0);  -- 默认组不可删
-- 组相关存储过程只有：ListModGroups / GetModGroupDetails / GetSelectedModGroup /
-- ChangeSelectedModGroup / CreateModGroup / CopyModGroup / DeleteModGroup
-- ⇒ **没有** UPDATE ModGroups SET Name 这类“改名”过程
```

`Modding` 组接口**对局内也能用**：原版 `Menus/InGameTopOptionsMenu.lua:480`、
`Choosers/ResearchChooser.lua:511` 都在对局里调 `Modding.GetActiveMods()`。

### 18.2 通道 E：模组配置组的名字（`UI/ModMiscModGroupStore.lua`，本轮新增）

**为什么值得试**：`Name` 是自由文本（TEXT），**不受**“存档名 = 一个文件名分量 ≤ 255 字节”
那条限制 —— 而那条正是把通道 A（`ModMiscStore`）卡在 ~100 字节/键的元凶。

存法（定长片段，按序号拼回）：

```
MMTSTORE~<hex(key)>~<3 位序号>~<hex(值分片)>        -- 一片一个配置组
```

* 写：先删同 key 的旧片，再按序 `Modding.CreateModGroup(名字, 当前组)`；
* 读：`Modding.GetModGroups()` 一次拿全，按 key+序号拼回并解码；
* 改值：没有改名接口 ⇒ **删旧建新**；
* 清：只删 `MMTSTORE~` 前缀的组。

**安全规矩（写进代码注释了）**：
1. 只碰自己前缀的组，别的组一律不动；
2. **永不删除当前选中的组**（哪怕名字碰巧带我们的前缀）—— 宁可漏删，
   也不能把玩家正在用的配置组删掉；
3. 建组时以“当前组”为模板 ⇒ 即使它被选中，启用集合也与原来一致（不会把 mod 关掉）；
4. 所有引擎调用 `pcall` 包住，失败只记日志。

**注意（UX 代价）**：每个数据片都会出现在模组界面的「配置组」下拉框里。
测试用的按钮旁边写了“测完请点清理”。

### 18.3 通道 F/G：引擎设置类的键值存储（`UI/ModMiscNameStoreProbe.lua`，本轮新增探针）

| 通道 | 写 | 读 | 原版先例 |
|---|---|---|---|
| F `useroption` | `Options.SetUserOption("ModMiscTool", "MMTProbe", 值)` + `Options.SaveOptions()` | `Options.GetUserOption(...)` | `FrontEnd/Multiplayer/Lobby.lua:1386` 记 `SeenPlayByCloudLobby` |
| G `userconfig` | `UserConfiguration.SetValue("MMTProbe", 值)` + `UserConfiguration.SaveCheckpoint()` | `UserConfiguration.GetValue(...)` | `Options_*.lua` 灌选项、`SetValue("LANPlayerName", option)` 存字符串 |

**实机结论（2026-10-05）：两条都不可用 —— 引擎只认它自己注册过的键。**

| 通道 | 实机表现 | 判定 |
|---|---|---|
| F `useroption` | 写入直接报错：`MMTProbe is not a registered option.`（栈里是 `lSetUserOption`） | **排除**：选项名有注册表校验 |
| G `userconfig` | 写 4096 B 不报错，但立刻读回 `[没有这个键]`（0 B） | **排除**：值没留下（未注册键 `GetValue` 返回 nil） |

也就是说“玩家看不见”这一点它们确实做到了（连引擎都看不见 🙂），代价就是**存不进自己的东西**。
除非能让引擎把我们的键**注册**成选项（那要走配置数据库加选项定义，且会出现在选项界面上），
否则这两条通道到此为止 —— 结论已入库（能力表 80/81），面板上的按钮留着以便随时复现。

**原本想验证的**：引擎认不认“它不认识的键”、值能多长、会不会被当成数字/布尔解释。

探针保留（用于复现结论），用法：

* **尺寸可选**：面板上「尺寸」按钮（自绘选项列表）= 64 B / 256 B / 1 KB / 4 KB / 16 KB /
  64 KB / 256 KB / **1 MB**，默认 4 KB；
* **写入（保留）**：按选中尺寸给两个通道各写一份**长度恰好等于所选尺寸**的载荷
  （`mmt=1;t=<os.time()>;tag=<通道>;n=<尺寸>;BBBB…`），写进去**不清** ——
  这样就能“写完 → 杀进程重开 → 点读取”，看 `t=` 还是不是这一轮那个数字；
* **自检阶梯**：8 B→64 B→256 B→1 KB→4 KB→16 KB 逐级写-读-比对，跑完自动清理
  （自检适合找“能被截断的尺寸”，保留式写入适合查“能不能跨进程”）。

关于“**modgroupname 可以到 1G**”这个说法：通道 E 的值落在 SQLite 的 `TEXT` 列里，
数据库层确实没有 255 字节那种文件名限制，但**引擎/内存/字符串处理这三关都还没验**，
而且 1 GB 的数据既不可能塞进 Lua 字符串实际使用、也不是我们的需求（我们要的是 KB–MB 级表格）。
**先按能验证的来**：本轮先测看不见的两条通道，配置组的尺寸上限下一轮用同一套尺寸阶梯去摸
（面板上配置组那一组按钮已经就位，把「尺寸」逻辑复用到它上面即可）。

### 18.4 面板怎么测（Automation 测试面板 · 常规页签）

| 按钮 | 做什么 | 看什么 |
|---|---|---|
| **配置组·尺寸** | 自绘列表：64 B / 256 B / 1 KB / 4 KB / 16 KB / 64 KB / 256 KB / 1 MB（默认 4 KB） | 当前尺寸显示在按钮上 |
| **配置组写入** | 按所选尺寸写一份**长度 = 所选尺寸**的数据并**保留**；写完立刻读回比对 | `写入 nB / m 片，读回 nB 一致=true/false`；再带上 `longestName` / `repeats` / `currentIsOurs` |
| **配置组读取** | 读回该 key | **杀进程重开后再点**：`t=` 还是上一轮那个 ⇒ 跨进程成立 |
| **配置组自检** | 8 B→64 B→256 B→1 KB→4 KB→16 KB 阶梯写-读-比对，跑完自动清理 | 每行 `ok/chunks/read/match`；第一个 `match=false` 就是上限 |
| **配置组诊断** | 组数 / 我们的条数 / 最长名字长度 / 重复片 / 当前选中的组（是否我们的） | 名字被截断看 `longestName`；`repeats>0` 说明有脏数据（点清理） |
| **配置组清理** | 删掉全部 `MMTSTORE~` 组；选中的先切走再删，删完把选中恢复成正常组 | `删除 n 条，失败 m 条` + `选中组恢复=true/false` |
| 设置存储 自检 / 读取 / 写入 / 清理 | 复现通道 F/G 的失败结论 | `useroption` 报 “not a registered option”；`userconfig` 读回 `[没有这个键]` |

**修完上面两个 bug 之后，请这样复测配置组通道**（这是目前唯一还没被证否的跨存档通道）：

0. **先点一次「配置组清理」**：上一轮写崩留下的脏数据（重复片、以及被抢走的选中组）
   需要清掉；这一步同时验证“选中的先切走再删”是否生效（看 `选中组恢复=true`）；
1. 尺寸先用 **4 KB** → 点「配置组写入」：看 `写入 4096B / 7 片，读回 4096B 一致=true`，
   并看 `longestName`（名字没被截断的话应该在 1200 字符上下）、`repeats=0`、`currentIsOurs=false`；
2. **杀掉游戏进程**（真杀，不是退回主菜单）→ 重开 → 打开面板 → 点「配置组读取」：
   读回的 `t=` 与第 1 步一致 ⇒ **跨进程持久化成立**（这条通道就定了）；
3. 逐步加大尺寸（16 KB → 64 KB → 256 KB → 1 MB），每级重复“写入 → 重启 → 读取”；
   哪一级开始 `一致=false` 或读回变短，上限就在那里（`longestName` 一起看）；
4. 顺带确认玩家自己的配置组没被动：诊断里 `currentIsOurs=false`，
   模组界面的配置组下拉框里除了 `MMTSTORE~…` 那些数据组之外，别的组都还在；
5. **测完点「配置组清理」**（数据片会一直留在模组界面的下拉框里，直到清掉）。

### 18.5 判定表

| 日志/面板表现 | 含义 | 下一步 |
|---|---|---|
| 配置组自检全绿到 16KB | 通道 E 可用，单键可达 16KB+ | 把大表格搬到这里，替代“分片上百分片小档”的方案 |
| 某个尺寸 `match=false` 且 `read` 比写的短 | **引擎截断了名字** | 把该尺寸的一半当分片大小；上限就按这个数 |
| 建组抛错 / `available=false` | 该上下文不允许改组（或接口不在） | 换上下文（前端 vs 对局内）再试 |
| 设置存储自检 `match=true` | 引擎认我们的键 | 优先用它（玩家看不见），继续摸尺寸上限 |
| 设置存储读回 `[没有这个键]` | 引擎只持久化它认识的键 | 该通道排除，回到配置组通道 |
| 设置存储写入后**重启仍读到** | 通道成立（且玩家看不见） | 优先用它做跨存档存储，尺寸按实测上限留一半余量 |
| 设置存储写入成功但重启后没了 | 只在内存里活着（`SaveOptions` 没把它写进文件） | 该通道只能当“同一次运行内”的缓存，排除 |
| 读回长度比写入短 | 值被截断（文件/字段长度限制） | 把该尺寸的一半当分片大小 |
| 调大尺寸后**选项界面异常/游戏变慢** | 值太大把用户选项文件撑坏了 | 立刻「设置存储清理」；上限按更小的尺寸定 |
| 面板「诊断」里 `ours` 一直涨 | 有片没被覆盖掉（key 变了/写入中断） | 点「清理」收摊，再查 key 是否稳定 |

### 18.6 本轮实机结果与修复（2026-10-05）

**授权的两条“看不见的通道”都失败**（见 18.3 表：`useroption` 被引擎按注册表拒收、
`userconfig` 写进去留不住）。**modgroupname 这条是通的** —— 面板「配置组写入」实测：
写 29 B、读回 29 B、逐字一致（日志 `Mod-group store write: panel = panel=1;t=…;r=823225`）。

但第一次自检**从第二级开始全灭**，原因是我这边两个 bug（不是通道的问题）：

| # | 现象（日志） | 真因 | 修法 |
|---|---|---|---|
| 1 | `跳过：这个组正被选中，不能删 -> MMTSTORE~…` / `选中组未被改动=false` / `currentGroup=3 name=MMTSTORE~…` | **`Modding.CreateModGroup` 会把新建的组设为“当前选中的组”**（原版界面看不出来，因为玩家建完会自己选回去）。于是：玩家的配置组选择被悄悄改掉；下一次写同 key 时旧片“正被选中”删不掉 ⇒ 同 key 同序号两份 ⇒ `复查到=2` 而 `片=1` ⇒ 读回 nil / `缺第 2 片` | 写前记住原选中组，写完全部**恢复**；删“当前选中的组”之前先照抄原版 `FrontEnd/Mods.lua` 的 `DeleteModGroup()`：**把选中切到别的组再删**。收尾统一走 `SettleSelection()`（原组没了/原组本身就是数据组 ⇒ 落到一个正常组，绝不把玩家选择留在数据组上） |
| 2 | `8B -> ok=true chunks=1 read=7 match=true`（看起来像“8 字节只读回 7”） | 自检载荷是 `<8></e>`，**只有 7 字节**，标称尺寸和实际字节数不一致 ⇒ 日志容易误读成失败 | 载荷改成**长度精确等于标称尺寸**（`BuildProbePayload`），日志同时打 `PayloadBytes`；面板「配置组写入」也改成“按所选尺寸写”，并回报 `longestName/repeats/currentIsOurs` |

顺带把防御补上：`Load` 遇到同 key 同序号会**明确报“重复片”**（以前会说“缺第 N 片”，误导排查方向）；
`Save` 的复查从“数量够就算过”改成**按名字逐个核对 + 数重复**；诊断里新增 `重复片数` 与
`当前选中的是不是我们的组`。

回归用例（桩环境模拟了引擎那两条真实行为：建组即选中、选中组删不掉）：
`mg_harness` 第 11–17 组 —— 抢走选中后能恢复、覆盖写不留残片、清理能把选中的数据组也清掉、
重复片被明确拒绝、自检载荷字节数精确、64 KB（110 片）逐字往返。

**下一步（等实机复测）**：按 18.4 的步骤 0–5 走一遍，把尺寸上限摸出来
（面板尺寸可选 64 B→1 MB）。关于“**1 G**”那个说法：`ModGroups.Name` 在 SQLite 里是 `TEXT`，
数据库层没有 255 字节那种限制，但**引擎传参/Lua 字符串/内存三关都还没验**，
而且 1 GB 既不现实也不是需求 —— 先测到 MB 级、够用就收。

### 18.6b 插曲：一次“静态检查没抓到”的实机崩溃（2026-10-05）

复测时点开面板直接崩：

```
Runtime Error: .../UI/AutomationTestPanel.lua:1655: function expected instead of nil
    in function 'OpenAutomationTestPanel'
```

**真因**：我在 `OpenAutomationTestPanel()` 开头加了 `ApplyModGroupChunkBytes()`（把面板选的
分片大小同步给存储模块），但这个函数（连同它那一组：`MODGROUP_CHUNK_STEPS` /
`m_ModGroupChunkBytes` / `BuildModGroupChunkEntries` / `GetSelectedModGroupChunkEntry`）
**只在我那次补丁脚本里“打印了 ✓”，实际没写进文件** —— 脚本先做完全部替换最后才写盘，
中途一条断言失败就整体退出，于是“成功”的两条也丢了。我随后看到的
`fwdcheck2` “无前向引用疑点”也救不了：它当时只检查“local 声明得比使用晚”，
**不检查“这个名字压根没有声明”**。

**两条整改**：

1. **工具补强**：`fwdcheck2.py` 增加**未定义标识符**检查 —— 被当函数调用、或被当值引用
   （项目助手命名风格）的裸名字，如果本文件没声明、也不在「本项目 + 游戏自带 UI」
   的名字索引里（缓存 6 小时，`--reindex` 重建），就点名。反向验证过：
   故意写 `NotAFunctionAnywhere(1)` 会被报出来；全项目现在 0 误报。
   顺带修掉一个正则退格误报（`SetStatus` 被截成 `SetStatu` 报出来）。
2. **工具落地到仓库外**：`devtools/`（工作区根目录，不参与打包）存检查器 + 全部桩测试 +
   README，免得临时目录被清掉就没法复跑。

**教训（给以后的自己）**：改完一批文件**必须**独立跑一次解析/检查再报“完成”；
补丁脚本要“先断言全部匹配、再统一写盘”，并且写完立刻验证文件里真的有那些名字。

### 18.7 第二轮实机：通道 E 通了（2026-10-05）

修完 §18.6 那两个 bug 之后复测，日志给出的是**明确的好消息**：

| 证据（日志原文） | 含义 |
|---|---|
| `Save key=panel 字节=65536 片=110 复查到=110 重复=0 缺=0 选中已恢复=true` | 64 KB 写成功；**没有重复片**；**玩家选中的配置组已被恢复**（上一轮的坑修好了） |
| `RemoveByKey 恢复选中组 handle=1 结果=true` / `Save 恢复选中组 handle=1 结果=true` | “先切走再删 / 写完恢复”两次都生效 |
| `写入 65536B / 110 片，读回 65536B 一致=true`；`longestName=1224 chars repeats=0 currentIsOurs=false` | 写读逐字一致；**单条组名 1224 字符被引擎原样接受**（没被截断）；诊断字段也对 |
| 本次会话**读到了上一轮会话写的** `t=1791182450`（该 `t` 在本日志里没有任何写入记录），110 片、65536 B 全部还原 | **跨进程持久化成立** —— 这是通道 E 最关键的一条 |

结论：**通道 E（模组配置组名字）可以当跨存档存储用**，而且它是目前唯一“前后端都能读写、
不受存档名 255 字节限制、且跨进程成立”的通道。

**下一问：上限到底在哪。** 已知 1224 字符 OK；再往上没人量过。为此本轮加了两个工具：

* **「名字上限」**：拿一个组逐级加长名字（载荷 1 KB→2 KB→4 KB→…→64 KB，hex 后名字 ≈ 2×载荷），
  每级读回比对：读回名字变短 ⇒ 引擎截断，那一级就是界限；跑完自动清理并核对选中组未变；
* **「分片」**：每片原始字节数 300 / 600 / 1200 / 2000 / 4000（默认 600 ⇒ 名字 ≈1224 字符）。
  名字越长片越少 —— 片太多不只是慢：**每条片都是一条配置组，还会把启用项复制一份**，
  1 MB 用 600 B/片 = 1748 条组，模组界面和数据库都会很难受。所以大数据的正路是**加大分片**，
  不是加片数。

**怎么测（下一轮）**：①「名字上限」→ 看 `名字上限：最大可用名字 N 字符（载荷 M 字节）`；
② 把「分片」调到那个上限的一半左右；③ 尺寸选 256 KB / 1 MB，走一遍“写入 → 重启 → 读取”。

**关于“1 G”**：`ModGroups.Name` 在 SQLite 里是 `TEXT`，数据库层没有 255 字节那种限制，
但**引擎的 Lua↔DB 传参**这一关现在只验证到 1224 字符；`Name` 之外还有 `SortIndex`/行数等
实际约束。等「名字上限」把真实数字量出来，再谈能不能往 GB 级走 —— 不过按我们的需求
（存档关系树、事件、表格），**KB–MB 级够用**，先把这条通道在 MB 级上跑稳。

### 18.8 第三轮实机：1 MB 也通了，大载荷改造上线（2026-10-05）

授权者实测「尺寸 1 MB + 分片 4000 字节」并重启后读取，日志：

```
Mod-group store read: panel = panel=1;t=1791194411;r=725350;MMMM…(共 1048576B)
    | chunks=263 bytes=1048576 | [1] panel #1 nameLen=8024 | [2] panel #2 nameLen=8024 …
```

* **1048576 B（1 MB）分 263 片读回，字节数与内容一致**；
* 每片原始 4000 字节 ⇒ 组名 **8024 字符**（8000 hex + 前缀），**引擎原样接受、没有截断**；
* 这份 1 MB 数据是**上一轮会话写的**（本日志里没有对应的写入行）⇒ **1 MB 级跨进程持久化成立**。

至此通道 E 的能力有了三段实测数据：**64 KB（110 片 / 1224 字符名字）→ 1 MB（263 片 / 8024 字符名字）**，
都跨进程一致。关于“1 G”那个说法：数据库层是 SQLite `TEXT`（没有 255 字节那种限制），
引擎这关现在验证到 8024 字符的组名；**但 1 GB 不是我们的需求** —— 存档关系树、事件、
表格都在 KB–MB 级，先把这条通道在 MB 级用稳比追 GB 有意义。面板的「分片」现在可选
300 / 600 / 1200 / 2000 / **4000（推荐大载荷）** / 8000 / 16000，想继续摸上限随时可以试。

**代价与建议（重要）**：每片 = 模组界面配置组下拉框里的一条 + 一份启用项副本。
1 MB 就是 **263 条**，界面会很长、模组数据库也会变大。所以：

* 大载荷分片用 **4000 字节**（默认），别用 300/600 去存大表；
* 数据量控制在**几百 KB 以内**，超过就考虑“载体存档”（`ModMiscCarrier`，随档走、界面干净）；
* 面板的「配置组清理」随时能把数据片收干净（只认 `MMTSTORE~` 前缀，绝不动玩家自己的组）。

**大载荷门面（本轮新增 `UI/ModMiscBigStore.lua`）**：事件的大载荷（`event.PayloadText`）
已经从“分片 blob”改成走这个门面：

    ModMiscBigStore.Save(key, text)   -- 优先配置组大通道；不可用/失败自动回退 ModMiscStore.SaveBlob
    ModMiscBigStore.Load(key)         -- 先大通道，读不到再回退 blob（**旧事件不用迁移**）
    ModMiscBigStore.Remove(key)       -- 两条通道都清
    ModMiscBigStore.SetChunkBytes(n)  -- 分片大小（默认 4000）
    ModMiscBigStore.GetInfo()         -- 大通道在不在、分片大小、现有数据片数

这样“事件带大表格”这条链路终于不受 ~100 字节/键的限制了；`SendEvent` / `FetchEventsForNode` /
`DropEventKeys` 三处已经切过去（发件日志会写 `通道 modgroup（片数）` 或 `通道 blob`）。

---

## 19. 通用数据存储协议（2026-10-05，授权者要求：有规可循）

授权者要求：建立通用序列化-反序列化协议，按**生命周期**（永久 / 进程内 / 用后即焚）、
**类型**（字符串 / 数字 / 表格）把数据存储定规矩；大型多层数据可以用**头记录指向下属分片**；
并且**用永久数据要慎重**。落地在 `UI/ModMiscDataProtocol.lua` + `UI/ModMiscDataRegistry.lua`。

### 19.1 三条铁律

| # | 规矩 | 怎么保证 |
|---|---|---|
| ① | **没登记不许写** | `DataProtocol.Save` 先查登记表，查不到直接拒（日志点名），杜绝“偷偷写盘” |
| ② | **永久数据必须显式** | `permanent` 必须写 `Owner` + `Version`，面板能审计/列出/清理；写入一律打日志（谁、多大、哪条通道） |
| ③ | **用后即焚的要真的焚** | `ephemeral` 带 TTL，`GC` 清；需要“读到就删”的标 `AutoDeleteOnLoad` |

### 19.2 生命周期 × 通道（按“读的代价/容量”选，别乱用）

| 生命周期 | 含义 | 允许的通道 |
|---|---|---|
| `permanent` | 跨存档、跨进程长期存在（关系树头指针等）。**慎重**：写下去就一直留在玩家机器上，直到 Purge | small / big / carrier |
| `session` | 只在本次运行的内存里，**不落盘**、重启即无（缓存、UI 状态、本局临时表） | memory（固定） |
| `ephemeral` | 落盘但用后即焚：带 TTL，GC 会清；可配“读到就删” | small / big / carrier |

| 通道 | 载体 | 容量/代价 | 什么时候用 |
|---|---|---|---|
| `memory` | Lua 表 | 无持久化 | session 专用 |
| `small` | 存档名编码（`ModMiscStore`） | ~100 B/键，**不用载入就能读** | 头指针、小索引、几十字节标记 |
| `big` | 配置组大通道（`ModMiscBigStore`） | **实测 1 MB 跨进程一致**；代价是数据片会出现在模组界面 | 事件载荷、表格 |
| `carrier` | 载体存档 | 随档走、界面干净，但**要载入那份档** | 超大表、需要跟档搬走的数据 |

### 19.3 序列化格式（自描述信封、二进制安全）

```
信封：  MMT1|<生命周期>|<版本>|<写入时间>|<类型>|<负载长度>|<负载>
值编码（长度前缀，字符串里出现什么都不怕）：
  n              nil
  b0 / b1        布尔
  d<数字>;       数字（负数/小数/科学计数都行）
  s<长度>:<字节>  字符串（UTF-8 或二进制原样）
  t<个数>:{ <键><值>… }   表格（键值成对递归；个数用于校验完整性）
```

解码是**严格递归下降**：长度不符 / 个数不符 / 尾部多余 → 明确报错，**绝不返回半截数据**
（dp_harness 专门用 6 组坏数据盯这条）。带 `版本` ⇒ 结构升级时给 `Migrate` 钩子即可平滑迁移。

### 19.4 大型多层数据：头记录指向下属分片

```
DataProtocol.SaveTree(name, root, { PartBytes = 32768 })
  ├─ 负载切成 N 片 → <name>$p1 … <name>$pN（走该数据集的通道）
  └─ 头记录 <name>$h = { Kind="tree", V, Bytes, Parts={ {Key,Bytes}… }, Stamp, Owner }
     （头很小：小通道放得下就走小通道 —— 不用载入就能拿到索引；否则走大通道）
DataProtocol.LoadTree(name)
  └─ 先读头 → 按头取片 → **逐片校验字节数** → 拼回 → 解码；缺片明确报“缺第 N 片”
```

### 19.5 审计 / GC / 慎重清理（面板「数据协议」一行）

| 按钮 | 作用 |
|---|---|
| **登记表** | 列出所有已登记数据集：生命周期、通道、owner、版本、TTL、是否“读到就删” |
| **审计** | 每条现在盘上有没有、多大、什么时候写的、多老；**大通道里有多少数据片**；**没人认领的孤儿** |
| **GC** | 清过期 ephemeral 项 + 清孤儿片（没时间戳的按“过期”处理，宁可不留来历不明的垃圾） |
| **清永久数据** | **点两次**（5 秒内）才执行 —— 永久数据是长期留在玩家机器上的东西，必须确认 |

### 19.6 现有数据全部登记（`UI/ModMiscDataRegistry.lua`，共 9 条）

| 数据集 | 生命周期 | 通道 | 备注 |
|---|---|---|---|
| `sg_head` | permanent | small | 主线头指针；`Owner=存档关系树`、v1、上限 96 B |
| `sg_pending` | ephemeral | small | 换图待接分支；TTL 900 s |
| `ev_*` | ephemeral | small | 事件信箱条目；TTL 7 天 |
| `evb_*` | ephemeral | big | 事件大载荷；**故意不设“读到就删”**（取件与投递是两步，读到就删会把载荷弄丢），靠 TTL + 投递时显式删 |
| `blob*` / `carrier*` | permanent | small / carrier | 通用分片大对象、载体档数据 |
| `panel` / `probe` / `nameprobe` | ephemeral | big | 测试面板的数据；TTL 1 小时 |

事件大载荷这条链路**已经走协议**（`SendEvent` / `FetchEventsForNode` / `DropEventKeys` 里
优先用 `DataProtocol`，没加载时退回 `ModMiscBigStore`/分片 blob），所以它现在也受审计与 GC 管。
其余旧调用点（关系树头指针等）**先登记、逐步迁移**：每次动到哪块功能，就把哪块换成协议调用。

### 19.7 桩测试（`devtools/dp_harness.lua`，16 组 50 项，全绿）

类型往返（含嵌套表/中文/负数小数）｜6 组坏数据严格报错｜没登记不许写｜small 读写删｜
类型不符拦截｜版本迁移钩子｜用后即焚与 keep 例外｜session 不落盘｜SaveTree/LoadTree 与
“缺第 N 片”｜审计的字节数/时间/年龄｜GC 只清过期不动永久｜孤儿检测与清理｜
Purge 单个 / PurgeAllPermanent（含通配条目）｜登记表校验（缺 Owner、永久用 memory 都拒）｜
事件载荷不设自动删除的语义。

**过程中抓到的两个真 bug**（都是协议自己的，不是测试写错）：
1. 表格个数解析忘了跳过 `t<个数>:` 里的冒号 ⇒ **所有表格都解不出来**（第 1 组当场抓到）；
2. `PurgeAllPermanent` 对通配条目只删了登记表里那个字面名（`blob*`），真数据没动 ⇒
   改成按前缀枚举现有键再删（第 14 组抓到）。
另外把模块内部对全局 `DataProtocol` 的引用改成局部表 `M`（同一进程里被 `dofile` 两次时，
方法会挂在旧实例上、登记表对不上号 —— 桩环境抓到）。

### 19.8 协议传输模拟器（devs 仓，2026-10-05）

本地模拟器 `devs/BasilissaModMiscTools/Tests/protocol_transport_sim.lua`（8 场景 / 48 项断言全绿）
把三条通道换成可注入故障的模拟实现，**直接加载 mod 仓里的真模块**，于是协议逻辑能在 Termux 里反复快跑：
容量阶梯（64 B→1 MB）、small 文件名上限、`SaveTree/LoadTree` 头指向分片、进程重启 + TTL + GC、
故障注入（组名截断 / 中间丢片 / 通道不可用 / 载体未载入 / 小档写爆）、审计与慎重清理、上限阶梯、
以及**真·跨进程**（把模拟磁盘序列化后另起一个 `lua5.1` 进程读回）。

它第一轮就抓到本模块两个真 bug（已修）：

| 现象 | 真因 | 修法 |
|---|---|---|
| TT L 过期了 `GC` 却报“清了 0 项” | `GC`/`Audit` 盯着登记表里的**字面名** `evb_*`，真实键是 `evb_xxx` ⇒ 通配数据集的 TTL 永远不生效、审计也看不到它们 | 新增 `EnumerateKeys(spec)`：按前缀去两条通道枚举**真实键**；GC 逐键判过期，Audit 逐键列出（面板审计现在能看到每一条事件载荷） |
| 大通道写失败回退后，配置组里留下写了一半的片 | 回退前没清半成品 | `ModMiscBigStore.Save` 回退前先 `Remove(key)` 清掉半成品 |

同时固化成断言的一条性质：**协议信封能挡住被截断的数据** —— 组名被引擎截断时，
`ParseEnvelope` 的负载长度校验会让读取**失败**，而不是返回半截或错内容。

另：模拟器报表确认 `PartBytes > 4000` 没有额外收益 —— 大通道自身按 4000 B 切片，
所以“每片 16 KB”跟“每片 4 KB”产生的配置组条数一样（都是受 4000 B 切片约束）。

### 19.9 保真与检测（2026-10-05，授权者定的重点）

授权者明确：**这不是网络传输、不需要高性能**，重点是**能不能原样还原**（尤其是 Lua 混合表格；
元表太难可以不做），以及**误领 / 丢包这类情况能被检测出来**。据此把协议改了一轮：

#### 19.9.1 还原（保真）

| 情况 | 结论 | 做法 |
|---|---|---|
| **混合表**：空洞数组 `[1][2][4]`、`[0]`、负数键、浮点键 `[1.5]`、布尔键、字符串键并存 | ✅ 逐键还原 | 编码按 `t<个数>:{键 值 …}` 递归，键也走同一套编码（长度前缀，不会有歧义） |
| **二进制字符串**（含 `\0`） | ✅ 原样 | 字符串一律 `s<长度>:<字节>`，不做转义 |
| **数字精度**：`0.1+0.2`、`1/3`、`2^53+1`、`1e-17`、`π` | ✅ 按位还原 | **`string.format("%.17g")`**；`tostring()` 是 `%.14g`，会写成 `0.3` —— 那是“假还原” |
| `±inf` / `NaN` | ✅ 还原 | 单独标记 `dinf;` / `d-inf;` / `dnan;` |
| **共享子表**（同一张表出现两次） | ✅ 还原成**同一张表** | 用引用：第一次出现写 `t…`，之后再出现写 `r<编号>;` |
| **自引用 / 环** | ✅ 解得开，不死循环 | 同上；解码时**先登记再填** |
| 函数 / userdata / thread 当键或值 | ✅ **明确报错**（不静默丢字段） | 编码遇到不支持类型直接失败并点名 |
| **元表**（`__index` 之类） | ⚠️ **只保存类名，行为由解码侧装回** | 表带 `__mmtclass = "名字"` 时编码成 `t<个数>:[名字]{…}`；`DataProtocol.RegisterClass("名字", {OnDecode=fn})` 在解码侧装回行为。**没登记的类：字段照还原，但会明确报告“类丢了”**（`GetLastDecodeReport().DroppedClasses`），绝不假装还原成功 |

#### 19.9.2 检测（误领 / 丢包 / 损坏）

信封升级到 **v2**（v1 仍可读）：

```
MMT2|生命周期|版本|写入时间|类型|<名字长度>:<数据集名>|<校验和>|<负载长度>|<负载>
```

| 情况 | 检测方式 | 报出来的话 |
|---|---|---|
| **误领**：读到的是别人家的数据（键被搬错、串了） | 信封里写着这份数据属于谁；与请求的键比对（通配数据集按前缀判定） | `误领：这份数据属于 fid_small，不是 fid_other` |
| **丢包（分片缺一片）** | 头记录里每片的字节数逐片校验 | `缺第 1 片（…$p1）：没有这个 blob` |
| **截断** | 负载长度校验 + 每片字节数 | `负载长度不符（头写 N，实到 M）` |
| **静默损坏**（长度对得上、内容被改了） | FNV-1a 32 位**校验和** | `校验和不符（数据损坏或丢包）` |
| **元表类丢了** | 解码报告 | `警告：… 里的表带元表类 'Pair'，但解码侧没登记 ⇒ 只还原了字段，行为没装回去` |
| 老格式（v1，无名字/校验和） | 仍按长度校验读回，确认兼容 | — |

#### 19.9.3 测试

* 桩测试 `devtools/dp_harness.lua`：**22 组 / 75 项**（新增混合表、数字精度、共享引用与环、
  不支持类型报错、元表类登记与丢失报告、校验和/误领/丢包/v1 兼容）；
* devs 仓协议传输模拟器：**9 个场景 / 58 项**，其中场景 9「保真与检测」全程走模拟通道
  （含跨重启后逐键比对）；
* 过程中协议自己又抓到两个 bug：`ctx.classes[className]` 在类名为 nil 时 `table index is nil`；
  `m_Classes` 声明在 `DecodeValue` 之后 ⇒ Lua 5.1 里被解析成全局 nil（`fwdcheck2` 的前向引用检查当场点名）。

**性能不在目标里**：本轮没有做任何性能优化或性能测试；模拟器跑一轮的时间只当“本机耗时”记录，
不作为指标。

### 19.10 调用迁移：所有存储一律走协议（2026-10-05，授权者要求）

授权者：**把现在的调用迁移到协议上，无需兼容旧有方法**。于是把散落的存储调用全部收进
`DataProtocol`，把旧的拼串格式、散键、兼容分支与回退路径**删掉**（不留旧数据迁移代码）。

#### 迁移对照

| 原来 | 现在 | 说明 |
|---|---|---|
| `ModMiscStore.Save("sg_head", id)` | `DataProtocol.Save("sg_head", id)` | 登记项 permanent/small |
| `sg_pending` 拼串 `parent\|kind\|stamp\|epoch\|logical` + `SplitFields` 解析（历史上踩过 3 段/4 段解析 bug） | **表** `{Parent, Kind, Stamp, WrittenAt, Logical}` | 登记项 ephemeral/small，TTL 900 s；解析交给协议 |
| 事件信箱 `ev_*` 拼串 `Type\|Detail\|Amount\|…`（9 段） | **表** `{Type, Detail, Amount, AcceptTurn, FromNode, FromPlayerID, FromCiv, Stamp, PayloadKey}` | 协议负责编解码；`FetchEventsForNode` 用 `ListMatching(前缀)` 取键 |
| 事件大载荷（曾走分片 blob + 多级回退） | `DataProtocol.Save(evb_*, text)` | ephemeral/big；回退链（BigStore/blob/协议）**已删** |
| CustomData 五个散键 `NodeId/ParentId/Kind/Stamp/Offset/Logical` | **一个表** `sgnode`（persave 通道） | 新增 `persave` 生命周期 + `save`（CustomData）通道 |
| `WriteCustomDataValue/ReadCustomDataValue`、`MODMISC_CD_PREFIX`、`SplitFields`（用于存储） | **删除** | 这些名字在 SaveGraph 里已不再存在 |
| 资产放置记录拼串 `fn\|arg;fn\|arg…` + “tonumber 成功就当数字”的猜法 | **表** `ModMiscAssetPlacements = {V, Records[{fn, args}]}`（persave） | 数字按原类型还原，不再改型 |
| 建局侧的 `WriteCustomData(Ghost…)` | `DataProtocol.Save("ghost_citystates"/"ghost_majorplayers")`（persave） | 前端/建局上下文也 include 了协议（Civ6Common 里） |
| Support_UI 的 `ui_*`（UI 存给 gameplay 读）与跨存档探针 | `ui_*` / `svprobe`（persave） | 探针现在验证的是“随档通道” |
| 诊断探针 `ModMiscStore.Save("selftest"/"ingame")` | `DataProtocol.Save("probe_*")` | 登记项 ephemeral/small |

#### 迁移中发现并修掉的两个真问题

1. **小通道单键上限装不下协议信封**：`ev_*` 的信箱条目信封 ≈200 字节，而文件名 255 字节
   那条限制只给单键 ~90 字节（`blob_harness` 的 300 KB 事件用例当场报“发件=false”）✗。
   修法：协议的小通道适配层做**自动溢出** —— 放得下就一个档，放不下就交给
   `ModMiscStore.SaveBlob` 分片，**逻辑键不变**（读/删/枚举都归一化 `$<n>`/`$m`）。
   于是小通道变成“容量近似无限、不用载入就能读、且完全不出现在模组界面”的通道
   —— 信箱这类瞬时元数据继续留在它上面，不必挤到大通道去。
2. **生命周期校验漏了新增的 `persave`**：登记 `sgnode` 时报“生命周期非法”；
   同时把协议里所有通道调用都加了“通道没加载”的守卫（桩测试里 `ModMiscStore = nil` 的场景不再炸）。

#### 校验

* 12 套桩测试全绿（`sg_harness`/`sg2_harness`/`ev_harness` 现在都先装协议再跑；
  `blob_harness` 的场景 6 改成“300 KB 载荷走协议 + 投递后残留检查”，实测残留 0）；
* devs 仓模拟器新增**场景 10（随档通道）**：读档还在、**新局不继承**、审计能列出；
  共 **10 场景 / 62 项全绿**；
* `fwdcheck2`（前向引用 + 未定义标识符）与 `luac -p` 全项目通过。

### 19.11 换图（地图间数据传输）全部走协议：用后即焚 + 随档落地（2026-10-05）

授权者：把切换地图机制里的地图间数据传输全部改成新方法；**综合使用本地存储与用后即焚，
避免不必要的永久数据**。

#### 交接的三层生命周期（各就各位，谁都不多留一秒）

| 数据 | 生命周期 / 通道 | 为什么 |
|---|---|---|
| **交接单**（`sg_pending`） | **ephemeral / small**（TTL 900 秒） | 只在“存完原档 → 新局开局”这一小段里活着；新局开局读走即删。放 small 通道：不用载入就能读，且不出现在模组界面 |
| **交接载荷**（`xmap_*`，要带过去的数据） | **ephemeral / big**（TTL 900 秒） | 可能几十 KB～MB；放配置组大通道（实测 1 MB）。同样是“读走即删”（`TakeMapHandoffPayload` 内部先读后删） |
| **本局身份**（`sgnode`） | **persave / save(CustomData)** | 新局开局把交接单里的关系固化进**这一局的档**（父节点/类型/地图/逻辑回合偏移）—— 从此不再依赖“存储此刻读不读得到” |
| 主线头（`sg_head`） | permanent / small | 关系树入口，正常存档时才写；**换图这一步不碰它** |

字段上交接单带上 `FromMap / ToMap / Engine / PayloadKey`，所以新局日志能直接说清
“从哪张图换到哪张图、带了什么”。

#### 换了什么（都在 `ModMiscSaveGraph` 里）

    API.PrepareSwitch({ FromMap=, ToMap=, Engine=, Payload=<任意表> })
    API.SetMapHandoffPayload(payload) / API.TakeMapHandoffPayload()   -- 取走即删
    API.OnMapHandoff(fn)          -- 注册接收方（新局开局回调，载荷原样交付）
    （三者都挂到 ExposedMembers.ModMiscToolUI，别的 mod 也能用）

新局开局的消费顺序（`ReportAfterLoad` 里）：
① 交接单里的关系 → 写进 `sgnode`（persave）；② 载荷读走并交付给所有处理器，随后删键；
③ 交接单本身删掉。日志一行说清“parent/kind/地图/载荷交给几个处理器”。

#### 测试（`devtools/sg_harness.lua` 第 14 节，9 项全绿）

跨“进程重开”走完整条链路（把模拟磁盘与配置组状态带到新 env，等于实机的换图后启动）：
* 交接单写了、带地图信息与载荷键 ✓
* **没有新增任何 permanent 落地项** ✓（对比换图前后的永久项集合）
* 载荷在 `xmap_*`（ephemeral/big）里 ✓
* 新局身份随档落地：`parent=a1 kind=B Continents.lua→Pangaea.lua` ✓、偏移 17 ✓
* 载荷交付给处理器且逐字段一致 ✓
* 交接单与载荷**都用后即焚**（两边都清零）✓

顺带把建局侧的 `cg_marker`（创建新局/换图前打的时间戳标记）也迁到协议（persave 表），
它是“这局是不是全新的”判据，语义上正好属于随档数据。

### 19.12 gameplay 侧存储（DataStore）也迁到协议：新增 `property` 通道（2026-10-05）

授权者：`DataStore` 这个 Lua 文件与文档也要更新。于是把**gameplay 侧**的随档存储也纳入同一套协议。

#### 新增通道：`property`（gameplay 专用）

| 通道 | 引擎 API | 谁能用 | 语义 |
|---|---|---|---|
| `save` | `WriteCustomData` / `ReadCustomData` | 前端 / 对局内 **UI** | 随档（写进 game parameters，**写后要存档才落盘**） |
| `property` | `Game:SetProperty` / `Game:GetProperty` | **gameplay 脚本** | 随档（游戏状态的一部分，存档即带走、读档自动还原） |

两者**互不可见**（同名的键在两边读不到对方），协议里靠 `persave` 登记项显式声明在哪一侧：
`Channel = "save"`（UI）或 `"property"`（gameplay），不写默认 `save`。
审计（面板「数据协议 → 审计」）会分别标成「随档·UI(CustomData)」/「随档·gameplay(Game:SetProperty)」，
并按各自的通道去读 —— 这一条正是本轮抓到的 bug：审计原来写死读 `save` 通道，gameplay 那一侧永远显示为空。

#### `ModTool_DataStore.lua` 的变化

* 不再自己拼键拼串、不再直接 `Game:SetProperty`：一律 `DataProtocol.Save/Load/Remove`；
* 键：`ds_<key>`（登记项 **`ds_*` 通配**，因为 `SetData(key, value)` 是**通用公开 API**，
  不可能要求每个 key 都来登记）；类型标 `any`（数字/字符串/表都行，协议负责编解码）；
* 值类型从“拼串 + 猜”变成协议原类型：数字按 `%.17g` 精确还原，表支持嵌套与共享引用；
* 探针（开局读一次、读不到才写）：载荷从 `ds=1;t=…;turn=…` 拼串改成表
  `{At, Nonce, Turn}`；那条“UI 的键 gameplay 读不到”的边界检查改成读 UI 探针的新键 `svprobe`
  （仍然预期 nil）；
* 文件头注释重写成“只看这一页就够”的规则：键/生命周期/通道/值类型/能力边界（随档、不跨档、
  与 UI 互不可见）；
* gameplay 侧 `include("ModMiscDataProtocol")` / `include("ModMiscDataRegistry")`（VFS 按文件名解析，
  和现有 `include("ModMiscStore")` 一个写法）；时钟用守卫（gameplay 不保证有 `os`）。

#### 测试（`devtools/dp_harness.lua` 第 23 节）

`property` 通道可用 ✓｜原始键确实写进 `Game:SetProperty` ✓｜表结构读回一致 ✓｜
数字保真（`0.1+0.2`）✓｜删除 = 写 nil ✓｜审计能列出 property 条目并标明“gameplay”侧 ✓；
另有一组**两个存储互不可见**的断言：UI 键不在 property 里、gameplay 键不在 CustomData 里、
各自读各自的值 ✓。桩测试总数 **84 项**，全绿。

#### 相关文档

* `API_Documentation.txt` 的 §3.12「跨存档 / 随档数据」一节已按同样口径改写
  （`SetData/GetData` 的语义、`ds_*` 通配登记、以及“两个存储互不可见”）。

### 19.13 实机事故：换图后**分支识别失败** —— 小通道的“排队写出”赶不上重开（2026-10-06）

授权者实测：换图后分支认不出自己。日志把原因钉死了。

#### 现象链

```
换图[1/2]：交接单已写入（parent=tmgj0moz，新局算分支，起点逻辑回合=1，无载荷）
[Store] 已请求写入 [sg_pending$0] = [MMT2|ephemeral|1|…]      ← 195 字节 > 单键上限 ⇒ 分 3 片 + 元数据
[Store] SaveBlob [sg_pending]：195 字节 → 3 片（每片 ≤ 80 字节）结果=true
…
[Store] LoadBlob [sg_pending]：读回 195 字节（3 片）           ← 同一会话内读得到（读的是内存表）
换图[2/2]：调用已返回 result=true                              ← 重开
—— 新会话 ——
[Store] 扫描完成：存储档 **3 份** → 去重后 **3 个键**           ← 应有 6 份（4 个分片 + 原有的两份）
[Store] LoadBlob [sg_pending]：没有元数据（这个 blob 不存在 / 没写完整）
判定：current=nil incoming=nil head=tmgj0moz pending=nil ⇒ parent=nil kind=M   ← 认成了主线根节点
```

#### 真因

`small` 通道的每个键 = 一个**小配置档**，由 `Network.SaveGame` **排队异步**写出
（`ModMiscStore.Save` 只是“请求写入”，内存表立刻更新、磁盘稍后）。而换图这条链路是
「写交接单 → 存原档 → 重开」，中间只隔几秒 —— **实测 4 个分片里只有 1 个赶在重开前落盘**，
于是新局扫描只看到 3 个档、`sg_pending` 的元数据不在 ⇒ 交接单读不出来 ⇒ 分支认不出自己。

同一会话里读得到，是因为 `GetAll/Get` 读的是**内存表**，掩盖了“还没落盘”这件事。

#### 修法

**关键跨重启数据不许挂在会被分片的小通道上**：

| 数据 | 通道（改后） | 为什么 |
|---|---|---|
| 交接单 `sg_pending` | **big**（模组数据库，同步调用，1 MB 跨进程已验证） | 换图链路必须“写完立刻重开也能读到” |
| 事件信箱 `ev_*` | **big** | 收件人可能正好在重开/读档窗口里，同一类风险（条目 ~200 字节，必然分片） |
| 小数据（`sg_head`、`probe_*`…） | small（不变） | 一个档一个键、写完不马上重开，足够可靠 |

另外给 `small` 的溢出路径加了**明确警告**：一旦退化成分片写，日志会写清
“每个分片是一个排队写出的配置档，紧接着重开/读档可能来不及落盘 —— 关键数据请改用 big 通道”，
不再沉默退化。

#### 教训（写进选型规则）

* 选通道不能只看“容量够不够”，还要看**写入何时真正落盘**：small = 排队异步（省界面、能免载入读），
  big = 同步（数据片会出现在模组界面）。**跨重启/跨进程立刻要读的数据，一律 big**；
* 桩测试里“写→读”永远是同步成功的，**测不出这类时间窗问题** —— 这条只能靠实机日志；
* 日志里 `扫描完成：存储档 N 份 → 去重后 M 个键` 是判断“有没有真的落盘”的最好一眼：
  换图前后对比这个数字，缺了就说明有文件没赶上。

#### 回填的回归断言（`devtools/dp_harness.lua` 第 24 节）

`sg_pending` 必须走 big ✓；`ev_*` 必须走 big ✓；两者仍是 ephemeral + TTL（用后即焚）✓。
桩测试共 **88 项**，全绿。

### 19.14 实机事故二：自动换图“声称留下存档、实际没有” —— 错信 SaveComplete（2026-10-06）

授权者：自动切换时声称留下了存档，实际没有存档出现；并且提醒**此前多次失败导致代码不断加水加面**。
这次先找根因，再把多余的补丁删掉。

#### 真因

`Events.SaveComplete` 是**所有存档共用**的事件（回调参数只有一个数字，认不出是哪一份）。
换图前刚好写了交接单 —— 而交接单现在走 `big` 通道没问题，但**小通道**那一侧（`ModMiscStore`
写的配置档、以及任何其它存档）都会触发同一个事件。旧流程于是：

```
SaveComplete 一到 ⇒ 认为“原档写好” ⇒ 起一个 8 秒（或 +7 秒兜底）的盲倒计时 ⇒ 到点重开
```

而同一时刻真正的游戏存档可能还没落盘（引擎写档是异步的） ⇒ **重开把还没写完的档带走了** ⇒
“面板说存好了、存档列表里却没有”。旧代码其实**已经查过列表**（日志里那句
`落盘复查：节点 … 没在列表里（可能还没写完）`），但那个结果只被用来打日志，
**没有参与“能不能切换”的判断** ✗。

#### 修法与简化（删掉加水加面的部分）

| 旧 | 新 |
|---|---|
| `SaveComplete` 当作“存好了”，据此起倒计时 | **只记日志**，并写明“这个事件认不出是哪份存档” |
| `OnSaved`（SaveComplete）+7 秒兜底倒计时 | 删除 |
| 盲倒计时 + 重试次数上限 + 重试间隔等一堆常量 | 删到只剩一个 `SWITCH_AUTO_DELAY`（确认**之后**才开始的倒计时） |
| “落盘复查”只打日志 | **成为唯一判据**：`API.VerifySaveNow` 查到才算确认（`m_SaveState.Verified`） |
| 切换随时可以点 | `SwitchNow` **硬门槛**：未确认落盘一律拒绝（日志写明节点/第几次/等了多久） |
| 失败后无限重试/自愈 | 面板每 ~2 秒查一次；40 秒未确认**重发一次**；再 40 秒仍无 ⇒ 标记失败、老实报错、不切 |

状态文案也跟着说人话：`正在确认原档落盘… <档名>（N 秒）` → `原档已确认落盘 —— 稍后自动切换` →
`两次都没能确认原档落盘 —— 本次没有切换`。

#### 回归断言（`devtools/sg_harness.lua` 第 5 节）

* 派发一次 `SaveComplete`、但存档列表里没有该档 ⇒ **拒绝切换**（重开次数保持 0）✓
* 列表里查到该档 ⇒ 状态变 `Verified`，此时切换成功（重开 1 次）✓

这组断言正是这次事故的最小复现：**事件说“完成了”不算数，文件真的在列表里才算数。**

#### 教训

* 引擎的“完成事件”往往是**全局**的（认不出是哪一笔），凡是“完成后要做不可逆动作”的地方，
  都要用**可验证的事实**（列表/文件/回读）当判据，而不是事件本身；
* 之前几轮为了绕过“点了不跳转/分支认不出自己”，加了不少**猜测式兜底**（盲倒计时、多次重试、
  超时自愈）。它们让症状消失了、把病因留下来了 —— **这轮的做法是反过来：先把判据换成可验证的，
  再把兜底删掉。**

### 19.15 实机反馈三：第一次写了档却切不了，之后再按连档都不写了（2026-10-06）

授权者：第一次按切换键**有存档**、但**无法切换**；这之后再按切换键**就不存档了**；
而且切换写出来的档在 UI 列表里看不到 —— 用「储存」键存的档却能正常刷出来。

#### 三个问题各自的原因与修法

| 现象 | 原因 | 修法 |
|---|---|---|
| 第一次有档但**切不了** | 19.14 加的硬门槛：`SwitchNow` 要求“列表里确认到这份档”才放行。档写了但没在列表里查到 ⇒ 一律拒绝 | 保留门槛（这是对的），但补上**玩家显式覆盖**：连续两次都没确认时，面板提示「再点一次仍要切换」，第二次点击用 `SwitchNow({ Force = true })` 照切（日志写明“原档未确认落盘”） |
| 之后再按**连档都不写了** | 死锁：面板看到 `HasPendingSwitch()` 为真 ⇒ 走“第二步”分支 ⇒ 发现未确认 ⇒ 只提示“等待中”就 return，**不会重新发存档**；`SaveNode` 那边又被“上一笔还在等回执”拦着 | ① 面板改成“**按一次 = 再试一次**”：未确认且距上次 >5 秒 ⇒ `RetrySave()` 重发（最多两次），并显示“正在重发原档（第 N 次）”；② `SaveNode` 的等待窗口收紧为固定超时，超时**一律自愈放行**（不再把人永久拦在门外） |
| 切换写的档**UI 里看不到**，储存键的能看到 | 两条路径其实是同一段代码（都是 `BuildNextNode → SaveNode → Network.SaveGame`），差别只在换图前多写了一次交接单。**未定位** ⇒ 本轮把判定与诊断都改硬：验证**按档名比对**（不再依赖把档名解析成 id），并把「请求的档名 / 引擎回显的最近存档名 / 列表条数与前几条」全部打进日志 | 见下：日志现在能一眼看出“引擎有没有改名/换目录/压根没写” |

#### 本轮新增的诊断（下次实机日志就能定性）

```
即将调用 Network.SaveGame（switch） name=MMT~…~L001（parent=0 kind=M turn=1）
  saveFile: Name=MMT~…~L001 Location=0 Type=1 FileType=0 Directory=0
  Network.SaveGame 已受理；引擎回显 GetLastSaveName=…   ← 与请求不同会标「引擎改名？」
落盘确认：找 MMT~…~L001；列表 3 条（前几条：… / …）；最近一次存档名(引擎)=…
```

* 若“引擎回显”与请求名一致、列表里却没有 ⇒ 文件没落盘（引擎/存储层问题）；
* 若回显被改名 ⇒ 我们按档名比对会失败，但日志会直接标出来；
* 若列表里出现了但名字不同 ⇒ 也能一眼看到（前几条会打出来）。

#### 回归断言（`devtools/sg_harness.lua` 第 5 节，共 15 项）

未确认时可以重发存档（存档次数 +1）✓；重发后仍未确认 ⇒ 切换依然被拒 ✓；
`MarkSaveFailed` 之后 ⇒ 显式覆盖可以切换 ✓。

### 19.16 实机反馈四：事件收不到 + 保存后列表不刷新（2026-10-06）

授权者：事件接受没有成功；另外确认现在点保存也不会在 UI 上及时刷新。

#### 两个都是我自己在 19.14 那轮改出来的（“简化”时误删/误加）

| 现象 | 真因 | 修法 |
|---|---|---|
| **点保存后列表不刷新** | 19.14 把 `SaveComplete` 处理里“回执后扫一次列表 + 回调 `OnChecked`”整段换成了“只记日志” ⇒ 面板 `DoSave` 的 `OnChecked` 永远不来、`RefreshAll()` 永不执行 | 恢复那一段：回执到了照常 `API.Refresh` 并回调 `OnChecked`（语义写清：`found=true` 只代表“列表里有这个 id”，不代表回执就是这份档的） |
| **事件收不到** | 19.10 把信箱搬到 `big` 通道之后，`IntakeEvents` 仍然先过 `WhenStoreReady`（等**小通道扫描**就绪）⇒ 扫描慢/不回包时收件被一起卡住；而收件其实只走大通道，根本不需要那次扫描 | 去掉这道多余的门；`FetchEventsForNode` 增加扫描诊断：打印“找什么前缀、命中几个键、键名列表”，一眼看出是大通道没有信箱还是读失败 |

#### 教训（第三次同一类问题）

“简化”和“修复”一样要有**回归网**：这两处（保存后刷新、收件入口）都不在桩测试覆盖里，
删掉/改掉之后没有任何东西会红。所以这轮除了修，还把收件路径的诊断补齐 ——
下次日志里应当能看到：

```
收件扫描：节点 <id> 找前缀 ev_<id>_，命中 N 个键（…）
收件完成：节点 <id> 入列 N 条（本局逻辑回合 …，偏移 +…）
```

若“命中 0 个键”，就是大通道里确实没有发给它的信箱（发送端没写成功或目标节点 id 不对）；
若“命中 N 个键但入列 0 条”，则是 `TurnEvents.AddIncoming`（gameplay 侧）没收下。

### 19.17 逻辑重做：创建分支 与 切换 分开（授权者 2026-10-06 的新流程）

授权者：把逻辑改成 —— **创建分支**与**切换**分开：点「创建分支」生成一个**逻辑分支档**；
在列表里选中某个逻辑档后点「切换」→ **先保存当前存档** → **弹窗确认** → 确认后重开游戏。

#### 新流程

```
① 创建分支（按钮「创建分支」）
     API.CreateBranchNode()
       └─ 强制 Kind=B，父 = 本局当前节点（没有则主线头），存一份档 + 记关系
          **不重开、不切换** —— 玩家随时能在列表里看到这条分支线

② 切换（按钮「切换到选中」，需先在列表里选一条）
     弹窗「切换到 <档名>？会先保存当前存档，然后重开游戏到新地图」
       └─ 玩家点确认
            ├─ API.PrepareSwitch({ TargetNodeId = 选中的档 })
            │    ├─ 交接单：父 = **选中的逻辑档**，逻辑回合/偏移以它为准
            │    └─ 发一笔存档（保存当前档）
            └─ API.SwitchNow("确认弹窗之后") → Network.RestartGame()
                 （未确认落盘时先用 Force 走一次：玩家已经在弹窗里确认过）
```

#### 与旧流程的差别（顺手把“加水加面”的删掉）

| 旧 | 新 |
|---|---|
| 点一次「换图」= 存原档；再点一次 = 重开；中间还有盲倒计时自动切 | 「创建分支」只落档；「切换」走弹窗确认 —— **切换这个不可逆动作永远由玩家点确认** |
| 分支关系在“切换”时才建立，父是**本局当前节点** | 分支关系在「创建分支」时就建立；切换的目标是**玩家选中的那条逻辑档**，父/逻辑回合都以它为准 |
| 自动倒计时（`SWITCH_AUTO_DELAY`） | 删除（确认弹窗取代它） |

#### 测试（`devtools/sg_harness.lua` 第 5/14 节，共 18 项）

创建分支只落档、不重开 ✓；分支档确实是 `B` 且父指向当前节点 ✓；
切换时交接单的父 = **选中的逻辑档** ✓；载荷/身份/偏移/用后即焚等原有断言全部保持 ✓。

### 19.18 实机反馈五：本地化丢失 + 创建分支不显示 + 协议改进（2026-10-06）

#### ① 本地化丢失 —— 撞键（重复 Tag）

我给新按钮起的键 `LOC_MODMISC_SAVEPANEL_SWITCH` **和已有的旧键同名**（旧的是 “Switch map (auto)”）
⇒ 文案表里出现重复 Tag，本地化整条出问题（按钮显示成键名）。已改名为
`LOC_MODMISC_SAVEPANEL_SWITCH_SELECTED`（EN/CN + 面板 XML 一起改）。
**并把“文案键唯一性”加进校验**：`Text.xml` / `Text_CN.xml` 里同名 Tag 数量必须为 0。

#### ② 创建分支后面板不显示

「创建分支」写完档后只做了一次立即刷新，而**写档是异步落盘的** ⇒ 那一次扫描扫不到新档；
而 SaveComplete 之后 SaveGraph 还会再扫一次并回调 `OnChecked` —— 但 `DoCreateBranch` 没接这个回调 ✗。
修法：接上 `OnChecked = RefreshAll`，并在创建后再按帧补刷一次（90 帧 ≈ 3 秒），等档真的到了列表里再画。

#### ③ 协议改进：时间戳/过期时间可选 + 加载时自检

* **时间戳改成可选项**（`NeedsStamp`）：只有“声明了 TTL”或 `KeepStamp = true` 的数据集才写时间戳；
  永久/随档/进程内的写空字段，读出来是 `nil` —— 省字节，也让“谁需要过期判据”一目了然。
  GC 仍然只对**声明过 TTL 的 ephemeral** 生效；TTL 数据集若没时间戳（写坏了）才当过期清掉。
* **加载时自检**：新增 `DataProtocol.AutoGC(reason)` —— 各上下文在“游戏加载完成/进局”的探针里调一次：
  `ModMiscSaveGraph.ReportAfterLoad`（对局内 `after-load`）与 `Civ6Common`（前端/建局，一次性）
  都会跑；只清到期的 ephemeral，永久与随档数据一律不碰。日志：
  `加载自检（after-load）：清过期 N 项（…）`。

#### 校验（这轮新增/更新）

* 文案键唯一性：EN/CN 各 281 个 Tag、重复 0 ✓；
* `dp_harness` 第 25 节：永久数据不带时间戳 ✓、TTL 数据带时间戳 ✓、
  `AutoGC` 清到期/留未到期/不动永久 ✓；第 11 节断言同步更新为“时间戳可选”；
* 全套：luac 34 个全过、前向引用 0、未定义标识符 0、12 套桩测试全绿。

### 19.19 实机反馈六：存档被认成分支 + 逻辑档仍不显示（2026-10-06）

#### ① 存档保存后被识别为分支 —— 创建分支偷偷改了「本局身份」

`SaveNode` 每次都会把节点身份写进随档数据（`sgnode`）—— 这是“我是谁”的记录。
而 `CreateBranchNode` 复用了 `SaveNode` ⇒ 它把**分支的身份**写进了本局 ✗：
从此本局认为自己是那条分支（`Kind=B`、`Parent=某节点`），于是**之后每次「存档」都跟着算成分支** ✗✗。

修法：`SaveNode` 新增 `WriteIdentity = false` 开关；创建分支时用它 ——
**分支档只是“另一条线”的记录，不是“我是谁”**（关系完全靠档名里的 `id/parent/kind` 表达）。
日志会写：`按调用方要求：本次只写档，**不改本局身份**（创建分支档）`。
回归断言（sg_harness）：创建分支后本局身份仍是 `kind=M parent=0` ✓。

#### ② 逻辑档仍然不显示 —— 加“逐条列出解析结果”的诊断

上一轮接了 `OnChecked → RefreshAll` 并补刷 3 秒，理论上够；既然仍不显示，就把事实打出来：
`API.Refresh` 扫描完成后**逐条列出解析到的关系档**（id / kind / parent / T / map / L），
一眼就能判断是“档根本没进列表”还是“进了但没渲染”。

```
扫描完成：列表 3 档，其中本 mod 关系档 2 档
  关系档 tmgj2drn kind=M parent=- T001 Continents L001
  关系档 tmgx…    kind=B parent=tmgj2drn T001 Pangaea L001
```

若是“列表 3 档、关系档 1 档”，说明新档的名字没被认出来（解析问题，日志里会有原始档名可对）；
若“关系档 2 档”但面板没画出来，则是渲染/刷新时序问题（再看补刷日志）。

### 19.20 逻辑存档改成**占位**（授权者 2026-10-06）+ 空引用修复

授权者：出现了空引用；另外**逻辑存档并不需要是真的存档**，它只是一个占位 ——
在点击确认切换、生成新存档之前移除逻辑存档，由真存档代替。

#### ① 逻辑分支 = 占位记录（不再写真存档）

| 旧 | 新 |
|---|---|
| `CreateBranchNode` 走 `SaveNode` → **真写一份存档**（还会顺手改本局身份，见 19.19） | 只往协议里写一条**占位记录** `sg_branch_<id>`（登记项 `sg_branch_*`，ephemeral/big，TTL 7 天） |
| 面板里看到的是真存档 | 面板把占位**并进关系树**（标「（逻辑占位）」），可选中、可当切换目标 |
| —— | 点「切换到选中」→ 弹窗确认 → **重开前先移除占位**，新局第一次存档生成的**真存档接手**这条线 |

占位里只存 6 个短字段：`{P=父, K=类型, T=回合, M=地图, S=戳, L=逻辑回合}`；
切换时关系挂到**占位所依附的那条线**（占位的父），而不是占位自己 —— 这样新局的真存档会正确挂在父线下面。

#### ② 空引用

本轮实际修到的空引用点：
* `CreateBranchNode` 不接 `options`（面板传了 `OnChecked`）⇒ 改签名并加 `OnCreated` 回调；
* 占位记录的 `Turn/Map/Stamp/Logical` 可能是 nil ⇒ 写入前统一归一化（`tonumber` / `tostring` / nil 透传），
  渲染与解析不会再炸；
* `MergeBranchPlaceholders` 在 `Refresh`（扫描回包）里用到、却定义在后面 ⇒ Lua 5.1 把它解析成全局 nil
  （**fwdcheck2 前向引用检查当场点名**）；现在在文件顶部前置声明、用赋值式定义，调用点再加 nil 守卫；
* `BuildTreeLines` 也主动合并占位（不再依赖“扫描先跑过”）。

#### 测试（`devtools/sg_harness.lua`，20 项）

创建分支**不产生真存档**（存档数不变、重开 0 次）✓｜占位写下且父=当前节点、类型 B ✓｜
占位出现在关系树里（面板能看到）✓｜切换到占位后交接单父=占位所依附的线 ✓；
原有载荷/身份/偏移/用后即焚等断言全部保持 ✓。

#### 实机判读

* 点「创建分支」→ 日志 `创建分支占位：id=… 父=… 逻辑回合=…（**没有写真存档**，只落占位）`；
  列表里应立刻出现一条带「（逻辑占位）」的 `B` 线，**存档文件数不变**；
* 选中它 → 「切换到选中」→ 弹窗确认 → 日志 `移除逻辑分支占位：…（由真存档接手）` → 重开；
* 新局开局日志 `本局接手换图交接：parent=<占位所依附的线> kind=B …`，之后第一次存档即生成真分支档。

### 19.21 实机日志里的三个报错（2026-10-06）

| 日志 | 真因 | 修法 |
|---|---|---|
| `Support_UI.lua:180: bad argument #2 to 'tonumber' (integer expected, got string)` | 迁移后 `DataProtocol.Load()` 返回 **(值, 来源)** 两个值，直接写成 `tonumber(DataProtocol.Load(k))` ⇒ 第二个值被当成 `tonumber` 的第二个参数 ✗ | 加一层括号截断返回值：`tonumber((DataProtocol.Load(k)))`；`tostring(...)` 两处同样处理。**并把此模式加进校验**（`grep` 复查：`tonumber(DataProtocol.Load` / `tostring(DataProtocol.Load` / `.. DataProtocol.Load` 应为空） |
| `ModTool.lua:159: function expected instead of nil` | gameplay 侧调用 `ExposedMembers.ModMiscToolUI.GetExperienceAndPromotionsUI` —— UI 侧的暴露是**后发布**的，gameplay 早一步调用就是 nil ✗ | 改成**防御式调用**：取不到就当没有经验数据（`expPoint=0`），绝不直接当函数用 |
| `ModMiscSavePanel.lua:644: attempt to index a nil value` | `PopupDialogInGame` 在存档面板这个上下文里可能是 nil ⇒ `PopupDialogInGame:new(...)` 直接索引 nil ✗ | 新增 `AskConfirm(text, onConfirmed)`：有弹窗就用弹窗；没有就退化成**“再点一次确认”**（面板自有状态行提示），切换/载入/删除都走它 |

教训：
* **多返回值**是 Lua 的常见坑 —— 迁移成“返回 (值, 来源)”这种签名时，凡是把调用塞进另一个函数参数的位置都要加括号；
* **跨上下文暴露**（`ExposedMembers`）不能用“应该已经发布了”来假设 —— 调用点必须能容忍 nil；
* UI 能力（弹窗之类）要**探测式使用**，而不是假定每个上下文都有。

### 19.22 实机反馈七：点「切换」没反应（2026-10-06）

授权者：点击切换后没有反应；怀疑是**旧存档的存在阻止了新存档的建立**，建议“先删旧档、保证唯一性”。

#### ① 重开不能从弹窗回调里发起（这是“没反应”的主因）

早前实机验证过的硬约束：`Network.RestartGame()` **只有从按钮回调里调**才会真的重开 ——
从弹窗回调 / 事件回调 / 按帧回调里调，都是“调用返回 true，但游戏不重开”（第 42 条）。
而 19.17 改成“弹窗确认后自动重开”之后，重开就落在了**弹窗回调**里 ✗ ⇒ 点确认、什么都没发生 ✗。

修法：把确认与执行**拆开**，执行一定发生在按钮回调里：

```
点「切换到选中」（第 1 次） → 确认框（有弹窗用弹窗；没有就提示“再点一次确认”）
                              → 上膛：状态行「已确认。再点一次「切换到选中」就开始保存当前档并重开。」
点「切换到选中」（第 2 次，**按钮回调**）→ PrepareSwitch（写交接单 + 存当前档）→ SwitchNow → 重开
```

#### ② 同名旧档先删（采纳授权者的建议，保证唯一性）

`SaveNode` 现在会在发存档请求**之前**，把**同名**的旧档先删掉（`UI.DeleteSavedGame`）——
引擎对“档名已存在”的请求有忽略的可能，先清路最稳。不同名的旧档仍按老规矩：**写成功之后**再删，
这样万一写失败也不会丢旧档。日志会写：`同名旧档先删除：… 已删除` / `为保证唯一性，先删掉 N 份同名旧档，再写新档`。

#### 判读

* 第 1 次点「切换到选中」后，状态行应出现「已确认。再点一次…」（或弹窗）；
* 第 2 次点击后日志依次出现：`同名旧档先删除…`（若有）→ `即将调用 Network.SaveGame（switch）` →
  `移除逻辑分支占位：…` → `换图[2/2]：即将调用 Network.RestartGame()`；
* 若第 2 次点击后仍不重开，说明这条路径在实机上还有别的前提（下一步就换回“点一次直接重开”的单步按钮）。

### 19.23 实机约束：**同名存档不能直接存**（授权者 2026-10-06 指出）

授权者：文明 6 里存在同名存档时无法直接存档（玩家操作时「存档」键会变灰），**UI 层的调用接口很可能同样受限**。

这解释了两个此前的谜团：
* **切换写的档在列表里看不到**：切换前缓存名（同一节点、同一回合、同一分钟）与盘上旧档**完全同名** ⇒
  引擎忽略这次 `Network.SaveGame` ⇒ 文件根本没写出来；
* **点保存也不刷新**：同一分钟内连存两次＝同名 ⇒ 第二次同样被忽略。

#### 修法：档名**构造上唯一**（不再依赖“同名先删”这种补偿手段）

* 时间戳从 `%Y%m%d-%H%M` 改成 **`%Y%m%d-%H%M%S`**（精确到秒）+ 随机 2 位 base36 尾巴：
  `MMT~<id>~<parent>~<kind>~T<turn>~<map>~20261006-092313-9z~L042`
  同一秒连存两次也不会撞名（回归断言已加）；字段数不变、不含 `~`，**老档名照样能解析**；
* 于是「一条线一个档」的策略改成：**每次存都是全新名字**（引擎一定接受），
  写成功后再按**节点 id** 清掉同一节点的陈旧档（不再只删 `OldEntry` 那一份），保证列表里一条线只留一份；
* v1.92 的“同名旧档先删”保留作为兜底（万一有历史遗留的同名档挡路）。

#### 判读

* 保存/切换后日志里档名应长这样：`…~20261006-092313-9z~L042`（带秒与尾巴）；
* 若仍出现“写了但列表里没有”，日志里的 `落盘确认：找 <带秒的档名>；列表 N 条（前几条：…）`
  能直接对上 —— 那时就不是同名问题，而是别的（存储层/引擎行为）。

### 19.24 实机反馈八：**「切换失败」的根因**（2026-10-06，直接从 Lua.log 读出）

授权者那次 Lua.log 的尾部（v1.92 一带的构建）只有这一行，而且**连打四次**，之后再无任何日志：

```
[SavePanel] Switch to tmgps8rb? The current game will be saved first, then the game restarts onto the new map. | Tap again to confirm
```

⇒ 点多少次都停在第一步，`PrepareSwitch` 一次都没被调到。四个根因：

#### 根因一：退化确认路径拿**闭包对象**比相等（永远不相等）

`AskConfirm` 在没有 `PopupDialogInGame` 的上下文里走退化分支，记的是 `m_ArmedConfirm = onConfirmed`，
下一次点击判断 `m_ArmedConfirm == onConfirmed` —— 每点一次按钮都会新建一个闭包，**永远为假**
⇒ 永远只打印「再点一次确认」，永远走不到真正的动作。
**修**：判据换成稳定的字符串键 `armKey`（例如 `"switch:" .. targetId`）。

#### 根因二：本上下文里 `PopupDialogInGame` 是 nil —— 所有直接 `PopupDialogInGame:new` 的地方都在空转

同一份日志里 `DoDeleteSelected` 的报错就是它（`attempt to index a nil value`，被 pcall 接住只留一行日志），
删除永远做不成；载入同理。
**修**：删除 / 载入 / 切换全部改走统一的 `AskConfirm`。

#### 根因三：落盘轮询**从来没挂上**（自锁）

按帧回调只在 `EnsureSwitchTick()` 里挂，而 `EnsureSwitchTick` 只被 `MarkRestartReady` 调用，
`MarkRestartReady` 又只在**轮询回调**里被调到 ⇒ 轮询根本不会开始 ——“落盘确认”那几行日志一行都不会出现，
状态机永远停在第 ② 步。**修**：一开始切换（`PerformSwitch`）就把轮询挂上。
（`devtools/panel_harness.lua` 现在专门断言这条。）

#### 根因四（认知修正）：引擎自己的重开就是在**弹窗 Yes 回调**里调的

* `Base/Assets/UI/Menus/InGameTopOptionsMenu.lua`：`OnRestartGame` 开确认弹窗 → Yes 回调 `OnReallyRestart` → `Network.RestartGame()`；
* `Base/Assets/UI/Menus/SaveGameMenu.lua`：`OnYes` → `Network.SaveGame`；
* `Base/Assets/UI/FrontEnd/LoadGameMenu.lua`：`OnLoadYes` → `Network.LoadGame`。

⇒ 早前“`RestartGame` 只能在按钮回调里调”的说法**过宽**。真正的界线是
**要由 UI 交互处理器发起**（面板按钮 / 弹窗按钮都算），而**不是** `Events.*` 回调或按帧回调。
本 mod 仍把重开放在**面板按钮回调**里（Automation 面板那次唯一实测通过的形态），只是理由改成这一条。

#### 新流程（v1.94 → v1.95）：**存原档**与**重开**分开占点击

```
① 点「切换到选中」→ 确认（引擎弹窗；本上下文没有弹窗 ⇒ 状态行提示“再点一次确认”）
② 确认下来那一下 = 只做两件事：写交接单 + 存当前档（PrepareSwitch），**不重开**
   （存原档放在确认回调里是安全的：引擎自己的存档菜单也在弹窗回调里调 Network.SaveGame）
③ 面板按帧轮询存档列表；查到这份档 ⇒「原档已确认在存档列表里——再点一次「切换到选中」就重开」
④ 再点一次 → **这次回调里只调 Network.RestartGame()**（顺带移除逻辑占位）
   两次都没确认落盘 ⇒ 状态行老实报失败；玩家再点一次 = 显式强切（Force，日志写明“原档未确认落盘”）
```

逻辑分支占位同时改成**随档保存**（`sg_branches`，persave / CustomData；CustomData 没有枚举接口，
所以**一个键装一张表** `{[id]={P,K,T,M,S,L}}`，增删都改这张表）—— 授权者：逻辑档保留在存档内即可，
无需设为跨存档数据。

#### 判读（这次实机要看的日志行）

```
   换图：进入“可重开”状态（落盘确认回调，目标=…，原档已确认落盘）——等玩家点一次「切换到选中」，那一次只做重开
   换图[3/3]：即将调用 Network.RestartGame()（原因=按钮回调（重开专用）） 环境：anyMultiplayer=… savedGame=… worldBuilder=… isGameHost=… turn=…
   换图[3/3]：调用已返回 result=…（**若之后还打得出日志，说明引擎没真的重开**）
```

* 若 ① 之后**始终**没有 `即将调用 Network.SaveGame（switch）`：说明确认那一步还是没走通（看“再点一次确认”）；
* 若 ③ 之后没有「原档已确认…」而是一直 `落盘确认：找 …`：就是**存档没落盘**（引擎侧问题，不是流程问题）；
* 若打出「调用已返回」之后**还有日志**：引擎没重开。下一步就改成**单步按钮**（点一次只调 `RestartGame`，
  什么都不存），并把 `anyMultiplayer / worldBuilder / savedGame` 三个环境值对上引擎自己的门槛
  （`InGameTopOptionsMenu` 的重开对多人 / worldbuilder 有限制，见该文件 316 行附近）。

#### 新局第一档由 mod 自动存掉（v1.97）：把“由真存档接手”这句话兑现

逻辑占位在重开前就被移除，所以新局必须**自己产生那份真存档**，否则那条分支线在树上是空的。
做法：

* 固化交接单时在本局身份（`sgnode`，persave）里留 `AutoSavePending = true`；
* 面板在**本局第一个 `LocalPlayerTurnBegin`** 上调 `RunPendingAutoSave()` 存掉它 ——
  触发点不能挂在 `LoadGameViewStateDone`（加载画面里存档第 19.8 条已实机证否）；
* 清标记**先于**发存档请求 ⇒ 新档里不带标记，读档回来也不会又存一次；同一局只自动存一次；
* 存出来的这档按 `incoming` 关系算成**选中逻辑档的分支**（`kind=B`、parent=占位所依附的那条线），
  逻辑回合按固化下来的偏移算（桩测试里：引擎 42 + 偏移 17 = L059）。

#### 另外两处“张冠李戴 / 判据失效”（v1.98，静态审计找出来的）

1. **锚点覆盖了本局记录**：`PrepareSwitch` 原来把选中逻辑档的逻辑回合写进 `node.Logical/Offset`，
   可那个 node 同时就是**本局这一档**的存档记录 ⇒ 本局引擎 42 回合、逻辑 42 会被记成目标档的
   逻辑 18 / 偏移 17，读档回来逻辑回合变成 59。现在拆开：`anchorLogical` 只喂交接单
   （新局的回合同步锚点），本局这一档仍记本局自己的逻辑回合与偏移。
   桩测试断言：切到占位后本局逻辑回合仍是 42、身份偏移不是 17。
2. **“档名一致”那条判据从来没生效**：解析出来的节点把原始档名放在 `RawName`，而落盘确认比的是
   `node.Name`（一直是 nil）⇒ 一直靠 id 回退在判，日志还打印成“解析出的 id 一致（档名不同？）”，
   排查时被这行误导过。现在改比 `RawName`，日志的档名样例也不再打 nil。

#### 切到逻辑占位之后：**发给它的事件必须由新局继承**（v1.99）

占位在重开前就被移除，它的信箱键却是 `ev_<占位id>_*`；新局的节点 id 是后来才生成的
⇒ 不处理的话，“发给某个逻辑档的事件”**永远收不到**，而且是最难查的那种静默丢失
（发件方那边一切正常、收件方那边什么都没发生）。

做法：交接单带 `InheritNodeId` → 新局开局探针固化进 `identity.InheritIds`（随档走）→
`IntakeEvents` 把“本局节点 + 继承来的 id”都扫一遍，继承来的事件带 `InheritedFrom`，
日志与广播里都写明“继承自逻辑档 X”。两个坑一并堵上：

* **存档写身份是整表覆盖**：不带 `InheritIds` 的话，新局第一次存档之后继承就断了
  （桩测试专门断言“存档写身份不会把继承列表擦掉”）；
* **换图之前那一局不许认领**：`GetInheritedNodeIds` 只在“本局还没有身份”时才读交接单 ——
  否则旧局点一次「收件」就把占位的信箱提前领走删掉，新局反而收不到。

#### 树根位置的逻辑占位：关系挂错（v2.00，端到端桩测试抓出来的）

还没存过任何本 mod 的档就点「创建分支」⇒ 占位自己没有父。这时 `PrepareSwitch` 原来只写
`node.Parent = targetId`（占位 id），而占位在重开前就被移除 ⇒ **悬空父**：
树里显示“父档不在列表”，新局也跟着挂到不存在的节点上，连新局的自动存档都跟着挂错。

修法：
* 占位没有父 ⇒ 关系挂**根**（`MODMISC_SAVE_ROOT_PARENT`），日志写明“树根位置的逻辑占位”；
* `ResolveNewSaveParent` 认 incoming 时**只看类型、不再要求有父**，否则树根位置的换图新局
  会掉到 root 分支被当成主线 M；
* 开局探针的固化条件补上“`Parent == nil` 但有 `InheritNodeId`”这种换图。

#### 端到端桩测试（v2.00）

`devtools/e2e_harness.lua`：**真面板 + 真 ModMiscSaveGraph** 放在同一个桩环境里，
用「点按钮 + 跑帧 + 让异步列表查询回包」驱动完整流程（23 条断言）。
之前两个桩各管一半（panel 用假模块、sg 用假面板），中间那条**接口缝**没人看 ——
而实机那几次失败坏的多半正是这条缝。现在它跑通：

```
创建分支（真占位）→ 点两次切换（确认 → 只发存档、不重开）
→ 跑帧轮询（存档进列表 → 认出 → 状态行说可以重开）
→ 再点一次（只重开：占位移除、重开恰好一次）
→ 看门狗（上下文还活着 ⇒ 明说“引擎没重开”）
→ 模拟新局（交接固化 + 信箱继承 + 自动存档标记 → 第一回合自动存出真存档）
→ 另一条：切到**真存档**（关系挂那条真档、没有占位可删、不设信箱继承）
```

#### 交接单过期就**拒绝重开**（v2.02）：宁可让你重来，也不静默丢关系

交接单（`sg_pending`）是“新局算这条线的分支”的唯一凭据，TTL 900 秒。第 ② 步存原档到
第 ③ 步点重开之间要是隔太久（玩家走开了），它会被判过期并清掉；老代码这时只打一行警告
**照样重开** ⇒ 得到一局“不知道自己是分支”的新局，关系静默丢失 —— 比失败更难查。

现在 `SwitchNow` 直接拒绝，并返回一个 `handoff-lost` 标记；面板把“可重开”状态清回去，
状态行写「换图交接单过期了——为免丢掉分支关系，这次切换被取消。再点一次「切换到选中」重新准备。」
玩家再点两次就重新写交接单 + 再存一档，随后正常重开（端到端桩测试把这条回路也跑了一遍）。

#### 重开看门狗（v1.96）：把“引擎没重开”这件事直接写出来

`Network.RestartGame()` 返回 true **不等于**重开了。真重开的话本 UI 上下文会被销毁、按帧回调不会再跑；
还能跑就说明引擎没理这次调用。所以第 ④ 步发出重开后上表 5 秒看门狗，到点若本上下文还活着：

```
**引擎没有重开**：Network.RestartGame() 已返回但游戏仍在运行（第 N 次）—— 本上下文还活着，
LoadGameViewStateDone 见过 X 次，引擎回合=…。真重开过的话日志里会出现新的 `panel loading build=…`
并重新走一遍开局探针。
```

状态行同时变成「引擎**没有**重开——游戏还在跑。请再点一次「切换到选中」。」，
并且把“可重开”状态摆回去 ⇒ **再点一次就是纯重开重试**（不再确认、不会再存一档）——
状态行让玩家做什么，那一次点击就真的做什么。交接单要是已过期，模块会拒绝并让面板回到
“重新准备”（v2.02），不会闷头切出一个不知自己是分支的新局。

⇒ 下次实机不用再从“后面还有没有日志”去猜，日志和界面都会直接说。

#### 桩测试

`devtools/panel_harness.lua`（34 条断言）：把**真面板文件**读进来，用假 `ModMiscSaveGraph` 记录调用，
模拟“点按钮 / 跑帧”，断言：①确认→存原档；②未确认不许重开；③确认后那次点击只重开、不再存一笔；
④超时只重发一次；⑤失败后必须显式确认才 Force；⑥载入 / 删除的确认路径能走通；⑦轮询确实挂上了。

### 19.25 实机复测清单：换图 / 切换（v1.99）

一页纸照着点，每步都写清「该看到什么」与「没看到说明卡在哪」。日志关键字都给全，
`adb` 拉 `Lua.log` 后直接搜这些串即可。

| 步 | 操作 | 该看到（面板状态行 / Lua.log） | 没看到说明什么 |
|----|------|------------------------------|----------------|
| 0 | 进游戏开面板 | `[SavePanel] panel loading build=…`、`开局探针 after-load(store=…)` | mod 没加载 / 面板 context 没起 |
| 1 | 点「创建分支」 | 状态行「Branch save created」；日志`创建分支占位：id=… 父=… 逻辑回合=…` | 参数没构造出来（看同一行的报错） |
| 2 | 在列表里选中那条 `B`（带「逻辑占位」字样） | 状态行「已选中 …」 | 占位没并进树（`MergeBranchPlaceholders`） |
| 3 | 点「切换到选中」（第 1 次） | 状态行「…?」+ 详情「再点一次确认」（本上下文没有 `PopupDialogInGame`，走的就是这条退化路径） | 确认路径没走通 |
| 4 | 再点一次（第 2 次） | 状态行「原档存档请求已发出（节点 …）」；日志 `即将调用 Network.SaveGame（switch） name=MMT~…~L…` | **没重开是正常的**，这一步就不该重开 |
| 5 | 等 2–5 秒 | 状态行「原档已确认在存档列表里——再点一次…」；日志 `落盘确认：找 …；列表 N 条` → `已找到（档名一致）` | 一直停在 `落盘确认：找 …` ⇒ 存档没落盘（引擎侧，看 `saveFile:` 那行与 `GetLastSaveName`） |
| 6 | 再点一次（第 3 次） | 日志 `移除逻辑分支占位：…` → `换图[3/3]：即将调用 Network.RestartGame()` → `调用已返回 result=true`；随后游戏重开 | 若出现 `**引擎没有重开**` ⇒ 引擎拒了这次调用；把同一行的 `anyMultiplayer / worldBuilder / savedGame` 发我 |
| 7 | 新局第一个回合 | 日志 `本局接手换图交接：parent=… kind=B …` → `本局继承信箱：逻辑档 X 的待收事件由本局接收` → `换图后新局：…自动存本局第一档` | 没自动存 ⇒ 看 `换图后未自动存档：…` 那行（标记没留 / 存档没发出去） |
| 8 | 面板再看列表 | 多出一条新的 `B`，父指向占位所依附的那条线；占位那条**已消失** | 占位还在 ⇒ 第 6 步没走到移除；新 `B` 没出现 ⇒ 第 7 步的自动存档没成 |

**如果第 6 步没重开，先分清是“我们的流程”还是“引擎/局面”**：
打开 Automation 测试面板第 2 页签，点它自己的「RestartGame（创建新局 / 换地图）」——
那是**只调一次 `Network.RestartGame()`** 的最小入口（2026-10-05 实机验证过可用）。

* 它也**不重开** ⇒ 是引擎/当前局面拒了重开（把两侧日志都发我，重点看
  `anyMultiplayer / worldBuilder / savedGame` 三个值）；
* 它能重开、而我们的切换不能 ⇒ 差在我们的流程或时序，我按日志改（面板侧已经拆成
  “只存原档”和“只重开”两次点击，就是为了排除“存档还在写”这个干扰）。

**事件那条线**（换图后要验的第二件事）：在旧局给逻辑占位发一条事件（选中占位 → 设类型/内容 →
发送）→ 按上表切过去 → 新局开局日志应出现
`收件：节点 … 有 N 条待取事件` 与 `已入列：GOLD … （继承自逻辑档 X）`，
并且回合到点时正常触发。

### 19.26 方案更换：**存储与切换彻底分开**（授权者 2026-10-06 定）

> 本节之后的方案取代 §19.17–§19.25 里那套「两步式 + 落盘确认 + 逻辑占位」：
> 那套的实测结果是**卡在“等确认”**（见下一段），授权者决定换成更简单、成功率更高的做法。

#### 为什么放弃旧方案

实机日志（2026-10-06 10:41–10:45，4124 行）读出来的事实：

* `即将调用 Network.SaveGame（switch）` **2 次**（第 ② 步都发出去了），落盘复查也**确认文件在列表里**；
* `Network.RestartGame` **0 次**——面板始终没进入「可重开」状态：`进入“可重开”状态` 0 条、
  `落盘确认：找 …` 0 条（按帧轮询一次查询都没发出去）；
* 逐行核对代码后确认两处断点：`OnSaveGraphComplete` 那条**只调 OnChecked、不设 Verified**，
  而面板的轮询又跑在 `ContextPtr:SetRefreshHandler` 上（实机证据显示它没跑）。
  ⇒ 两条路同时断，玩家怎么点都只是在「确认 → 又存一档」之间循环。

结论：**切换不该依赖“存档 + 等回执 + 等按帧回调”这条长链**。

#### 新方案（v3.00 起）

```
点「重开为新分支」→ 确认 → 同一个按钮回调里：
  ① 门槛：**必须存在主线存档**（主线头 / 列表里的主线档 / 本局自己就是主线档）。
     没有 ⇒ 只报「请先按「存档」手动存一档」，**不做任何自动存档**；
  ② 写一条**换图广播** sw_bcast（跨存档存储、**进程内、5 分钟有效、读到即删**）；
  ③ 立刻 Network.RestartGame()（回调里只有这两件事，没有任何等待）。
```

新局开局（`ReportAfterLoad`）：**先清超出有效期的信息**（AutoGC + 广播自检 300 秒），
再检测有没有广播：**有就一律认定本局是分支**（父 = 广播里的主线档；逻辑回合锚点 = 广播里的逻辑回合），
然后立刻删掉广播（用后即焚）。已知漏洞（授权者明确接受）：这 5 分钟内开的任何新局都会被当成分支；
若本局已经有自己的身份（这 5 分钟里读了一份老档），则**不改**本局关系，只把广播消费掉，并在日志写明。

#### 手动改关系的接口（新增）

| 接口 | 作用 |
|---|---|
| `SetCurrentRelation(kind[, parentId])` | 把**本档**设为主线（M）/ 分支（B，父=给定或主线头） |
| `SetNodeRelation(id, kind[, parentId])` | 把**别的档**设为主线/分支（改它的父）；父不能是自己 |
| `ClearNodeRelation(id)` | 清掉某条档的关系覆盖，回到档名里写的关系 |
| `ListRelationOverrides()` | 列出所有覆盖（诊断） |

原理：parent/kind 写在**档名**里、引擎没有改名 API ⇒ 改动落在**关系覆盖表 `sg_over`**（permanent/small），
读列表建树前套用（节点上标 `Overridden`，树里显示「手动改过关系」）；本局自己那条**同时改写身份**，
于是下次存档就把新关系写进档名（自然收敛）。
面板上对应四个按钮：**本档→主线 / 本档→分支 / 选中→主线 / 选中→分支**。

#### 换图后“引擎没重开”怎么看出来

不再依赖按帧回调：`SwitchToNewBranch` 成功返回后，面板记一个标记；
**之后任何一次按钮动作**开头都会检查它——还活着就写一行
`**引擎没有重开**：上次 RestartGame 之后本上下文还活着（动作=…）`。这是最直接的证据。

#### 复测要点（替换 §19.25 的 3–7 步）

1. 先按「存档」存一档（这时它成为主线）；
2. 点「重开为新分支」→ 再点一次确认 ⇒ 日志应出现
   `换图广播已写入（**5 分钟内有效、读到即删**）` → `换图[3/3]：即将调用 Network.RestartGame()`
   → `调用已返回 result=true`，接着游戏应真的重开（没有新的 `panel loading` 之前还有日志 ⇒ 没重开）；
3. 新局开局日志：`after-load(… broadcast=a1（写于 N 秒前）)` → `本局认定为**分支**（换图广播）`；
4. 在新局按「存档」⇒ 新档名应是 `MMT~<新id>~<主线id>~B~…`；
5. 关系按钮：选中任意一条 → 「选中→主线」/「选中→分支」⇒ 树立即重画、日志 `关系覆盖已写入`。

### 19.27 ~~新测试项：UI 环境连通性~~ —— **已撤销**（授权者 2026-10-06）

> **结论：前端与对局内是两套环境，这个连通性探针没有意义，已整体删除。**
> 授权者第二次遇到“返回主界面闪退”后拍板取消。删除范围：`UI/ModMiscContextProbe.lua`
> （整文件）、前端 include 与触发、`Support_UI` 的进游戏触发、Automation 面板的
> 「环境连通性」按钮与说明、两个 LOC 键、modinfo 清单项。
>
> 下面保留原始设计，只为回溯“当时想测什么”。

#### （原始设计，已作废）

要回答的问题：**主页面（前端）缓存的数据，进游戏后读得到吗？退出回主页面后呢？**
—— 也就是「跨游戏状态的两个 Lua 环境之间到底有没有共享的读写通道」。
探针：`UI/ModMiscContextProbe.lua`，日志前缀 `[ModMiscTool][CtxProbe]`。

三个通道各测一遍（每个都写清“写/读/结果”）：

| 通道 | 实现 | 说明 |
|---|---|---|
| **A 模组配置组名字** | `ModMiscModGroupStore`（`Modding` 组接口） | 引擎数据库里的自由文本 ⇒ **最有希望跨游戏状态的一条** |
| **B 档名通道** | `ModMiscStore` | **只读不写**：前端写普通存档已实机证否（闪退，第 73 条），不能拿它冒险 |
| **C 进程内共享表** | `ExposedMembers` / 全局变量 | 两个游戏状态各一份 Lua 状态，多半不共享 —— 写进去再读回来，测出来才作数 |

触发点（自动，不用手点）：

* **前端上下文加载**（= 主页面出现；首次进主页面、退出对局回主页面都会走一次）：
  `UI/Replacements/Civ6Common.lua` 里 include 那一刻先跑一次，前端刷新回调里再补跑一次
  （那一刻存储/组接口可能还没就绪；探针自己限制“每个 context 最多两次”）；
* **进游戏**（`LoadGameViewStateDone`）：`UI/Support_UI.lua` 的 Initialize 里跑一次；
* 手动：Automation 测试面板「时间线」页 → **环境连通性**按钮（`ModMiscContextProbe.Check`）。

#### 怎么读日志

同一个标记会写进 A 通道，形如 `frontend-前端上下文加载-<os.time>-<随机>`。按时间顺序看：

```
[CtxProbe] ==== 环境连通性检查：context=frontend 原因=前端上下文加载 本次标记=frontend-…-1234 ====
[CtxProbe]   A 模组配置组：写入 true
[CtxProbe]   A 模组配置组：读到 frontend-…-1234       ← 主页面写进去了
[CtxProbe]   B 档名通道：**只读不写**（前端写档已证否：会闪退）
[CtxProbe]   B 档名通道：IsReady=… 读到 …
[CtxProbe]   C 进程内共享表（exposed）：通用=frontend-… ｜…
（进游戏）
[CtxProbe] ==== 环境连通性检查：context=ingame 原因=进游戏（加载完成） 本次标记=ingame-…-5678 ====
[CtxProbe]   A 模组配置组：读到 frontend-…-1234       ← **通了**（前端写的能读到；若是 nil/另一个标记 就是不通）
[CtxProbe]   C 进程内共享表（exposed）：…frontend 写的=… ← 前端写的那份还在不在，一眼看出上下文是否共享
（退出回主页面）
[CtxProbe] ==== 环境连通性检查：context=frontend … ====
[CtxProbe]   A 模组配置组：读到 ingame-…-5678          ← 反过来也通（对局内写的回到主页面能读）
```

判读：**A 通道读到的是上一阶段写的标记 ⇒ 该通道跨游戏状态可用**（这也是我们所有跨存档存储的
基础假设）；读到 `nil（没有这份数据）` ⇒ 该通道在前端/对局内之间不通，得换通道或换写法。
C 通道的“frontend 写的 / ingame 写的”两栏就是“两边的 Lua 状态是否共享”的直接证据。

### 19.28 实机反馈（2026-10-06 12:0x）：换图成功、事件“收到了但没执行”、回主界面闪退

#### 好消息：v3.00 的新换图方案**实机走通了**

```
换图广播已写入（**5 分钟内有效、读到即删**）：父=tmgwo9sx 逻辑回合=1 …
换图[3/3]：即将调用 Network.RestartGame()（原因=面板按钮（重开为新分支））
   环境：anyMultiplayer=false savedGame=false worldBuilder=false isGameHost=true turn=1
换图[3/3]：调用已返回 result=true
（新局）换图广播已消费（开局已认定本局为分支）：父=tmgwo9sx 逻辑回合=1，写于 41 秒前
（新局）本局认定为**分支**（换图广播）：父=tmgwo9sx kind=B 锚点逻辑回合=1（偏移 +0）
```

⇒ 「写广播 + 直接重开」在设备上**真的重开了**，新局也**正确认定自己是分支**。旧的“两步式 + 落盘确认”
可以彻底放下。

#### 事件：收到了，但**没执行**（已修）

日志证据（同一局）：

```
发件：GOLD 100 x100 → 节点 tmgwo9sx（接受逻辑回合 1）key=ev_tmgwo9sx_… 结果=true
（新局开局）收件扫描：节点 tmgwo9sx … 命中 1 个键
已入列：GOLD 100 x100 接受回合=1 来自=tmgwpyce（现有 1 条）
已投递并清理 1 个信箱键
收件完成：本局节点 tmgwo9sx 入列 1 条
```

⇒ **收件链条全对**（信箱读到 → 入列 → 信箱清理）。问题在**执行时机**：
`ProcessDue` 只在 `Events.LocalPlayerTurnBegin`（每回合开始）跑，而“接受回合 = 当前逻辑回合”的事件
本该**到点就执行**；玩家在第 1 回合收到、第 1 回合就离开 ⇒ 什么都没发生，看起来像“接收失败”。

**修法**：`AddIncoming` 入列后立刻按“到点”结算一次（`ProcessDue("accept-now")`，它自己跳过还没到点的）。
没到点的事件照旧留到回合开始 —— 语义不变，只是把“已经到点的”立刻兑现。

#### 回主界面闪退（tombstone）

```
signal 11 (SIGSEGV) … Cause: null pointer dereference
#00 pc … libHavokScript2013.2.0_Android_FinalRelease.so (hksi_luaL_unref(lua_State*, int, int)+172)
pid: com.aspyr.civvi, tid: 12626, name: Thread-7
```

这是**引擎在拆卸 Lua 状态时崩在工作线程上**（`luaL_unref` 是引擎侧引用计数，不是我们的 Lua 代码）。
那份日志里**没有** `[CtxProbe]` 行 ⇒ 崩的那次还没有本探针（v3.00/3.01 部署），所以探针不是肇因。
我们能做的、也已经做的：

* **退出那一刻零副作用**：`Events.ExitToMainMenu` 处理器原来会调 `ClearBranchBroadcast()`
  （= 删一个模组配置组 = 引擎数据库写）——那是我们**退出瞬间唯一还在动引擎的操作**，现在改成只打一行日志。
  代价：退出后 5 分钟内新开的一局会被残留广播认成分支（已知漏洞，TTL 兜底）；
* 探针里加了显式开关 `MODMISC_CTXPROBE_FRONTEND_WRITE`：万一主界面再闪退，
  把它改 `false` 就变成“前端只读不写”，一步定位是不是前端写引擎数据库的问题。

若再次闪退，建议同时做一次对照：只留本 mod、关掉其它 mod（日志里还有 DiplomacyRework / Norn_UI /
ConvinentCarrier 等）跑一遍 —— `luaL_unref` 这类拆卸期崩溃在多个 mod 共存时并不罕见，
要先分清是“我们的退出副作用”还是“别的 mod 的退出副作用”。


### 19.29 「前端零副作用」策略（授权者 2026-10-06 定）

授权者的结论是**前端（主页面/建局界面）与对局内是两套环境**，所以本 mod 的规则改成：

* **前端上下文不写任何存储**。原先前端 include 时跑 `DataProtocol.AutoGC("frontend")`
  （清过期键 = 模组配置组/配置档的写），现在跳过，只记一行日志；
  过期清理只在对局内做（`Support_UI` 的 after-load AutoGC + 协议自己的 TTL 判定）。
* **前端不扫存档列表**。原先前端首次刷新会 `ModMiscStore.Refresh()`（= `UI.QuerySaveGameList`
  异步查询 + 挂一个 `LuaEvents.FileListQueryResults` 回调）。前端读到的跨存档数据对局内也用不上，
  却给“退出到主界面”的拆卸期留下一个可能在飞的引擎查询与已注册回调 ——
  正是拆卸期崩溃的常见来源。现在不扫。
* 前端只保留**建局需要**的动作：`WriteCustomData`（城邦数量等，随档数据，进程内）与
  城邦数量的 `GameConfiguration` 设置 —— 这些是本 mod 在前端的功能本身，不动。

至此，退出到主界面那一刻本 mod 的行为是：`ExitToMainMenu` 只打一行日志（§19.28），
前端上下文零写、零扫描。若这样仍然闪退，就基本可以排除本 mod 的退出副作用，
下一步应按“只留本 mod / 逐个关掉其它 mod”做对照（日志里同时加载着
DiplomacyRework、Norn_UI、ConvinentCarrier 等）。

### 19.30 重开时 unref 闪退 → 把「写广播」与「重开」拆成两次点击（v3.05）

授权者反馈：**退出到主界面不闪退了**（§19.29 的前端零副作用生效），
但**重开游戏又开始出现同样的 `luaL_unref` 闪退**。

#### 判断

换图那一刻我们只做两件事：① 写换图广播（`sw_bcast` = 一次**模组配置组写**，引擎数据库，
落盘在工作线程上）；② 立刻 `Network.RestartGame()`（引擎拆卸整个游戏状态）。
`luaL_unref` 崩在拆卸期的工作线程上 ⇒ **“数据库写还在飞、引擎已经开始拆 Lua 状态”** 是最合理的解释
（§19.29 之前，退出到主界面之所以崩，也是同一个形状：那时我们在 `ExitToMainMenu` 里删配置组）。

#### 改法：写与重开分开占两次点击

```
点「重开为新分支」→ 确认 → 第 1 下：**只写广播**（Restart=false），状态行「分支信息已缓存…再点一次就重开」
点「重开为新分支」→ 第 2 下：**只重开**（Broadcast=false，复用那条广播）
```

两次点击之间隔着玩家的手速（通常 1 秒以上），引擎的数据库写早就结算完，
重开那一刻本 mod **不做任何引擎写**。第二下若发现广播已经过期/被消费（TTL 300 秒），
模块会拒绝并让玩家重新确认一次（会重新写广播），不会闷头重开。

#### 判读（下次实机）

```
分支广播已缓存（本次**不重开**）：等玩家再点一次，那一下只重开
广播复用：不重复写，直接用 N 秒前那条（广播写于 N 秒前，数据库写已结算）
换图[3/3]：即将调用 Network.RestartGame()（原因=面板按钮（重开为新分支）（广播写于 N 秒前，数据库写已结算））
```

* 若这样**不再闪退** ⇒ 就是“数据库写紧跟拆卸期”的问题，这个拆法就是最终形态；
* 若**仍然闪退** ⇒ 说明与我们的写无关（重开那一刻我们确实什么都不写了），
  下一步做对照：只留本 mod / 关掉其它 mod（DiplomacyRework、Norn_UI、ConvinentCarrier 等）
  跑同样的“存档 → 换图”两步，看是不是引擎/别的 mod 在重开时的拆卸问题。
