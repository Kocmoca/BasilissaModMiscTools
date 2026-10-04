# Civ6 VanillaData Automation 系 Lua 接口总结

> 想直接看可复用接口（观察者/玩家视角、存档读档、AssetPreview、跑分）：见 `Automation_HighValue_APIs.md`。

> **范围**：`VanillaData/Base/UI/Automation/*.lua`（共 10 个 Lua 文件，不含 `Automation_NarrationPopup*.xml`）
>
> **交叉校验**：
> * `Civ VI Modding Companion 2.0.xlsx` 的 `Objects`、`Events`、`Module Objects`、`Module Global Funcs` 四个工作表（用于补全 C++ 侧 `Automation` 全局对象和 LuaEvents 列表）。
> * `Civ6PC/Base/Assets/UI/Automation/` 当前安装版（仅用于版本差异提示；本总结以 VanillaData 为准）。
>
> **结论先行**：Automation 系 Lua 文件不是“引擎 Automation 对象的定义”，而是 **C++ `Automation` 全局对象的消费者 + 一套测试/观察/播报脚本**。它们全部用全局函数名，没有 `ExposedMembers` 封装；要集成到 Mod Misc Tool，必须自己加一层隔离和暴露层。
>
> 目前只做了静态梳理，未在设备上实机验证，关键不确定项见第 11 节。

---

## 1. 快速结论

1. **核心接口是 C++ 全局对象 `Automation.*`**，负责日志、参数集、暂停、测试完成信号、随机数、时间、输入处理。Companion 标注它在 Gameplay/UI 两侧都存在；本组脚本实际都在 UI 侧运行。
2. **测试框架由 `Tests` 全局表驱动**。每个测试是一个表，支持 `Run`、`Stop`、`GameStarted`、`PostGameInitialization` 四个约定入口。
3. **LuaEvents 是主流程总线**：`AutomationStart -> AutomationRunTest -> AutomationGameStarted / AutomationPostGameInitialization -> AutomationTestComplete -> AutomationRunTest ... -> AutomationComplete`。
4. **Automation 参数集存在 C++ 侧**（如 `CurrentTest`、启动参数 `RunTests`、本地参数 `TestIndex`），脚本注释明确说不要依赖 Lua local 变量，因为加载新游戏/切换 DLC 时 Lua context 会被重建。
5. **所有脚本都用全局函数名**：`AddToList`、`RemoveFromList`、`Initialize`、`Uninitialize`、`CanSeePlot`、`OnCityVisibilityChanged` 等在同一 Lua context 中极易冲突；尤其 `Automation_BenchmarkCamera.lua`、`Automation_BenchmarkCamera_Capitals.lua`、`Automation_ObserverCamera.lua` 定义了大量同名函数。
6. **VanillaData 与当前安装版有版本差**：`Automation_StandardTests.lua`、`Automation_StandardTestSupport.lua` 在 `Civ6PC/Base/Assets/UI/Automation/` 中更新更多功能（多人大厅类型、人数配置、`Tests["End"]`、`Automation.GetParameterSet` 等）。若最终集成目标是当前游戏，封装前应先以当前安装版为准再核对一次。

---

## 2. 文件清单

| 文件 | 角色 | 运行/加载方式 | 主要公开名字 |
|---|---|---|---|
| `Automation_StandardTestSupport.lua` | 标准测试公共框架 | 被 `StandardTests` 和 `DailySmokeTest` 通过 `include(...)` 加载 | `LookAtCapital`、`GetCurrentTestObserver`、`StartupObserverCamera`、`GetCurrentTestHandler`、`StoreCurrentTestParameters`、`OnAutomation*`、`Tests["QuitApp"/"QuitGame"/"PauseGame"]` |
| `Automation_StandardTests.lua` | 标准测试套件 | UI 上下文；主菜单/对局内都可能被重建 | `Tests["PlayGame"/"LoadGame"/"HostGame"/"JoinGame"]`、`UpdatePlayerCounts`、`ReadUserConfigOptions`、`LogCurrentPlayers`、多人事件处理 |
| `Automation_DailySmokeTest.lua` | 旧版/精简冒烟测试套件 | UI 上下文；自己 `include` 标准支持 | `Tests = {}`、`Turns = 5`、`Tests["PlayGame"/"LoadGame"]`，以及同名的公共辅助函数 |
| `Automation_NarrationManager.lua` | 把游戏事件转成播报消息 | 对局内 UI 上下文，由 `AutomationGameStarted` 初始化 | `SendPlayerNarrationMessage`、`SendPlayerPlayerNarrationMessage`、各 `On*` 事件处理、`Initialize`、`Uninitialize` |
| `Automation_NarrationPopup.lua` | 播报弹窗队列和显示 | `InGame.xml` / `InGame_PHONE.xml` / `InGame_TABLET.xml` 中注册为隐藏 `LuaContext` | `ShowNarrationPopup`、`OnAddToNarrationQueue`、`UpdateQueue`、`Close`、`IsBlockingInput`、`Initialize` |
| `Automation_ObserverCamera.lua` | 自动观察镜头活动调度 | 对局内 UI 上下文 | `VisitActivity` 枚举、`PickBestCity`、`PickBestActivity`、`StartCurrentActivity`、`CheckActivityComplete` 及各事件处理 |
| `Automation_BenchmarkCamera.lua` | 跑分镜头（可见城市轮换） | 跑分加载，UI 上下文 | `AddToList`、`RemoveFromList`、`GetEntryForPlayer`、`OnBenchmark*` |
| `Automation_BenchmarkCamera_Capitals.lua` | 跑分镜头（只轮换主要文明首都） | 跑分加载，UI 上下文；与上一个文件互斥 | 同名全局函数，`Entry` 结构相同 |
| `Automation_Profile.lua` | AutoProfiler + AssetPreview 资产跑分 | 主菜单/进入对局后运行 | `SetSummaryFile`、`ResetView`、`ForEachHex`、`City_BuildTestList`、`Unit_BuildTestList` 等 |

