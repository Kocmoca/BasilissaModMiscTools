include("ModTool_Support_Functions.lua")
include("ModTool_Support_UI.lua")
include("Civ6Common")   -- ReadCustomData：读取创建游戏时保存的城邦数量
include("ModMiscStore") -- 跨存档存储（存档名编码通道）
include("ModMiscAssetStore") -- 永久资产放置（读档自动重放）
include("ModMiscCreateGame") -- 对局内「创建新局 / 换地图」验证（开局探针 + 面板入口）
include("ModMiscTurnEra") -- 回合数 / 年代 探查与试写（开局探针 + 面板入口）
include("ModMiscSaveGraph") -- 存档关系树（主线/分支）+ 换图存档（成品功能）
print("[ModMiscTool] Support_UI loaded build=" .. tostring(MODMISC_BUILD_TAG))

local allUnitPromotions = {}

function InitializeAllUnitPromotions()
	for promotionRow in GameInfo.UnitPromotions() do
		local promotionType = promotionRow.UnitPromotionType
		local promotionClass = promotionRow.PromotionClass
		if allUnitPromotions[promotionClass] == nil then
			allUnitPromotions[promotionClass] = {}
		end
		table.insert(allUnitPromotions[promotionClass], promotionType)
	end
end

function GetExperienceAndPromotionsUI(playerID, unitID)
	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil then
		return nil, nil
	end
	local unitExp = unit:GetExperience()
	if unitExp == nil then
		return nil, nil
	end
	local expPoint = unitExp:GetExperiencePoints()
	local promotions = {}
	local promoClass = GameInfo.Units[unit:GetType()].PromotionClass
	local potentialPromo = allUnitPromotions[promoClass]
	if potentialPromo == nil then
		return 0, {}
	end
	for _, promo in ipairs(potentialPromo) do
		local promoIndex = GameInfo.UnitPromotions[promo].Index
		if unitExp:HasPromotion(promoIndex) then
			table.insert(promotions, promoIndex)
		end
	end
	if promotions == nil then
		print("error, failed to get promotions")
	end
	return expPoint, promotions
end

function GetPlayerAllianceType(playerID, subPlayerID)
	local player = Players[playerID]
	if player == nil then
		return nil
	end
	local playerDiplomacy = player:GetDiplomacy()
	local allianceType = playerDiplomacy:GetAllianceType(subPlayerID)
	if allianceType == -1 then
		return nil
	end
	local allianceRow = GameInfo.Alliances[allianceType]
	if allianceRow == nil then
		return nil
	end
	return allianceRow.AllianceType
end


------------------------------------------------------------------------------
-- 通用收支账本 provider
------------------------------------------------------------------------------

local m_LedgerProvider = nil

function RegisterLedgerProvider(provider)
if provider == nil then return false end
m_LedgerProvider = provider
return true
end

function GetLedgerProvider()
return m_LedgerProvider
end

function GetLedgerSummary(playerID)
if m_LedgerProvider == nil or m_LedgerProvider.getSummary == nil then
return nil
end
return m_LedgerProvider.getSummary(playerID)
end

function GetLedgerItems(playerID, filter)
if m_LedgerProvider == nil or m_LedgerProvider.getItems == nil then
return {}
end
return m_LedgerProvider.getItems(playerID, filter)
end

function GetLocalLedgerSummary()
local localPlayerID = Game.GetLocalPlayer()
if localPlayerID == nil or localPlayerID == -1 then return nil end
return GetLedgerSummary(localPlayerID)
end

function GetLocalLedgerItems(filter)
local localPlayerID = Game.GetLocalPlayer()
if localPlayerID == nil or localPlayerID == -1 then return {} end
return GetLedgerItems(localPlayerID, filter)
end

function LedgerProviderAvailable()
return m_LedgerProvider ~= nil
end


-- ===========================================================================
-- 幽灵玩家池（开局交接）
--
-- 创建游戏界面（见 UI/Replacements/Civ6Common.lua 的前端 hook）会把城邦数量拉满，
-- 并用 WriteCustomData 存下玩家原本选择的数量；这里把它读出来交给 gameplay 侧，
-- 由 ModTool_GhostPlayers.lua 把多出来的城邦搬到地图外当幽灵玩家。
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 城邦玩家判断：IsMinor() 只有 UI 端有（gameplay 侧会报 function expected
-- instead of nil），因此由 UI 端提供，gameplay 侧通过 ExposedMembers 调用。
-- ---------------------------------------------------------------------------

