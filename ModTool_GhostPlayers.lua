-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家（引擎认可的 off-map 玩家）
--
-- 参照 EXera（分封城邦）的做法：开局时把若干尚未建城的城邦玩家搬到地图外
-- （清掉地图上的单位，只在地图外 (-1,-1) 留一个开拓者），这些玩家从开局就
-- 存在于 game core，AI/外交子系统都有它们的条目。
--
-- 这样测试面板就能拿这些槽位当“新玩家”用：改文明/领袖、建城、放单位都不会
-- 像运行中 PlayerManager():AddPlayer() 那样把 AI 外交表踩空（
-- GameCore::AI::Diplomatic::GetDiplomaticStateIndex 空指针 → 闪退）。
--
-- 只在全新开局（回合 <= 1）且尚未记录过时执行一次；读档进老局不会动任何城邦。
-- ===========================================================================

-- 【开局阶段】幽灵化的主要文明是否顺手改成城邦（避免它继续参与外交）。
-- 2026-10-01 实机：打开时那一次开局“游戏加载出错”（日志停在 LoadScreen: OnLoadGameViewStateDone，
-- InGame UI 根本没开始加载）⇒ 这条**开局阶段**的转换保持关闭；城邦化改在
-- “本地玩家建立第一座城市”那一刻做（安全时机，见下面的 GHOST_AUTO_CONVERT_ON_FIRST_CITY）。
local GHOST_CONVERT_MAJOR_TO_CITY_STATE = false
local GHOST_PLAYER_MAX = 64   -- 兜底上限（正常用不到：所有多余城邦都当幽灵）
-- 目标池为空时是否允许跨池兜底（前置声明：函数定义早于下面的赋值）
local GHOST_ALLOW_POOL_FALLBACK = false
-- 城邦幽灵的**申报上限**（建局侧按 mod 申报算好后写进随档数据传进来）：
--   nil = 没这道数据（老档/老前端）⇒ 不限额，沿用旧行为
--   0   = 没有 mod 申报城邦幽灵 ⇒ 一个都不产生
--   N   = 最多产生 N 个城邦幽灵
local m_CityStateGhostPoolLimit = nil
-- 主流幽灵的**申报上限**（同样由建局侧按 mod 申报算好传进来；含义同上：nil/0/N）
local m_MajorGhostPoolLimit = nil
local GHOST_PLAYER_PROPERTY = 'kocmoca_modmisctool_ghost_players'
local CITY_STATE_GHOST_PLAYER_PROPERTY = 'kocmoca_modmisctool_city_state_ghost_players'
local UNIT_TYPE_SETTLER = 'UNIT_SETTLER'

-- ===========================================================================
-- 【授权者 2026-10-26】主流 → 城邦：按**入口**授权
-- ----------------------------------------------------------------------------
-- 2026-10-17 曾把这条路整体拦截（转换后的主流玩家没有外交/使者数据，属半城邦状态，
-- 官方城邦面板取关系数据拿到 nil 会整行报错；见下面手动入口那段注释）。
-- 2026-10-26 授权者确认恢复"本地玩家建立第一座城市时自动批量城邦化"；
-- 同日又要求新增幽灵 debug 面板（显式按钮，人工触发），因此入口表为：
--   * auto_first_city = true  —— 建首城自动批量（不在加载过渡阶段，时机已验证）
--   * debug_panel     = true  —— 幽灵 debug 面板上的「城邦化」按钮（授权者显式操作）
--   * manual          = false —— 其它 mod 直接调用，仍按 2026-10-17 定案拦截
-- 要放开其它 mod 的调用：把 GHOST_ALLOW_MANUAL_MAJOR_TO_CITY_STATE 改成 true。
-- 入口是否放行只在这里判定；转换函数拿到授权后无条件执行。
-- ===========================================================================
local GHOST_AUTO_CONVERT_ON_FIRST_CITY = true
local GHOST_ALLOW_DEBUG_PANEL_MAJOR_TO_CITY_STATE = true
local GHOST_ALLOW_MANUAL_MAJOR_TO_CITY_STATE = false

local function IsMajorToCityStateConversionAllowed(conversionSource)
	if conversionSource == 'auto_first_city' then
		return GHOST_AUTO_CONVERT_ON_FIRST_CITY == true
	end
	if conversionSource == 'debug_panel' then
		return GHOST_ALLOW_DEBUG_PANEL_MAJOR_TO_CITY_STATE == true
	end
	return GHOST_ALLOW_MANUAL_MAJOR_TO_CITY_STATE == true
end

print("[ModMiscTool][Ghost] ghost module loaded build=" .. tostring(MODMISC_BUILD_TAG)
	.. " autoCityStateConvert=" .. tostring(GHOST_CONVERT_MAJOR_TO_CITY_STATE)
	.. " autoConvertOnFirstCity=" .. tostring(GHOST_AUTO_CONVERT_ON_FIRST_CITY)
	.. " debugPanelConvert=" .. tostring(GHOST_ALLOW_DEBUG_PANEL_MAJOR_TO_CITY_STATE)
	.. " manualConvert=" .. tostring(GHOST_ALLOW_MANUAL_MAJOR_TO_CITY_STATE))

-- ===========================================================================
-- 【授权者 2026-10-17 定案】拦截"手动把主流文明 → 城邦文明"
-- ----------------------------------------------------------------------------
-- 实机结论：把一个**主流玩家**造成城邦后，引擎只认了等级，外交/使者那套数据没有跟着建
-- ⇒ 官方城邦面板取关系数据拿到 nil（行渲染报错、使者按钮失效），该玩家在引擎里处于半城邦状态。
-- 城邦幽灵池本来就是在开局时由**真正的城邦**转过来的（InitializeGhostPlayers），不需要再做转换，
-- 所以手动入口（其它 mod 调用）保持关闭；幽灵 debug 面板是 2026-10-26 单独授权的入口：
--   * ConvertGhostPlayerToCityState / ConvertAllGhostMajorPlayersToCityState 对 manual 来源一律拒绝；
--   * ConfigureGhostPlayerIdentity 拒绝把主流玩家下发成 CITY_STATE（Vassal System 走这条）。
-- ===========================================================================

-- ============================================================================
-- 【授权者 2026-10-17】开拓者归位：**地图外的开拓者移动进城市**（不新赠）
-- ----------------------------------------------------------------------------
-- 现象：幽灵化时用 InitUnit(SETTLER, -1, -1) 把玩家搬到地图外垫底，那个开拓者一直留在地图外。
--       AI 一次只盯一个开拓者，于是玩家落地后它不再自己找地建城 ⇒「不会自己建城」。
-- 判据（授权者 2026-10-17 定案）：**建城那一刻，看这个玩家名下有没有"正常存活的、坐标为负的开拓者"**；
--   有 ⇒ 拉进城市；没有 ⇒ 什么都不做。不按"是不是幽灵 / 是不是本地玩家"过滤
--   （幽灵建城那刻可能已被归到本地玩家名下，用身份去卡会把该做的归位挡掉）。
-- 机制（授权者口径，也是唯一做法）：
--       **遍历该玩家的单位 ⇒ 找出"开拓者类型"且"在地图外（坐标 < 0）"的 ⇒ UnitManager.PlaceUnit 拉进城市。**
--       不新赠开拓者（赠送机制已取消）；不做快照比对、不删单位。
-- 触发时机：`Events.CityAddedToMap`（转城与直接建城都会触发）—— 建城事件里移动开拓者是**通用**处理方式。
-- ============================================================================

-- 单位是不是"开拓者类型"：先看数据表的 FoundCity，再退回 UNIT_SETTLER 的类型名/哈希
local function IsSettlerUnit(unit)
	if unit == nil then return false end
	local unitType = nil
	pcall(function() unitType = unit:GetType() end)
	-- ① 数据表 FoundCity（能建城的单位就是开拓者系）
	if unitType ~= nil then
		local info = nil
		pcall(function() info = GameInfo.Units[unitType] end)
		if info ~= nil and info.FoundCity == true then return true end
		if info ~= nil and info.UnitType == UNIT_TYPE_SETTLER then return true end
		-- ② 直接比哈希（部分上下文里 GameInfo.Units[hash] 查不到行）
		local settlerHash = nil
		pcall(function() settlerHash = GameInfo.Units[UNIT_TYPE_SETTLER].Hash end)
		if settlerHash ~= nil and unitType == settlerHash then return true end
	end
	-- ③ 类型名字符串
	local typeName = nil
	pcall(function() typeName = unit:GetTypeName() end)
	if typeName == UNIT_TYPE_SETTLER then return true end
	return false
end

-- 单位是不是"真的在地图外"。
-- ----------------------------------------------------------------------------
-- 【授权者 2026-10-17 实机事故】**坐标读不到 ≠ 地图外**：
--   本地玩家建城那一刻，刚被消耗掉的开拓者还留在 `player:GetUnits()` 里，读坐标会报错；
--   以前把"报错"当地图外 ⇒ 把本地玩家的单位也拉进了新城市
--   （日志：`player=0 … 明细=…@已入城`）。
-- 【授权者 2026-10-17 追加】**非幽灵玩家一律不该被搬运**，判定要严。
--   下面三道**全部成立**才算"在地图外"，任何一道不成立都返回 false：
--     ① 单位句柄还在，且（能查到的前提下）`IsAlive()` 为真 —— 被消耗/将死的单位不算；
--     ② 坐标能读成功，且是数字（读不到 ⇒ 不是地图外，只是脏句柄）；
--     ③ 坐标为负（真正的"地图外"只有这种写法，幽灵就是这么被搬出去的）；
--     （判据只到③：**不要**再加"地图上取不到该 plot"这类交叉验证 ——
--       地图上不显示的玩家/单位，`Map.GetPlot(x, y)` 照样能取到地块，用它会误杀真正的幽灵单位。）
local m_unreadableUnitWarned = false

-- 单位是不是"已经死了/正在死"（这类单位即使坐标是负的也不能搬，见 IsUnitOffMap 注释）
local function IsUnitDeadOrDying(unit)
	if unit == nil then return true end
	local aliveOk, alive = pcall(function() return unit:IsAlive() end)
	if aliveOk and alive == false then return true end
	local damageOk, damage = pcall(function() return unit:GetDamage() end)
	if damageOk and type(damage) == 'number' and damage >= 100 then return true end
	local delayedOk, delayed = pcall(function() return unit:IsDelayedDeath() end)
	if delayedOk and delayed == true then return true end
	return false
end

local function IsUnitOffMap(unit)
	if unit == nil then return false end

	-- ① 句柄有效 + **真的还活着**：
	--    【授权者 2026-10-17 实机】建城时引擎会把"建城的那个开拓者"杀死并搬到地图外，
	--    它在下一次刷新前还留在 unit 列表里、坐标已经变成负值 ⇒ 会被我们当成"地图外开拓者"搬回城里。
	--    所以这里必须把"将死/已死"的单位排除掉，判据三条一起用：
	--      a) `IsAlive()` 为 false ⇒ 排除（能查到才拦）；
	--      b) `GetDamage() >= 100` ⇒ 排除（本项目杀单位的老规矩就是先 SetDamage(100) 再 Kill）；
	--      c) `IsDelayedDeath()` 为 true ⇒ 排除（引擎已经排队要删它了）。
	if IsUnitDeadOrDying(unit) then return false end

	-- ② 坐标必须读得到、是数字
	local ok, unitX, unitY = pcall(function() return unit:GetX(), unit:GetY() end)
	if not ok or type(unitX) ~= 'number' or type(unitY) ~= 'number' then
		if not m_unreadableUnitWarned then
			m_unreadableUnitWarned = true
			print('[ModMiscTool][Ghost] 有单位读不到坐标（多半是刚被消耗掉的单位）'
				.. ' ⇒ 跳过，不参与开拓者归位')
		end
		return false
	end

	-- ③ 坐标为负 ⇒ 就是我们要找的"地图外开拓者"
	--    （授权者 2026-10-17：不要再拿 `Map.GetPlot` 去交叉验证 —— 地图外/未显示的玩家照样能取到地块，
	--      那条判定会误杀真正的幽灵单位，所以判据只保留 ①②③。）
	return unitX < 0 or unitY < 0
end

-- 遍历玩家单位、统计开拓者总数 / 其中地图外的个数
local function CountFindCityUnits(playerID, offMapOnly)
	local count = 0
	local player = Players[playerID]
	if player == nil then return 0 end
	pcall(function()
		local units = player:GetUnits()
		if units == nil then return end
		for _, unit in units:Members() do
			if IsSettlerUnit(unit) then
				if (not offMapOnly) or IsUnitOffMap(unit) then
					count = count + 1
				end
			end
		end
	end)
	return count
end

function GetGhostSettlerCount(playerID)
	return CountFindCityUnits(playerID, false)
end

function GetGhostOffMapSettlerCount(playerID)
	return CountFindCityUnits(playerID, true)
end