`Automation_NarrationPopup_PHONE.xml` / `Automation_NarrationPopup.xml` 只提供控件，不导出 Lua 接口。

---

## 3. C++ 侧 `Automation` 全局对象接口

> 来源：Companion `Objects` 工作表中 `C-Automation` 对象定义；参数名和默认值用 VanillaData Lua 源码实际调用校正。  
> Companion 标注该对象在 Gameplay/UI 两侧均存在；本组 Lua 文件只证明了 UI 侧用法。

### 3.1 参数集与查询

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `Automation.GenerateSaveName()` | 无 | `saveName :string` | 生成自动化存档名。 |
| `Automation.GetLastGeneratedSaveName()` | 无 | `saveName :string` | 读取最近一次生成的存档名，`LoadGame` 测试默认用它。 |
| `Automation.GetSetParameter(paramSet, param [, default])` | `paramSet:string`、`param:string`、可选默认值 | `value:(any)` | 从命名的参数集中读一个键。**源码多次使用第三个默认值参数**（Companion 模型没有完整列出，属于源码已验证用法）。 |
| `Automation.GetParameterSet(paramSet)` | `paramSet:string` | `params:table` | 取整个参数集。Companion 已文档化，但 VanillaData 脚本未调用；当前安装版 `Automation_StandardTests.lua` 已使用。 |
| `Automation.GetStartupParameter(startupParam)` | `startupParam:string` | `value:(any)` | 读启动参数。测试框架唯一使用的是 `"RunTests"`。 |
| `Automation.GetLocalParameter(localParam [, default])` | `localParam:string`、可选默认值 | `value:(any)` | 读 Automation 本地参数；用于跨 Lua context 重载保存 `TestIndex`、`QuitApp`、`AutomationStarted` 等。 |
| `Automation.GetTime()` | 无 | `number` | Companion 标为 `unixTimeStamp`；源码把它当毫秒/秒级的活动计时器用（与镜头持续时间比较）。单位待实测。 |
| `Automation.GetRandomNumber(roof)` | `roof:number` | `randInt:number` | 返回随机整数。范围是 `[0, roof)` 还是 `[1, roof]` 待实测；源码只用来做小范围镜头缩放。 |
| `Automation.IsActive()` | 无 | `boolean` | Automation 是否激活；ActionPanel、IntroScreen、StagingRoom 等多个原版 UI 都会调用。 |
| `Automation.IsAutoStartEnabled()` | 无 | `boolean` | 是否自动开始；`LoadScreen.lua` 用它决定加载完成后自动点击开始。 |
| `Automation.IsPaused()` | 无 | `boolean` | 是否暂停。 |

### 3.2 写入与动作

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `Automation.SetSetParameter(paramSet, param, value)` | `paramSet:string`、`param:string`、`value:any` | 无 | 写入命名参数集的一个键。Companion 按 1/2/3 个参数拆成多行，Lua 实际调用为 3 参形式。 |
| `Automation.SetParameterSet(paramSet, params)` | `paramSet:string`、`params:table` | 无 | 用整张表覆盖命名参数集。测试框架用它把 `RunTests` 里的表项复制到 `CurrentTest`。 |
| `Automation.ClearParameterSet(paramSet)` | `paramSet:string` | 无 | 清空命名参数集。 |
| `Automation.SetLocalParameter(localParam, value)` | `localParam:string`、`value:any` | 无 | 写 Automation 本地参数。 |
| `Automation.SetActive(isActive)` | `isActive:boolean` | 无 | 开关 Automation；`AutomationComplete` 时关闭。 |
| `Automation.SetAutoStartEnabled(isEnabled)` | `isEnabled:boolean` | 无 | 开启自动开始，用于 Benchmark/Profile。 |
| `Automation.Pause(isPaused)` | `isPaused:boolean` | 无 | 暂停/恢复；`NarrationManager` 绑定空格键切换。 |
| `Automation.SendTestComplete()` | 无 | 无 | 测试主动报告完成。脚本注释强调**不要直接触发 `LuaEvents.AutomationTestComplete`**，由 Automation 系统在安全时机代发。 |
| `Automation.SetInputHandler(inputHandler)` | `inputHandler:function` | 无 | 注册 Automation 输入处理；`NarrationManager` 用来处理空格暂停。 |
| `Automation.RemoveInputHandler(inputHandler)` | `inputHandler:function` | 无 | 注销输入处理。 |
| `Automation.Log(message)` | `message:string` | 无 | 写 `Automation.log`，没有已知长度上限。 |
| `Automation.LogDivider()` | 无 | 无 | 写分隔线。 |
| `Automation.LogDateAndTime()` | 无 | 无 | Companion 中有，VanillaData 脚本未调用。 |

### 3.3 参数集语义

* **命名参数集**：`CurrentTest` 是当前测试的参数表；`RunTests` 是通过启动参数传入的测试列表（不是参数集，由 `GetStartupParameter` 读取）。
* **写入时机**：
  * `StoreCurrentTestParameters()` 先 `ClearParameterSet("CurrentTest")`；
  * 如果 `RunTests[i]` 是 table：`SetParameterSet("CurrentTest", testEntry)`；
  * 如果是字符串：`SetSetParameter("CurrentTest", "Test", testName)`。
* **本地参数**：`TestIndex`、`AutomationStarted`、`QuitApp` 都是 Auto 本地参数，不跟某个测试走，但脚本注释明确说它们比 Lua local 更可靠，因为 context 可能重载。

---

## 4. 测试框架接口

### 4.1 `Tests` 表契约

测试文件共同约定：

