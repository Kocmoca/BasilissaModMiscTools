# Civ6 Automation 系 Lua：高价值可复用接口

> 来源：`VanillaData/Base/UI/Automation/*.lua`
>
> 补充证据：
> * `Civ6PC/Debug/Autoplay.ltp`：AutoplayManager 的完整配置面板，可确认 `SetTurns(-1) = No limit`、`GetObserveAsPlayer / GetReturnAsPlayer` 无参读回。
> * `Civ VI Modding Companion 2.0.xlsx` 的 `Objects` 工作表：接口名、参数类型、返回类型。
> * `Civ6PC/Base/Assets/UI/Automation/*.lua`：当前安装版对照。
>
> 这份文档只挑“能拿来做工具/自动化/观察/存档/资产预览”的接口，不重复上一份全量清单。

---

## 0. 优先级总表

| 能力 | 核心接口 | 出现位置 | 用途 |
|---|---|---|---|
| 自动玩 / AI 对局 | `AutoplayManager.SetTurns` / `SetReturnAsPlayer` / `SetObserveAsPlayer` / `SetActive` | `Automation_StandardTests.lua`、`Automation_DailySmokeTest.lua` | 让引擎自动推回合，观察 AI，最后把控制权交回指定玩家。 |
| 观察者 / 玩家视角 | 同上 `SetObserveAsPlayer` / `SetReturnAsPlayer` | 同上 | `SetObserveAsPlayer` 切观察谁；`SetReturnAsPlayer` 决定自动播完后回到谁。 |
| 镜头 / 2D·3D 视角 | `UI.LookAtPlot`、`UI.SetWorldRenderView`、`UI.GetMapLookAtWorldTarget`、`UI.GetPlotCoordFromWorld` | `Automation_ObserverCamera.lua`、`Automation_BenchmarkCamera*.lua` | 定位地块、切 3D/2D 战略视图、自动巡游城市/战斗/奇迹。 |
| 存档 / 读档 | `Network.SaveGame`、`Network.LoadGame` | `Automation_StandardTests.lua`、`Automation_DailySmokeTest.lua`、`Automation_Profile.lua` | 自动存档、读固定测试图、读档继续自动播。 |
| 开图 / 联机 | `Network.HostGame`、`Network.JoinGame`、`Matchmaking.*` | `Automation_StandardTests.lua` | 程序化 host/join，跑多人自动测试。 |
| 程序化开新游戏 | `GameConfiguration.*`、`MapConfiguration.*` | `Automation_StandardTests.lua`、`Automation_DailySmokeTest.lua` | 规则集、地图脚本、难度、速度、种子、时代、回合上限、AI 槽位。 |
| 资产预览 / 跑分 | `AssetPreview.*`、`AutoProfiler.*` | `Automation_Profile.lua` | 在城市、区域、建筑、地标、单位上批量 spoof 资产，输出 CSV。 |
| 输入热键 | `Automation.SetInputHandler`、`Input.GetActionId`、`Events.InputActionTriggered` | `Automation_NarrationManager.lua`、`Automation_NarrationPopup.lua` | 空格暂停自动化；Action 热键。 |
| 事件/弹窗阻塞 | `UI.ReferenceCurrentEvent`、`UI.ReleaseEventID` | `Automation_NarrationPopup.lua` | 播报弹窗期间参考并阻止后续事件处理。 |
| 运行时参数 | `Automation.GetSetParameter`、`SetSetParameter`、`GetLocalParameter`、`SetLocalParameter` | 所有测试文件 | 跨 Lua context 重载保存测试参数和状态。 |

---

## 1. AutoplayManager：观察者视角 / 玩家视角 / 自动玩

### 1.1 接口签名

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `AutoplayManager.SetTurns(turnsActive :number)` | `-1` 或正数 | 无 | 自动播回合数；`-1` 表示 **No limit**（来自 `Debug/Autoplay.ltp`）。 |
| `AutoplayManager.GetTurns()` | 无 | `number` | 读当前自动播回合数。 |
| `AutoplayManager.SetObserveAsPlayer(observeAs :number)` | `PlayerTypes.NONE`、`PlayerTypes.OBSERVER` 或玩家 ID | 无 | **切换观察者看到谁/以什么身份观察**。 |
| `AutoplayManager.GetObserveAsPlayer()` | 无 | `PlayerTypes / playerID` | 读当前观察对象。 |
| `AutoplayManager.SetReturnAsPlayer(playerID :number)` | 玩家 ID | 无 | 自动播结束后把控制权/视角交回哪个玩家。测试里统一传 `0`。 |
| `AutoplayManager.GetReturnAsPlayer()` | 无 | `playerID :number` | 读当前返回玩家。 |
| `AutoplayManager.SetActive(isActive :boolean)` | boolean | 无 | 启动/停止自动播。 |
| `AutoplayManager.IsActive()` | 无 | boolean | 自动播是否正在运行。 |
| `AutoplayManager.SetDisableAssertsForAutoplay(value :number)` | 0/1 或 boolean | 无 | 自动播时禁用断言；调试 Tuner 中使用。 |
| `AutoplayManager.GetDisableAssertsForAutoplay()` | 无 | 0/1 或 boolean | 读取当前设置。 |