-- **核心**：遍历玩家单位 ⇒ 地图外的开拓者 ⇒ PlaceUnit 拉进 (iX, iY)；返回拉过去的个数
-- 【授权者 2026-10-17 定案·判据只有一条】**看这个玩家名下有没有"正常存活的、坐标为负的开拓者"**。
--   不要再用"是不是幽灵 / 是不是本地玩家"当门槛：
--     * 幽灵建城那一刻可能已经被归到本地玩家名下（事件里的 ownerID 就是本地玩家），
--       拿身份去卡反而会把该做的归位挡掉；
--     * 反过来，正常玩家也不可能凭空有一个"存活 + 坐标为负"的开拓者 —— 这条判据本身就是最准的识别。
--   所以入口只做参数检查，真正的过滤在 `IsUnitOffMap`（存活 / 坐标可读 / 为负 / 地图上无该地块）。
function RelocateOffMapSettlersIntoCity(playerID, iX, iY, reason)
	if playerID == nil or iX == nil or iY == nil or iX < 0 or iY < 0 then return 0 end
	local player = Players[playerID]
	if player == nil then return 0 end

	local scanned, moved, failed = 0, 0, 0
	local detail = {}
	local seenSettlers = {}
	pcall(function()
		local units = player:GetUnits()
		if units == nil then return end
		for _, unit in units:Members() do
			scanned = scanned + 1
			if IsSettlerUnit(unit) then
				-- 【授权者 2026-10-17】排查"建城后飞来一个开拓者"：把每个开拓者的现场都打出来
				local uid, ux, uy, alive, uType = '?', '?', '?', '?', '?'
				pcall(function() uid = tostring(unit:GetID()) end)
				pcall(function() uType = tostring(unit:GetType()) end)
				pcall(function() ux, uy = unit:GetX(), unit:GetY() end)
				pcall(function() alive = tostring(unit:IsAlive()) end)
				table.insert(seenSettlers, 'unit=' .. uid .. ' type=' .. uType
					.. ' pos=' .. tostring(ux) .. ',' .. tostring(uy)
					.. ' alive=' .. alive .. ' 判定地图外=' .. tostring(IsUnitOffMap(unit)))
			end
			if IsSettlerUnit(unit) and IsUnitOffMap(unit) then
				local unitID = nil
				pcall(function() unitID = unit:GetID() end)
				local ok, placed = pcall(function() return UnitManager.PlaceUnit(unit, iX, iY) end)
				-- 位置在拉回来之后再读一次，作为"真的动了"的证据
				local afterOffMap = IsUnitOffMap(unit)
				if ok and not afterOffMap then
					moved = moved + 1
					table.insert(detail, tostring(unitID) .. '@已入城')
				else
					failed = failed + 1
					table.insert(detail, tostring(unitID) .. '@失败(' .. tostring(ok)
						.. ',' .. tostring(placed) .. ',仍在地图外=' .. tostring(afterOffMap) .. ')')
				end
			end
		end
	end)

	if #seenSettlers > 0 then
		print('[ModMiscTool][Ghost] 开拓者现场：player=' .. tostring(playerID)
			.. ' 单位总数=' .. tostring(scanned)
			.. ' 其中开拓者=' .. tostring(#seenSettlers)
			.. ' | ' .. table.concat(seenSettlers, ' | ')
			.. ' | 本次原因=' .. tostring(reason))
	end
	if moved == 0 and failed == 0 then return 0 end   -- 没有地图外开拓者 ⇒ 后面不吵日志
	print('[ModMiscTool][Ghost] 开拓者归位：player=' .. tostring(playerID)
		.. ' 扫描单位=' .. tostring(scanned)
		.. ' 地图外开拓者→城市=' .. tostring(moved)
		.. ' 失败=' .. tostring(failed)
		.. ' 位置=' .. tostring(iX) .. ',' .. tostring(iY)
		.. ' 原因=' .. tostring(reason)
		.. (#detail > 0 and (' 明细=' .. table.concat(detail, '|')) or ''))
	return moved
end

-- 建城/转城之后调用：事件没生效时兜一次（幂等 —— 已经在地图内就直接返回，不打印）
-- 判据同 RelocateOffMapSettlersIntoCity：只看"有没有正常存活的负坐标开拓者"。
function EnsureGhostSettlerInCity(playerID, iX, iY, reason)
	if playerID == nil or iX == nil or iY == nil then return 0 end
	local offMap = GetGhostOffMapSettlerCount(playerID)
	if offMap <= 0 then return 0 end
	print('[ModMiscTool][Ghost] 建城/转城后确保开拓者入城：player=' .. tostring(playerID)
		.. ' 地图外开拓者=' .. tostring(offMap)
		.. ' 位置=' .. tostring(iX) .. ',' .. tostring(iY)
		.. ' 原因=' .. tostring(reason))
	return RelocateOffMapSettlersIntoCity(playerID, iX, iY, reason)
end

-- 是不是幽灵（含"刚落地的前幽灵"）：城市落地那一刻池子已经把人摘掉了，
-- 所以除了两个池子，还要看历史台账（进池子时记下的原身份）和"地图外还有开拓者"这个物理特征。
function IsGhostOrFormerGhost(playerID)
	if playerID == nil then return false end
	if IsCityStateGhostPlayer(playerID) then return true end
	if IsGhostPlayer(playerID) then return true end
	if GetGhostOriginalIdentity(playerID) ~= nil then return true end
	return GetGhostOffMapSettlerCount(playerID) > 0
end

-- 所有"曾经是幽灵"的玩家 ID（含已经落地的）：历史台账 + 两个池子，去重排序
function GetKnownGhostPlayerIDs()
	local seen, list = {}, {}
	local function Add(playerID)
		if playerID ~= nil and seen[playerID] ~= true then
			seen[playerID] = true
			table.insert(list, playerID)
		end
	end
	pcall(function()
		for playerID, _ in pairs(GetGhostOriginalIdentities()) do Add(playerID) end
	end)
	pcall(function()
		for _, playerID in ipairs(GetGhostPlayers()) do Add(playerID) end
		for _, playerID in ipairs(GetCityStateGhostPlayers()) do Add(playerID) end
	end)
	table.sort(list)
	return list
end

-- 读档兜底：老存档里"已经有城、开拓者却还卡在地图外"的幽灵，就地归位。
-- 新建城市全由 CityAddedToMap 事件负责；这里只在**载入后第一次回合开始**跑一遍（省得每回合扫单位）。
local m_SettleSweepDone = false
function SweepGhostOffMapSettlers(reason)
	local fixed = 0
	for _, playerID in ipairs(GetKnownGhostPlayerIDs()) do
		if GetGhostOffMapSettlerCount(playerID) > 0 then
			local city = nil
			pcall(function()
				local cities = Players[playerID]:GetCities()
				if cities ~= nil then
					city = cities:GetCapitalCity()
					if city == nil then
						for _, eachCity in cities:Members() do
							city = eachCity
							break
						end
					end
				end
			end)
			if city ~= nil then
				local cx, cy = nil, nil
				pcall(function() cx, cy = city:GetX(), city:GetY() end)
				if cx ~= nil and cy ~= nil and cx >= 0 and cy >= 0 then
					if RelocateOffMapSettlersIntoCity(playerID, cx, cy, reason) > 0 then
						fixed = fixed + 1
					end
				end
			end
		end
	end
	if fixed > 0 then
		print('[ModMiscTool][Ghost] 开拓者归位兜底（' .. tostring(reason or '?')
			.. '）：修好 ' .. tostring(fixed) .. ' 个玩家')
	end
	return fixed
end

-- 【授权者 2026-10-17 定案】城市添加到地图的事件里判断是否为幽灵：是 ⇒ 把地图外的开拓者移动进城市。
-- 转城不一定触发 CityAddedToMap ⇒ 再挂一道 CityTransfered（新拥有者有地图外开拓者才处理）
function HandleGhostCityTransfered(newOwnerID, cityID)
	if newOwnerID == nil or cityID == nil then return end
	-- 判据同上：只看有没有"正常存活的负坐标开拓者"
	if GetGhostOffMapSettlerCount(newOwnerID) <= 0 then return end
	local iX, iY = nil, nil
	pcall(function()
		local city = CityManager.GetCity(newOwnerID, cityID)
		if city ~= nil then iX, iY = city:GetX(), city:GetY() end
	end)
	if iX == nil or iY == nil then return end
	RelocateOffMapSettlersIntoCity(newOwnerID, iX, iY,
		'城市转移事件 cityID=' .. tostring(cityID))
end

function HandleGhostCityAddedToMap(ownerID, cityID, iX, iY)
	if ownerID == nil then return end
	-- 【授权者 2026-10-17】排查用：城市落地事件一律留痕（这个事件很稀疏，不会吵）
	local localID = nil
	pcall(function() localID = Game.GetLocalPlayer() end)
	print('[ModMiscTool][Ghost] 城市落地事件：owner=' .. tostring(ownerID)
		.. ' cityID=' .. tostring(cityID)
		.. ' pos=' .. tostring(iX) .. ',' .. tostring(iY)
		.. ' 本地玩家=' .. tostring(localID)
		.. ' 地图外开拓者=' .. tostring(GetGhostOffMapSettlerCount(ownerID)))
	-- 【授权者 2026-10-17 定案】唯一判据：这个玩家名下有没有"正常存活的、坐标为负的开拓者"。
	--   * 不按"是不是幽灵 / 是不是本地玩家"过滤 —— 幽灵建城那刻可能已被归到本地玩家名下；
	--   * 正常玩家不可能有这种单位，所以这条判据本身就足够，而且不会误伤。
	if GetGhostOffMapSettlerCount(ownerID) <= 0 then return end
	if iX == nil or iY == nil or iX < 0 or iY < 0 then
		pcall(function()
			local city = CityManager.GetCity(ownerID, cityID)
			if city ~= nil then iX, iY = city:GetX(), city:GetY() end
		end)
	end
	if iX == nil or iY == nil or iX < 0 or iY < 0 then
		print('[ModMiscTool][Ghost] 城市落地事件：拿不到城市坐标，跳过开拓者归位 owner='
			.. tostring(ownerID) .. ' cityID=' .. tostring(cityID))
		return
	end
	RelocateOffMapSettlersIntoCity(ownerID, iX, iY, '城市落地事件 cityID=' .. tostring(cityID))
end

-- transfer 之后旧 cityID 对应的 Lua 城市对象可能被销毁；用地块 index 找新城市，
-- 不要再用旧的 CityManager.GetCity(owner, oldCityID)。
local function FindCityByPlotIndex(playerID, plotIndex)
	if playerID == nil or plotIndex == nil then return nil end

	local plot = Map.GetPlotByIndex(plotIndex)
	if plot ~= nil then
		local city = Cities.GetPlotPurchaseCity(plot)
		if city ~= nil then
			local ownerOk, owner = pcall(function() return city:GetOwner() end)
			if not ownerOk or owner == playerID then
				return city
			end
		end
	end

	local player = Players[playerID]
	if player ~= nil then
		local cities = player:GetCities()
		if cities ~= nil then
			for _, city in cities:Members() do
				local cityPlot = Map.GetPlot(city:GetX(), city:GetY())
				if cityPlot ~= nil and cityPlot:GetIndex() == plotIndex then
					return city
				end
			end
		end
	end
	return nil
end


-- ===========================================================================
-- 幽灵玩家列表（存档内持久化）
-- ===========================================================================

function GetGhostPlayers()
	local ghosts = Game:GetProperty(GHOST_PLAYER_PROPERTY)
	if ghosts == nil then return {} end
	return ghosts
end

-- pcall 包一层：取值失败时返回 nil，别把脚本打断
local function CallOrNil(fn)
	local ok, value = pcall(fn)
	if not ok then
		return nil
	end
	return value
end

-- ===========================================================================
-- 幽灵“原身份”台账（2026-10-15 授权者）
--
-- 背景：玩家创建时引擎会记下它的**原文明/原领袖**，之后我们改 PlayerConfigurations
-- 也改不掉引擎记的那一份 —— 外交界面/议会之类的地方会按引擎记录显示，
-- 于是“幽灵被改成别的文明”时容易出现显示冲突（和场上真正拥有该文明的玩家撞车）。
--
-- 所以：**进池子的那一刻**把每个幽灵的原文明/原领袖记下来（存档属性，随档走），
-- 之后向幽灵池要“特定文明+领袖”时，优先挑**原身份就相符**的那个 ——
-- 这样引擎记录与我们要显示的一致，外交界面不会冲突；顺带这种幽灵通常也不需要改身份，
-- 于是“建立城市后的实际效果”也不需要读档（身份真被改过的仍需要读档，见 Vassal System）。
-- ===========================================================================
local GHOST_IDENTITY_PROPERTY = 'kocmoca_modmisctool_ghost_identities'

function GetGhostOriginalIdentities()
	local record = Game:GetProperty(GHOST_IDENTITY_PROPERTY)
	if record == nil then return {} end
	return record
end

function GetGhostOriginalIdentity(playerID)
	if playerID == nil then return nil end
	return GetGhostOriginalIdentities()[playerID]
end

-- 只在“第一次进池子”时记（之后无论怎么改身份，台账都是引擎那份原身份）
function RecordGhostOriginalIdentity(playerID, reason)
	if playerID == nil then return nil end
	local record = Game:GetProperty(GHOST_IDENTITY_PROPERTY)
	if record == nil then record = {} end
	local existing = record[playerID]
	if existing ~= nil then return existing end

	local playerConfig = PlayerConfigurations[playerID]
	local civType = nil
	local leaderType = nil
	if playerConfig ~= nil then
		civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
		leaderType = CallOrNil(function() return playerConfig:GetLeaderTypeName() end)
	end
	local entry = { civ = civType, leader = leaderType, turn = Game.GetCurrentGameTurn(),
		reason = reason or '' }
	record[playerID] = entry
	Game:SetProperty(GHOST_IDENTITY_PROPERTY, record)
	print('[ModMiscTool][Ghost] 记录原身份：player=' .. tostring(playerID)
		.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType)
		.. '（' .. tostring(reason or '进池子') .. '）')
	return entry
end

-- 给调用方打分用：原文明+原领袖全都相符 = 2、只中一个 = 1、不中或没台账 = nil
function GetGhostOriginalIdentityScore(playerID, civType, leaderType)
	local entry = GetGhostOriginalIdentity(playerID)
	if entry == nil then return nil end
	local score = 0
	local considered = 0
	if leaderType ~= nil and leaderType ~= '' then
		considered = considered + 1
		if entry.leader == leaderType then score = score + 1 end
	end
	if civType ~= nil and civType ~= '' then
		considered = considered + 1
		if entry.civ == civType then score = score + 1 end
	end
	if considered == 0 then return nil end
	return score
end

-- ===========================================================================
-- 幽灵玩家的“新鲜度”：拿到城市的玩家不再是幽灵
--
-- 【2026-10-15 授权者】幽灵被复活（拿到城市、回到地图上）之后，框架还把它当幽灵：
--   * 外交界面/外交条被压制，看不到这个新附庸；
--   * 点它的城市 banner 会去开领袖/外交场景，而该玩家又被当幽灵挡下 ⇒ 场景半开，
--     引擎那边 BulkHide(true, "Diplomacy") 之后再也等不到 BulkHide(false) ⇒ HUD 五组全隐藏。
-- 所以这里做两层：
--   ① 兜底判定：**有城市 ⇒ 不是幽灵**（池子还没清干净也不会再被当幽灵）；
--   ② 及时清池：激活/建城/转城之后立刻把它从两个池子里摘掉（RemoveGhostPlayerFromPool），
--      另提供全量刷新 RefreshGhostPoolsFromCities 给其它 mod 与回合事件调用。
-- ===========================================================================
local m_GhostCityFallbackLogged = {}

-- 该玩家现在有没有城市（有首都/任意城市都算：转移城市那一刻可能还没设首都）
function PlayerOwnsCity(playerID)
	if playerID == nil then return false end
	local player = Players[playerID]
	if player == nil then return false end
	local cities = CallOrNil(function() return player:GetCities() end)
	if cities == nil then return false end
	local capital = CallOrNil(function() return cities:GetCapitalCity() end)
	if capital ~= nil then return true end
	-- 刚转移过来的城市可能还没被标成首都，再数一遍
	local count = CallOrNil(function() return cities:GetCount() end)
	return (count or 0) > 0
end

-- 池子成员是不是“还是幽灵”：有城市就不是了（并记一次日志，便于核对）
local function GhostPoolEntryStillGhost(playerID, poolLabel)
	if not PlayerOwnsCity(playerID) then return true end
	if m_GhostCityFallbackLogged[playerID] ~= true then
		m_GhostCityFallbackLogged[playerID] = true
		print("[ModMiscTool][Ghost] " .. poolLabel .. " 池里的玩家 " .. tostring(playerID)
			.. " 已经有城市 ⇒ 按“不是幽灵”处理，并会从池子里清掉")
	end
	return false
end

-- 把一个玩家从两个池子里摘掉（激活/复活后调用；幂等）
function RemoveGhostPlayerFromPool(playerID, reason)
	if playerID == nil then return false end
	local removed = false
	local majorGhosts = Game:GetProperty(GHOST_PLAYER_PROPERTY)
	if majorGhosts ~= nil then
		local kept = {}
		for _, ghostID in ipairs(majorGhosts) do
			if ghostID == playerID then removed = true else table.insert(kept, ghostID) end
		end
		if removed then Game:SetProperty(GHOST_PLAYER_PROPERTY, kept) end
	end
	local cityGhosts = Game:GetProperty(CITY_STATE_GHOST_PLAYER_PROPERTY)
	if cityGhosts ~= nil then
		local kept = {}
		local removedCity = false
		for _, ghostID in ipairs(cityGhosts) do
			if ghostID == playerID then removedCity = true else table.insert(kept, ghostID) end
		end
		if removedCity then
			Game:SetProperty(CITY_STATE_GHOST_PLAYER_PROPERTY, kept)
			removed = true
		end
	end
	ReleaseAnyGhostPlayer(playerID)
	if removed then
		print("[ModMiscTool][Ghost] 玩家 " .. tostring(playerID) .. " 已移出幽灵池（"
			.. tostring(reason or "未说明") .. "）；主流池剩 " .. tostring(GetGhostPlayerCount())
			.. "、城邦池剩 " .. tostring(GetCityStateGhostPlayerCount()))
	end
	return removed
end

-- 全量刷新：池子里凡是已经拿到城市的，全部摘掉（兜底 + 给其它 mod/回合事件调）
function RefreshGhostPoolsFromCities(reason)
	local stale = {}
	local function Collect(pool)
		for _, ghostID in ipairs(pool) do
			if PlayerOwnsCity(ghostID) then table.insert(stale, ghostID) end
		end
	end
	Collect(GetGhostPlayers())
	Collect(GetCityStateGhostPlayers())
	for _, ghostID in ipairs(stale) do
		RemoveGhostPlayerFromPool(ghostID, reason or "已有城市")
	end
	if #stale > 0 then
		print("[ModMiscTool][Ghost] 幽灵池刷新（" .. tostring(reason or "?") .. "）：清掉 "
			.. tostring(#stale) .. " 个已有城市的玩家")
	end
	return #stale
end

function IsGhostPlayer(playerID)
	if playerID == nil then return false end
	for _, ghostID in ipairs(GetGhostPlayers()) do
		if ghostID == playerID then
			-- 兜底：已经有城市的“前幽灵”不再是幽灵（复活后必须立刻从外交压制里消失）
			return GhostPoolEntryStillGhost(playerID, "主流")
		end
	end
	return false
end

-- ===========================================================================
-- 查询接口（供其他 mod 调用）
-- ===========================================================================

function GetGhostPlayerCount()
	return #GetGhostPlayers()
end

-- 是否“可用”：仍是幽灵（off-map）、没有首都、也没有地图上的单位
function IsGhostPlayerAvailable(playerID)
	if not IsGhostPlayer(playerID) then return false end

	local player = Players[playerID]
	if player == nil then return false end

	local cities = player:GetCities()
	if cities ~= nil and cities:GetCapitalCity() ~= nil then return false end

	return not PlayerHasOnMapUnit(playerID)
end

function GetAvailableGhostPlayers()
	local available = {}
	for _, playerID in ipairs(GetGhostPlayers()) do
		if IsGhostPlayerAvailable(playerID) then
			table.insert(available, playerID)
		end
	end
	return available
end

function GetAvailableGhostPlayerCount()
	return #GetAvailableGhostPlayers()
end

-- 取一个可用幽灵的玩家 ID（没有则返回 nil）
function GetAvailableGhostPlayerID()
	local available = GetAvailableGhostPlayers()
	return available[1]
end

-- ---------------------------------------------------------------------------
-- 预约（claim）：多个 mod 同时取幽灵时避免抢到同一个
-- 说明：claim 只是建议性记录，不改变“可用”判定；用不到时调用 ReleaseGhostPlayer 释放，
--       幽灵被带回地图后会被自动清理。
-- ---------------------------------------------------------------------------

local GHOST_CLAIM_PROPERTY = 'kocmoca_modmisctool_ghost_claims'

function GetGhostPlayerClaims()
	local claims = Game:GetProperty(GHOST_CLAIM_PROPERTY)
	if claims == nil then return {} end
	return claims
end

function IsGhostPlayerClaimed(playerID)
	for _, claimedID in ipairs(GetGhostPlayerClaims()) do
		if claimedID == playerID then return true end
	end
	return false
end

-- 预约一个可用幽灵；返回 playerID，没有可用则返回 nil
function ClaimAvailableGhostPlayer()
	local claims = GetGhostPlayerClaims()
	for _, playerID in ipairs(GetGhostPlayers()) do
		if IsGhostPlayerAvailable(playerID) and not IsGhostPlayerClaimed(playerID) then
			table.insert(claims, playerID)
			Game:SetProperty(GHOST_CLAIM_PROPERTY, claims)
			return playerID
		end
	end
	return nil
end

function ReleaseGhostPlayer(playerID)
	local claims = GetGhostPlayerClaims()
	for index = #claims, 1, -1 do
		if claims[index] == playerID then
			table.remove(claims, index)
		end
	end
	Game:SetProperty(GHOST_CLAIM_PROPERTY, claims)
end

-- 指定预约某个主流幽灵（给“优先找已有匹配领袖/文明”的调用方用）。
function ClaimGhostPlayer(playerID)
	if not IsGhostPlayerAvailable(playerID) then return false end
	if IsGhostPlayerClaimed(playerID) then return false end
	local claims = GetGhostPlayerClaims()
	table.insert(claims, playerID)
	Game:SetProperty(GHOST_CLAIM_PROPERTY, claims)
	return true
end

-- ===========================================================================
-- 城邦幽灵玩家池（与主流幽灵池分开维护）
--
-- 旧的 GetGhostPlayers / ClaimAvailableGhostPlayer / IsGhostPlayer 等接口
-- 现在全部指“主流玩家幽灵”；需要城邦幽灵时走下面这一套。
-- ===========================================================================

function GetCityStateGhostPlayers()
	local ghosts = Game:GetProperty(CITY_STATE_GHOST_PLAYER_PROPERTY)
	if ghosts == nil then return {} end
	return ghosts
end

function IsCityStateGhostPlayer(playerID)
	if playerID == nil then return false end
	for _, ghostID in ipairs(GetCityStateGhostPlayers()) do
		if ghostID == playerID then
			return GhostPoolEntryStillGhost(playerID, "城邦")
		end
	end
	return false
end

function GetCityStateGhostPlayerCount()
	return #GetCityStateGhostPlayers()
end

function IsCityStateGhostPlayerAvailable(playerID)
	if not IsCityStateGhostPlayer(playerID) then return false end
	local player = Players[playerID]
	if player == nil then return false end
	local cities = player:GetCities()
	if cities ~= nil and cities:GetCapitalCity() ~= nil then return false end
	return not PlayerHasOnMapUnit(playerID)
end

function GetAvailableCityStateGhostPlayers()
	local available = {}
	for _, playerID in ipairs(GetCityStateGhostPlayers()) do
		if IsCityStateGhostPlayerAvailable(playerID) then
			table.insert(available, playerID)
		end
	end
	return available
end

function GetAvailableCityStateGhostPlayerCount()
	return #GetAvailableCityStateGhostPlayers()
end

function GetAvailableCityStateGhostPlayerID()
	local available = GetAvailableCityStateGhostPlayers()
	return available[1]
end

local CITY_STATE_GHOST_CLAIM_PROPERTY = 'kocmoca_modmisctool_city_state_ghost_claims'

function GetCityStateGhostPlayerClaims()
	local claims = Game:GetProperty(CITY_STATE_GHOST_CLAIM_PROPERTY)
	if claims == nil then return {} end
	return claims
end

function IsCityStateGhostPlayerClaimed(playerID)
	for _, claimedID in ipairs(GetCityStateGhostPlayerClaims()) do
		if claimedID == playerID then return true end
	end
	return false
end

function ClaimAvailableCityStateGhostPlayer()
	local claims = GetCityStateGhostPlayerClaims()
	for _, playerID in ipairs(GetCityStateGhostPlayers()) do
		if IsCityStateGhostPlayerAvailable(playerID)
			and not IsCityStateGhostPlayerClaimed(playerID) then
			table.insert(claims, playerID)
			Game:SetProperty(CITY_STATE_GHOST_CLAIM_PROPERTY, claims)
			return playerID
		end
	end
	return nil
end

function ReleaseCityStateGhostPlayer(playerID)
	local claims = GetCityStateGhostPlayerClaims()
	for index = #claims, 1, -1 do
		if claims[index] == playerID then
			table.remove(claims, index)
		end
	end
	Game:SetProperty(CITY_STATE_GHOST_CLAIM_PROPERTY, claims)
end

-- 指定预约某个城邦幽灵。
function ClaimCityStateGhostPlayer(playerID)
	if not IsCityStateGhostPlayerAvailable(playerID) then return false end
	if IsCityStateGhostPlayerClaimed(playerID) then return false end
	local claims = GetCityStateGhostPlayerClaims()
	table.insert(claims, playerID)
	Game:SetProperty(CITY_STATE_GHOST_CLAIM_PROPERTY, claims)
	return true
end

-- 通用判定 / 释放：操作接口拿到的 ghostID 不一定来自哪个池。
function GetGhostPlayerPoolType(playerID)
	if IsGhostPlayer(playerID) then return 'major' end
	if IsCityStateGhostPlayer(playerID) then return 'citystate' end
	return nil
end

function IsKnownGhostPlayer(playerID)
	return GetGhostPlayerPoolType(playerID) ~= nil
end

function IsKnownGhostPlayerAvailable(playerID)
	local poolType = GetGhostPlayerPoolType(playerID)
	if poolType == 'major' then return IsGhostPlayerAvailable(playerID) end
	if poolType == 'citystate' then return IsCityStateGhostPlayerAvailable(playerID) end
	return false
end

function ReleaseAnyGhostPlayer(playerID)
	local poolType = GetGhostPlayerPoolType(playerID)
	if poolType == 'major' then
		ReleaseGhostPlayer(playerID)
	elseif poolType == 'citystate' then
		ReleaseCityStateGhostPlayer(playerID)
	end
end

-- ===========================================================================
-- 上/下地图
-- ===========================================================================

function PlayerHasOnMapUnit(playerID)
	local player = Players[playerID]
	if player == nil then return false end
	local units = player:GetUnits()
	if units == nil then return false end
	for _, unit in units:Members() do
		if unit:GetX() >= 0 and unit:GetY() >= 0 then
			return true
		end
	end
	return false
end

-- 把玩家搬到地图外。
--
-- 关键顺序：**先保证地图外有一个开拓者，再处理地图上的单位**——否则玩家会出现
-- “零单位”的瞬间，被引擎判定为灭亡（幽灵玩家就死了）。
-- 地图上的开拓者优先用 UnitManager.PlaceUnit 直接挪到地图外（基座 AustraliaScenario
-- 有用例），挪不动才退化为 UnitManager.Kill。
-- 能否把该玩家回收成幽灵。返回 nil 表示可以，否则返回原因字符串。
-- 【硬规则·授权者实机验证】已经建城的玩家一律不能回收：
--   引擎在“全部城市被移除”时会直接判定玩家死亡，手里有开拓者也救不回来，
--   所以这里连碰都不碰（既不拆城、也不清单位），只回报原因。
function GetGhostifyBlockReason(playerID)
	local player = Players[playerID]
	if player == nil then
		return "no engine player"
	end
	-- 这里仍直接用 pcall（历史上 CallOrNil 声明在本函数之后；现在虽然已经前移，
	-- 但这段是“硬保护”路径，少一层间接更稳妥）
	local ok, cities = pcall(function() return player:GetCities() end)
	if not ok then
		cities = nil
	end
	if cities ~= nil then
		local cityCount = 0
		for _ in cities:Members() do
			cityCount = cityCount + 1
		end
		if cityCount > 0 then
			return "player has " .. tostring(cityCount) .. " city/cities"
		end
	end
	return nil
end

-- 这个槽位到底有没有“真玩家”？
--
-- 【为什么必须有这个函数】空槽位的 Players[id] **不是 nil**：它是个内部对象为空的桩，
-- IsMajor() 返回 false、没有城市也没有单位 —— 于是幽灵 pass 那套筛选条件会全部通过，
-- 接着对它调 UnitManager.InitUnit 就会**原生闪退**：
--     signal 11 (SIGSEGV) … IUnitManager::lInitUnit(lua_State*)+24 ，fault addr 0x…e0，x0=0
-- （2026-10-04 实机 100% 复现；此前把上限抬到 62 时坑被占满的槽位盖住，只是偶尔踩到。）
--
-- 判定用**正向信号**：有单位或城市 ⇒ 一定是真玩家。开局时每个城邦都有 3 个单位
-- （日志里的 onMapUnits=3），所以这个门槛不会误伤真城邦；真被跳过也只是它留在地图上，
-- 与幽灵机制无关，无害。
-- 注意：本函数在文件前段，CallOrNil 还没声明（它是后段的 local function），
-- 用了会在运行时被解析成全局 nil —— 所以这里直接 pcall。
local function PlayerSlotHasPlayer(playerID)
	local player = Players[playerID]
	if player == nil then return false end

	local ok, units = pcall(function() return player:GetUnits() end)
	if ok and units ~= nil then
		for _ in units:Members() do
			return true
		end
	end

	local cityOk, cities = pcall(function() return player:GetCities() end)
	if cityOk and cities ~= nil then
		for _ in cities:Members() do
			return true
		end
	end
	return false
end

-- ===========================================================================
-- 幽灵搬移时“怎么删掉地图上的单位”（排障开关，2026-10-13）
--
-- 默认 true = 授权者定的唯一路线：`SetDamage(100)` 让引擎记账，再 `UnitManager.Kill`
--            （少了打伤害这一步，引擎不知道单位已经死了 ⇒ 拆局/重设 AI 时爆悬空引用）。
-- false    = 本功能上线前的旧行为：只 `UnitManager.Kill`。
-- 【为什么留这个开关】2026-10-13 凌晨仍在崩的 teardown 闪退
--   （`GameCore::AI::BehaviorTree::Manager::Reset()` -> `je_free`）出现在“幽灵搬移改成
--   伤害+删除”之后，而幽灵搬的正是 **AI 玩家**的单位 ⇒ 需要一条“换回旧行为再复现”的旁路，
--   一次就能排除/坐实。世界建造测试面板里有对应按钮。
-- ===========================================================================
local m_GhostDamageBeforeKill = true

function SetGhostDamageBeforeKill(enabled)
	m_GhostDamageBeforeKill = (enabled ~= false)
	print("[ModMiscTool][Ghost] 幽灵搬移删除方式：" .. (m_GhostDamageBeforeKill
		and "SetDamage(100) + Kill（默认）" or "仅 Kill（旧行为）"))
	return m_GhostDamageBeforeKill
end

function GetGhostDamageBeforeKill()
	return m_GhostDamageBeforeKill
end

function MovePlayerOffMap(playerID)
	local player = Players[playerID]
	if player == nil then return false end

	-- 空槽位一律不碰：对它 InitUnit 会原生闪退（见 PlayerSlotHasPlayer 的注释）
	if not PlayerSlotHasPlayer(playerID) then
		print("[ModMiscTool][Ghost] player " .. tostring(playerID)
			.. " 是空槽位（无单位无城市）→ 跳过，避免 InitUnit 闪退")
		return false
	end

	-- 有城市的玩家不动：移除全部城市 = 玩家死亡（开拓者也救不回来）
	local blockReason = GetGhostifyBlockReason(playerID)
	if blockReason ~= nil then
		print("[ModMiscTool][Ghost] refuse to ghost player " .. tostring(playerID)
			.. ": " .. blockReason .. "（已有城市，回收会致死）")
		return false
	end

	-- 收集地图上的单位，并记录是否已经有地图外单位
	local onMapUnits = {}
	local hasOffMapUnit = false
	local units = player:GetUnits()
	if units ~= nil then
		for _, unit in units:Members() do
			if unit:GetX() >= 0 and unit:GetY() >= 0 then
				table.insert(onMapUnits, unit)
			else
				hasOffMapUnit = true
			end
		end
	end

	-- 1) 先在地图外放好开拓者：玩家全程都有单位，不会被引擎判定为灭亡
	--    （EXera 的 DeleteUnitsOnMap 就是这个手法：地图外有单位后，这些城邦的单位
	--      就不会出现在地图上）
	if not hasOffMapUnit then
		UnitManager.InitUnit(playerID, UNIT_TYPE_SETTLER, -1, -1)
		-- 确认地图外真的多出单位了再清场：万一 InitUnit 没生效就把图上的单位全杀掉，
		-- 这个玩家会变成“零单位”当场灭亡（也可能是幽灵溢出的成因之一）
		hasOffMapUnit = false
		local recheck = player:GetUnits()
		if recheck ~= nil then
			for _, unit in recheck:Members() do
				if unit:GetX() < 0 or unit:GetY() < 0 then
					hasOffMapUnit = true
					break
				end
			end
		end
	end

	if not hasOffMapUnit then
		print("[ModMiscTool][Ghost] player " .. tostring(playerID)
			.. " off-map settler NOT created -> 放弃清场，避免把玩家清成零单位而灭亡")
		return false
	end

	-- 2) 再清掉地图上的单位。
	--    [已验证失败] UnitManager.PlaceUnit(unit, -1, -1)：调用不报错，但引擎会把单位拉回地图，
	--    幽灵重新落地建城（表现为“所有玩家都不是幽灵”）。搬离地图只能用 InitUnit + Kill。
	--    [已验证失败] 反过来先 Kill 再 InitUnit：中间有“零单位”瞬间，玩家被判灭亡直接死掉。
	local killedCount = 0
	for _, unit in ipairs(onMapUnits) do
		-- 【授权者 2026-10-12 定的唯一路线】伤害 >= 100 ⇒ 返回；否则 SetDamage(100) 再 Kill。
		-- 少了打伤害这一步，引擎不知道单位已经死了（只是从 Lua 视野里消失），
		-- AI / 引擎侧还留着它 ⇒ 拆局或重设 AI 时爆悬空引用
		-- （实机 tombstone：GameCore::AI::BehaviorTree::Manager::Reset() -> je_free）。
		-- 幽灵搬的正是 **AI 玩家**的单位，最该守这条；同款写法见本 mod 的 DamageToUnit。
		if m_GhostDamageBeforeKill and unit:GetDamage() < 100 then
			unit:SetDamage(100)
		end
		UnitManager.Kill(unit, false)
		killedCount = killedCount + 1
	end

	print("[ModMiscTool][Ghost] player " .. tostring(playerID) .. " moved off-map"
		.. " onMapUnits=" .. tostring(#onMapUnits)
		.. " killed=" .. tostring(killedCount))
	return true
end

-- ===========================================================================
-- 运行时补建幽灵槽位（EXera 分封城邦 CreateCityStatePlayer 的做法）
--
-- 引擎自己创建的城邦玩家数量受“数据库里城邦文明条数”限制（请求 62 只出 36）。
-- 但“不能重复文明”的拦截很可能只在 UI 层，引擎层未必禁止，所以这里尝试另一种途径：
--   取一个空玩家槽位 → 直接给 PlayerConfigurations 设城邦文明（可复用已有类型）
--   → StartCityState() 初始化 → 立刻搬到地图外 → 登记进幽灵池。
-- 全程不复制数据库，得到的仍是“引擎认可的玩家”。
-- ===========================================================================

-- 数据库里所有城邦文明类型（gameplay 端可直接读 GameInfo）
local function GetCityStateCivTypes()
	local civTypes = {}
	for civRow in GameInfo.Civilizations() do
		if civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE' then
			table.insert(civTypes, civRow.CivilizationType)
		end
	end
	return civTypes
end

-- 数据库里所有主要文明类型
local function GetMajorCivTypes()
	local civTypes = {}
	for civRow in GameInfo.Civilizations() do
		if civRow.StartingCivilizationLevelType ~= 'CIVILIZATION_LEVEL_CITY_STATE' then
			table.insert(civTypes, civRow.CivilizationType)
		end
	end
	return civTypes
end

-- 取某文明的默认领袖（CivilizationLeaders）
local function GetDefaultLeaderType(civType)
	for civLeaderRow in GameInfo.CivilizationLeaders() do
		if civLeaderRow.CivilizationType == civType then
			return civLeaderRow.LeaderType
		end
	end
	return nil
end

-- ===========================================================================
-- 其它 mod 接口：用幽灵玩家激活定制附庸 / 新建幽灵城市
--
-- 幽灵玩家都是开局搬到地图外的城邦玩家，本身还没有建城。把它们投入使用时，
-- 关键顺序是：先在一个“可用且未预约”的幽灵上配置文明/领袖，再把城市交给它，
-- 最后补一个定居者 —— 因为城市是 transfer 过去的，不是它自己建造的，
-- 城市丢失后无法走正常复国流程，需要靠这个定居者重新落地。
-- ===========================================================================

-- 运行中把已存在的幽灵玩家切成主流文明时，WorldBuilder 的 SetPlayerLeader 有时
-- 不会立刻把 PlayerConfigurations 侧的名字/文明/等级刷新给 UI；这里把已知的
-- PlayerConfiguration setter 打包补一层，保证附庸面板能立刻读到新领袖/新文明。
-- 方法存在性全部按单个 pcall 处理，避免某个平台缺某个 setter 时整体失败。
local function ApplyPlayerConfigIdentity(playerID, civType, leaderType, civLevel)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return false end

	local leaderName = nil
	local leaderRow = GameInfo.Leaders[leaderType]
	if leaderRow ~= nil then
		leaderName = leaderRow.Name
		if Locale ~= nil and Locale.Lookup ~= nil then
			leaderName = Locale.Lookup(leaderRow.Name)
		end
	end

	if leaderName ~= nil and playerConfig.SetLeaderName ~= nil then
		pcall(function() playerConfig:SetLeaderName(leaderName) end)
	end
	if playerConfig.SetLeaderTypeName ~= nil then
		pcall(function() playerConfig:SetLeaderTypeName(leaderType) end)
	end
	if civLevel == 'CIVILIZATION_LEVEL_FULL_CIV' then
		if playerConfig.SetMajorCiv ~= nil then
			pcall(function() playerConfig:SetMajorCiv() end)
		end
		if playerConfig.SetIsMinorCiv ~= nil then
			pcall(function() playerConfig:SetIsMinorCiv(false) end)
		end
	end
	if civType ~= nil and playerConfig.SetCivilizationTypeName ~= nil then
		pcall(function() playerConfig:SetCivilizationTypeName(civType) end)
	end

	local readCivType, readLeaderType, readCivLevel = nil, nil, nil
	local expectedLevelID = nil
	if CivilizationLevelTypes ~= nil then
		expectedLevelID = CivilizationLevelTypes[civLevel]
	end
	pcall(function() readCivType = playerConfig:GetCivilizationTypeName() end)
	pcall(function() readLeaderType = playerConfig:GetLeaderTypeName() end)
	pcall(function() readCivLevel = playerConfig:GetCivilizationLevelTypeID() end)
	print('[ModMiscTool][Ghost] applied player config player=' .. tostring(playerID)
		.. ' civ=' .. tostring(readCivType)
		.. ' leader=' .. tostring(readLeaderType)
		.. ' level=' .. tostring(readCivLevel)
		.. ' requestedLevel=' .. tostring(civLevel)
		.. ' expectedLevelID=' .. tostring(expectedLevelID))
	return true
end

-- 配置幽灵玩家的文明 / 领袖 / 文明等级。
-- 走 WorldBuilder 的 SetPlayerLeader（普通对局内已验证可用）；civLevel 省略时按文明表里的等级。
-- 说明：这里用**全局**函数（ModTool.lua 的导出块看不到别的文件里的 local）
function LocalPlayerHasMet(playerID)
	if playerID == nil then return false end
	local localPlayerID = Game.GetLocalPlayer()
	if localPlayerID == nil or localPlayerID == playerID then return false end
	local localPlayer = Players[localPlayerID]
	if localPlayer == nil then return false end
	local met = CallOrNil(function() return localPlayer:GetDiplomacy():HasMet(playerID) end)
	return met == true
end

function ConfigureGhostPlayerIdentity(playerID, civType, leaderType, civLevel)
	if playerID == nil then return false, 'no player' end
	if not IsKnownGhostPlayer(playerID) then return false, 'player is not a ghost' end

	-- 【2026-10-15 授权者定的硬规则】**主流 → 城邦**必须过滤“已经和本地玩家见过面”的。
	-- 这里是所有改身份的**唯一收口**（Misc Tool 面板、Vassal System 的定制附庸都走它），
	-- 所以过滤放在这里最保险：见面的玩家已经进了外交关系数据，转成城邦后官方城邦面板
	-- 取不到关系透镜数据（DiplomaticState=nil）⇒ 面板打不开 ⇒ “给城邦派使者”回合拦截项
	-- 卡死 ⇒ 无法进入下一回合（2026-10-15 实机定案）。
	-- UI 侧（城邦面板加固补丁 / 见面幽灵转回主流按钮）只作为兜底，不承担这条规则。
	local targetLevel = civLevel
	if targetLevel == nil and civType ~= nil and civType ~= '' then
		local targetCivRow = GameInfo.Civilizations[civType]
		if targetCivRow ~= nil then targetLevel = targetCivRow.StartingCivilizationLevelType end
	end
	if targetLevel == 'CIVILIZATION_LEVEL_CITY_STATE'
		and CallOrNil(function() return Players[playerID]:IsMajor() end) == true
		and LocalPlayerHasMet(playerID) then
		print('[ModMiscTool][Ghost] 拒绝把已见面的玩家转成城邦：player=' .. tostring(playerID)
			.. ' civ=' .. tostring(civType) .. '（见面幽灵留在主流体系）')
		return false, 'local player has already met this player (keep as major)'
	end

	local civRow = nil
	if civType ~= nil and civType ~= '' then
		civRow = GameInfo.Civilizations[civType]
		if civRow == nil then return false, 'unknown civ type ' .. tostring(civType) end
	end

	if leaderType == nil or leaderType == '' then
		if civType == nil then return false, 'no leader and no civ' end
		leaderType = GetDefaultLeaderType(civType)
	end
	if leaderType == nil then return false, 'no default leader for ' .. tostring(civType) end
	if GameInfo.Leaders[leaderType] == nil then
		return false, 'unknown leader type ' .. tostring(leaderType)
	end

	local level = civLevel
	if level == nil and civRow ~= nil then
		level = civRow.StartingCivilizationLevelType
	end
	if level == nil then
		level = 'CIVILIZATION_LEVEL_CITY_STATE'
	end

	-- 【授权者 2026-10-17】手动 / 其它 mod 入口的主流 → 城邦转换保持拦截
	-- （2026-10-26 只恢复了"建首城自动批量"那一个入口；见文件顶部 GHOST_ALLOW_MANUAL_MAJOR_TO_CITY_STATE）
	if level == 'CIVILIZATION_LEVEL_CITY_STATE'
		and GHOST_ALLOW_MANUAL_MAJOR_TO_CITY_STATE ~= true
		and CallOrNil(function() return Players[playerID]:IsMajor() end) == true then
		print('[ModMiscTool][Ghost] 拒绝把主流玩家转成城邦（转换已拦截）：player=' .. tostring(playerID)
			.. ' civ=' .. tostring(civType))
		return false, 'major to city-state conversion blocked'
	end

	if WorldBuilder == nil or WorldBuilder.PlayerManager == nil then
		return false, 'WorldBuilder PlayerManager unavailable'
	end
	local ok, err = pcall(function()
		WorldBuilder.PlayerManager():SetPlayerLeader(playerID, leaderType, civType, level)
	end)
	if not ok then
		print('[ModMiscTool][Ghost] ConfigureGhostPlayerIdentity failed player=' .. tostring(playerID)
			.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType)
			.. ' level=' .. tostring(level) .. ' err=' .. tostring(err))
		return false, tostring(err)
	end

	ApplyPlayerConfigIdentity(playerID, civType, leaderType, level)

	return true
end

-- 把 lordID 名下的一座城市转给一个可用幽灵，让它正式落地。
-- 调用方在成功后应自己建立“附庸”关系（本 API 只负责启用幽灵和给定居者）。
-- existingGhostID：可选。传入时表示该幽灵已经在“存档前”配置好身份，本次只做转移；
-- 不传时沿用旧行为：内部 claim + 配置后再转移。
function TransferCityToGhostPlayer(lordID, cityID, civType, leaderType, civLevel, existingGhostID, behavior)
	local city = CityManager.GetCity(lordID, cityID)
	if city == nil then return false, 'city not found', nil end
	if Players[lordID] == nil then return false, 'lord player not found', nil end

	-- transfer 会销毁旧城市对象，先把坐标和 plotIndex 记下来；之后只能靠 plotIndex 找新城市。
	local oldX, oldY = city:GetX(), city:GetY()
	local oldPlot = Map.GetPlot(oldX, oldY)
	local plotIndex = oldPlot ~= nil and oldPlot:GetIndex() or nil

	local ghostID = existingGhostID
	local claimedHere = false
	if ghostID == nil then
		-- 【2026-10-17 授权者】**池子 = 附庸行为**（与文明类型/等级无关）：
		--   普通行为（normal）      = 主流池（会扩张、正常建造）
		--   保守行为（conservative）= 城邦池（不扩张、建造的区域也少）
		-- 调用方给了 behavior 就用它；没给（老调用）才退回"按等级猜"，保持旧行为。
		local useCityStatePool
		if behavior == 'conservative' or behavior == 'citystate' then
			useCityStatePool = true
		elseif behavior == 'normal' or behavior == 'major' then
			useCityStatePool = false
		else
			useCityStatePool = (civLevel == 'CIVILIZATION_LEVEL_CITY_STATE')
		end
		if useCityStatePool then
			ghostID = ClaimAvailableCityStateGhostPlayer()
		else
			ghostID = ClaimAvailableGhostPlayer()
		end
		if ghostID == nil and GHOST_ALLOW_POOL_FALLBACK then
			ghostID = useCityStatePool
				and ClaimAvailableGhostPlayer() or ClaimAvailableCityStateGhostPlayer()
			if ghostID ~= nil then
				print('[ModMiscTool][Ghost] 目标池为空，跨池兜底取到幽灵 ' .. tostring(ghostID)
					.. '（行为可能与所选不一致）')
			end
		end
		if ghostID == nil then
			return false, 'no available ghost player', nil
		end
		claimedHere = true

		local configured, configErr = ConfigureGhostPlayerIdentity(ghostID, civType, leaderType, civLevel)
		if not configured then
			ReleaseGhostPlayer(ghostID)
			return false, configErr, ghostID
		end
	else
		if not IsKnownGhostPlayer(ghostID) then
			return false, 'player is not a ghost', ghostID
		end
		if not IsKnownGhostPlayerAvailable(ghostID) then
			return false, 'ghost player is not available', ghostID
		end
	end

	local transferOk, transferErr = pcall(function()
		CityManager.TransferCity(city, ghostID, BY_CULTURAL_IDENTITY)
	end)
	if not transferOk then
		if claimedHere then
			ReleaseAnyGhostPlayer(ghostID)
		end
		return false, tostring(transferErr), ghostID, nil
	end

	-- 转移已让幽灵不再“可用”，预约记录可以释放；城市本身会阻止它再次被取用。
	ReleaseAnyGhostPlayer(ghostID)
	-- 它已经有城市了 ⇒ 立刻从幽灵池摘掉（别再被当幽灵压制外交）
	RemoveGhostPlayerFromPool(ghostID, "城市已转移给该玩家")

	-- 旧 cityID 的城市对象在这个时候可能已销毁。用存档前记下的 plotIndex 找新城市；
	-- 找不到也不影响给幽灵补定居者，落点用原地块坐标。
	local newCity = nil
	if plotIndex ~= nil then
		newCity = FindCityByPlotIndex(ghostID, plotIndex)
	end
	if newCity == nil then
		print('[ModMiscTool][Ghost] new city not found by plotIndex=' .. tostring(plotIndex)
			.. ' ghost=' .. tostring(ghostID))
	end

	-- 开拓者归位：主路径是 CityAddedToMap / CityTransfered 事件；
	-- 这里再"确保"一次（幂等：开拓者已经在地图内就什么都不做），免得事件路径没触发时漏掉。
	do
		local iX, iY = oldX, oldY
		pcall(function()
			if newCity ~= nil then iX, iY = newCity:GetX(), newCity:GetY() end
		end)
		EnsureGhostSettlerInCity(ghostID, iX, iY, '转城后确保开拓者入城')
	end

	print('[ModMiscTool][Ghost] activated ghost player ' .. tostring(ghostID)
		.. ' by transferring city ' .. tostring(cityID)
		.. ' plotIndex=' .. tostring(plotIndex)
		.. ' lord=' .. tostring(lordID)
		.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType))
	return true, nil, ghostID, newCity
end

-- 在地图落点直接为幽灵玩家建城（用于单位操作面板：杀掉单位后原地 CreateCity）。
-- plotIndex 为地图地块 index；开拓者归位由 CityAddedToMap 事件统一处理。
function CreateCityForGhostPlayer(playerID, plotIndex, civType, leaderType, civLevel)
	if playerID == nil or plotIndex == nil then return false, 'invalid args', nil end
	if not IsKnownGhostPlayer(playerID) then return false, 'player is not a ghost', nil end
	if not IsKnownGhostPlayerAvailable(playerID) then
		return false, 'ghost player is not available', nil
	end
	if Players[playerID] == nil then return false, 'ghost player not found', nil end

	local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return false, 'invalid plot index ' .. tostring(plotIndex), nil end

	if civType ~= nil or leaderType ~= nil then
		local configured, configErr = ConfigureGhostPlayerIdentity(playerID, civType, leaderType, civLevel)
		if not configured then
			return false, configErr, nil
		end
	end

	local createdCity = nil
	local ok, err = pcall(function()
		createdCity = WorldBuilder.CityManager():Create(playerID, plot)
	end)
	if not ok or createdCity == nil then
		local reason = ok and 'WorldBuilder CityManager Create returned nil' or tostring(err)
		print('[ModMiscTool][Ghost] CreateCityForGhostPlayer failed player=' .. tostring(playerID)
			.. ' plotIndex=' .. tostring(plotIndex) .. ' err=' .. tostring(reason))
		return false, reason, nil
	end

	-- 开拓者归位：主路径是 CityAddedToMap 事件；这里再"确保"一次（幂等，躲开事件不触发的情形）
	EnsureGhostSettlerInCity(playerID, plot:GetX(), plot:GetY(), '建城后确保开拓者入城')
	print('[ModMiscTool][Ghost] created city for ghost player ' .. tostring(playerID)
		.. ' at plotIndex=' .. tostring(plotIndex)
		.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType))
	-- 已经落地建城 ⇒ 立刻从幽灵池摘掉（否则框架继续把它当幽灵：外交不显示、点 banner 会出问题）
	RemoveGhostPlayerFromPool(playerID, "已建城")
	return true, nil, createdCity