function IsMinorPlayerUI(playerID)
    local player = Players[playerID]
    if player == nil then return false end
    return player:IsMinor() == true
end

-- 还没有首都的城邦玩家（新开局里它们手上只有开拓者）→ 幽灵池候选
function GetUnsettledCityStatePlayerIDsUI()
    local playerIDs = {}
    for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
        local player = Players[playerID]
        if player ~= nil and player:IsMinor() and not player:IsBarbarian() then
            local cities = player:GetCities()
            if cities == nil or cities:GetCapitalCity() == nil then
                table.insert(playerIDs, playerID)
            end
        end
    end
    return playerIDs
end

-- 文件加载阶段就暴露，保证 gameplay 侧随时能拿到
if not ExposedMembers.ModMiscToolUI then
    ExposedMembers.ModMiscToolUI = {}
end
ExposedMembers.ModMiscToolUI.IsMinorPlayerUI = IsMinorPlayerUI
ExposedMembers.ModMiscToolUI.GetUnsettledCityStatePlayerIDsUI = GetUnsettledCityStatePlayerIDsUI
local GHOST_CITY_STATE_CUSTOM_DATA_KEY = "ModMiscToolCityStateCount"
local GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY = "ModMiscToolMajorPlayerCount"
-- 前端 hook 没记下数量时的兜底：按标准图默认的城邦数量保留在图上，多出来的当幽灵
local GHOST_FALLBACK_KEEP_CITY_STATES = 12
-- 前端 hook 没记下人数时的兜底：按“1 个玩家”算边界
local GHOST_FALLBACK_KEEP_MAJOR_PLAYERS = 1
-- 当前幽灵 pass 挂在哪个事件上。改挂时机时**这一行和文件末尾的注册一起改**，
-- 日志里会打出来，方便定位“这次跑的是哪种时机”。
local GHOST_PASS_TRIGGER_NAME = "LoadGameViewStateDone"
local m_GhostInitDone = false

local function HandOffGhostCityStateCount()
    if m_GhostInitDone then return end
    m_GhostInitDone = true

    local script = ExposedMembers.ModMiscToolScript
    if script == nil or script.InitializeGhostPlayers == nil then return end

    local savedCount = tonumber(ReadCustomData(GHOST_CITY_STATE_CUSTOM_DATA_KEY))
    if savedCount == nil or savedCount <= 0 then
        savedCount = GHOST_FALLBACK_KEEP_CITY_STATES
        print("[ModMiscTool][Ghost] no saved city state count, fallback keep="
            .. tostring(savedCount))
    else
        print("[ModMiscTool][Ghost] handing off saved city state count=" .. tostring(savedCount))
    end
    -- 玩家设定的主要文明人数：用来算槽位边界（边界之后的城邦槽位全部变幽灵）
    local savedMajors = tonumber(ReadCustomData(GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY))
    if savedMajors == nil or savedMajors <= 0 then
        savedMajors = GHOST_FALLBACK_KEEP_MAJOR_PLAYERS
        print("[ModMiscTool][Ghost] no saved major player count, fallback majors="
            .. tostring(savedMajors))
    else
        print("[ModMiscTool][Ghost] handing off configured major players=" .. tostring(savedMajors))
    end

    -- 一次判定搞定：id 大于 (主要文明数 + 城邦数 - 1) 的城邦槽位全部搬成幽灵
    print("[ModMiscTool][Ghost] pass start trigger=" .. GHOST_PASS_TRIGGER_NAME
        .. " keepMajors=" .. tostring(savedMajors)
        .. " keepCityStates=" .. tostring(savedCount))
    script.InitializeGhostPlayers(savedCount, savedMajors)
end