### 1.2 观察者 / 玩家视角的实际调用方式

`Automation_StandardTests.lua` 每个测试的 `PostGameInitialization` 都是同一套：

```lua
local observeAs = GetCurrentTestObserver()

AutoplayManager.SetTurns(turnCount)
AutoplayManager.SetReturnAsPlayer(0)
AutoplayManager.SetObserveAsPlayer(observeAs)
AutoplayManager.SetActive(true)
```

其中 `GetCurrentTestObserver()` 来自 `Automation_StandardTestSupport.lua`：

```lua
local observeAs = Automation.GetSetParameter("CurrentTest", "ObserveAs", 0)
if observeAs == "OBSERVER" then observeAs = PlayerTypes.OBSERVER end
if observeAs == "NONE" then observeAs = PlayerTypes.NONE end
```

因此：

* **观察者视角**：`SetObserveAsPlayer(PlayerTypes.OBSERVER)`
* **不观察任何玩家**：`SetObserveAsPlayer(PlayerTypes.NONE)`
* **观察某个玩家**：`SetObserveAsPlayer(playerID)`
* **自动播结束后回到玩家 0**：`SetReturnAsPlayer(0)`
* **无限自动播**：`SetTurns(-1)`
* **停止自动播**：`AutoplayManager.SetActive(false)`；`Automation_NarrationManager.lua` 在胜利暂停时也是用它停自动播。

推荐顺序：

```lua
-- 1. 先停，避免运行中改观察对象
AutoplayManager.SetActive(false)

-- 2. 配置自动播
AutoplayManager.SetTurns(-1)                         -- No limit
AutoplayManager.SetObserveAsPlayer(PlayerTypes.OBSERVER)
AutoplayManager.SetReturnAsPlayer(0)

-- 3. 启动
AutoplayManager.SetActive(true)

-- 4. 停止
AutoplayManager.SetActive(false)
```

> 注意：原版测试是在 `PostGameInitialization` 里调用，此时游戏已经初始化、还未开始正常回合。用在你自己的工具里也建议等到游戏加载完成后再启动自动播。

---

## 2. UI 镜头 / 视角切换

### 2.1 接口签名

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `UI.LookAtPlot(x :number, y :number [, zoom :number])` | 地图坐标、可选缩放 | 无 | 把镜头定位到地块。原版 Automation 中 zoom 用过 `0.95`、`0.2~0.7` 等。 |
| `UI.SetWorldRenderView(view :WorldRenderView)` | `WorldRenderView.VIEW_3D` / `VIEW_2D` | 无 | 切换 3D 世界视图和 2D 战略视图。 |
| `UI.GetWorldRenderView()` | 无 | `WorldRenderView` | 读当前视图。 |
| `UI.GetMapLookAtWorldTarget()` | 无 | `worldX, worldY` | 读当前镜头对准的世界坐标。 |
| `UI.GetPlotCoordFromWorld(worldX, worldY)` | 世界坐标 | `x, y` | 世界坐标转地图坐标。 |
| `UI.GridToWorld(mapX, mapY)` | 地图坐标 | `worldX, worldY, worldZ` | 地图坐标转世界坐标，用于 `WorldAnchor` 等 UI。 |
| `UI.GetAmbientTimeOfDaySpeed()` / `UI.SetAmbientTimeOfDaySpeed(speed)` | number | number / 无 | 环境光动画速度。 |
| `UI.IsAmbientTimeOfDayAnimating()` / `UI.SetAmbientTimeOfDayAnimating(bool)` | boolean | boolean / 无 | 环境光动画开关。 |
| `UI.PlaySound(soundName :string)` | 音效名 | 无 | 播放 UI 音效。 |
| `Game.GetLocalObserver()` | 无 | playerID | 本地观察者 ID。 |
| `Game.GetLocalPlayer()` | 无 | playerID | 本地玩家 ID。 |
| `PlayerVisibilityManager.GetPlayerVisibility(playerID)` | 玩家 ID | visibility object | 返回对象可调 `:IsVisible(x, y)`。 |

### 2.2 自动镜头巡游的做法

`Automation_ObserverCamera.lua` 实际逻辑：

1. 监听 `CityVisibilityChanged`，维护可见城市列表。
2. `PickBestCity()` 用当前镜头世界坐标找最近未访问城市。
3. `ActivityHandlers[VisitActivity.City].Start`：

```lua
local iValue = Automation.GetRandomNumber(4)
local zoom = 0.3 + (iValue * 0.1)
UI.LookAtPlot(activity.x, activity.y, zoom)
```

4. `PickViewType()` 随机在 3D / 2D 间切换：

```lua
UI.SetWorldRenderView(WorldRenderView.VIEW_2D)
UI.PlaySound("Set_View_2D")

UI.SetWorldRenderView(WorldRenderView.VIEW_3D)
UI.PlaySound("Set_View_3D")
```

5. `PickBestCity()` 读当前镜头位置：

```lua
wx, wy = UI.GetMapLookAtWorldTarget()
x, y = UI.GetPlotCoordFromWorld(wx, wy)
```

### 2.3 可用地块可见性判断