end

-- ===========================================================================
-- 【授权者 2026-10-26】幽灵玩家 debug 面板：数据快照 + 四个显式操作
-- ----------------------------------------------------------------------------
-- 面板（UI/GhostDebugPanel.lua）只负责显示与转发；判定与执行都在 gameplay 侧：
--   * GetGhostPlayerDebugList()           逐个幽灵的快照（池 / 身份 / 可用 / 预约 / 见面 / 原身份）
--   * ConvertGhostPlayerToCityState(id, nil, 'debug_panel')  城邦化（入口授权见文件顶部）
--   * RestoreGhostPlayerAsMajor(id)       主流化（用进池时记的原身份台账复原）
--   * FoundCityForGhostPlayer(id)         自动找一块可用的地给它建城（建完即出池）
--   * RemoveGhostPlayerByKillingUnits(id) 移除幽灵：杀掉它名下所有单位（含地图外开拓者）
--
-- 说明：
--   * 杀单位走授权者 2026-10-12 定的路线：伤害 >= 100 直接跳，否则 SetDamage(100) 再 Kill；
--   * 已经把城市建出来的玩家不再是幽灵，移除操作会拒绝（拆城 = 玩家当场死亡）；
--   * 返回的 reason 是**诊断码**（英文短标识），面板负责把它和本地化文案拼在一起显示。
-- ===========================================================================

