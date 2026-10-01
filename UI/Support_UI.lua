include("ModTool_Support_Functions.lua")
include("ModTool_Support_UI.lua")
include("Civ6Common")   -- ReadCustomData：读取创建游戏时保存的城邦数量
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
local m_GhostInitDone = false

local function HandOffGhostCityStateCount()
    if m_GhostInitDone then return end

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

    script.InitializeGhostPlayers(savedCount)

    -- 主要文明同理：只有前端 hook 真的抬过上限（说明玩家选的比上限少）才有记录，
    -- 没有记录就说明本来就没有富余，什么都不做
    local savedMajors = tonumber(ReadCustomData(GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY))
    if savedMajors ~= nil and savedMajors > 0 and script.InitializeGhostMajorPlayers ~= nil then
        print("[ModMiscTool][Ghost] handing off saved major player count=" .. tostring(savedMajors))
        script.InitializeGhostMajorPlayers(savedMajors)
    else
        print("[ModMiscTool][Ghost] no saved major player count, skip major ghosts")
    end

    m_GhostInitDone = true
end

Events.LoadGameViewStateDone.Add(HandOffGhostCityStateCount)
Events.LocalPlayerTurnBegin.Add(HandOffGhostCityStateCount)

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

-- 探针只在启动函数里跑一次（每次进入游戏一次）：先读、读不到就写

function Initialize()
	InitializeAllUnitPromotions()

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
end
Events.LoadGameViewStateDone.Add(Initialize)