```lua
function CanSeePlot(x, y)
    local pPlayerVis = PlayerVisibilityManager.GetPlayerVisibility(Game.GetLocalObserver())
    if pPlayerVis ~= nil then
        return pPlayerVis:IsVisible(x, y)
    end
    return false
end
```

这个模式适合做“只在观察者/本地玩家可见时展示”的提示或镜头。

---

## 3. Network：存档 / 读档 / 联机

### 3.1 接口签名

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `Network.SaveGame(saveGame :table)` | 存档描述表 | 脚本未使用 | 异步保存；完成后触发 `Events.SaveComplete`。 |
| `Network.LoadGame(save :table / string, serverType :ServerType)` | 存档描述表或路径、服务器类型 | `success :boolean` | 失败可用于提前结束测试；成功通常意味着 Lua context 会重建。 |
| `Network.HostGame(serverType :ServerType)` | `ServerType.SERVER_TYPE_NONE` / `SERVER_TYPE_LAN` | 脚本未使用 | 程序化主机。 |
| `Network.JoinGame(serverID :number)` | 服务器 ID | `success :boolean, pending :boolean` | 来自 `Lobby.lua` 的实际用法。 |
| `Network.LeaveGame()` | 无 | 无 | 离开当前会话。 |
| `Network.GetGameConfigurationSaveType()` | 无 | `SaveTypes.*` | 当前游戏配置对应的存档类型。 |
| `Network.IsGameHost()` | 无 | boolean | 是否主机。 |

相关枚举：

* `SaveLocations.LOCAL_STORAGE`
* `SaveTypes.SINGLE_PLAYER` / `SaveTypes.NETWORK_MULTIPLAYER`
* `SaveDirectories.DEFAULT`
* `ServerType.SERVER_TYPE_NONE` / `ServerType.SERVER_TYPE_LAN`
* `LobbyTypes.LOBBY_LAN`

### 3.2 存档：`Network.SaveGame`

`Automation_StandardTests.lua` / `Automation_DailySmokeTest.lua` 的用法：

```lua
local saveGame = {}
saveGame.Name = Automation.GenerateSaveName()
saveGame.Location = SaveLocations.LOCAL_STORAGE
saveGame.Type = SaveTypes.SINGLE_PLAYER
saveGame.IsAutosave = false
saveGame.IsQuicksave = false

Network.SaveGame(saveGame)

-- 保存不是立即完成，等事件
Events.SaveComplete.Add(function()
    Automation.SendTestComplete()
end)
```

注意：

* `Network.SaveGame` 后不要立即读同一存档；测试代码会等 `Events.SaveComplete`。
* `Automation.GenerateSaveName()` 生成的存档名可用 `Automation.GetLastGeneratedSaveName()` 读回。

### 3.3 读档：`Network.LoadGame`

表形式（单机）：

```lua
local loadGame = {}
loadGame.Location = SaveLocations.LOCAL_STORAGE
loadGame.Type = SaveTypes.SINGLE_PLAYER
loadGame.IsAutosave = false
loadGame.IsQuicksave = false
loadGame.Directory = SaveDirectories.DEFAULT
loadGame.Name = Automation.GetSetParameter("CurrentTest", "SaveName")
    or Automation.GetLastGeneratedSaveName()

local bResult = Network.LoadGame(loadGame, ServerType.SERVER_TYPE_NONE)
if bResult == false then
    -- 立即失败，可以做错误处理
end
```

路径形式（`Automation_Profile.lua`）：

```lua
Network.LoadGame("./Empty Map.Civ6Save", ServerType.SERVER_TYPE_NONE)
```

多人存档/主机：

```lua
local saveFileTable = {
    Name = saveFileName,
    Type = SaveTypes.NETWORK_MULTIPLAYER,
}
Network.LoadGame(saveFileTable, ServerType.SERVER_TYPE_LAN)

-- 或者直接开 LAN
Network.HostGame(ServerType.SERVER_TYPE_LAN)
```

自动继续加载页：

```lua
Automation.SetAutoStartEnabled(true)
Network.LoadGame(save, ServerType.SERVER_TYPE_NONE)
```

`Automation_Profile.lua` 在 `OnMainMenu()` 里先 `Automation.SetAutoStartEnabled(true)` 再读档，就是利用这个机制让加载完成后自动开始。

### 3.4 LAN 搜索 / 加入

`Automation_StandardTests.lua` 的 `Tests["JoinGame"]`：

```lua
Matchmaking.InitLobby(LobbyTypes.LOBBY_LAN)
Matchmaking.RefreshGameList()

Events.MultiplayerGameListUpdated.Add(JoinGame_OnGameListUpdated)
Events.MultiplayerGameListComplete.Add(JoinGame_OnGameListComplete)

-- 事件：更新搜索结果
function JoinGame_OnGameListUpdated(eAction, idLobby, eLobbyType, eSearchType)
    if eLobbyType ~= LobbyTypes.LOBBY_LAN then return end
    if eAction ~= 3 then return end  -- 新增项

    local serverTable = Matchmaking.GetGameListEntry(idLobby)
    if serverTable ~= nil then
        local serverEntry = serverTable[1]
        if serverEntry.serverName == targetGameName then
            Network.JoinGame(serverEntry.serverID)
        end
    end
end

-- 事件：列表搜索完成
function JoinGame_OnGameListComplete(eLobbyType, eSearchType)
    if eLobbyType ~= LobbyTypes.LOBBY_LAN then return end
    Matchmaking.RefreshGameList()  -- 没找到就继续刷
end
```