-- 读玩家配置侧的文明/领袖（空槽位 / 读失败都返回 nil）
local function GetConfigIdentitySafe(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return nil, nil end
	local civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
	local leaderType = CallOrNil(function() return playerConfig:GetLeaderTypeName() end)
	return civType, leaderType
end

-- 从原身份台账里删掉一个玩家（幽灵被移除后，台账不应再留它）
function ForgetGhostOriginalIdentity(playerID)
	if playerID == nil then return false end
	local record = Game:GetProperty(GHOST_IDENTITY_PROPERTY)
	if record == nil or record[playerID] == nil then return false end
	record[playerID] = nil
	Game:SetProperty(GHOST_IDENTITY_PROPERTY, record)
	return true
end

local function BuildGhostDebugEntry(playerID, poolType)
	local player = Players[playerID]
	local civType, leaderType = GetConfigIdentitySafe(playerID)
	local record = GetGhostOriginalIdentity(playerID)
	local claimed = false
	if poolType == 'citystate' then
		claimed = IsCityStateGhostPlayerClaimed(playerID)
	else
		claimed = IsGhostPlayerClaimed(playerID)
	end
	return {
		playerID = playerID,
		pool = poolType,
		isGhost = true,
		civType = civType,
		leaderType = leaderType,
		isMajor = CallOrNil(function() return player:IsMajor() end),
		available = IsKnownGhostPlayerAvailable(playerID),
		claimed = claimed,
		hasCity = PlayerOwnsCity(playerID),
		hasOnMapUnit = PlayerHasOnMapUnit(playerID),
		met = LocalPlayerHasMet(playerID),
		originalCivType = record ~= nil and record.civ or nil,
		originalLeaderType = record ~= nil and record.leader or nil,
	}
end

-- 面板列表：主流池在前、城邦池在后（面板自己按池显示标签）
function GetGhostPlayerDebugList()
	local list = {}
	for _, ghostID in ipairs(GetGhostPlayers()) do
		table.insert(list, BuildGhostDebugEntry(ghostID, 'major'))
	end
	for _, ghostID in ipairs(GetCityStateGhostPlayers()) do
		table.insert(list, BuildGhostDebugEntry(ghostID, 'citystate'))
	end
	return list
end

-- ===========================================================================
-- 调试列表扩展（2026-10-26 授权者要求）：把「杀死幽灵」扩成「杀死任意选中玩家」
--
-- 列表 = 幽灵池（主流 + 城邦）在前，其余存活玩家按 playerID 排在后面；
-- 幽灵条目 isGhost = true，普通玩家条目 isGhost = false（面板按它禁用幽灵专属按钮）。
-- 只用于调试面板；GetGhostPlayerDebugList 的原有语义保持不变。
-- ===========================================================================
local function BuildPlayerDebugEntry(playerID)
	local player = Players[playerID]
	local civType, leaderType = GetConfigIdentitySafe(playerID)
	return {
		playerID = playerID,
		pool = 'player',
		isGhost = false,
		civType = civType,
		leaderType = leaderType,
		isMajor = CallOrNil(function() return player:IsMajor() end),
		available = false,
		claimed = false,
		hasCity = PlayerOwnsCity(playerID),
		hasOnMapUnit = PlayerHasOnMapUnit(playerID),
		met = LocalPlayerHasMet(playerID),
	}
end

-- 蛮族 / 叛军 / 自由城市不是可“杀死”的普通玩家（对齐 GrayFox BanPlayer 的跳过逻辑）
local function IsNonSelectablePlayer(playerID)
	if playerID == 62 or playerID == 63 then return true end
	local player = Players[playerID]
	if player == nil then return true end
	if CallOrNil(function() return player:IsBarbarian() end) == true then return true end
	if CallOrNil(function() return player:IsFreeCities() end) == true then return true end
	return false
end

function GetPlayerDebugList()
	local list = GetGhostPlayerDebugList()
	local seen = {}
	for _, entry in ipairs(list) do
		seen[entry.playerID] = true
	end

	local maxSlots = CallOrNil(function() return GameDefines.MAX_PLAYERS end) or 64
	for playerID = 0, maxSlots - 1 do
		if not seen[playerID] and not IsNonSelectablePlayer(playerID) then
			local player = Players[playerID]
			if player ~= nil and CallOrNil(function() return player:IsAlive() end) == true then
				table.insert(list, BuildPlayerDebugEntry(playerID))
			end
		end
	end
	return list
end

-- 主流化：把幽灵改回主流文明（原身份台账优先；没有台账就用它当前的配置身份）
function RestoreGhostPlayerAsMajor(playerID)
	if playerID == nil or Players[playerID] == nil then return false, 'no_player' end
	if not IsKnownGhostPlayer(playerID) then return false, 'not_ghost' end
	if CallOrNil(function() return Players[playerID]:IsMajor() end) == true then
		return true, 'already_major'
	end

	local record = GetGhostOriginalIdentity(playerID)
	local civType = record ~= nil and record.civ or nil
	local leaderType = record ~= nil and record.leader or nil
	if civType == nil or leaderType == nil then
		civType, leaderType = GetConfigIdentitySafe(playerID)
	end
	if civType == nil or leaderType == nil then return false, 'no_identity' end
	if GameInfo.Civilizations[civType] == nil or GameInfo.Leaders[leaderType] == nil then
		return false, 'unknown_identity'
	end

	-- 主路径与世界编辑器面板一致（SetPlayerLeader + FULL_CIV）；不可用时退回只改 PlayerConfigurations
	local configured = ConfigureGhostPlayerIdentity(playerID, civType, leaderType,
		'CIVILIZATION_LEVEL_FULL_CIV')
	if not configured then
		ApplyPlayerConfigIdentity(playerID, civType, leaderType, 'CIVILIZATION_LEVEL_FULL_CIV')
	end
	if CallOrNil(function() return Players[playerID]:IsMajor() end) ~= true then
		ApplyPlayerConfigIdentity(playerID, civType, leaderType, 'CIVILIZATION_LEVEL_FULL_CIV')
	end
	if CallOrNil(function() return Players[playerID]:IsMajor() end) ~= true then
		print('[ModMiscTool][Ghost] 主流化失败 player=' .. tostring(playerID)
			.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType))
		return false, 'still_city_state'
	end

	print('[ModMiscTool][Ghost] 主流化 player=' .. tostring(playerID)
		.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType)
		.. '（原身份台账=' .. tostring(record ~= nil) .. '）')
	return true, 'ok'