-- ===========================================================================
-- 【时机】当前**仍挂在 LoadGameViewStateDone**（授权者要求先按现状测一轮再调）
--
-- 背景：授权者确认，加载失败是**加入幽灵机制之后**才出现的 ⇒ 问题出在这套机制。
-- 可疑点之一是**时机** —— LoadGameViewStateDone 是加载过渡阶段，本项目此前就在
-- 同一个事件上踩过坑（循环给 20+ 玩家换领袖/文明 → 开局直接挂，日志停在
-- `LoadScreen: OnLoadGameViewStateDone`）。而幽灵 pass 要在这一个事件里对 ~50 个
-- 玩家各做一次 InitUnit + Kill(×3)，同一量级的操作压在同一个时刻，小概率挂掉说得通。
--
-- 【改法已备好，两行一起改】测完要调时：
--     GHOST_PASS_TRIGGER_NAME = "LocalPlayerTurnBegin"        （上面的常量，只影响日志）
--     Events.LocalPlayerTurnBegin.Add(HandOffGhostCityStateCount)   （文件末尾的注册）
-- LocalPlayerTurnBegin（第 1 回合本地玩家回合开始）时开局已完成、AI 还没动、
-- 城邦手里还是开拓者尚未建城 —— 搬家逻辑完全等价，但不再压在加载过渡上。
-- 另一个可疑点（场上玩家过多、出生位置重叠）已由 GhostPlayers_MapSizes.sql
-- 按地图尺寸分档压过一轮。
--
-- 注意：一旦改挂 LocalPlayerTurnBegin，其他 mod 若在 LoadGameViewStateDone 就要用
-- 幽灵池会拿到空池 —— 需要就改在 LocalPlayerTurnBegin 之后取，或先自己调
-- ModMiscToolScript.InitializeGhostPlayers。
-- ===========================================================================
Events.LoadGameViewStateDone.Add(HandOffGhostCityStateCount)

-- ===========================================================================
-- WriteCustomData / ReadCustomData 跨存档探针
--
-- 协议：启动函数（Initialize，每次进入游戏一次）先读；读不到就写一份 run=1；
-- 下次进游戏若读到上次写的那份，就说明数据真的跨了存档。结果只打日志，不做 UI。
--
-- [部分可用] 实测结论：同进程有效、跨启动无效 ——
--   两次完整退出进程后的新局日志都是 VERDICT=first-write（prev=nil），
--   说明 CustomData 只是进程内的 game parameters，没落盘。
--   仍待验证：存档 → 退出进程 → 读档（读档日志里 turn > 1）。
--
-- 判定写在日志的 VERDICT= 里：
--   first-write    没读到 → 已写入，需要再进一局才有结论
--   cross-save-OK  读到的是“上一次进游戏/另一个进程”写的 → 跨存档成立
--   same-session   读到的是“本次进游戏”里刚写的 → 只证明活过了这次读档，不算证据
--                   （payload 带 load=<本进程第几次进游戏>，本模块用 m_ProbeWrittenPayloads 记账）
--
-- 两条路径都值得跑：
--   * 新建游戏 → 退回主菜单 → 再新建游戏（验证 CustomData 是否跨局保留）
--   * 存档 → 完全退出进程 → 重开 → 读档（验证是否随存档一起保存）
-- ===========================================================================
local CROSS_SAVE_PROBE_KEY = "ModMiscToolCrossSaveProbe"
-- payload -> 写入时是“本进程第几次进游戏”，用来区分“同一局里又读到自己刚写的”和“真的跨了局”
local m_ProbeWrittenPayloads = {}
local m_ProbeLoadIndex = 0

local function RunCrossSaveProbe(source)
    -- 前端能写不代表局内也能写（UI.GetGameParameters() 在局内可能不可用），两边都 pcall
    local readOk, raw = pcall(ReadCustomData, CROSS_SAVE_PROBE_KEY)
    if not readOk then
        print("[ModMiscTool][Probe] " .. source .. ": FAILED ReadCustomData -> " .. tostring(raw))
        return nil
    end
    local previous = nil
    if raw ~= nil and tostring(raw) ~= "" then
        previous = tostring(raw)
    end

    -- 每进一次游戏把 run 加一，日志里就能看出“第几次启动读到了第几次写的数据”
    local runIndex = 1
    if previous ~= nil then
        local lastRun = tonumber(string.match(previous, "^run=(%-?%d+)"))
        if lastRun ~= nil then runIndex = lastRun + 1 end
    end

    local turn = 0
    local ok, turnValue = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok and turnValue ~= nil then turn = turnValue end

    local payload = "run=" .. tostring(runIndex)
        .. ";load=" .. tostring(m_ProbeLoadIndex)
        .. ";turn=" .. tostring(turn)
        .. ";prev=" .. tostring(raw)
    local writeOk, writeErr = pcall(WriteCustomData, CROSS_SAVE_PROBE_KEY, payload)
    if not writeOk then
        print("[ModMiscTool][Probe] " .. source .. ": FAILED WriteCustomData -> " .. tostring(writeErr)
            .. "（局内只能读、不能写）")
        return nil
    end
    m_ProbeWrittenPayloads[payload] = m_ProbeLoadIndex

    if previous == nil then
        print("[ModMiscTool][Probe] " .. source .. ": VERDICT=first-write 没读到数据，已写入 ["
            .. payload .. "]；退回主菜单再进一局（或读档）看下一次的结论")
        return payload
    end

    -- 上一次写入发生在“本进程的这一次进游戏”里 → 只是读到自己刚写的，不算跨存档证据
    if m_ProbeWrittenPayloads[previous] == m_ProbeLoadIndex then
        print("[ModMiscTool][Probe] " .. source
            .. ": VERDICT=same-session 读到的是本次进游戏里刚写的 [" .. previous
            .. "]，只证明活过了这次读档，不算跨存档证据；已写入 [" .. payload .. "]")
        return payload
    end

    print("[ModMiscTool][Probe] " .. source .. ": VERDICT=cross-save-OK 读到了上一次进游戏"
        .. "(load index " .. tostring(m_ProbeWrittenPayloads[previous]) .. ")写入的 [" .. previous
        .. "]，跨存档成立；已写入 [" .. payload .. "]")
    return payload