配套事件：

* `Events.MultiplayerGameListUpdated(eAction, idLobby, eLobbyType, eSearchType)`
* `Events.MultiplayerGameListComplete(eLobbyType, eSearchType)`
* `Events.MultiplayerHostMigrated(newHostID)`
* `Events.TurnEnd(iTurn)`
* `Events.SaveComplete()`

> `Network.LoadGame` 成功后会触发加载状态切换；不要假设 `Network.LoadGame` 返回后当前 Lua 栈一定还能继续执行原上下文。这也是原版测试把状态写进 Automation 参数集的原因。

---

## 4. AssetPreview：资产预览 / Spooff 测试

`Automation_Profile.lua` 用 `AssetPreview` 在跑分地图上批量显示资产，并且用 `AutoProfiler` 输出 CSV。

### 4.1 清场 / 枚举

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `AssetPreview.ClearLandmarkSystem()` | 无 | 无 | 清掉所有地标预览。 |
| `AssetPreview.ClearUnitSystem()` | 无 | 无 | 清掉所有单位预览。 |
| `AssetPreview.ClearLandmarkAt(x, y)` | 地块坐标 | 无 | 清单个地标。 |
| `AssetPreview.DestroyAll()` | 无 | 无 | 清所有预览实例。 |
| `AssetPreview.GetDistrictCount()` | 无 | number | 区域数量。 |
| `AssetPreview.GetDistrictName(index)` | number | string | 区域名。 |
| `AssetPreview.GetDistrictBaseList(index)` | number | table | 区域基底列表；每项含 `civ, era, appeal, index, hasbldgs` 等。 |
| `AssetPreview.GetDistrictBuildingList(index)` | number | table | 区域建筑列表；每项含 `civ, era, appeal, bldg, bldgname`。 |
| `AssetPreview.GetLandmarkCount()` | 无 | number | 地标数量。 |
| `AssetPreview.GetLandmarkName(index)` | number | string | 地标名。 |
| `AssetPreview.GetLandmarkAssetList(index)` | number | table | 地标资产列表；每项含 `civ, era, appeal, variant, resources`。 |
| `AssetPreview.GetUnitList()` | 无 | table | 单位列表；每项含 `hash, cultures`。 |
| `AssetPreview.MakeHash(text)` | string | number | 文本转 hash，单位/资源列表里常用。 |

### 4.2 Spoof 放置

| 方法 | 参数 | 说明 |
|---|---|---|
| `AssetPreview.SpoofCityAt(x, y, civIndex, eraIndex, population)` | 城市 | 在城市地格放置城市资产。原版对每个文明/时代调用；第 5 参数固定传 `22`，含义按调试面板推测为人口/规模。 |
| `AssetPreview.SpoofDistrictBaseAt(x, y, civ, era, appeal, population, state, districtIndex, variant)` | 区域基底 | 区域状态常见 `"Construction"` / `"Worked"` / `"Pillaged"`。 |
| `AssetPreview.SpoofBuildingAt(x, y, civ, era, appeal, state, districtIndex, buildingHash)` | 区域建筑 | 建筑状态常见 `"Worked"` / `"Pillaged"`。 |
| `AssetPreview.SpoofLandmarkAt(x, y, civ, era, appeal, resourceHash, state, landmarkIndex, variant)` | 地标 | 状态常见 `"Worked"` / `"Unworked"` / `"Pillaged"`。 |
| `AssetPreview.SpoofUnitAt(x, y, cultureHash, unitHash)` | 单位 | 按文化/单位 hash 放置。 |
| `AssetPreview.SpoofCityCivAt(...)` | 城市/文明 | 另一个城市预览接口；Companion 中存在，Automation_Profile 未调用。 |
| `AssetPreview.CreateDistrictAt(...)` / `CreateBuildingAt(...)` | 预览实例 | 创建类接口；Automation_Profile 未直接使用。 |

### 4.3 典型工作流

```lua
local function ResetView()
    AssetPreview.ClearLandmarkSystem()
    AssetPreview.ClearUnitSystem()
end

ResetView()

local fillRatio = ForEachPassableLandHex(function(x, y)
    AssetPreview.SpoofCityAt(x, y, civ.Index, GameInfo.Eras[eraType].Index, 22)  -- 第5参原版固定 22
end)

AutoProfiler.AddColumn(tostring(fillRatio))
```

区域示例：

```lua
local nDistricts = AssetPreview.GetDistrictCount()
for districtIndex = 0, nDistricts - 1 do
    local districtName = AssetPreview.GetDistrictName(districtIndex)
    local baseList = AssetPreview.GetDistrictBaseList(districtIndex)

    for _, props in pairs(baseList) do
        AssetPreview.SpoofDistrictBaseAt(
            x, y,
            props.civ, props.era, props.appeal,
            0,                  -- population（原版 Profile 传 0；调试面板用 Population 控件）
            "Worked",           -- state
            districtIndex,
            props.index
        )
    end
end
```

注意：