end

-- 这块地能不能直接建城：陆地 + 不可通行排除 + 没有城市/区域/所有者/单位
local function IsUsableGhostCityPlot(plot)
	if plot == nil then return false end
	if plot:IsWater() then return false end
	if plot:IsImpassable() then return false end
	if plot:IsCity() then return false end
	local owner = plot:GetOwner()
	if owner ~= nil and owner >= 0 then return false end
	if plot:GetUnit() ~= nil then return false end
	local districtType = nil
	pcall(function() districtType = plot:GetDistrictType() end)
	if districtType ~= nil and districtType >= 0 then return false end
	return true
end

-- 建城选址锚点：本地玩家首都 → 地图中心 → 原点
local function GetGhostCitySiteAnchor()
	local localPlayerID = Game.GetLocalPlayer()
	local localPlayer = Players[localPlayerID]
	local capital = nil
	if localPlayer ~= nil then
		local cities = CallOrNil(function() return localPlayer:GetCities() end)
		if cities ~= nil then
			capital = CallOrNil(function() return cities:GetCapitalCity() end)
		end
	end
	if capital ~= nil then
		local capitalX = CallOrNil(function() return capital:GetX() end)
		local capitalY = CallOrNil(function() return capital:GetY() end)
		if capitalX ~= nil and capitalY ~= nil then
			return capitalX, capitalY, 'local_capital'
		end
	end
	local gridWidth, gridHeight = nil, nil
	pcall(function() gridWidth, gridHeight = Map.GetGridSize() end)
	if type(gridWidth) == 'number' and type(gridHeight) == 'number'
		and gridWidth > 0 and gridHeight > 0 then
		return math.floor(gridWidth / 2), math.floor(gridHeight / 2), 'map_center'
	end
	return 0, 0, 'origin'
end

-- 从锚点按环状搜索候选地块（半径 1..maxRadius，够 12 个就停）
local function CollectGhostCitySiteCandidates(anchorX, anchorY, maxRadius)
	local candidates = {}
	for radius = 1, maxRadius do
		for deltaX = -radius, radius do
			for deltaY = -radius, radius do
				if math.max(math.abs(deltaX), math.abs(deltaY)) == radius then
					local plot = Map.GetPlot(anchorX + deltaX, anchorY + deltaY)
					if IsUsableGhostCityPlot(plot) then
						table.insert(candidates, plot)
					end
				end
			end
		end
		if #candidates >= 12 then break end
	end
	return candidates
end

-- 给幽灵建城：自动选址（本地玩家首都附近 → 地图中心），逐个候选尝试
-- 返回：是否成功, 诊断码, x, y
function FoundCityForGhostPlayer(playerID)
	if playerID == nil or Players[playerID] == nil then return false, 'no_player' end
	if not IsKnownGhostPlayer(playerID) then return false, 'not_ghost' end
	if not IsKnownGhostPlayerAvailable(playerID) then return false, 'unavailable' end

	local anchorX, anchorY, anchorLabel = GetGhostCitySiteAnchor()
	local candidates = CollectGhostCitySiteCandidates(anchorX, anchorY, 12)
	-- 首都周边实在没地（群岛/被围死）⇒ 退到地图中心再找一轮
	if #candidates == 0 and anchorLabel == 'local_capital' then
		local gridWidth, gridHeight = nil, nil
		pcall(function() gridWidth, gridHeight = Map.GetGridSize() end)
		if type(gridWidth) == 'number' and type(gridHeight) == 'number'
			and gridWidth > 0 and gridHeight > 0 then
			anchorX, anchorY, anchorLabel = math.floor(gridWidth / 2), math.floor(gridHeight / 2),
				'map_center'
			candidates = CollectGhostCitySiteCandidates(anchorX, anchorY, 12)
		end
	end
	if #candidates == 0 then
		print('[ModMiscTool][Ghost] 建城失败 player=' .. tostring(playerID)
			.. '：锚点=' .. tostring(anchorLabel) .. ' 附近没有可用地块')
		return false, 'no_plot'
	end

	for _, plot in ipairs(candidates) do
		local plotIndex = CallOrNil(function() return plot:GetIndex() end)
		if plotIndex ~= nil then
			local ok, reason = CreateCityForGhostPlayer(playerID, plotIndex)
			if ok then
				local plotX = CallOrNil(function() return plot:GetX() end)
				local plotY = CallOrNil(function() return plot:GetY() end)
				print('[ModMiscTool][Ghost] 幽灵建城 player=' .. tostring(playerID)
					.. ' at ' .. tostring(plotX) .. ',' .. tostring(plotY)
					.. '（锚点=' .. tostring(anchorLabel) .. '）')
				return true, 'ok', plotX, plotY
			end
			print('[ModMiscTool][Ghost] 建城候选失败 player=' .. tostring(playerID)
				.. ' plotIndex=' .. tostring(plotIndex) .. ' reason=' .. tostring(reason))
		end
	end
	return false, 'create_failed'
end

-- 移除幽灵：杀掉它名下所有单位（地图外开拓者是它的“命根子”），再清池 + 清台账
-- 返回：是否成功, 诊断码, 杀死的单位数
function RemoveGhostPlayerByKillingUnits(playerID)
	if playerID == nil or Players[playerID] == nil then return false, 'no_player' end
	if not IsKnownGhostPlayer(playerID) then return false, 'not_ghost' end
	if PlayerOwnsCity(playerID) then return false, 'has_city' end

	-- 先把所有“占用/预约”清掉：这个玩家马上就不存在了
	ReleaseGhostPlayer(playerID)
	ReleaseCityStateGhostPlayer(playerID)

	local player = Players[playerID]
	local unitSnapshot = {}
	local units = CallOrNil(function() return player:GetUnits() end)
	if units ~= nil then
		for _, unit in units:Members() do
			table.insert(unitSnapshot, unit)
		end
	end

	if #unitSnapshot == 0 then
		RemoveGhostPlayerFromPool(playerID, 'debug panel remove（名下没有单位）')
		ForgetGhostOriginalIdentity(playerID)
		print('[ModMiscTool][Ghost] 移除幽灵 player=' .. tostring(playerID) .. '：名下没有单位，只清池')
		return true, 'no_units', 0
	end

	local killed, failed = 0, 0
	for _, unit in ipairs(unitSnapshot) do
		local ok = pcall(function()
			if m_GhostDamageBeforeKill and unit:GetDamage() < 100 then
				unit:SetDamage(100)
			end
			UnitManager.Kill(unit, false)
		end)
		if ok then killed = killed + 1 else failed = failed + 1 end
	end

	RemoveGhostPlayerFromPool(playerID, 'debug panel remove')
	ForgetGhostOriginalIdentity(playerID)
	print('[ModMiscTool][Ghost] 移除幽灵 player=' .. tostring(playerID)
		.. '：杀死单位 ' .. tostring(killed) .. '、失败 ' .. tostring(failed))
	return true, 'ok', killed
end

-- ===========================================================================
-- 调试面板：杀死任意选定玩家（2026-10-26 授权者要求）
--
-- 做法对齐 GrayFox 的 BanPlayer（GrayFox_Script.lua）：把该玩家的城市逐座
--   CityManager.TransferCityToFreeCities(city) 转成自由城市；
-- 只保留“转城”这一步，**不杀单位**——授权者的 Levithan 局里，杀死该玩家单位会
--   触发引擎侧卡死（Lua 与日志都无输出），城市转走已足够让该玩家失去全部城市；
--   剩余单位原样留给测试者处理，结果里回报数量。
-- 没有城市的玩家（幽灵 / 已失去全部城市）：只清幽灵池与占用，同样不动单位。
--
-- 返回：success, reason, transferredCities, failedCities, remainingUnits
-- ===========================================================================
local function CountPlayerUnits(playerID)
	local player = Players[playerID]
	if player == nil then return 0 end
	local units = CallOrNil(function() return player:GetUnits() end)
	if units == nil then return 0 end
	local count = 0
	for _ in units:Members() do
		count = count + 1
	end
	return count
end

function KillSelectedPlayer(playerID)
	if playerID == nil or Players[playerID] == nil then return false, 'no_player' end
	if IsNonSelectablePlayer(playerID) then return false, 'not_killable' end

	local player = Players[playerID]
	local citySnapshot = {}
	local cityCollection = CallOrNil(function() return player:GetCities() end)
	if cityCollection ~= nil then
		for _, city in cityCollection:Members() do
			table.insert(citySnapshot, city)
		end
	end

	-- 池子/台账统一清理：对普通玩家是空操作，对已激活的幽灵则把它摘出去
	local function ClearGhostBookkeeping(reason)
		ReleaseGhostPlayer(playerID)
		ReleaseCityStateGhostPlayer(playerID)
		RemoveGhostPlayerFromPool(playerID, reason)
		ForgetGhostOriginalIdentity(playerID)
	end

	-- 没有城市：只清池，不杀单位（避免复现卡死）
	if #citySnapshot == 0 then
		ClearGhostBookkeeping('debug kill（名下没有城市）')
		local remainingUnits = CountPlayerUnits(playerID)
		print('[ModMiscTool][Ghost] 杀死玩家 player=' .. tostring(playerID)
			.. '：名下没有城市，只清池；剩余单位 ' .. tostring(remainingUnits) .. '（未杀单位）')
		return true, 'no_city', 0, 0, remainingUnits
	end

	if CityManager.TransferCityToFreeCities == nil then return false, 'no_api' end

	local transferred, failed = 0, 0
	for _, city in ipairs(citySnapshot) do
		local ok, result = pcall(function()
			return CityManager.TransferCityToFreeCities(city)
		end)
		-- 有的版本失败时返回 false 而不是抛错，两种都算失败
		if ok and result ~= false then
			transferred = transferred + 1
		else
			failed = failed + 1
		end
	end

	ClearGhostBookkeeping('debug kill（城市已转自由城市）')
	local remainingUnits = CountPlayerUnits(playerID)
	print('[ModMiscTool][Ghost] 杀死玩家 player=' .. tostring(playerID)
		.. '：转自由城市 ' .. tostring(transferred) .. '、失败 ' .. tostring(failed)
		.. '；剩余单位 ' .. tostring(remainingUnits) .. '（未杀单位）')
	return true, 'ok', transferred, failed, remainingUnits
end

-- 空槽位：玩家配置里没有文明类型（EXera 的 FindEmptyPlayerSlot）
local function FindEmptyPlayerSlot()
	for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
		local playerConfig = PlayerConfigurations[playerID]
		if playerConfig ~= nil then
			local civType = playerConfig:GetCivilizationTypeName()
			if civType == nil or civType == '' then
				return playerID
			end
		end
	end
	return nil
end

-- ===========================================================================
-- 诊断：补建失败时定位“卡在哪一步”
--   1) DumpPlayerSlots —— 槽位全貌：引擎实际建了几个玩家、还剩几个空槽位
--   2) DescribeSlot    —— 单个槽位的“配置侧 + 引擎侧”状态
--   3) SetConfigEx     —— 每个 setter 单独 pcall 并回读，区分“没这个 API”和“设了没生效”
-- ===========================================================================
local m_LastCreateDiagnostics = nil

local SLOT_STATUS_NAMES = {}
if SlotStatus ~= nil then
	if SlotStatus.SS_OPEN ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_OPEN] = 'SS_OPEN' end
	if SlotStatus.SS_COMPUTER ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_COMPUTER] = 'SS_COMPUTER' end
	if SlotStatus.SS_TAKEN ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_TAKEN] = 'SS_TAKEN' end
	if SlotStatus.SS_CLOSED ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_CLOSED] = 'SS_CLOSED' end
end

local function SlotStatusName(status)
	if status == nil then
		return 'nil'
	end
	return SLOT_STATUS_NAMES[status] or ('#' .. tostring(status))
end


local function MaxPlayerSlots()
	local maxSlots = CallOrNil(function() return GameDefines.MAX_PLAYERS end)
	if type(maxSlots) ~= 'number' or maxSlots <= 0 then
		return 64
	end
	return maxSlots
end

-- ===========================================================================
-- 城邦化：把“幽灵化的主要文明”改造成城邦（2026-10-15 补实现）
--
-- 【为什么需要】幽灵化的主流玩家仍是大文明 ⇒ 会走领袖场景那套外交（AI 来交涉、进外交界面）。
-- 授权者定的做法：走**换领袖 + 换文明 + 文明等级**——就是地图编辑器/面板「应用」用的同一个
-- 接口 WorldBuilder.PlayerManager():SetPlayerLeader(id, leader, civ, 'CIVILIZATION_LEVEL_CITY_STATE')。
-- **不调用 StartCityState()**：给空槽位造玩家时它不生效，给已存在玩家用时又与一次
-- “开局加载出错”同时出现过（属未定责的坑，见 API_Verification_Status 第 29/31 条）。
--
-- 【硬保护】已经有城市的玩家直接拒绝（移除全部城市会让玩家当场死亡，开拓者也救不回来）。
-- 【时机】只能在游戏跑起来之后执行：**正常入口 = 本地玩家建第一座城时自动批量**
--        （TryAutoConvertGhostsOnFirstCity，2026-10-26 恢复）；手动入口按 2026-10-17 定案拦截。
--        在加载过渡阶段批量改身份会把开局搞挂 —— 实测两次复现，所以不要挂到 LoadGameViewStateDone 上。
--
-- 注：2026-10-15 之前这三个调用点（本函数、面板按钮、GHOST_CONVERT_MAJOR_TO_CITY_STATE 开关）
--     引用的是一个**从未定义**的函数，所以「城邦化选中玩家」按钮一直是空点。
-- ===========================================================================