end

-- 面板调用入口（跨 context 只回传一个字符串，避免依赖多返回值）
function RunCrossSaveProbeUI(source)
    return RunCrossSaveProbe(tostring(source or "panel"))
end

-- ===========================================================================
-- 跨存档数据存取（UI 侧）
--
-- ⚠️ UI 端**用不了** Game:SetProperty（授权者确认），所以 UI 侧只能走 CustomData：
--   它写进当前这局的 game parameters，**写完必须再存一次档**才会落盘。
--   而且它和 gameplay 侧的 Game:SetProperty 是**两个独立的存储** —— 同一个 key
--   在两边互不可见。要对局内自动落盘的数据，请用 gameplay 侧的 SetData。
--
-- 键前缀比 gameplay 侧多一个 ui_，避免两边混用同一个键时产生误解。
-- ===========================================================================
local MODMISC_UI_DATA_KEY_PREFIX = "kocmoca_modmisctool_ui_"

local function LogUIData(message)
    print("[ModMiscTool][UIData] " .. message)
end

function SetModMiscCustomData(key, value)
    if key == nil then
        LogUIData("Set 失败：key 为 nil")
        return false
    end
    local ok, err = pcall(WriteCustomData, MODMISC_UI_DATA_KEY_PREFIX .. tostring(key), value)
    if not ok then
        LogUIData("Set 失败 key=" .. tostring(key) .. " -> " .. tostring(err))
        return false
    end
    return true
end

function GetModMiscCustomData(key)
    if key == nil then return nil end
    local ok, value = pcall(ReadCustomData, MODMISC_UI_DATA_KEY_PREFIX .. tostring(key))
    if not ok then
        LogUIData("Get 失败 key=" .. tostring(key) .. " -> " .. tostring(value))
        return nil
    end
    if value == nil or tostring(value) == "" then return nil end
    return value
end

-- 探针只在启动函数里跑一次（每次进入游戏一次）：先读、读不到就写

-- ===========================================================================
-- 恢复游戏内 UI（等价于原版的调试热键 Shift+Alt+B，安卓没键盘所以做成接口）
--
-- 背景：InGame.lua 的 BulkHide 是**引用计数**（m_bulkHideTracker）——
-- 某个界面调了 BulkHide(true, x) 之后，配对的 BulkHide(false, x) 没跑到
-- （报错 / 上下文被顶掉），计数就卡在 >=1，于是
-- WorldViewControls / HUD / PartialScreens / Screens / TopLevelHUD **五大组永久隐藏**，
-- 表现就是“UI 全部消失”。原版为此留了 Shift+Alt+B 强制恢复。
--
-- 这里不碰那个 local 计数器（跨 context 也碰不到），只把这五组强制显示回来，
-- 让玩家立刻能继续操作。返回被恢复的组名列表。
-- ===========================================================================
local INGAME_BULK_HIDE_GROUPS = {
	"WorldViewControls", "HUD", "PartialScreens", "Screens", "TopLevelHUD",
}