* `AssetPreview` 是 UI 层对象（Companion 标注 UI only），不要放到 Gameplay Lua 里调用。
* 这些 `Spoof*` 接口会实际生成预览资产，应该在 benchmark/preview 或调试环境用；正常对局中慎用。
* 第 5 个参数等具体含义部分来自原版调用，不是完整公开文档；以实测为准。

---

## 5. AutoProfiler：自动跑分 / CSV 输出

### 5.1 接口

| 方法 | 参数 | 说明 |
|---|---|---|
| `AutoProfiler.SetFilePath(filePath)` | string | 设置 CSV 输出路径。 |
| `AutoProfiler.AddColumn(summaryColumnName)` | string | 给当前测试行添加一列。 |
| `AutoProfiler.SetTestName(testName)` | string | 设置当前测试名。 |
| `AutoProfiler.Start()` | 无 | 开始当前测试。 |
| `AutoProfiler.SetLookAtCount(count)` | number | 镜头采样次数。 |
| `AutoProfiler.SetLookAtFrames(frames)` | number | 每个采样保持/渲染帧数。 |
| `AutoProfiler.SetCameraZoom(zoom)` | number | 跑分镜头缩放。 |
| `AutoProfiler.SetGPUStallThreshold(threshold)` | number | GPU stall 阈值。 |
| `AutoProfiler.SetWaitForTerrain(bool)` | boolean | 是否等地形加载。 |
| `AutoProfiler.SetWaitForLandmarks(bool)` | boolean | 是否等地标资源加载。 |
| `AutoProfiler.RunCommand(command)` | string | 和 `UI.DebugCommand` 相同，执行调试命令。 |
| `AutoProfiler.IsIdle()` | 无 | 是否空闲。 |
| `AutoProfiler.GetStateString()` | 无 | 当前状态字符串。 |
| `AutoProfiler.GetTimeRemaining()` | 无 | 剩余时间。 |
| `AutoProfiler.GetTestName()` | 无 | 当前测试名。 |
| `AutoProfiler.GetLookAtCount()` / `GetLookAtFrames()` / `GetCameraZoom()` / `GetGPUStallThreshold()` / `GetWaitForTerrain()` / `GetWaitForLandmarks()` | 无 | 读取配置。 |

### 5.2 原版跑分流程

`Automation_Profile.lua`：

```lua
function OnGameLoad()
    Automation.SetAutoStartEnabled(true)

    AutoProfiler.SetLookAtCount(20)
    AutoProfiler.SetLookAtFrames(100)
    AutoProfiler.SetCameraZoom(1)
    AutoProfiler.SetGPUStallThreshold(1)
    AutoProfiler.SetWaitForTerrain(false)

    AutoProfiler.RunCommand("toggle vfx")
    AutoProfiler.RunCommand("toggle clutter")
    AutoProfiler.RunCommand("toggle terrain update")
    AutoProfiler.RunCommand("toggle ui")

    -- 生成测试列表，然后启动第一个
    OnBenchmarkFinished()
end

function OnBenchmarkFinished()
    local test = m_TestList[m_CurrentTestIndex]
    if test then
        m_CurrentTestIndex = m_CurrentTestIndex + 1
        test.prepare()                 -- 这里调用 AssetPreview.Spoof...
        AutoProfiler.SetTestName(test.name)
        AutoProfiler.Start()
    end
end

LuaEvents.AutoProfilerBenchmarkFinished.Add(OnBenchmarkFinished)
```

`AutoProfiler` 的切换是事件驱动的：一个测试完成后触发 `LuaEvents.AutoProfilerBenchmarkFinished`，回调里放下一个。

---

## 6. 程序化开新游戏：GameConfiguration / MapConfiguration

`Automation_StandardTests.lua` 的 `Tests["PlayGame"].Run` 展示了一整套“无 UI 手动点选”的开局流程。

### 6.1 常用接口

| 对象 | 方法 | 说明 |
|---|---|---|
| `GameConfiguration` | `SetToDefaults()` | 重置为默认配置。 |
| `GameConfiguration` | `SetRuleSet(ruleSet)` | 规则集。 |
| `GameConfiguration` | `SetHandicapType(handicap)` | 难度。 |
| `GameConfiguration` | `SetGameSpeedType(gameSpeed)` | 游戏速度。 |
| `GameConfiguration` | `SetStartEra(startEra)` | 开始时代。 |
| `GameConfiguration` | `SetMaxTurns(maxTurns)` | 分数胜利回合上限。 |
| `GameConfiguration` | `SetTurnLimitType(TurnLimitTypes.CUSTOM)` | 设置回合限制类型。 |
| `GameConfiguration` | `SetValue(key, value)` | 通用配置，例如 `"GAME_SYNC_RANDOM_SEED"`。 |
| `GameConfiguration` | `GetHumanPlayerIDs()` | 获取人类槽位。 |
| `GameConfiguration` | `SetParticipatingPlayerCount(n)` | 参与玩家数。 |
| `GameConfiguration` | `GetHiddenPlayerCount()` | 隐藏玩家数。 |
| `GameConfiguration` | `GetStartEra()` | 当前开始时代。 |
| `GameConfiguration` | `GetTeamName(team)` | 队伍名。 |
| `MapConfiguration` | `SetScript(mapScript)` | 地图脚本。 |
| `MapConfiguration` | `SetMapSize(mapSize)` | 地图尺寸。 |
| `MapConfiguration` | `SetMaxMajorPlayers(n)` | 最大主要文明数。 |
| `MapConfiguration` | `SetValue(key, value)` | 通用地图配置，如 `"RANDOM_SEED"`。 |
| `MapConfiguration` | `GetMapSize()` | 当前地图尺寸。 |
| `PlayerConfiguration[id]` | `SetSlotStatus(SlotStatus.SS_COMPUTER)` | 把人类槽位转 AI。VanillaData 用单数 `PlayerConfiguration`；当前安装版部分写法已改成 `PlayerConfigurations[id]`，移植时注意。 |
| `UserConfiguration` | `SetLockedValue(userConfig, isLocked)` / `LockValue(userConfig, isLocked)` | 锁定快速移动/快速战斗等配置。 |