```lua
Tests = {};                 -- 全局表，键为测试名
Tests["MyTest"] = {};

Tests["MyTest"].Run = function()
    -- 必须：启动测试；通常最后调用 Automation.SendTestComplete()
end

Tests["MyTest"].Stop = function()
    -- 可选：清理 LuaEvents、Events、UserConfiguration、AutoplayManager
end

Tests["MyTest"].GameStarted = function()
    -- 可选：进入地图、UI 可见后调用
end

Tests["MyTest"].PostGameInitialization = function(bWasLoaded)
    -- 可选：游戏初始化完成、地形生成之前调用
end
```

### 4.2 内置测试

| 测试 | 定义文件 | 作用 |
|---|---|---|
| `Tests["QuitApp"]` | `Automation_StandardTestSupport.lua` | 通过本地参数 `QuitApp=true` 让框架在 `AutomationComplete` 时关闭应用。 |
| `Tests["QuitGame"]` | 同上 | 不在主菜单时返回主菜单，然后完成测试。 |
| `Tests["PauseGame"]` | 同上 | 对局内调用 `Automation.Pause(true)`。 |
| `Tests["PlayGame"]` | `Automation_StandardTests.lua` | 自动开新单机游戏并自动玩若干回合，结束后存档。 |
| `Tests["LoadGame"]` | 同上 | 读入上一次生成的存档并自动玩若干回合。 |
| `Tests["HostGame"]` | 同上 | 主机端开 LAN 多人游戏并自动玩若干回合。 |
| `Tests["JoinGame"]` | 同上 | 客户端搜索、加入 LAN 游戏并自动玩若干回合。 |
| `Tests["PlayGame"]` / `Tests["LoadGame"]` | `Automation_DailySmokeTest.lua` | 旧版精简套件，和 `StandardTests` **同名会互相覆盖**，不能在一个 context 内同时加载两个测试套件。 |

### 4.3 `Automation_StandardTestSupport.lua` 公共接口

| 函数 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `LookAtCapital(ePlayer)` | `ePlayer:number` | `boolean` | 把镜头移到该玩家首都；找不到返回 false。 |
| `GetCurrentTestObserver()` | 无 | `playerID / PlayerTypes.*` | 读 `CurrentTest.ObserveAs`，支持数字或 `"NONE"` / `"OBSERVER"`。 |
| `StartupObserverCamera(observeAs)` | playerID/`PlayerTypes.*` | 无 | 看观察者/指定玩家的首都或第一个单位。 |
| `GetCurrentTestHandler()` | 无 | `handlerTable, testName` | 根据 `RunTests` + 本地 `TestIndex` 找当前测试表。 |
| `StoreCurrentTestParameters()` | 无 | 无 | 把当前 `RunTests` 项写入 `CurrentTest` 参数集。 |
| `OnAutomationRunTest(option)` | `option:string?` | 无 | LuaEvents 处理：调用当前测试 `Run()`；`option == "Restart"` 时不重复记录/装载参数。 |
| `OnAutomationStopTest()` | 无 | 无 | 调用当前测试 `Stop()`。 |
| `OnAutomationGameStarted()` | 无 | 无 | 调用当前测试 `GameStarted()`。 |
| `OnAutomationPostGameInitialization(bWasLoad)` | `bWasLoad:boolean` | 无 | 调用当前测试 `PostGameInitialization(bWasLoad)`。 |
| `OnAutomationComplete()` | 无 | 无 | `SetActive(false)`；根据 `QuitApp` 本地参数决定退出应用或返回主菜单。 |
| `OnAutomationTestComplete()` | 无 | 无 | 递增 `TestIndex`，再 `LuaEvents.AutomationRunTest()`。 |
| `OnAutomationStart()` | 无 | 无 | 触发第一次 `LuaEvents.AutomationRunTest()`。 |
| `OnAutomationMainMenuStarted()` | 无 | 无 | 主菜单启动：首次发 `AutomationStart`，之后发 `AutomationRunTest("Restart")`。 |

### 4.4 测试生命周期

```text
C++/Automation 发 LuaEvents.AutomationMainMenuStarted()
        │
        ├─ 首次：读本地 AutomationStarted=false → 写 true → LuaEvents.AutomationStart()
        └─ 之后：LuaEvents.AutomationRunTest("Restart")

LuaEvents.AutomationStart()
        └─ OnAutomationStart() → LuaEvents.AutomationRunTest()

LuaEvents.AutomationRunTest(option?)
        ├─ GetCurrentTestHandler() + StoreCurrentTestParameters()
        └─ handler.Run()

游戏初始化/进入地图
        ├─ LuaEvents.AutomationPostGameInitialization(bWasLoad) → handler.PostGameInitialization()
        └─ LuaEvents.AutomationGameStarted()               → handler.GameStarted()

测试完成
        └─ Automation.SendTestComplete()
             └─ C++ 发 LuaEvents.AutomationTestComplete()
                  ├─ LuaEvents.AutomationStopTest()       → handler.Stop()
                  ├─ TestIndex = TestIndex + 1
                  └─ LuaEvents.AutomationRunTest()        → 下一个测试

没有更多测试
        └─ LuaEvents.AutomationComplete()
             └─ Automation.SetActive(false)
                  ├─ QuitApp == true → Events.UserConfirmedClose()
                  └─ 否则             → Events.ExitToMainMenu()
```

---

## 5. 各 Automation Lua 文件公开接口

### 5.1 `Automation_StandardTests.lua`

公开名字：