function RestoreInGameUI()
	local restored = {}
	for _, group in ipairs(INGAME_BULK_HIDE_GROUPS) do
		local control = ContextPtr:LookUpControl("/InGame/" .. group)
		if control == nil then
			print("[ModMiscTool][RestoreUI] 找不到 /InGame/" .. group)
		elseif control:IsHidden() then
			control:SetHide(false)
			table.insert(restored, group)
		end
	end
	print("[ModMiscTool][RestoreUI] 已恢复：" ..
		(#restored > 0 and table.concat(restored, ",") or "(没有隐藏的组)"))
	return restored
end

function Initialize()
	InitializeAllUnitPromotions()

	-- ===========================================================================
	-- [跨存档存储·对局内] 对局内能不能用同一套「存档名」通道读写
	--
	-- 读：扫一遍配置档列表（和前端同一套，能读到前端写进去的键）
	-- 写：Network.SaveGame{FileType=GAME_CONFIGURATION} —— **这一枪对局内从没试过**，
	--     风险与「对局内读配置档卡死」同源，所以调用前先打一行日志：
	--     要是进程卡死，日志里最后一行就是它。
	--     若这条路不行，退路是改成写普通存档（GAME_STATE，对局内写是静默的、已验证），
	--     代价是存档列表里多一个大档。
	-- ===========================================================================
	-- 对局内写配置档这条已经验证通过（2026-10-04：ig=… 跨进程读回逐字一致），
	-- 所以写测试关掉，免得每次开局都往存储里塞一个 ingame 键。
	-- 读的那半留着：开局顺手打一行“存储里现在有什么”，当诊断用。
	local MODMISC_STORE_INGAME_WRITE_TEST = false

	local function LogStoreInGame(message)
		print("[ModMiscTool][Store] in-game: " .. message)
	end

	local function RunStoreProbeInGame()
		if ModMiscStore == nil then
			LogStoreInGame("ModMiscStore 模块没加载（ImportFiles 里缺 UI/ModMiscStore.lua？）")
			return
		end

		ModMiscStore.OnReady(function()
			LogStoreInGame("扫描完成；selftest=[" .. tostring(ModMiscStore.Get("selftest"))
				.. "] ingame=[" .. tostring(ModMiscStore.Get("ingame")) .. "]")

			if not MODMISC_STORE_INGAME_WRITE_TEST then return end
			local payload = "ig=1;t=" .. tostring(os.time())
				.. ";r=" .. tostring(math.random(100000, 999999))
			LogStoreInGame("即将调用 Network.SaveGame(配置档) 写入 [" .. payload .. "]")
			ModMiscStore.Save("ingame", payload)
			LogStoreInGame("Save 调用已返回（没卡死）")
		end)
		ModMiscStore.Refresh()
	end

	RunStoreProbeInGame()

	-- 永久资产放置：读档/开局时按记录重放一次
	-- （放在 Support_UI 里只跑一次；模块本身不挂事件，免得每个 context 各重放一遍）
	if ModMiscAssetStore ~= nil then
		local ok, placed = pcall(ModMiscAssetStore.LoadAndRestore)
		if not ok then
			print("[ModMiscTool][AssetStore] 重放失败 -> " .. tostring(placed))
		end
	end

	-- 创建新局 / 换地图：开局探针（每次进游戏一次）。
	-- 判定「上一轮按钮调用之后进的是哪一局」——标记在 = 还在原局或读回了旧档，
	-- 标记没了 = 新局（CustomData 不跨新局）。结论看 Lua.log 的 [ModMiscTool][CreateGame] 行。
	if ModMiscCreateGame ~= nil then
		local ok, err = pcall(ModMiscCreateGame.ReportAfterCreateInGame)
		if not ok then
			print("[ModMiscTool][CreateGame] 开局探针失败 -> " .. tostring(err))
		end
	end

	-- 存档关系 + 换图：开局探针 —— 报“本局是哪个节点 / 主线头 / 有没有待接分支”，
	-- 并把关系树打进日志。换图后进新局时，这一行就是“关系带过去了没有”的直接证据。
	if ModMiscSaveGraph ~= nil then
		local ok, err = pcall(ModMiscSaveGraph.ReportAfterLoad)
		if not ok then
			print("[ModMiscTool][SaveGraph] 开局探针失败 -> " .. tostring(err))
		end
	end

	-- 回合 / 年代：开局探针（一行现状）。重启换图前后一对比就知道回合与年代有没有被复位。
	if ModMiscTurnEra ~= nil then
		local ok, err = pcall(ModMiscTurnEra.ReportAfterLoad)
		if not ok then
			print("[ModMiscTool][TurnEra] 开局探针失败 -> " .. tostring(err))
		end
	end


	-- 跨存档探针：启动流程只跑这一次，结论看 Lua.log 里的 [ModMiscTool][Probe] 行
	m_ProbeLoadIndex = m_ProbeLoadIndex + 1
	RunCrossSaveProbe("startup(load " .. tostring(m_ProbeLoadIndex) .. ")")
	if not ExposedMembers.ModMiscToolUI then
		ExposedMembers.ModMiscToolUI = {}
	end
	ExposedMembers.ModMiscToolUI.GetExperienceAndPromotionsUI = GetExperienceAndPromotionsUI
	ExposedMembers.ModMiscToolUI.GetBuildingsIndexAtPlotUI = GetBuildingsIndexAtPlotUI
	ExposedMembers.ModMiscToolUI.GetUnitIconAndName = GetUnitIconAndName
	ExposedMembers.ModMiscToolUI.CanUnitTypeGetExp = CanUnitTypeGetExp
	ExposedMembers.ModMiscToolUI.allUnitPromotions = allUnitPromotions
	ExposedMembers.ModMiscToolUI.GetPlayerAllianceType = GetPlayerAllianceType
ExposedMembers.ModMiscToolUI.RegisterLedgerProvider = RegisterLedgerProvider
ExposedMembers.ModMiscToolUI.GetLedgerProvider = GetLedgerProvider
ExposedMembers.ModMiscToolUI.GetLedgerSummary = GetLedgerSummary
ExposedMembers.ModMiscToolUI.GetLedgerItems = GetLedgerItems
ExposedMembers.ModMiscToolUI.GetLocalLedgerSummary = GetLocalLedgerSummary
ExposedMembers.ModMiscToolUI.GetLocalLedgerItems = GetLocalLedgerItems
ExposedMembers.ModMiscToolUI.LedgerProviderAvailable = LedgerProviderAvailable
ExposedMembers.ModMiscToolUI.ShowLoadWarningPopup = ShowLoadWarningPopup
ExposedMembers.ModMiscToolUI.IsMinorPlayerUI = IsMinorPlayerUI
ExposedMembers.ModMiscToolUI.GetUnsettledCityStatePlayerIDsUI = GetUnsettledCityStatePlayerIDsUI
ExposedMembers.ModMiscToolUI.RunCrossSaveProbeUI = RunCrossSaveProbeUI
	-- 跨存档数据存取（UI 侧）：写 CustomData，**写完要再存一次档**才落盘
	ExposedMembers.ModMiscToolUI.SetCustomData = SetModMiscCustomData
	ExposedMembers.ModMiscToolUI.GetCustomData = GetModMiscCustomData

	-- 对局内「创建新局 / 换地图」（UI 层）：接口与日志判定见 UI/ModMiscCreateGame.lua
	if ModMiscCreateGame ~= nil then
		ExposedMembers.ModMiscToolUI.CreateGame = ModMiscCreateGame
		ExposedMembers.ModMiscToolUI.DescribeCreateGameContext = ModMiscCreateGame.DescribeContext
		ExposedMembers.ModMiscToolUI.GetCurrentMapScript = ModMiscCreateGame.GetCurrentMapScript
		ExposedMembers.ModMiscToolUI.ListMapScripts = ModMiscCreateGame.ListMapScripts
		ExposedMembers.ModMiscToolUI.ApplyMapScript = ModMiscCreateGame.ApplyMapScript
		ExposedMembers.ModMiscToolUI.ArmCreateGameMarker = ModMiscCreateGame.ArmMarker
		ExposedMembers.ModMiscToolUI.RestartGameInGame = ModMiscCreateGame.RestartGame
		-- 注意：HostGame **故意不暴露** —— 2026-10-05 实机结论：对局内调用它不报错、
		-- 也不建新局（静默空操作），详见 API_Verification_Status.md 第 43 条。
	end

	-- 回合数 / 年代（UI 层）：**只暴露读接口** —— 2026-10-05 实机确认写接口全部无效
	-- （回合、年代、下一局开始年代都改不动，见 API_Verification_Status.md 第 13 节）。
	-- 模块本身留着：读数可用，写的那几个函数只作留档。
	if ModMiscTurnEra ~= nil then
		ExposedMembers.ModMiscToolUI.TurnEra = ModMiscTurnEra
		ExposedMembers.ModMiscToolUI.DescribeTurnEraContext = ModMiscTurnEra.DescribeContext
		ExposedMembers.ModMiscToolUI.GetTurnInfo = ModMiscTurnEra.GetTurnInfo
		ExposedMembers.ModMiscToolUI.GetDateString = ModMiscTurnEra.GetDateString
		ExposedMembers.ModMiscToolUI.GetPlayerEraType = ModMiscTurnEra.GetPlayerEraType
	end

	-- 永久资产放置（API_Documentation.txt 3.10.2 里写的对外名字，实现是 ModMiscAssetStore）
	if ModMiscAssetStore ~= nil then
		ExposedMembers.ModMiscToolUI.PlaceAssetPersistent = ModMiscAssetStore.PlaceAndRecord
		ExposedMembers.ModMiscToolUI.RemovePersistentAssetsAt = ModMiscAssetStore.RemoveAt
		ExposedMembers.ModMiscToolUI.ClearPersistentAssets = ModMiscAssetStore.ClearAllRecords
		ExposedMembers.ModMiscToolUI.RestorePersistentAssets = ModMiscAssetStore.RestoreAll
		ExposedMembers.ModMiscToolUI.GetPersistentAssetCount = ModMiscAssetStore.GetCount
		ExposedMembers.ModMiscToolUI.GetPersistentAssets = ModMiscAssetStore.GetAll
	end

	-- 存档关系树 + 换图（成品功能）：接口与格式说明见 UI/ModMiscSaveGraph.lua
	if ModMiscSaveGraph ~= nil then
		ExposedMembers.ModMiscToolUI.SaveGraph = ModMiscSaveGraph
		ExposedMembers.ModMiscToolUI.DescribeSaveGraph = ModMiscSaveGraph.DescribeContext
		ExposedMembers.ModMiscToolUI.GetSaveGraphTree = ModMiscSaveGraph.BuildTreeLines
		ExposedMembers.ModMiscToolUI.SaveGameWithRelation = ModMiscSaveGraph.SaveCurrentGame
		ExposedMembers.ModMiscToolUI.SwitchMap = ModMiscSaveGraph.SwitchMap
		ExposedMembers.ModMiscToolUI.BuildRelationSaveName = ModMiscSaveGraph.BuildSaveName
		ExposedMembers.ModMiscToolUI.ParseRelationSaveName = ModMiscSaveGraph.ParseSaveName
	end

	-- 跨存档存储（存档名编码通道，已实机验证）：给别的 mod 直接用的接口。
	-- 用法：RefreshData() → OnDataReady 回调里 GetData(key)；
	--       SaveData(key, value) 异步落盘（内部先写新档、SaveComplete 后删旧档）。
	-- 数据在 UI 层（前端与对局内 UI 都能用）；gameplay 侧拿不到，需要就经 ExposedMembers 转。
	if ModMiscStore ~= nil then
		ExposedMembers.ModMiscToolUI.SaveData = ModMiscStore.Save
		ExposedMembers.ModMiscToolUI.GetData = ModMiscStore.Get
		ExposedMembers.ModMiscToolUI.GetAllData = ModMiscStore.GetAll
		ExposedMembers.ModMiscToolUI.RemoveData = ModMiscStore.Remove
		ExposedMembers.ModMiscToolUI.RemoveAllData = ModMiscStore.RemoveAll
		ExposedMembers.ModMiscToolUI.RefreshData = ModMiscStore.Refresh
		ExposedMembers.ModMiscToolUI.IsDataReady = ModMiscStore.IsReady
		ExposedMembers.ModMiscToolUI.OnDataReady = ModMiscStore.OnReady
		ExposedMembers.ModMiscToolUI.StoreGetBuildTag = function() return ModMiscStore.BuildTag end
	end
end
-- 退出到主菜单 = 这一局到此为止：把「待接分支」清掉。
-- 不清的话，之后新开的一局会把上一次没走完的换图关系认成自己的来源
-- —— 授权者 2026-10-05 实测到的“退出到主界面新开存档被识别为分支”。
if Events.ExitToMainMenu ~= nil and Events.ExitToMainMenu.Add ~= nil then
	Events.ExitToMainMenu.Add(function()
		if ModMiscSaveGraph ~= nil and ModMiscSaveGraph.ClearPendingBranch ~= nil then
			pcall(ModMiscSaveGraph.ClearPendingBranch, "退出到主菜单")
		end
	end)
end

Events.LoadGameViewStateDone.Add(Initialize)