### 6.2 开局流程

```lua
GameConfiguration.SetToDefaults()

local ruleSet = Automation.GetSetParameter("CurrentTest", "RuleSet")
if ruleSet ~= nil then GameConfiguration.SetRuleSet(ruleSet) end

local mapScript = Automation.GetSetParameter("CurrentTest", "MapScript")
if mapScript ~= nil then
    MapConfiguration.SetScript(mapScript)
    UpdatePlayerCounts()
end

local difficulty = Automation.GetSetParameter("CurrentTest", "Handicap")
    or Automation.GetSetParameter("CurrentTest", "Difficulty")
if difficulty ~= nil then GameConfiguration.SetHandicapType(difficulty) end

local mapSize = Automation.GetSetParameter("CurrentTest", "MapSize")
if mapSize ~= nil then
    MapConfiguration.SetMapSize(mapSize)
    UpdatePlayerCounts()
end

local gameSpeed = Automation.GetSetParameter("CurrentTest", "GameSpeed")
if gameSpeed ~= nil then GameConfiguration.SetGameSpeedType(gameSpeed) end

-- 人类槽位转 AI
for _, id in ipairs(GameConfiguration.GetHumanPlayerIDs()) do
    PlayerConfiguration[id].SetSlotStatus(SlotStatus.SS_COMPUTER)
end

-- 种子/时代/最大回合
local mapSeed = Automation.GetSetParameter("CurrentTest", "MapSeed")
if mapSeed ~= nil then MapConfiguration.SetValue("RANDOM_SEED", mapSeed) end

local gameSeed = Automation.GetSetParameter("CurrentTest", "GameSeed")
if gameSeed ~= nil then GameConfiguration.SetValue("GAME_SYNC_RANDOM_SEED", gameSeed) end

local startEra = Automation.GetSetParameter("CurrentTest", "StartEra")
if startEra ~= nil then GameConfiguration.SetStartEra(startEra) end

local maxTurns = Automation.GetSetParameter("CurrentTest", "MaxTurns")
if maxTurns ~= nil and maxTurns >= 1 then
    GameConfiguration.SetMaxTurns(maxTurns)
    GameConfiguration.SetTurnLimitType(TurnLimitTypes.CUSTOM)
end

Network.HostGame(ServerType.SERVER_TYPE_NONE)
```

这套接口适合做：

* 一键开自定义测试局；
* AI vs AI 自动跑图；
* 固定地图/固定种子复现；
* 自动加满玩家或降成少数 AI。

---

## 7. 运行时辅助：参数、输入、事件阻塞

### 7.1 Automation 参数

```lua
-- 读 CurrentTest 参数，带默认值
local turns = Automation.GetSetParameter("CurrentTest", "Turns", 5)

-- 写 CurrentTest 参数
Automation.SetSetParameter("CurrentTest", "HasLaunched", 1)

-- 整表替换
Automation.SetParameterSet("CurrentTest", { Test = "PlayGame", Turns = 20 })

-- 跨 context 本地参数
local index = Automation.GetLocalParameter("TestIndex", 1)
Automation.SetLocalParameter("TestIndex", index + 1)
```

这些参数在 C++ 侧，不随 Lua context 重载丢失，适合存测试进度。

### 7.2 输入处理

`Automation_NarrationManager.lua`：

```lua
function KeyHandler(key)
    if key == Keys.VK_SPACE then
        Automation.Pause(not Automation.IsPaused())
        return true
    end
    return false
end

function OnInputHandler(pInputStruct)
    local uiMsg = pInputStruct:GetMessageType()
    if uiMsg == KeyEvents.KeyUp then
        return KeyHandler(pInputStruct:GetKey())
    end
    return false
end

Automation.SetInputHandler(OnInputHandler)

-- 退出时
Automation.RemoveInputHandler(OnInputHandler)
```

Action 热键则用 `Input.GetActionId("AutomationTogglePause")` + `Events.InputActionTriggered`。

### 7.3 阻止后续事件处理

`Automation_NarrationPopup.lua` 在显示弹窗时：

```lua
if narrationData.ReferenceEvent then
    ms_eventID = UI.ReferenceCurrentEvent()
end

-- 关闭时
UI.ReleaseEventID(ms_eventID)
```

适合做“有重要弹窗时，抢占当前 UI 事件，避免底下的 UI 继续响应”的场景。