| 名字 | 说明 |
|---|---|
| `Tests` | 全局测试表；本文件定义 `PlayGame`、`LoadGame`、`HostGame`、`JoinGame`。 |
| `SharedGame_OnSaveComplete()` | `Events.SaveComplete` 处理：把测试标记完成。 |
| `SharedGame_OnAutoPlayEnd()` | `LuaEvents.AutoPlayEnd` 处理：用 `Automation.GenerateSaveName()` 存档，并等 `Events.SaveComplete`。 |
| `UpdatePlayerCounts()` | 按地图尺寸更新 `MapConfiguration.SetMaxMajorPlayers` 和 `GameConfiguration.SetParticipatingPlayerCount`。 |
| `GetTrueOrFalse(value)` | 把 `true/false/0/非0` 统一成 boolean。 |
| `ReadUserConfigOptions()` | 从 `CurrentTest` 读 `QuickMovement`、`QuickCombat`，锁进 `UserConfiguration`。 |
| `RestoreUserConfigOptions()` | 解除 QuickMovement/QuickCombat 锁定。 |
| `LoadGame_OnAutoPlayEnd()` | `LoadGame` 的自动播出结束处理。 |
| `JoinGame_OnGameListUpdated(...)` | LAN 游戏列表刷新：找到目标房间后 `Network.JoinGame`。 |
| `JoinGame_OnGameListComplete(...)` | 没找到目标房间时继续 `Matchmaking.RefreshGameList()`。 |
| `JoinGame_OnTurnEnd(iTurn)` | 递减 `CurrentTest.RemainingTurns`。 |
| `JoinGame_MultiplayerHostMigrated(newHostID)` | 读 `CurrentTest.QuitOnHostMigrate`，必要时完成测试。 |
| `LogCurrentPlayers()` | 用 `PlayerManager.GetAlive()` 把玩家 ID 和文明短名写入 Automation 日志。 |

每个测试的入口：

* `Tests["PlayGame"]`：`Run`、`PostGameInitialization`、`GameStarted`、`Stop`
* `Tests["LoadGame"]`：`Run`、`PostGameInitialization`、`GameStarted`、`Stop`
* `Tests["HostGame"]`：`Run`、`PostGameInitialization`、`GameStarted`、`Stop`
* `Tests["JoinGame"]`：`Run`、`PostGameInitialization`、`GameStarted`、`Stop`

主要依赖：`GameConfiguration`、`MapConfiguration`、`PlayerConfiguration`/`PlayerConfigurations`、`Network`、`Matchmaking`、`AutoplayManager`、`UserConfiguration`、`SaveLocations`/`SaveTypes`/`SaveDirectories`、`ServerType`、`LobbyTypes`、`TurnLimitTypes`、`SlotStatus`。

### 5.2 `Automation_DailySmokeTest.lua`

公开名字：

| 名字 | 说明 |
|---|---|
| `Tests` | 全局测试表；本文件重新赋值为 `{}`，只定义 `PlayGame`、`LoadGame`。 |
| `Turns` | 全局默认回合数，源码中为 `5`。 |
| `PlayGame_OnSaveComplete()` | 存档完成后 `Automation.SendTestComplete()`。 |
| `PlayGame_OnAutoPlayEnd()` | 自动播完调用 `Automation.GenerateSaveName()` 后存档。 |
| `UpdatePlayerCounts()` | 同标准套件。 |
| `GetTrueOrFalse(value)` | 同标准套件。 |
| `ReadUserConfigOptions()` / `RestoreUserConfigOptions()` | 同标准套件。 |
| `LoadGame_OnAutoPlayEnd()` | 读档流程的自动播结束。 |
| `LogCurrentPlayers()` | 日志输出存活玩家。 |

注意：本文件与 `Automation_StandardTests.lua` 同名全局函数和 `Tests = {}` 冲突，**不能同时 include**。

### 5.3 `Automation_NarrationManager.lua`

公开接口：

| 名字 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `CanSeePlot(x, y)` | 坐标 | boolean | 用本地观察者可见性判断。 |
| `IsEventEnabled(eventName)` | string | boolean | 读 `CurrentTest` 中 `NarrationEvent_<事件名>` 或 `NarrationEvent_All`。 |
| `SendPlayerNarrationMessage(messageText, player)` | string, playerID | 无 | 发一条带文明短名的单玩家播报。 |
| `SendPlayerPlayerNarrationMessage(messageText, player1, player2)` | string, playerID, playerID | 无 | 发一条双玩家播报。 |
| `OnWonderCompleted(x, y)` | 坐标 | 无 | 可见时播报 `NarrationEvent_WonderCompleted`。 |
| `OnDiplomacyDeclareWar(player1, player2)` | playerID, playerID | 无 | 播报宣战。 |
| `OnDiplomacyMakePeace(player1, player2)` | playerID, playerID | 无 | 播报和平。 |
| `OnDiplomacyRelationshipChanged(player1, player2)` | playerID, playerID | 无 | 当前空实现。 |
| `OnPlayerDefeat(player1, player2)` | playerID, playerID | 无 | 播报玩家被击败/被谁击败。 |
| `OnTeamVictory(team, victoryType)` | team, victoryType | 无 | 播报胜利；`NarrationPauseOnVictory` 为真时暂停并给“Done”按钮。 |
| `OnPlayerEraChanged(player, era)` | playerID, era | 无 | 播报进入新时代。 |
| `OnCityOccupationChanged(player, cityID)` | playerID, cityID | 无 | 当前空实现。 |
| `OnSpyMissionUpdated()` | 无 | 无 | 当前空实现。 |
| `OnUnitActivate(owner, unitID, x, y, eReason, bVisibleToLocalPlayer)` | 见签名 | 无 | 只在可见且 `eReason == EventSubTypes.FOUND_CITY` 时播报建城。 |
| `KeyHandler(key)` | key | boolean | 空格切换 `Automation.Pause`。 |
| `OnInputHandler(pInputStruct)` | input struct | boolean | 处理 KeyUp。 |
| `Initialize()` | 无 | 无 | 注册所有游戏事件 + `Automation.SetInputHandler`。 |
| `Uninitialize()` | 无 | 无 | `Automation.RemoveInputHandler`。 |
| `OnAutomationGameStarted()` | 无 | 无 | 调用 `Initialize()`。 |
| `OnAutomationGameEnded()` | 无 | 无 | 调用 `Uninitialize()`。 |