-- 地图上已经被占用的文明（挑城邦时避开，免得凭空多出重复城邦）
local function CollectCivTypesInUse()
	local used = {}
	for playerID = 0, MaxPlayerSlots() - 1 do
		local playerConfig = PlayerConfigurations[playerID]
		if playerConfig ~= nil then
			local civType = CallOrNil(function()
				return playerConfig:GetCivilizationTypeName()
			end)
			if civType ~= nil and civType ~= '' then used[civType] = true end
		end
	end
	return used
end

-- 挑一个还没人用的城邦文明；全被占了就退回第一个（允许重复，但会打日志）
local function PickCityStateCivForConversion()
	local used = CollectCivTypesInUse()
	local fallback = nil
	for _, civType in ipairs(GetCityStateCivTypes()) do
		if used[civType] ~= true then return civType end
		if fallback == nil then fallback = civType end
	end
	return fallback
end

-- ===========================================================================
-- 城邦身份的**合规校验与修复**（2026-10-15 授权者报“官方城邦界面按钮点不开”后补）
--
-- 硬规则：一个玩家被当作城邦时，必须同时满足
--   ① 文明是城邦级（StartingCivilizationLevelType = CIVILIZATION_LEVEL_CITY_STATE）
--   ② 领袖是**小文明原型**（Leaders.InheritFrom 非空：SCIENTIFIC/TRADE/… 那一层）
-- 为什么：官方城邦面板（Assets/UI/PartialScreens/CityStates.lua）用领袖原型查加成文本，
--   查不到时 GetBonusText 只返回 "UNKNOWN"（Details 为 nil），而面板会无条件拼接
--   `Bonuses[1].Title .. "[NEWLINE]" .. Bonuses[1].Details` ⇒ 拼接 nil 直接报错 ⇒
--   **整个城邦面板打不开（按钮点了没反应）**。
-- 我们的城邦化有一条兜底路径是“只把 PlayerConfigurations 标成 minor”，如果领袖没换成
--   小文明原型，就会留下这种半成品状态 —— 所以这里既做校验也做修复。
-- ===========================================================================

local function IsCityStateLeaderArchetype(leaderType)
	if leaderType == nil then return false end
	local leaderRow = GameInfo.Leaders[leaderType]
	return leaderRow ~= nil and leaderRow.InheritFrom ~= nil
end

local function IsCityStateLevelCivType(civType)
	if civType == nil then return false end
	local civRow = GameInfo.Civilizations[civType]
	return civRow ~= nil
		and civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE'
end