---

## 8. 最推荐接入 Mod Misc Tool 的几条线

1. **观察者/自动玩**
   * `AutoplayManager.SetTurns/SetObserveAsPlayer/SetReturnAsPlayer/SetActive`
   * 配合 `Game.GetLocalObserver()`、`PlayerManager.GetAlive()`、`UI.LookAtPlot`
   * 可以做成“进入 AI 观察模式 / 切到某玩家视角 / 自动跑 N 回合”。
2. **存档/读档/自动继续**
   * `Network.SaveGame` + `Events.SaveComplete`
   * `Network.LoadGame` + `Automation.SetAutoStartEnabled(true)`
   * 可以做成“一键存测试档/一键读测试档并自动继续”。
3. **镜头巡检**
   * `UI.LookAtPlot`、`UI.SetWorldRenderView` 以及 ObserverCamera 的活动调度思路。
   * 可以做成“自动巡游所有可见城市/战斗/奇迹”的 debug 工具。
4. **资产预览/跑分**
   * `AssetPreview.*` + `AutoProfiler.*`
   * 适合独立 debug 工具，不建议混进正常玩法逻辑。

---

## 9. 调用位置速查

| 主题 | 文件 | 行号 |
|---|---|---|
| AutoplayManager 启动自动播 | `Automation_StandardTests.lua` | 195-199、306-310、448-452、533-537 |
| 自动播停止 | 同上 | 227、479、571 |
| Network.SaveGame | 同上 | 31 |
| Network.LoadGame | 同上 | 277、426 |
| Network.HostGame | 同上 | 176、429 |
| Network.JoinGame | 同上 | 605 |
| Matchmaking 搜索/加入 | 同上 | 511-512、589、620 |
| UI.LookAtPlot / 3D-2D 切换 | `Automation_ObserverCamera.lua` | 164-212、246-250、381-382、412-417 |
| UI.LookAtPlot 跑分 | `Automation_BenchmarkCamera*.lua` | 86-105、158-163 等 |
| AssetPreview / AutoProfiler | `Automation_Profile.lua` | 6-211、241-253 |
| 输入处理 | `Automation_NarrationManager.lua` | 192-235 |
| ReferenceEvent / ReleaseEventID | `Automation_NarrationPopup.lua` | 242-246、265-279 |
| AutoplayManager Getter/Setter 参考 | `Civ6PC/Debug/Autoplay.ltp` | 25-63、100-111、145-160、179-211 |

---

## 10. 测试面板实际调用方法（`UI/AutomationTestPanel.lua`）

### 10.1 视角切换：AutoplayManager

按钮“切到选中玩家视角”：

```lua
local returnAs = Game.GetLocalPlayer()
if returnAs == nil or returnAs < 0 then returnAs = 0 end

AutoplayManager.SetActive(false)
AutoplayManager.SetTurns(m_SelectedTurns)          -- -1 = No limit
AutoplayManager.SetReturnAsPlayer(returnAs)
AutoplayManager.SetObserveAsPlayer(m_SelectedPlayerIndex) -- PlayerTypes.OBSERVER / NONE / playerID
AutoplayManager.SetActive(true)
```

按钮“观察者模式”：

```lua
AutoplayManager.SetActive(false)
AutoplayManager.SetTurns(m_SelectedTurns)
AutoplayManager.SetReturnAsPlayer(Game.GetLocalPlayer())
AutoplayManager.SetObserveAsPlayer(PlayerTypes.OBSERVER)
AutoplayManager.SetActive(true)
```

按钮“停止并回本地玩家”：

```lua
AutoplayManager.SetActive(false)
AutoplayManager.SetObserveAsPlayer(Game.GetLocalPlayer())
AutoplayManager.SetReturnAsPlayer(Game.GetLocalPlayer())
```

面板同时读回测试：

```lua
AutoplayManager.IsActive()
AutoplayManager.GetObserveAsPlayer()
AutoplayManager.GetReturnAsPlayer()
AutoplayManager.GetTurns()
```

因此可以验证：

* 任意玩家是否可选：玩家选择器会遍历 `Players[0..MAX_PLAYERS-1]`。
* 能否切到对方的视角：观察对象传给 `SetObserveAsPlayer(playerID)`。
* 能否切到观察者模式：观察对象传 `PlayerTypes.OBSERVER`。
* 自动播完后回到哪个玩家：`SetReturnAsPlayer(playerID)`。
* 不限回合观察：`SetTurns(-1)`。

### 10.2 游戏内存档 / 读档

面板固定使用一个测试槽位：

```lua
local SAVE_NAME = "ModMiscAutomationTest"
```

后台存档：

```lua
local saveGame = {
    Name = SAVE_NAME,
    Location = SaveLocations.LOCAL_STORAGE,
    Type = Network.GetGameConfigurationSaveType(), -- 失败则退回 SaveTypes.SINGLE_PLAYER
    IsAutosave = false,
    IsQuicksave = false,
    Directory = SaveDirectories.DEFAULT,
}

Events.SaveComplete.Add(OnSaveComplete)
Network.SaveGame(saveGame)
```

`OnSaveComplete` 里再 `Events.SaveComplete.Remove(OnSaveComplete)`，并把结果写到提示信息窗。