### 5.4 `Automation_NarrationPopup.lua`

公开接口：

| 名字 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `AddButton(data, text, callbackFunc, isHotkeyed)` | narration data, string, function, boolean | 无 | 按 `ShowPortrait` 选择按钮栈创建按钮。 |
| `OnPortraitTimerEnd()` / `OnMetaTimerEnd()` | 无 | 无 | 计时结束开始淡出。 |
| `OnPortraitPopupComplete(timeToDisplay)` / `OnBasePopupComplete(autoHide)` | 时间 | 无 | 淡出完成后关闭并处理下一条。 |
| `ShowNarrationPopup(narrationData)` | table | 无 | 显示播报弹窗；设置文本、图片、按钮、世界锚点，并 `UIManager:QueuePopup`。 |
| `Close()` | 无 | 无 | 关闭弹窗、释放 event ID、停止 advisor 语音。 |
| `OnDiploSceneClosed()` / `OnDiploSceneOpened()` | 无 | 无 | 记录外交场景是否打开，用于输入拦截判断。 |
| `UpdateQueue()` | 无 | 无 | 当前无弹窗时取队列下一条。 |
| `OnAddToNarrationQueue(item)` | table | 无 | LuaEvents 处理：入队并尝试出队。 |
| `OnAdvisorLower()` | 无 | 无 | 关闭弹窗。 |
| `OnInputActionTriggered(actionId)` | actionId | 无 | 处理 `AutomationTogglePause` 动作热键。 |
| `IsBlockingInput()` | 无 | boolean | 弹窗显示、外交场景未打开、且 `BlocksInput` 为真时拦截输入。 |
| `KeyHandler(key)` / `OnInputHandler(pInputStruct)` | 见签名 | boolean | 输入处理入口。 |
| `OnShutdown()` | 无 | 无 | 移除事件订阅、释放 event ID。 |
| `Initialize()` | 无 | 无 | 注册 UI/引擎/LuaEvents；文件底部会自动调用一次。 |

### 5.5 `Automation_ObserverCamera.lua`

全局定义：

* `hstructure Entry { hasVisited, player, id, x, y }`
* `hstructure Activity { started, tracking, lingering, type, startTime, duration, x, y }`
* `VisitActivity`：全局枚举表，值为 `None=0`、`Unit=1`、`City=2`、`Plot=3`、`Combat=4`、`Wonder=5`、`District=6`。

公开接口：

| 名字 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `AddToList(objects, player, id)` | table, player, id | entry | 去重添加可见城市条目。 |
| `RemoveFromList(objects, player, id)` | table, player, id | 无 | 移除。 |
| `CanSeePlot(x, y)` | 坐标 | boolean | 本地观察者可见性判断。 |
| `CurrentActivityPercentComplete()` | 无 | number | 当前活动完成百分比；无活动/无时长返回 100。 |
| `CurrentActivityElapsed()` | 无 | number | 当前活动已过时间。 |
| `ClearCurrentActivity()` | 无 | 无 | 重置当前活动。 |
| `Initialize()` | 无 | 无 | 重置状态，读 `Force3DView`、`UseView`、`View*MinTime/MaxTime`、`GameSeed`。 |
| `Uninitialize()` | 无 | 无 | 关闭标记并清空可见城市。 |
| `ClearVisitedFlag(objects)` | table | 无 | 清所有 `hasVisited`。 |
| `ClearVisitedFlagForPlayer(objects, player)` | table, player | 无 | 按玩家清。 |
| `GetEntryForPlayer(objects, player, id)` | table, player, id | entry | 查条目。 |
| `GetClosestUnvisited(objects, x, y)` | table, 坐标 | entry | 找最近未访问；都访问过则先清标记。 |
| `PickBestCity()` | 无 | 无 | 选最近未访问城市作为当前活动。 |
| `PickBestUnit()` | 无 | 无 | 当前空实现。 |
| `PickViewType()` | 无 | 无 | 按 `View*MinTime/MaxTime` 在 3D/2D 间切换。 |
| `PickBestActivity()` | 无 | 无 | 先选城市，没有就等待 5 秒。 |
| `StartCurrentActivity()` | 无 | 无 | 调用活动类型对应 `ActivityHandlers`。 |
| `CheckActivityComplete()` | 无 | 无 | 每帧更新：切视角、完成活动、选新活动。 |
| `OnCityVisibilityChanged(...)` | 引擎事件参数 | 无 | 维护可见城市列表。 |
| `OnPlayerTurnActivated(player, bFirstTime)` | 玩家, bool | 无 | 按概率打断当前活动去看玩家首都。 |
| `OnCombatVisBegin(combatMembers)` / `OnCombatVisEnd(attacker)` | 引擎事件参数 | 无 | 战斗镜头打断/停留。 |
| `OnUnitActivate(...)` | 引擎事件参数 | 无 | 建城时看新城。 |
| `OnWonderCompleted(x, y)` | 坐标 | 无 | 看到奇迹完成。 |
| `OnDistrictBuildProgressChanged(...)` / `OnDistrictPillaged(...)` | 引擎事件参数 | 无 | 区域完成/被劫掠时看区域。 |
| `OnAutomationAppUpdateComplete()` | 无 | 无 | Automation 每帧/更新回调，未暂停时 `CheckActivityComplete()`。 |
| `OnAutomationGameStarted()` / `OnAutomationGameEnded()` | 无 | 无 | 初始化/反初始化。 |

### 5.6 `Automation_BenchmarkCamera.lua` 和 `Automation_BenchmarkCamera_Capitals.lua`

两个文件结构相同，后者额外只跟踪主要文明首都。公开接口：