-- 读回玩家当前身份（读不到就是 nil）
local function GetPlayerIdentityTypes(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return nil, nil end
	local civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
	local leaderType = CallOrNil(function() return playerConfig:GetLeaderTypeName() end)
	return civType, leaderType
end

-- 身份是否合规（对外暴露：面板/其它 mod 自检用）
function IsLegalCityStateIdentity(playerID)
	local civType, leaderType = GetPlayerIdentityTypes(playerID)
	return IsCityStateLevelCivType(civType) and IsCityStateLeaderArchetype(leaderType)
end

-- 把某玩家改成合规的城邦身份（文明级 + 小文明原型领袖）；改不成返回 false
local function ApplyLegalCityStateIdentity(playerID)
	local civType = GetPlayerIdentityTypes(playerID)
	local targetCiv = IsCityStateLevelCivType(civType) and civType or PickCityStateCivForConversion()
	if targetCiv == nil then return false, 'no city-state civilization available' end
	local targetLeader = GetDefaultLeaderType(targetCiv)
	if not IsCityStateLeaderArchetype(targetLeader) then
		return false, 'no archetype leader for ' .. tostring(targetCiv)
	end
	ApplyPlayerConfigIdentity(playerID, targetCiv, targetLeader, 'CIVILIZATION_LEVEL_CITY_STATE')
	if not IsLegalCityStateIdentity(playerID) then
		return false, 'identity still illegal after apply'
	end
	return true
end

-- 自检 + 修复：扫所有“城邦玩家”（非蛮族、非自由城市），把身份不合规的修好。
-- 返回：合规数, 修复数, 失败数
function RepairCityStatePlayerIdentities()
	local okCount, repaired, failed = 0, 0, 0
	local failedIDs = {}
	for playerID = 0, MaxPlayerSlots() - 1 do
		local player = Players[playerID]
		if player ~= nil and CallOrNil(function() return player:IsMajor() end) == false then
			local isBarbarian = CallOrNil(function() return player:IsBarbarian() end)
			local civType = GetPlayerIdentityTypes(playerID)
			local isFreeCity = civType ~= nil and string.find(civType, 'FREE_CITIES') ~= nil
			-- 【空槽位】配置里连文明都没有 = 引擎没给这个槽位建玩家（IsMajor() 也会返回 false）
			-- ⇒ 不是城邦，**不要修**（否则会把空槽位当城邦乱改）
			local isEmptySlot = (civType == nil or civType == '')
			if isBarbarian ~= true and not isFreeCity and not isEmptySlot then
				if IsLegalCityStateIdentity(playerID) then
					okCount = okCount + 1
				else
					local fixed, reason = ApplyLegalCityStateIdentity(playerID)
					if fixed then
						repaired = repaired + 1
						print('[ModMiscTool][Ghost] 城邦身份已修复 player=' .. tostring(playerID)
							.. ' civ=' .. tostring(select(1, GetPlayerIdentityTypes(playerID)))
							.. ' leader=' .. tostring(select(2, GetPlayerIdentityTypes(playerID))))
					else
						failed = failed + 1
						table.insert(failedIDs, tostring(playerID) .. '(' .. tostring(reason) .. ')')
					end
				end
			end
		end
	end
	print('[ModMiscTool][Ghost] 城邦身份自检：合规 ' .. tostring(okCount)
		.. '、修复 ' .. tostring(repaired)
		.. '、失败 ' .. tostring(failed)
		.. (#failedIDs > 0 and ('（失败：' .. table.concat(failedIDs, '、') .. '）') or ''))
	return okCount, repaired, failed
end

-- ===========================================================================
-- 【2026-10-15 授权者】**已经和本地玩家见过面的幽灵不许留在城邦体系里**
--
-- 授权者定位：某个幽灵开局时被本地玩家看到（外交列表里显示为“被压制”），后来又被转成城邦，
-- 于是官方城邦面板在它身上取外交关系透镜数据时拿到 nil：
--   `CityStates_PHONE.lua:380  DIPLO_PIP_INFO[kCityState.DiplomaticState].IconName`
--   （该玩家的外交状态是 -1 ⇒ DiplomaticState=nil ⇒ 索引 nil ⇒ 面板构建中断 ⇒ 打不开），
-- 而城邦面板是“给城邦派使者”这个**回合拦截项**的出口 ⇒ 面板打不开 = 无法进入下一回合。
--
-- 处理：
--   ① 已经见面的幽灵 → **转回主流玩家**（用进池子时记的原身份台账复原，见 RestoreMetGhostsAsMajorPlayers）；
--   ② 以后主流转城邦时**过滤掉已见面的**（见 ConvertGhostPlayerToCityState 开头的检查）。
-- ⚠️ 改身份不要在开局加载阶段批量做（实机撞过：加载会被中止）—— 所以①只挂在面板按钮上，
--    由授权者手动触发，触发完按流程存档重读。
-- ===========================================================================
-- 把“已经和本地玩家见过面”的幽灵转回主流玩家（原身份台账复原）。
-- 返回：恢复数, 跳过数（本来就是主流）, 失败数
function RestoreMetGhostsAsMajorPlayers()
	local restored, skipped, failed = 0, 0, 0
	local notes = {}
	local record = GetGhostOriginalIdentities()
	for playerID, entry in pairs(record) do
		local player = Players[playerID]
		if player ~= nil and LocalPlayerHasMet(playerID) then
			local isMajor = CallOrNil(function() return player:IsMajor() end)
			if isMajor == true then
				skipped = skipped + 1
			else
				local civType, leaderType = entry.civ, entry.leader
				if civType == nil or leaderType == nil then
					failed = failed + 1
					table.insert(notes, tostring(playerID) .. '(台账缺文明/领袖)')
				else
					ApplyPlayerConfigIdentity(playerID, civType, leaderType, 'CIVILIZATION_LEVEL_FULL_CIV')
					if CallOrNil(function() return player:IsMajor() end) == true then
						restored = restored + 1
						table.insert(notes, tostring(playerID) .. '=' .. tostring(civType))
						print('[ModMiscTool][Ghost] 见面幽灵转回主流：player=' .. tostring(playerID)
							.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType))
					else
						failed = failed + 1
						table.insert(notes, tostring(playerID) .. '(转回失败)')
					end
				end
			end
		end
	end
	print('[ModMiscTool][Ghost] 见面幽灵转回主流：恢复 ' .. tostring(restored)
		.. '、本来就是主流 ' .. tostring(skipped) .. '、失败 ' .. tostring(failed)
		.. (#notes > 0 and ('（' .. table.concat(notes, '、') .. '）') or ''))
	return restored, skipped, failed
end

-- conversionSource：入口标识。'auto_first_city' = 本地玩家建首城时的自动批量；
--                   'debug_panel' = 幽灵 debug 面板上的显式按钮；
--                   其它 / 省略 = 手动，按 2026-10-17 定案拦截（见文件顶部入口表）。
function ConvertGhostPlayerToCityState(playerID, civType, conversionSource)
	if playerID == nil then return false, 'no player' end
	if Players[playerID] == nil then return false, 'player not found' end

	-- 硬保护：已经有城市 ⇒ 拒绝（拆城 = 玩家死亡）
	local blockReason = GetGhostifyBlockReason(playerID)
	if blockReason ~= nil then
		print('[ModMiscTool][Ghost] 拒绝城邦化玩家 ' .. tostring(playerID) .. '：' .. tostring(blockReason))
		return false, blockReason
	end

	-- 本来就是城邦（IsMajor() == false）⇒ 视为已完成；但身份不合规要顺手修好
	-- （老版本留下的“城邦玩家 + 主流领袖”半成品会让官方城邦面板打不开）
	local isMajor = CallOrNil(function() return Players[playerID]:IsMajor() end)
	if isMajor == false then
		if IsLegalCityStateIdentity(playerID) then
			print('[ModMiscTool][Ghost] 玩家 ' .. tostring(playerID) .. ' 已经是城邦，跳过')
			return true, 'already city-state'
		end
		local fixed, reason = ApplyLegalCityStateIdentity(playerID)
		print('[ModMiscTool][Ghost] 玩家 ' .. tostring(playerID)
			.. ' 已是城邦但身份不合规，修复=' .. tostring(fixed) .. '（' .. tostring(reason or 'ok') .. '）')
		if fixed then return true, 'already city-state (identity repaired)' end
		return false, 'illegal city-state identity: ' .. tostring(reason)
	end

	-- 【授权者 2026-10-26】入口授权：手动/其它 mod 调用仍按 2026-10-17 定案拦截；
	-- 只有"建首城自动批量"（auto_first_city）这一个入口放行。
	if not IsMajorToCityStateConversionAllowed(conversionSource) then
		print('[ModMiscTool][Ghost] 拒绝城邦化 player=' .. tostring(playerID)
			.. '：入口=' .. tostring(conversionSource or 'manual')
			.. '（主流→城邦只对"建首城自动批量"和"幽灵 debug 面板"开放）')
		return false, 'major to city-state conversion blocked'
	end

	-- 【2026-10-15 授权者】已经和本地玩家见过面的**不许**转城邦：
	-- 见面的玩家进了外交关系数据，转成城邦后官方城邦面板取关系透镜数据拿到 nil ⇒ 面板打不开
	-- ⇒ “给城邦派使者”这个回合拦截项卡死 ⇒ 无法进入下一回合。见面的要留在主流体系里。
	if LocalPlayerHasMet(playerID) then
		print('[ModMiscTool][Ghost] 拒绝城邦化玩家 ' .. tostring(playerID)
			.. '：本地玩家已经见过它（见面幽灵留在主流体系）')
		return false, 'local player has already met this player (keep as major)'
	end

	if civType == nil then civType = PickCityStateCivForConversion() end
	if civType == nil then return false, 'no city state civilization in database' end
	local leaderType = GetDefaultLeaderType(civType)
	if leaderType == nil then
		return false, 'no leader for ' .. tostring(civType)
	end

	-- 主路径：世界编辑器那套（与面板「应用」同一个接口）
	local applied = false
	if WorldBuilder ~= nil and WorldBuilder.PlayerManager ~= nil then
		applied = CallOrNil(function()
			WorldBuilder.PlayerManager():SetPlayerLeader(playerID, leaderType, civType,
				'CIVILIZATION_LEVEL_CITY_STATE')
			return true
		end) == true
	end
	if not applied then
		print('[ModMiscTool][Ghost] SetPlayerLeader 不可用，退回只改 PlayerConfigurations')
	end

	-- 判定标准（授权者定）：转换后 player:IsMajor() 是否变成 false
	local stillMajor = CallOrNil(function() return Players[playerID]:IsMajor() end)
	if stillMajor ~= false then
		ApplyPlayerConfigIdentity(playerID, civType, leaderType, 'CIVILIZATION_LEVEL_CITY_STATE')
		-- 【硬规则】只有身份合规（文明级 + 小文明原型领袖）才允许补 minor 标记：
		-- 否则会留下“城邦玩家 + 主流领袖”的半成品，官方城邦面板取不到加成文本 ⇒ 面板打不开。
		if IsLegalCityStateIdentity(playerID) then
			local playerConfig = PlayerConfigurations[playerID]
			if playerConfig ~= nil and playerConfig.SetIsMinorCiv ~= nil then
				pcall(function() playerConfig:SetIsMinorCiv(true) end)
			end
		else
			print('[ModMiscTool][Ghost] 玩家 ' .. tostring(playerID)
				.. ' 身份不合规（领袖不是小文明原型），拒绝只打 minor 标记')
		end
		stillMajor = CallOrNil(function() return Players[playerID]:IsMajor() end)
	end

	-- 二次校验：已经是城邦但身份不合规 ⇒ 强修；修不好就撤回 minor 标记（宁可不成，也别留半成品）
	if stillMajor == false and not IsLegalCityStateIdentity(playerID) then
		local fixed, reason = ApplyLegalCityStateIdentity(playerID)
		if not fixed then
			print('[ModMiscTool][Ghost] 城邦化玩家 ' .. tostring(playerID)
				.. ' 身份修不好（' .. tostring(reason) .. '），撤回 minor 标记')
			local playerConfig = PlayerConfigurations[playerID]
			if playerConfig ~= nil and playerConfig.SetIsMinorCiv ~= nil then
				pcall(function() playerConfig:SetIsMinorCiv(false) end)
			end
			return false, 'illegal city-state identity: ' .. tostring(reason)
		end
	end

	local ok = (stillMajor == false) and IsLegalCityStateIdentity(playerID)
	print('[ModMiscTool][Ghost] 城邦化玩家 ' .. tostring(playerID)
		.. ' civ=' .. tostring(civType) .. ' leader=' .. tostring(leaderType)
		.. ' setPlayerLeader=' .. tostring(applied)
		.. ' IsMajor=' .. tostring(stillMajor)
		.. ' 身份合规=' .. tostring(IsLegalCityStateIdentity(playerID))
		.. ' => ' .. (ok and 'OK' or 'FAILED'))
	if ok then return true end
	-- 注意别写 `return ok, ok and nil or '...'`：Lua 里 nil 为假，成功时也会返回那个字符串
	return false, 'city-state conversion failed (IsMajor=' .. tostring(stillMajor)
		.. ', legalIdentity=' .. tostring(IsLegalCityStateIdentity(playerID)) .. ')'
end

-- 一键：把所有“还在池子里且仍是 off-map”的主流幽灵都城邦化
-- （已经有城市的会被顺手移出池子；被带回地图使用中的会跳过）
-- conversionSource：入口标识，原样传给 ConvertGhostPlayerToCityState（见那里的说明）。
function ConvertAllGhostMajorPlayersToCityState(conversionSource, options)
	local snapshot = {}
	for _, ghostID in ipairs(GetGhostPlayers()) do
		table.insert(snapshot, ghostID)
	end
	local converted, failed, skipped = 0, 0, 0
	for _, ghostID in ipairs(snapshot) do
		if PlayerOwnsCity(ghostID) then
			RemoveGhostPlayerFromPool(ghostID, "已有城市（不再算主流幽灵）")
			skipped = skipped + 1
		elseif options ~= nil and options.skipNonMajor == true
			and CallOrNil(function() return Players[ghostID]:IsMajor() end) ~= true then
			-- 救档口径：只处理“当前仍是主流”的幽灵（已城邦化的不算新转换）
			skipped = skipped + 1
		elseif not IsGhostPlayerAvailable(ghostID) then
			skipped = skipped + 1
		elseif LocalPlayerHasMet(ghostID) then
			-- 【2026-10-15 授权者】已经见过面的幽灵**不转城邦**：见了面就进了外交关系数据，
			-- 转成城邦后官方城邦面板取不到关系透镜数据 ⇒ 面板打不开 ⇒ 回合被拦截项卡死。
			-- 这些留在主流体系里（要转回主流用 RestoreMetGhostsAsMajorPlayers）。
			print('[ModMiscTool][Ghost] 批量城邦化跳过 player=' .. tostring(ghostID)
				.. '：本地玩家已经见过它')
			skipped = skipped + 1
		else
			local ok = ConvertGhostPlayerToCityState(ghostID, nil, conversionSource)
			if ok then converted = converted + 1 else failed = failed + 1 end
		end
	end
	print('[ModMiscTool][Ghost] 批量城邦化完成：converted=' .. tostring(converted)
		.. ' failed=' .. tostring(failed) .. ' skipped=' .. tostring(skipped)
		.. ' 入口=' .. tostring(conversionSource or 'manual')
		.. '（池子里共 ' .. tostring(#snapshot) .. ' 个）')
	return converted, failed, skipped
end

-- 救档（2026-10-26 授权者要求）：一键把**还没和本地玩家见过面**的主流幽灵转成城邦。
-- 复用批量入口（它会跳过见面 / 不可用的），只额外要求“当前仍是主流”，
-- 避免把已经城邦化过的幽灵算成“本次转换”。
function ConvertUnmetMajorGhostsToCityState()
	local converted, failed, skipped = ConvertAllGhostMajorPlayersToCityState('debug_panel',
		{ skipNonMajor = true })
	print('[ModMiscTool][Ghost] 救档（未见面主流→城邦）：converted=' .. tostring(converted)
		.. ' failed=' .. tostring(failed) .. ' skipped=' .. tostring(skipped))
	return converted, failed, skipped
end

-- CityStates 表里该城邦文明对应的城邦类型（EXera 会额外设这一个字段）
local function GetCityStateTypeFor(civType)
	if GameInfo.CityStates == nil then
		print("[ModMiscTool][Ghost] GameInfo.CityStates is nil（本版本没有城邦类型表）")
		return nil
	end
	for cityStateRow in GameInfo.CityStates() do
		if cityStateRow.CivilizationType == civType then
			return cityStateRow.CityStateType
		end
	end
	return nil
end

local function DescribeSlot(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then
		return "slot " .. tostring(playerID) .. " config=nil"
	end
	local civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
	local leaderType = CallOrNil(function() return playerConfig:GetLeaderTypeName() end)
	local cityStateType = CallOrNil(function() return playerConfig:GetCityStateType() end)
	local isMinorCiv = CallOrNil(function() return playerConfig:IsMinorCiv() end)
	local slotStatus = CallOrNil(function() return playerConfig:GetSlotStatus() end)

	local player = Players[playerID]
	local engineState = 'enginePlayer=nil'
	if player ~= nil then
		local alive = CallOrNil(function() return player:IsAlive() end)
		local unitCount = nil
		local units = CallOrNil(function() return player:GetUnits() end)
		if units ~= nil then
			unitCount = 0
			for _ in units:Members() do
				unitCount = unitCount + 1
			end
		end
		local capital = CallOrNil(function() return player:GetCapitalCity() end)
		engineState = 'enginePlayer=yes alive=' .. tostring(alive)
			.. ' units=' .. tostring(unitCount)
			.. ' capital=' .. tostring(capital ~= nil)
	end
	return "slot " .. tostring(playerID)
		.. " civ=" .. tostring(civType)
		.. " leader=" .. tostring(leaderType)
		.. " csType=" .. tostring(cityStateType)
		.. " isMinor=" .. tostring(isMinorCiv)
		.. " status=" .. SlotStatusName(slotStatus)
		.. " " .. engineState
end

local function DumpPlayerSlots(tag)
	local emptySlots = {}
	local enginePlayerCount = 0
	local majorCount, minorCount, otherCount = 0, 0, 0
	for playerID = 0, MaxPlayerSlots() - 1 do
		local playerConfig = PlayerConfigurations[playerID]
		if playerConfig == nil then
			table.insert(emptySlots, tostring(playerID) .. '(noConfig)')
		else
			local civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
			if civType == nil or civType == '' then
				table.insert(emptySlots, tostring(playerID))
			else
				local civRow = GameInfo.Civilizations[civType]
				if civRow ~= nil and civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE' then
					minorCount = minorCount + 1
				elseif string.find(civType, 'BARBARIAN') ~= nil or string.find(civType, 'FREE_CITIES') ~= nil then
					otherCount = otherCount + 1
				else
					majorCount = majorCount + 1
				end
			end
		end
		if Players[playerID] ~= nil then
			enginePlayerCount = enginePlayerCount + 1
		end
	end
	print("[ModMiscTool][Ghost] slotdump(" .. tag .. ") MAX_PLAYERS=" .. tostring(MaxPlayerSlots())
		.. " enginePlayers=" .. tostring(enginePlayerCount)
		.. " major=" .. tostring(majorCount) .. " minor=" .. tostring(minorCount)
		.. " barbOrFree=" .. tostring(otherCount)
		.. " emptySlots=" .. tostring(#emptySlots))
	print("[ModMiscTool][Ghost] slotdump(" .. tag .. ") empty slot ids: "
		.. (#emptySlots > 0 and table.concat(emptySlots, ',') or 'none'))
	return {
		emptySlots = emptySlots,
		enginePlayers = enginePlayerCount,
		major = majorCount,
		minor = minorCount,
		barbOrFree = otherCount,
	}
end

-- 每个 setter 单独 pcall + 回读
local function SetConfigEx(playerConfig, label, setter, reader)
	local ok, err = pcall(setter)
	local readBack = nil
	if reader ~= nil then
		readBack = CallOrNil(reader)
	end
	print("[ModMiscTool][Ghost]   set " .. label
		.. " ok=" .. tostring(ok)
		.. (ok and '' or (' err=' .. tostring(err)))
		.. (reader ~= nil and (' -> read ' .. tostring(readBack)) or ''))
	return ok
end

-- [已验证失败] 运行时补建玩家对象：引擎不兑现。
--   设备实测（2026-10）：PlayerConfigurations 改得动、回读也对，但 Players[slot] 恒为 nil，
--   日志 `slot N configured but not created by engine`；城邦与主要文明两条路结论一致。
--   且 EXera 的 CreateCityStatePlayer 在其工程里零调用点（死代码），此路从未被真正走通。
--   本函数因此只保留作“验证引擎限制”的诊断入口（面板两个「补建幽灵槽位」按钮），
--   正常扩容请走 InitializeGhostPlayers / InitializeGhostMajorPlayers（抬上限路线）。
-- 运行时补建一个槽位；成功返回 playerID，失败返回 nil + 原因（同时打到日志）。
--   civType 省略：轮流用一个城邦文明（EXera 路径）
--   civType 给定：用指定文明；主要文明走同样的配置流程（isMinor=false、SS_TAKEN）
-- 用途：验证“不能重复文明 / 玩家数量上限”是否只在 UI 层。
function CreateGhostPlayerFromEmptySlot(civType)
	local civRow = nil
	local isMinor = true

	local cityStateCivTypes = GetCityStateCivTypes()
	local majorCivTypes = GetMajorCivTypes()

	if civType == nil then
		if #cityStateCivTypes == 0 then
			print("[ModMiscTool][Ghost] no city state civ type in database")
			m_LastCreateDiagnostics = 'db has no city-state civ'
			return nil, m_LastCreateDiagnostics
		end
		civType = cityStateCivTypes[(#GetGhostPlayers() % #cityStateCivTypes) + 1]
		civRow = GameInfo.Civilizations[civType]
	else
		civRow = GameInfo.Civilizations[civType]
		if civRow == nil then
			print("[ModMiscTool][Ghost] unknown civ type " .. tostring(civType))
			m_LastCreateDiagnostics = 'unknown civ ' .. tostring(civType)
			return nil, m_LastCreateDiagnostics
		end
		isMinor = civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE'
	end

	print("[ModMiscTool][Ghost] create request: civ=" .. tostring(civType)
		.. " minor=" .. tostring(isMinor)
		.. " db cityStates=" .. tostring(#cityStateCivTypes)
		.. " db majors=" .. tostring(#majorCivTypes))

	local slotStats = DumpPlayerSlots('before-create')
	local slot = FindEmptyPlayerSlot()
	if slot == nil then
		print("[ModMiscTool][Ghost] no empty player slot")
		print("[ModMiscTool][Ghost] 结论：引擎已把 " .. tostring(MaxPlayerSlots())
			.. " 个槽位全部占满，没有可补建的槽位")
		m_LastCreateDiagnostics = 'no empty slot'
		return nil, m_LastCreateDiagnostics
	end
	print("[ModMiscTool][Ghost] picked empty slot " .. tostring(slot)
		.. " (empty slots: " .. table.concat(slotStats.emptySlots, ',') .. ")")

	-- 城邦走 EXera 的完整路径：除文明类型外还要给 CityStates 表里的城邦类型
	local cityStateType = nil
	if isMinor then
		cityStateType = GetCityStateTypeFor(civType)
		print("[ModMiscTool][Ghost] city state type for " .. tostring(civType)
			.. " = " .. tostring(cityStateType))
	end

	local leaderType = GetDefaultLeaderType(civType)
	print("[ModMiscTool][Ghost] creating player at slot " .. tostring(slot)
		.. " civ=" .. tostring(civType) .. " leader=" .. tostring(leaderType)
		.. " csType=" .. tostring(cityStateType) .. " minor=" .. tostring(isMinor))
	print("[ModMiscTool][Ghost]   before config: " .. DescribeSlot(slot))

	local playerConfig = PlayerConfigurations[slot]
	if playerConfig == nil then
		print("[ModMiscTool][Ghost] PlayerConfigurations[" .. tostring(slot) .. "]=nil")
		m_LastCreateDiagnostics = 'no player config for slot ' .. tostring(slot)
		return nil, m_LastCreateDiagnostics
	end

	SetConfigEx(playerConfig, 'civType=' .. tostring(civType),
		function() playerConfig:SetCivilizationTypeName(civType) end,
		function() return playerConfig:GetCivilizationTypeName() end)
	if cityStateType ~= nil then
		SetConfigEx(playerConfig, 'cityStateType=' .. tostring(cityStateType),
			function() playerConfig:SetCityStateType(cityStateType) end,
			function() return playerConfig:GetCityStateType() end)
	end
	if leaderType ~= nil then
		SetConfigEx(playerConfig, 'leaderType=' .. tostring(leaderType),
			function() playerConfig:SetLeaderTypeName(leaderType) end,
			function() return playerConfig:GetLeaderTypeName() end)
	end
	SetConfigEx(playerConfig, 'isMinorCiv=' .. tostring(isMinor),
		function() playerConfig:SetIsMinorCiv(isMinor) end)
	SetConfigEx(playerConfig, 'slotStatus=' .. SlotStatusName(isMinor and SlotStatus.SS_COMPUTER or SlotStatus.SS_TAKEN),
		function() playerConfig:SetSlotStatus(isMinor and SlotStatus.SS_COMPUTER or SlotStatus.SS_TAKEN) end,
		function() return playerConfig:GetSlotStatus() end)

	local player = Players[slot]
	if player == nil then
		print("[ModMiscTool][Ghost] Players[" .. tostring(slot) .. "]=nil"
			.. "（配置写进去了，但引擎没在运行时生成玩家对象）")
	else
		local started, startErr = pcall(function() player:StartCityState() end)
		print("[ModMiscTool][Ghost]   StartCityState ok=" .. tostring(started)
			.. (started and '' or (' err=' .. tostring(startErr))))
	end

	-- 引擎没有把玩家建出来的话，这里如实返回 nil，别把空槽位当幽灵记进池子
	if Players[slot] == nil then
		print("[ModMiscTool][Ghost] slot " .. tostring(slot) .. " configured but not created by engine")
		print("[ModMiscTool][Ghost] 结论：运行时补建玩家对象不被引擎支持"
			.. "（PlayerConfigurations 改得动、回读也对，但 Players[] 不会多出玩家；"
			.. "EXera 的 CreateCityStatePlayer 也没有任何调用点，属死代码）")
		DumpPlayerSlots('after-create-failed')
		m_LastCreateDiagnostics = 'engine did not create player at slot ' .. tostring(slot)
		return nil, m_LastCreateDiagnostics
	end

	print("[ModMiscTool][Ghost]   after config: " .. DescribeSlot(slot))
	MovePlayerOffMap(slot)
	local ghosts = GetGhostPlayers()
	table.insert(ghosts, slot)
	Game:SetProperty(GHOST_PLAYER_PROPERTY, ghosts)
	DumpPlayerSlots('after-create-ok')

	print("[ModMiscTool][Ghost] created ghost player " .. tostring(slot)
		.. " as " .. tostring(civType) .. " pool total=" .. tostring(#ghosts))
	m_LastCreateDiagnostics = nil
	return slot
end

-- 最近一次补建失败的原因（面板直接显示，省得每次拉日志）
function GetLastGhostCreateDiagnostics()
	return m_LastCreateDiagnostics
end

-- [已验证失败] 同 CreateGhostPlayerFromEmptySlot：主要文明也补建不出来（引擎不生成玩家对象）。
-- 保留仅为诊断对比用。
function CreateGhostPlayerFromMajorCiv(civType)
	if civType == nil then
		local majorCivTypes = GetMajorCivTypes()
		if #majorCivTypes == 0 then
			print("[ModMiscTool][Ghost] no major civ type in database")
			return nil
		end
		civType = majorCivTypes[(#GetGhostPlayers() % #majorCivTypes) + 1]
	end
	return CreateGhostPlayerFromEmptySlot(civType)
end

-- ===========================================================================
-- 开局建立幽灵玩家池
-- ===========================================================================

-- [已验证失败] player:IsMinor() 在 gameplay 层不可用（报 function expected instead of nil），
-- 只有 UI 端有。
-- 因此城邦候选列表由 UI 端算好，这里通过 ExposedMembers 取；万一 UI 端还没暴露，
-- 退回 gameplay 端可用的 IsMajor/IsBarbarian 判断（基座 VikingScenario 等即用此法）。
local function GetUnsettledCityStatePlayerIDs()
	local uiMembers = ExposedMembers.ModMiscToolUI
	if uiMembers ~= nil and uiMembers.GetUnsettledCityStatePlayerIDsUI ~= nil then
		return uiMembers.GetUnsettledCityStatePlayerIDsUI()
	end

	print("[ModMiscTool][Ghost] UI helper missing, falling back to IsMajor check")
	local playerIDs = {}
	for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
		local player = Players[playerID]
		if player ~= nil and not player:IsMajor() and not player:IsBarbarian() then
			local cities = player:GetCities()
			if cities == nil or cities:GetCapitalCity() == nil then
				table.insert(playerIDs, playerID)
			end
		end
	end
	return playerIDs
end

-- 把候选里“超出 keepOnMap”的部分搬到地图外并入池子。
-- 从末尾往前取：引擎给玩家原本配置的槽位 id 更小，留在地图上的就是玩家自己选的那批。
-- beforeMove：可选钩子，在“搬离地图”之前对该玩家做一次加工（主要文明用它做城邦化）
-- ghostLimit：可选申报上限（nil = 不限额）——申报多少就最多搬多少
local function AddGhostsFromCandidates(candidates, keepOnMap, tag, skipPlayerID, beforeMove,
	ghostLimit)
	local ghosts = GetGhostPlayers()
	local knownGhosts = {}
	for _, ghostID in ipairs(ghosts) do
		knownGhosts[ghostID] = true
	end

	local ghostCount = math.min(#candidates - keepOnMap, GHOST_PLAYER_MAX)
	if ghostLimit ~= nil and ghostCount > ghostLimit then ghostCount = ghostLimit end
	if ghostCount <= 0 then
		print("[ModMiscTool][Ghost] " .. tag .. ": nothing to move (candidates="
			.. tostring(#candidates) .. " keep=" .. tostring(keepOnMap) .. ")")
		return 0, #ghosts, 0
	end

	local added = 0
	local processed = 0
	for index = #candidates, #candidates - ghostCount + 1, -1 do
		local playerID = candidates[index]
		if playerID ~= skipPlayerID and not knownGhosts[playerID] then
			-- 进池子前先记“引擎那份原身份”（之后改身份也不影响台账）
			RecordGhostOriginalIdentity(playerID, tag)
			-- 先加工再搬：主要文明城邦化后如果生成了单位，会被紧接着的 MovePlayerOffMap 清掉
			if beforeMove ~= nil and beforeMove(playerID) then
				processed = processed + 1
			end
			if MovePlayerOffMap(playerID) then
				table.insert(ghosts, playerID)
				knownGhosts[playerID] = true
				added = added + 1
			end
		end
	end

	Game:SetProperty(GHOST_PLAYER_PROPERTY, ghosts)
	return added, #ghosts, processed
end

-- originalCount：玩家在创建游戏时原本设置的城邦数量（UI 层从 CustomData 读出后传入）
-- 比它多出来的城邦会被搬到地图外，作为幽灵玩家池；没传值或不是新开局则不处理。
-- 诊断：列出**运行时数据库**里所有城邦文明（含本 mod 复制的 _GHOST1）。
-- 图标没法动态生成，只能按这份清单逐个写死，所以把它打到日志里，
-- 用来核对“哪些复制体还没有图标定义”。在 InitializeGhostPlayers 里调用一次。
local function LogCityStateCivTypes()
	local originals, duplicates = {}, {}
	for civRow in GameInfo.Civilizations() do
		if civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE' then
			local civType = tostring(civRow.CivilizationType)
			if string.sub(civType, -7) == '_GHOST1' then
				table.insert(duplicates, civType)
			else
				table.insert(originals, civType)
			end
		end
	end
	print("[ModMiscTool][Ghost] city state civ types: originals=" .. tostring(#originals)
		.. " duplicates=" .. tostring(#duplicates))
	print("[ModMiscTool][Ghost]   originals: " .. table.concat(originals, ','))
	print("[ModMiscTool][Ghost]   duplicates: " .. table.concat(duplicates, ','))
end

-- ===========================================================================
-- 开局把“多出来的城邦槽位”一次性变成幽灵
--
-- 判定规则（授权者定，简单确定）：按 playerID 划范围。
--   引擎开局排槽位的顺序：主要文明 0..majorCount-1，紧接着是玩家设定的城邦
--   majorCount..majorCount+cityStateCount-1；再往后就是多出来的城邦槽位（我们要的幽灵），
--   最后 62/63 是自由城市与蛮族，必须跳过。
--   所以 边界 = majorPlayerCount + cityStateCount - 1，
--   **id 大于边界、且不是 62/63 的城邦玩家，全部变成幽灵态**。
--
-- 开局时所有玩家都还没建城，所以不用考虑城市的影响（授权者确认）；
-- 城邦玩家一旦落地就有首都，MovePlayerOffMap 的“有城市就拒绝”保护也不会误伤。
--
-- ghostPoolLimit：城邦幽灵的**申报上限**（建局侧按 mod 申报算好后随档传进来）。
--   * 0    → 没有 mod 申报城邦幽灵：整个 pass 直接跳过，一个都不产生；
--   * N    → 最多搬 N 个（申报多少就最多多少）；
--   * nil  → 没这道数据（老档/老前端）：不限额，沿用旧行为。
-- ===========================================================================
function InitializeGhostPlayers(cityStateCount, majorPlayerCount, ghostPoolLimit)
	if cityStateCount == nil then return end

	m_CityStateGhostPoolLimit = nil
	if ghostPoolLimit ~= nil then
		m_CityStateGhostPoolLimit = math.max(0, math.floor(tonumber(ghostPoolLimit) or 0))
		if m_CityStateGhostPoolLimit <= 0 then
			-- 【硬规则】没申报就不产生城邦幽灵 —— 但**已经建好的池子不动**
			--（读档时池子由存档属性带着走，这里只是不再新增）。
			print("[ModMiscTool][Ghost] 城邦幽灵未申报（计划 0 个）→ 跳过城邦幽灵 pass"
				.. " (已有池子 " .. tostring(GetCityStateGhostPlayerCount()) .. " 个)")
			return
		end
	end

	LogCityStateCivTypes()

	local keepCityStates = math.max(0, math.floor(cityStateCount))
	local keepMajors = math.max(1, math.floor(majorPlayerCount or 1))
	local maxSlot = MaxPlayerSlots() - 1

	-- 边界不再用“玩家原本选择的主要文明数”，而是运行时实际创建的主要玩家数：
	-- 主流幽灵池启用后，引擎会先创建多出来的主要文明，城邦槽位整体后移。
	local actualMajorCount = 0
	for playerID = 0, maxSlot do
		local player = Players[playerID]
		if player ~= nil and CallOrNil(function() return player:IsMajor() end) == true then
			actualMajorCount = actualMajorCount + 1
		end
	end
	local boundary = actualMajorCount + keepCityStates - 1

	print("[ModMiscTool][Ghost] city state ghost pass: keepMajors=" .. tostring(keepMajors)
		.. " actualMajorCount=" .. tostring(actualMajorCount)
		.. " keepCityStates=" .. tostring(keepCityStates)
		.. " -> on-map ids 0.." .. tostring(boundary)
		.. " | ghost ids " .. tostring(boundary + 1) .. ".." .. tostring(maxSlot)
		.. " (skip 62/63)")

	local ghosts = GetCityStateGhostPlayers()
	local knownGhosts = {}
	for _, ghostID in ipairs(ghosts) do
		knownGhosts[ghostID] = true
	end

	local added = 0
	local skipped = {}
	local emptySlotCount = 0
	for playerID = boundary + 1, maxSlot do
		-- 申报多少就最多产生多少（m_CityStateGhostPoolLimit 为 nil 时表示不限额）
		if m_CityStateGhostPoolLimit ~= nil and added >= m_CityStateGhostPoolLimit then
			print("[ModMiscTool][Ghost] 城邦幽灵已达申报上限 "
				.. tostring(m_CityStateGhostPoolLimit) .. " → 不再搬（stop at slot "
				.. tostring(playerID) .. ")")
			break
		end
		if playerID ~= 62 and playerID ~= 63 and not knownGhosts[playerID] then
			local player = Players[playerID]
			-- 空槽位先剔掉：Players[id] 不是 nil 但内部是空的，
			-- 对它 InitUnit 会原生闪退（2026-10-04 实机 100% 复现，见 PlayerSlotHasPlayer）
			if player ~= nil and not PlayerSlotHasPlayer(playerID) then
				emptySlotCount = emptySlotCount + 1
				player = nil
			end
			if player ~= nil then
				local isMajor = CallOrNil(function() return player:IsMajor() end)
				local isBarbarian = CallOrNil(function() return player:IsBarbarian() end)
				local playerConfig = PlayerConfigurations[playerID]
				local civType = ''
				if playerConfig ~= nil then
					civType = tostring(CallOrNil(function()
						return playerConfig:GetCivilizationTypeName()
					end))
				end
				local isSpecial = (string.find(civType, 'BARBARIAN') ~= nil)
					or (string.find(civType, 'FREE_CITIES') ~= nil)
				if isMajor == false and isBarbarian ~= true and not isSpecial then
					RecordGhostOriginalIdentity(playerID, '城邦幽灵')
					if MovePlayerOffMap(playerID) then
						table.insert(ghosts, playerID)
						knownGhosts[playerID] = true
						added = added + 1
					else
						table.insert(skipped, tostring(playerID) .. "(" .. civType .. ")")
					end
				elseif civType ~= '' then
					-- 边界之后不是城邦的槽位：不该出现，记下来便于排查
					table.insert(skipped, tostring(playerID) .. "!" .. civType)
				end
			end
		end
	end

	Game:SetProperty(CITY_STATE_GHOST_PLAYER_PROPERTY, ghosts)
	print("[ModMiscTool][Ghost] city state ghost pass done: newlyOffMap=" .. tostring(added)
		.. " cityStatePoolTotal=" .. tostring(#ghosts)
		.. " emptySlots=" .. tostring(emptySlotCount)
		.. " plannedLimit=" .. tostring(m_CityStateGhostPoolLimit))
	if #skipped > 0 then
		print("[ModMiscTool][Ghost]   skipped slots: " .. table.concat(skipped, ' '))
	end
end

-- 语义化别名：InitializeGhostPlayers 现在只负责城邦幽灵池。
function InitializeCityStateGhostPlayers(cityStateCount, majorPlayerCount, ghostPoolLimit)
	return InitializeGhostPlayers(cityStateCount, majorPlayerCount, ghostPoolLimit)
end

-- 诊断/面板用：本局城邦幽灵的申报上限（nil = 不限额，0 = 不产生）
function GetCityStateGhostPoolLimit()
	return m_CityStateGhostPoolLimit
end

-- 主要文明候选：还没建城的主要文明，排除本机玩家（不能把自己搬到地图外）
local function GetUnsettledMajorPlayerIDs()
	local localPlayer = Game.GetLocalPlayer()
	local playerIDs = {}
	for playerID = 0, MaxPlayerSlots() - 1 do
		local player = Players[playerID]
		if player ~= nil and playerID ~= localPlayer then
			local isMajor = CallOrNil(function() return player:IsMajor() end)
			local isBarbarian = CallOrNil(function() return player:IsBarbarian() end)
			if isMajor == true and isBarbarian ~= true then
				local cities = CallOrNil(function() return player:GetCities() end)
				local capital = nil
				if cities ~= nil then
					capital = CallOrNil(function() return cities:GetCapitalCity() end)
				end
				if capital == nil then
					table.insert(playerIDs, playerID)
				end
			end
		end
	end
	return playerIDs
end

-- originalCount：玩家原本设置的主要文明玩家数（含本机玩家）。
-- 前端 hook 把参与玩家数抬到槽位预算允许的上限后，引擎会在开局多建一批主要文明；
-- 这里把超出的部分搬到地图外当幽灵，玩家自己的对手数量保持不变。
-- 只搬“还没建城”的：本机玩家与已经落地的对手一律不动。
function InitializeGhostMajorPlayers(originalCount, ghostPoolLimit)
	if originalCount == nil then return end

	m_MajorGhostPoolLimit = nil
	if ghostPoolLimit ~= nil then
		m_MajorGhostPoolLimit = math.max(0, math.floor(tonumber(ghostPoolLimit) or 0))
		if m_MajorGhostPoolLimit <= 0 then
			-- 【硬规则】没申报就不产生主流幽灵 —— 已有池子不动（读档时由存档属性带着走）
			print("[ModMiscTool][Ghost] 主流幽灵未申报（计划 0 个）→ 跳过主流幽灵 pass"
				.. " (已有池子 " .. tostring(GetGhostPlayerCount()) .. " 个)")
			return
		end
	end

	local candidates = GetUnsettledMajorPlayerIDs()
	if #candidates == 0 then return end

	local keepOnMap = math.max(0, math.floor(originalCount) - 1)
	-- 搬离之前先城邦化：避免幽灵化的主要文明继续参与外交（可用开关关掉）
	local beforeMove = nil
	if GHOST_CONVERT_MAJOR_TO_CITY_STATE then
		-- 注意：入口授权只认 'auto_first_city'（2026-10-26），开局阶段这条即使打开也会被拒。
		-- 保留它只是历史开关；真要恢复开局转换，得同时把 'init_stage' 加进
		-- IsMajorToCityStateConversionAllowed（但那正是会把开局加载搞挂的时机，见文件顶部）。
		beforeMove = function(ghostID)
			return ConvertGhostPlayerToCityState(ghostID, nil, 'init_stage')
		end
	else
		print("[ModMiscTool][Ghost] 开局阶段不城邦化 ⇒ 改在本地玩家建首城时自动做"
			.. "（autoConvertOnFirstCity=" .. tostring(GHOST_AUTO_CONVERT_ON_FIRST_CITY) .. "）")
	end
	local added, poolTotal, converted = AddGhostsFromCandidates(candidates, keepOnMap,
		'major players', Game.GetLocalPlayer(), beforeMove, m_MajorGhostPoolLimit)

	print("[ModMiscTool][Ghost] unsettled major players=" .. tostring(#candidates)
		.. " player choice=" .. tostring(keepOnMap + 1)
		.. " newly off-map=" .. tostring(added)
		.. " converted-to-city-state=" .. tostring(converted)
		.. " pool total=" .. tostring(poolTotal)
		.. " plannedLimit=" .. tostring(m_MajorGhostPoolLimit))
end

-- 诊断/面板用：本局主流幽灵的申报上限（nil = 不限额，0 = 不产生）
function GetMajorGhostPoolLimit()
	return m_MajorGhostPoolLimit
end

-- 面板用：一行统计，直接看引擎到底建了多少玩家、幽灵池还剩多少可用
function GetPlayerSlotSummary()
	local stats = DumpPlayerSlots('panel')
	return "major=" .. tostring(stats.major)
		.. " minor=" .. tostring(stats.minor)
		.. " engine=" .. tostring(stats.enginePlayers)
		.. " empty=" .. tostring(#stats.emptySlots)
		.. " majorPool=" .. tostring(GetGhostPlayerCount())
		.. " majorFree=" .. tostring(GetAvailableGhostPlayerCount())
		.. " majorPlan=" .. tostring(m_MajorGhostPoolLimit)
		.. " cityStatePool=" .. tostring(GetCityStateGhostPlayerCount())
		.. " cityStateFree=" .. tostring(GetAvailableCityStateGhostPlayerCount())
		.. " cityStatePlan=" .. tostring(m_CityStateGhostPoolLimit)
end

-- ===========================================================================
-- 【2026-10-15 授权者】自动批量城邦化：时机 = **本地玩家建立第一座城市时**
--
-- 为什么这个时机：
--   * 城邦化让幽灵不再带“大文明外交footprint”（外交界面/世界议会都不受影响，已实机验证）；
--   * 开局就做、且只做一次，之后玩家再要附庸时池子里已经是“城邦幽灵”，
--     原身份相符的还能免读档直接落地（见 Vassal_Script 的 immediate 判定）；
--   * 城市建立这个时刻是正常对局流程，不在加载过渡阶段（那阶段批量改身份会把开局搞挂）。
-- 【2026-10-17】曾默认关闭（这一步做的正是"主流→城邦"的转换）；
-- 【2026-10-26 授权者恢复 A 方案】**重新打开**，这是唯一被放行的城邦化入口。
-- 开关本身在文件顶部（GHOST_AUTO_CONVERT_ON_FIRST_CITY），入口授权见
-- IsMajorToCityStateConversionAllowed —— 手动/其它 mod 调用仍然是拦的。
-- ===========================================================================
-- 目标池为空时是否允许跨池兜底（默认关：行为语义要严格 —— 选保守就该给保守幽灵）
GHOST_ALLOW_POOL_FALLBACK = false
local GHOST_AUTO_CONVERT_PROPERTY = 'kocmoca_modmisctool_ghost_autoconvert_done'

function IsGhostAutoConvertDone()
	return Game:GetProperty(GHOST_AUTO_CONVERT_PROPERTY) == true
end

-- 返回：是否执行了批量城邦化
function TryAutoConvertGhostsOnFirstCity(playerID)
	if not GHOST_AUTO_CONVERT_ON_FIRST_CITY then return false end
	if IsGhostAutoConvertDone() then return false end
	if playerID == nil or playerID ~= Game.GetLocalPlayer() then return false end

	-- 只在“第一座城”那一刻做：已经有多座城说明是读老档/其它路径，不再补做
	local player = Players[playerID]
	if player == nil then return false end
	local cities = CallOrNil(function() return player:GetCities() end)
	local cityCount = 0
	if cities ~= nil then
		cityCount = CallOrNil(function() return cities:GetCount() end) or 0
	end
	if cityCount > 1 then
		Game:SetProperty(GHOST_AUTO_CONVERT_PROPERTY, true)
		return false
	end
	if GetGhostPlayerCount() <= 0 then
		Game:SetProperty(GHOST_AUTO_CONVERT_PROPERTY, true)
		return false
	end

	print('[ModMiscTool][Ghost] 本地玩家建立第一座城 ⇒ 自动批量城邦化（池子 '
		.. tostring(GetGhostPlayerCount()) .. ' 个，入口=auto_first_city）')
	local converted, failed, skipped = ConvertAllGhostMajorPlayersToCityState('auto_first_city')
	-- 成功过 / 没有可转的 ⇒ 收工；全失败 ⇒ 不落标记，等下一座城再试
	if converted > 0 or failed == 0 then
		Game:SetProperty(GHOST_AUTO_CONVERT_PROPERTY, true)
	end
	print('[ModMiscTool][Ghost] 首城自动城邦化结果：converted=' .. tostring(converted)
		.. ' failed=' .. tostring(failed) .. ' skipped=' .. tostring(skipped))
	return converted > 0
end

if Events ~= nil and Events.CityAddedToMap ~= nil then
	Events.CityAddedToMap.Add(function(ownerID, cityID, iX, iY)
		pcall(TryAutoConvertGhostsOnFirstCity, ownerID)
		-- 【授权者定案】城市落地 ⇒ 若拥有者是幽灵，把它地图外的开拓者移动进这座城
		pcall(HandleGhostCityAddedToMap, ownerID, cityID, iX, iY)
	end)
end

if Events ~= nil and Events.CityTransfered ~= nil then
	Events.CityTransfered.Add(function(newOwnerID, cityID)
		pcall(HandleGhostCityTransfered, newOwnerID, cityID)
	end)
end

-- ===========================================================================
-- 回合开始的轻量刷新：谁已经拿到城市就不再是幽灵
-- （激活那一刻已经会立刻出池；这里是“漏网”的兜底，保证外交压制不会滞后一整个回合）
-- ===========================================================================
if Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
	Events.LocalPlayerTurnBegin.Add(function()
		pcall(function() RefreshGhostPoolsFromCities("回合开始") end)
		-- 【授权者定案】新建城市由 CityAddedToMap 事件统一处理；这里只给老档兜一次底
		if not m_SettleSweepDone then
			m_SettleSweepDone = true
			pcall(SweepGhostOffMapSettlers, "载入后首次回合开始")
		end
	end)
end