后台读档：

```lua
local loadGame = {
    Name = SAVE_NAME,
    Location = SaveLocations.LOCAL_STORAGE,
    Type = SaveTypes.SINGLE_PLAYER,
    IsAutosave = false,
    IsQuicksave = false,
    Directory = SaveDirectories.DEFAULT,
}

-- 与 LoadGameMenu.OnLoadYes 相同：先 LeaveGame，再 LoadGame
Network.LeaveGame()
Network.LoadGame(loadGame, ServerType.SERVER_TYPE_NONE)
```

可验证：

* 对局中 `Network.SaveGame` 是否真的完成（等 `Events.SaveComplete`）。
* 对局中 `Network.LeaveGame + Network.LoadGame` 是否能读回。
* 读档成功后 Lua context 会重建，状态是否通过 Automation 参数 / CustomData 找回。

### 10.3 CustomData 跨存档探针

面板提供三个按钮：

1. “写入 CustomData 探针”
```lua
local payload = string.format("t=%d;turn=%d;r=%d", os.time(), Game.GetCurrentGameTurn(), math.random(100000, 999999))
WriteCustomData("ModMiscAutomationCrossSaveProbe", payload)
Automation.SetLocalParameter("ModMiscAutomationProbePayload", payload)
```

2. “写探针并存档”
```lua
WriteCustomData("ModMiscAutomationCrossSaveProbe", payload)
SaveGameToFixedSlot()
```

3. “读取 CustomData 探针”
```lua
local payload = ReadCustomData("ModMiscAutomationCrossSaveProbe")
local localPayload = Automation.GetLocalParameter("ModMiscAutomationProbePayload")
-- 面板同时显示 payload / localPayload / match
```

读档后 `OnLoadGameViewStateDone` 会自动再读一次并输出：

```lua
ReadCustomData("ModMiscAutomationCrossSaveProbe")
```

判定方式：

* 存档前写入 payload；
* 后台存档；
* 后台读档（或从主菜单读档）；
* 读档后读同一个 key；
* 如果读回来的 payload 和存档前一致，说明 CustomData 确实随存档/读档走，可以拿来做真跨存档传递。

### 10.4 AssetPreview 选择、放置、清除

资产分类：

* `CITY`
* `DISTRICT_BASE`
* `BUILDING`
* `LANDMARK`
* `UNIT`

资产列表由 `AssetPreview` 的只读接口得到：

```lua
AssetPreview.GetDistrictCount()
AssetPreview.GetDistrictName(i)
AssetPreview.GetDistrictBaseList(i)
AssetPreview.GetDistrictBuildingList(i)
AssetPreview.GetLandmarkCount()
AssetPreview.GetLandmarkName(i)
AssetPreview.GetLandmarkAssetList(i)
AssetPreview.GetUnitList()
```

放置按钮先让玩家在地图上选地块，再按分类调用：

```lua
AssetPreview.SpoofCityAt(x, y, civIndex, eraIndex, 22)

AssetPreview.SpoofDistrictBaseAt(x, y,
    props.civ, props.era, props.appeal,
    0, "Worked", districtIndex, props.index)

AssetPreview.SpoofBuildingAt(x, y,
    props.civ, props.era, props.appeal,
    "Worked", districtIndex, buildingHash)

AssetPreview.SpoofLandmarkAt(x, y,
    props.civ, props.era, props.appeal,
    resourceHash, "Worked", landmarkIndex, props.variant)

AssetPreview.SpoofUnitAt(x, y, cultureHash, unitHash)
```

清除按钮测试：

```lua
AssetPreview.ClearLandmarkAt(x, y)  -- 清指定地块
AssetPreview.DestroyAt(x, y)        -- 如果当前版本存在
AssetPreview.ClearLandmarkSystem() -- 清所有地标
AssetPreview.ClearUnitSystem()     -- 清所有单位
AssetPreview.DestroyAll()          -- 清所有预览实例
```

可验证：

* 能否从列表里选特定 Asset；
* 能否放到指定地块；
* 能否主动清掉指定地块 / 全部资产；
* `AssetPreview` 的调用是否只在 UI/benchmark 环境可用。

### 10.5 前端环境存档/读档结论

* **前端读档**：原版已经这样做。`Base/UI/FrontEnd/MainMenu.lua` 和 `Base/UI/FrontEnd/LoadGameMenu.lua`
  都在主菜单/加载菜单直接调用 `Network.LoadGame(...)`，所以“进入游戏场景前的前端环境读档”本身是可用的。
* **前端存档**：原版前端没有找到 `Network.SaveGame(...)` 的调用；存档依赖对局状态，主要应在对局中做。
* **后台静默**：`MainMenu.lua` / `LoadGameMenu.lua` 的 `Network.LoadGame` 都不经手动确认存档选择，只要给出存档描述表或路径即可；对局内 `Network.SaveGame` 完成后由 `Events.SaveComplete` 通知。
* **真跨存档**：如果面板测试里 `WriteCustomData -> Network.SaveGame -> Network.LoadGame -> ReadCustomData` 能读回同一个 payload，就可以用 CustomData 作为跨存档数据通道；否则仍应改用 `Game:SetProperty` 或存档描述表字段。