| 名字 | 说明 |
|---|---|
| `hstructure Entry { player, id, x, y }` | 可见城市条目。 |
| `AddToList(objects, player, id)` / `RemoveFromList(...)` / `GetEntryForPlayer(...)` | 列表维护。 |
| `OnCityVisibilityChanged(player, id, eVisibility)` | 维护可见城市；Capitals 版本只收主要文明首都。 |
| `OnPlayerTurnActivated(player, bFirstTime)` | 回合开始看自己的首都。 |
| `OnCombatVisBegin(combatMembers)` | 战斗开始看攻击方。 |
| `OnAutomationGameStarted()` | 看本地观察者/玩家首都。 |
| `OnBenchmarkStart()` / `OnBenchmarkEnd()` | 保存并恢复环境光动画速度。 |
| `OnBenchmarkToggleLookAt()` | 轮换看可见城市。 |

这两个文件与 `Automation_ObserverCamera.lua` 都定义 `AddToList`、`RemoveFromList`、`GetEntryForPlayer`、`CanSeePlot`（部分文件）等**同名全局函数**，不可在同一 context 中混用。

### 5.7 `Automation_Profile.lua`

公开接口：

| 名字 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `SetSummaryFile(strFileName)` | 文件名 | 无 | `AutoProfiler.SetFilePath("C:\\Temp\\" .. name)`。 |
| `ResetView()` | 无 | 无 | 清 AssetPreview 的 Landmark/Unit 系统。 |
| `ForEachPassableLandHex(fnPerHex)` | callback(x,y) | 可通过比例 | 遍历非海、可通行地块并调用回调。 |
| `ForEachHex(fnPerHex)` | callback(x,y) | `1.0` | 遍历整张地图。 |
| `City_BuildTestList(tTestList)` | table | 无 | 生成每个文明/时代的 `SpoofCityAt` 跑分项。 |
| `District_BuildTestList(tTestList)` | table | 无 | 生成区域状态（Construction/Worked/Pillaged）跑分项。 |
| `Building_BuildTestList(tTestList)` | table | 无 | 生成区域建筑跑分项。 |
| `Landmark_BuildTestList(tTestList)` | table | 无 | 生成地标/资源跑分项。 |
| `Unit_BuildTestList(tTestList)` | table | 无 | 生成单位/文化跑分项。 |
| `OnGameLoad()` | 无 | 无 | `AutomationGameStarted` 处理：配置 AutoProfiler，生成测试列表并启动。 |
| `OnBenchmarkFinished()` | 无 | 无 | `AutoProfilerBenchmarkFinished` 处理：跑下一个测试。 |
| `OnMainMenu()` | 无 | 无 | `AutomationMainMenuStarted` 处理：加载 `./Empty Map.Civ6Save`，随后解绑自己。 |

---

## 6. LuaEvents 接口

| 事件 | 参数 | 原版发布/订阅 | 说明 |
|---|---|---|---|
| `LuaEvents.AutomationMainMenuStarted` | 无 | C++ → 测试支持/Profile | 主菜单启动；测试框架据此开始或重启，Profile 据此加载跑分存档。 |
| `LuaEvents.AutomationStart` | 无 | 测试支持 | 请求开始整套测试。 |
| `LuaEvents.AutomationRunTest(option)` | `option:string?`（`"Restart"`） | 测试支持 | 运行当前测试。`"Restart"` 只跑 `Run()`，不再重复记录参数。 |
| `LuaEvents.AutomationStopTest` | 无 | 测试支持 | 请求调用当前测试 `Stop()`。 |
| `LuaEvents.AutomationTestComplete` | 无 | C++ → 测试支持 | 当前测试完成；递增 `TestIndex` 并跑下一个。 |
| `LuaEvents.AutomationPostGameInitialization(bWasLoad)` | boolean | C++ → 测试支持 | 游戏初始化完成但地形尚未生成。 |
| `LuaEvents.AutomationGameStarted` | 无 | C++ → 测试支持/Narration/Observer/Benchmark/Profile | 进入地图且 UI 可见。 |
| `LuaEvents.AutomationGameEnded` | 无 | C++ → Narration/Observer | 清理事件注册和输入。 |
| `LuaEvents.AutomationAppUpdateComplete` | 无 | C++ → ObserverCamera | Automation 每次 App 更新轮询。 |
| `LuaEvents.AutomationComplete` | 无 | C++ → 测试支持 | 所有测试结束；关闭 Automation 并退出/回主菜单。 |
| `LuaEvents.AutoPlayEnd` | 无 | AutoplayManager 或 C++ → StandardTests/DailySmoke | 自动播出结束；测试据此存档或完成。 |
| `LuaEvents.AutoProfilerBenchmarkFinished` | 无 | AutoProfiler → Profile | 当前资产跑分结束，启动下一个。 |
| `LuaEvents.Automation_AddToNarrationQueue(item)` | `item:table` | NarrationManager → NarrationPopup | 播报消息入队。 |
| `LuaEvents.DiploScene_SceneOpened` / `DiploScene_SceneClosed` | 无 | 外交场景 → NarrationPopup | 供弹窗判断输入拦截。 |

---

## 7. 游戏 `Events.*` 注册表

| 事件 | 处理函数（文件） | 用途 |
|---|---|---|
| `Events.CityVisibilityChanged` | `OnCityVisibilityChanged`（Observer / Benchmark / Benchmark_Capitals） | 维护可见城市列表。 |
| `Events.PlayerTurnActivated` | `OnPlayerTurnActivated`（Observer / Benchmark / Benchmark_Capitals） | 回合开始看首都。 |
| `Events.CombatVisBegin` | `OnCombatVisBegin`（Observer / Benchmark / Benchmark_Capitals） | 战斗镜头。 |
| `Events.CombatVisEnd` | `OnCombatVisEnd`（Observer） | 战斗后停留。 |
| `Events.UnitActivate` | `OnUnitActivate`（Observer / NarrationManager） | 建城/单位激活。 |
| `Events.WonderCompleted` | `OnWonderCompleted`（Observer / NarrationManager） | 奇迹完成。 |
| `Events.DistrictBuildProgressChanged` / `Events.DistrictPillaged` | `OnDistrictBuildProgressChanged` / `OnDistrictPillaged`（Observer） | 区域完成/被劫掠。 |
| `Events.SaveComplete` | `SharedGame_OnSaveComplete` / `PlayGame_OnSaveComplete`（StandardTests / DailySmoke） | 自动化存档完成。 |
| `Events.MultiplayerGameListUpdated` / `MultiplayerGameListComplete` | `JoinGame_OnGameListUpdated` / `JoinGame_OnGameListComplete`（StandardTests） | LAN 搜索/加入。 |
| `Events.MultiplayerHostMigrated` | `JoinGame_MultiplayerHostMigrated`（StandardTests） | 主机迁移。 |
| `Events.TurnEnd` | `JoinGame_OnTurnEnd`（StandardTests） | 递减剩余回合。 |
| `Events.InputActionTriggered` | `OnInputActionTriggered`（NarrationPopup） | 暂停动作热键。 |
| `Events.WonderCompleted` / `DiplomacyDeclareWar` / `DiplomacyMakePeace` / `DiplomacyRelationshipChanged` / `PlayerDefeat` / `PlayerEraChanged` / `TeamVictory` / `CityOccupationChanged` / `SpyMissionUpdated` / `UnitActivate` | NarrationManager 的 `On*` | 播报系统。 |
| `Events.BenchmarkStart` / `Events.BenchmarkEnd` / `Events.BenchmarkToggleLookAt` | BenchmarkCamera / Capitals | 跑分镜头开关与轮换。 |

另外这些脚本会**调用但不注册**：

* `Events.ExitToMainMenu()`：测试需要回主菜单时。
* `Events.UserConfirmedClose()`：`QuitApp` 测试真正退出应用时。

---

## 8. Narration 消息结构

`LuaEvents.Automation_AddToNarrationQueue(item)` 的 `item` 字段（源码注释 + `ShowNarrationPopup` 实际读取）：

| 字段 | 类型 | 必需 | 说明 |
|---|---|---|---|
| `Message` | string | 是 | 已 `Locale.Lookup` 的正文。 |
| `MessageAudio` | string | 否 | 播放的语音/音效名。 |
| `Image` | string | 否 | 贴图名。 |
| `OptionsNum` | number | 否 | 注释中存在，当前代码未实际使用。 |
| `Button1Text` / `Button2Text` | string | 否 | 有按钮文字才创建按钮。 |
| `Button1Func` / `Button2Func` | function(data) | 否 | 按钮回调；`Button1` 同时支持热键。 |
| `CalloutHeader` / `CalloutBody` | string | 否 | 世界锚点 callout。 |
| `PlotCallback` | function -> plotID | 否 | 返回需要锚定的地块 ID。 |
| `ShowPortrait` | boolean | 否 | true 用 advisor 头像气泡；false/无则用 meta 弹窗。 |
| `DisplayTime` | number | 否 | 自动关闭时间；无按钮时默认 2.5 秒。 |
| `BlocksInput` | boolean | 否 | 为 true 时弹窗期间拦截输入。 |
| `Title` | string | 否 | 弹窗标题；代码中额外支持。 |
| `ReferenceEvent` | boolean/number | 否 | 为真时 `UI.ReferenceCurrentEvent()` 阻止后续事件处理。 |

---

## 9. Automation 参数键

### 9.1 启动参数（`Automation.GetStartupParameter`）

| 键 | 类型 | 说明 |
|---|---|---|
| `RunTests` | table | 测试列表。元素可以是测试名字符串，也可以是带 `Test` 键的 table；table 项会被整体复制到 `CurrentTest`。 |

### 9.2 `CurrentTest` 参数集（`Automation.GetSetParameter / SetSetParameter`）

| 类别 | 键 | 说明 |
|---|---|---|
| 通用 | `Test` | 当前测试名（当 `RunTests` 项是字符串时写入）。 |
| 观察 | `ObserveAs` | `0`、`"NONE"`、`"OBSERVER"` 或玩家 ID。 |
| 开新游戏 | `RuleSet`、`MapScript`、`Handicap`/`Difficulty`、`MapSize`、`GameSpeed`、`MapSeed`、`GameSeed`、`StartEra`、`MaxTurns` | 传给 `GameConfiguration` / `MapConfiguration`。 |
| 回合 | `Turns` | 自动播回合数；PlayGame 默认 5/15，LoadGame 默认 1。 |
| 存档 | `SaveName`、`SaveDirectory` | LoadGame 指定存档；不填用 `Automation.GetLastGeneratedSaveName()`。 |
| 多人 | `GameName`、`SaveFile`、`MinPlayers`、`QuitOnHostMigrate` | HostGame/JoinGame 逻辑；`MinPlayers` 由 `StagingRoom.lua` 消费。 |
| 断点续测 | `HasLaunched`、`RemainingTurns` | LoadGame 防止重复启动；JoinGame 在 host migrate/resync 后继续。 |
| 性能 | `QuickMovement`、`QuickCombat` | 锁定 `UserConfiguration`。 |
| 播报 | `NarrationEvent_All`、`NarrationEvent_*`、`NarrationPauseOnVictory` | 控制 NarrationManager。 |
| 镜头 | `Force3DView`、`UseView`、`View2DMinTime`/`ViewStrategicMinTime`、`View2DMaxTime`/`ViewStrategicMaxTime`、`View3DMinTime`/`ViewWorldMinTime`、`View3DMaxTime`/`ViewWorldMaxTime`、`GameSeed` | 控制 ObserverCamera 视角和时长。 |

### 9.3 Automation 本地参数（`Automation.GetLocalParameter / SetLocalParameter`）

| 键 | 默认 | 说明 |
|---|---|---|
| `TestIndex` | `1` | 当前测试序号；跨 context 重载保存。 |
| `AutomationStarted` | `false` | 是否已经发过 `AutomationStart`。 |
| `QuitApp` | `false` | 所有测试结束后是否退出应用。 |

---

## 10. 集成/复用注意事项

1. **不要直接把 Automation 脚本 include 进 Mod Misc Tool 的现有 context**。它们大量使用全局函数名，和游戏 UI、其他 mod 的全局函数很容易冲突。
2. **优先封装 `Automation` 全局对象**。第 3 节的方法名、参数顺序、返回类型已交叉核对；封装时保持原名风格，只加 `ModMiscTool` 命名空间。
3. **`Automation` 的测试框架需要 UI context**。`Automation_StandardTests.lua` 里的 `UI.IsInFrontEnd`、`ContextPtr`、`Controls`、`UIManager`、`Matchmaking`、`Network` 都依赖 UI/前端环境；不要试图在 Gameplay 层直接跑整套测试。
4. **参数集是跨 context 状态通道**。如果要支持自定义测试，使用 `CurrentTest` / 本地参数，不要用 Lua local。
5. **`Tests` 是全局单例表**。`Automation_StandardTests.lua`、`Automation_DailySmokeTest.lua`、`Automation_StandardTestSupport.lua` 都会写 `Tests`；加载两个测试套件时后者会覆盖前者。
6. **三个镜头脚本同名全局最严重**：`BenchmarkCamera`、`BenchmarkCamera_Capitals`、`ObserverCamera` 都定义 `AddToList` / `RemoveFromList` / `GetEntryForPlayer` / `CanSeePlot` 等；只允许按用途加载一个。
7. **NarrationPopup 必须配 XML**：`Automation_NarrationPopup.lua` 依赖 `ContextPtr`、`Controls.AdvisorBase`、`Controls.MetaBase`、`InstanceManager`，应由 `InGame.xml` 中同 ID 的 `LuaContext` 加载。
8. **`Automation_NarrationManager` 注册输入处理器后必须注销**。它用 `Automation.SetInputHandler`，`Uninitialize` 里只 `RemoveInputHandler`，没有移除游戏 `Events.*` 订阅；重用时留意重复注册。
9. **`Automation.SendTestComplete()` 不要在测试外直接发**。它只是通知 Automation 系统，真正 LuaEvent 由 C++ 在安全时机发。
10. **版本差异**：VanillaData 的 `Automation_StandardTests.lua` 没有当前安装版新增的 `LUA`/多人大厅增强、`ApplyHumanPlayersToConfiguration`、`GetTestLobbyType`、`GetTestServerType`、`Automation.GetParameterSet` 等；封装前按目标游戏版本再整理一次。

---

## 11. 待实测/待确认

| # | 项目 | 当前判断 | 建议验证方式 |
|---|---|---|---|
| 1 | `Automation.GetRandomNumber(roof)` 的范围 | Companion 只写 `roof` / `randInt`，未写开闭区间 | 打印 1..roof 各值分布。 |
| 2 | `Automation.GetTime()` 单位 | Companion 写 `unixTimeStamp`，源码又当活动时长比较 | 打印相邻帧差值，确认秒/毫秒。 |
| 3 | `Automation.GetSetParameter` 第三个默认参数 | 源码已用，Companion 模型未完整列出 | UI context 中调 `GetSetParameter("CurrentTest", "NotExist", 123)`，确认返回 123。 |
| 4 | `Automation` 对象在 Gameplay context 是否同样可用 | Companion 标 Gameplay/UI 均有；本组脚本未验证 Gameplay | Gameplay Lua 打印 `type(Automation)` 并尝试 `IsActive()`。 |
| 5 | `Automation.GetParameterSet` 在 VanillaData 是否可用 | Companion 有，但 VanillaData 没用 | UI context 中调用并打印类型；当前安装版已使用，风险低。 |
| 6 | `Automation.IsAutoStartEnabled` / `SetAutoStartEnabled` 在前端的读取时机 | `LoadScreen.lua` 和 Profile 有使用 | 结合自动开始流程实机验证。 |
| 7 | `Events.MultiplayerHostMigrated` 重订阅行为 | `StandardTests` 在 `GameStarted` 里重新注册 | 实机多人局触发 host migration。 |
| 8 | `Automation_NarrationManager` 重复 Initialize 是否导致重复事件 | `Initialize` 没有先移除旧 Events | 连续两次调用 `Initialize()`，观察事件是否双触发。 |

---

## 12. 如果要把 Automation 接入 Mod Misc Tool 的建议分层

* **第 1 层：低层 `AutomationAPI`**
  * 只封装第 3 节的 `Automation.*` 方法，放在 UI context。
  * 参数集读写、暂停、日志、`IsActive`、`IsAutoStartEnabled`、输入处理器。
* **第 2 层：测试框架 `AutomationTestAPI`**
  * 封装 `Tests` 注册、`GetCurrentTestHandler`、`StoreCurrentTestParameters`。
  * 自定义测试不要直接覆盖全局 `Tests`；通过 `RunTests` 传入，或在自己的命名空间中维护测试表。
* **第 3 层：观察/播报可选模块**
  * `ObserverCamera`、`NarrationManager`、`NarrationPopup` 分别用独立 context 加载，不并入主 UI context。
* **暴露给其他 mod 时**：只暴露第 1、2 层，并沿用 Mod Misc Tool 的 `ExposedMembers.ModMiscToolUI.*` / `LuaEvents.ModMiscTool*` 风格加自己的前缀；不要暴露原始全局函数。
