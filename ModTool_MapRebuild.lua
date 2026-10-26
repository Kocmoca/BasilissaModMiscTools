-- ===========================================================================
-- Mod Misc Tool: 地图重建（海陆布局 / 河流 / 湖泊 / 大河）
--
-- 由 ModTool.lua include，运行在 Gameplay Lua；通过
-- ExposedMembers.ModMiscToolScript.MapRebuild / RebuildMap 暴露给其它 mod。
-- Exoplanet Homeland 只调用接口，不再维护这套地图生成代码。
--
-- 参考原版 Base/Assets/Maps/Utility/RiversLakes.lua：
--   * 湖泊 = 内陆非沿海陆地格改成 TERRAIN_COAST（原版 AddLakes 同款做法）；
--   * 河流 = 从陆地源头向最近水域走，用 WorldBuilder 的 EditRiver 加河沿；
--   * 大河 = 本项目自己的创造：用一条浅海（COAST）单元格带模拟宽阔大河，
--     从内陆一路切到海边，形成可通航的“水上门户”。
-- ===========================================================================

MapRebuild = MapRebuild or {}
local MR = MapRebuild

local PLOT_TYPE_MOUNTAIN = 0
local PLOT_TYPE_HILLS = 1
local PLOT_TYPE_LAND = 2
local PLOT_TYPE_OCEAN = 3

local SEALAND_LAYOUTS = {
    archipelago      = { Water = 0.72, Centers = 12 },
    small_continents = { Water = 0.62, Centers = 7 },
    continents       = { Water = 0.52, Centers = 4 },
    pangaea          = { Water = 0.42, Centers = 2 },
}

-- DirectionTypes：0=NE, 1=E, 2=SE, 3=SW, 4=W, 5=NW（原版 MapEnums.lua）。
local DIRECTION_DELTAS = {
    [0] = { 1, -1 },
    [1] = { 1, 0 },
    [2] = { 1, 1 },
    [3] = { -1, 1 },
    [4] = { -1, 0 },
    [5] = { -1, -1 },
}

local function Log(message)
    print("[ModMiscMapRebuild] " .. tostring(message))
end

local function PlotKey(x, y)
    return tostring(x) .. "," .. tostring(y)
end

function MR.ClassifyLayout(mapName)
    local name = string.lower(tostring(mapName or "")):gsub("_", " ")
    if name:find("archipelago", 1, true) ~= nil then return "archipelago" end
    if name:find("small continents", 1, true) ~= nil then return "small_continents" end
    if name:find("pangaea", 1, true) ~= nil then return "pangaea" end
    if name:find("continents", 1, true) ~= nil then return "continents" end
    return nil
end

local function SetTerrain(wb, plot, terrainType)
    if wb == nil or plot == nil then return false end
    if terrainType == nil then
        -- 地图单元格必须始终有一种地形，地形不能真正“清空”。
        -- 这里用浅海 TERRAIN_COAST 作为“清空/中性”语义（授权者 2026-10-20）。
        terrainType = "TERRAIN_COAST"
    end
    -- 大河格只允许保持水域：后续任何 SetTerrain（湖泊/海陆重刷）都不能把它改回陆地。
    if plot.BigRiver == true and terrainType ~= "TERRAIN_COAST"
        and terrainType ~= "TERRAIN_OCEAN" then
        return false
    end
    local row = GameInfo ~= nil and GameInfo.Terrains ~= nil
        and GameInfo.Terrains[terrainType] or nil
    if row == nil then return false end
    local current = nil
    pcall(function() current = plot:GetTerrainType() end)
    if current ~= nil and tonumber(current) == tonumber(row.Index) then return false end
    return pcall(wb.SetTerrainType, plot, row.Index)
end

local function SetFeature(wb, plot, featureType)
    if wb == nil or plot == nil then return false end
    local featureIndex = -1
    if featureType ~= nil then
        local row = GameInfo ~= nil and GameInfo.Features ~= nil
            and GameInfo.Features[featureType] or nil
        if row == nil then return false end
        featureIndex = tonumber(row.Index) or -1
    end
    local current = nil
    pcall(function() current = plot:GetFeatureType() end)
    -- nil 表示清地貌（-1）；这是常规清理，和“大河断点”无关。
    if current ~= nil and tonumber(current) == featureIndex then return false end
    if featureIndex == -1 and current ~= nil and tonumber(current) < 0 then return false end
    return pcall(wb.SetFeatureType, plot, featureIndex)
end

local function ClearResource(wb, plot)
    if wb == nil or plot == nil then return false end
    local current = -1
    pcall(function() current = plot:GetResourceType() end)
    if current == nil or tonumber(current) < 0 then return true end
    return pcall(wb.SetResourceType, plot, -1, 0)
end

local function ClearImprovement(wb, plot)
    if wb == nil or plot == nil or wb.SetImprovementType == nil then return false end
    local improvement = nil
    pcall(function() improvement = plot:GetImprovementType() end)
    if improvement == nil or tonumber(improvement) == nil
        or tonumber(improvement) < 0 then
        return false
    end
    return pcall(wb.SetImprovementType, plot, -1, -1)
end

local function RandomLandPlot(land, width, height)
    for _ = 1, 120 do
        local x = math.random(0, width - 1)
        local y = math.random(0, height - 1)
        local key = PlotKey(x, y)
        if land[key] == true then
            local plot = Map.GetPlot(x, y)
            if plot ~= nil then
                local water, mountain, wonder = false, false, false
                pcall(function() water = plot:IsWater() == true end)
                pcall(function() mountain = plot:IsMountain() == true end)
                pcall(function() wonder = plot:IsNaturalWonder() == true end)
                if not water and not mountain and not wonder then
                    return x, y, plot
                end
            end
        end
    end
    return nil
end

local function IsNaturalWonderPlot(plot)
    if plot == nil then return false end
    local wonder = false
    pcall(function() wonder = plot:IsNaturalWonder() == true end)
    return wonder
end

-- 引擎的六边形邻居用 Map.GetAdjacentPlot 取；手写 DIRECTION_DELTAS 是棋盘格，
-- 在六边形坐标系里 NE/SE/SW/NW 的实际偏移取决于行奇偶，直接加 delta 会走出
-- “自认为连续、游戏里不连续”的大河（授权者 2026-10-20，参见 vector2/六边形坐标）。
local GetAdjacentPlot

local function FindNearestWater(x, y, land, width, height)
    local start = Map.GetPlot(x, y)
    if start == nil then return nil end
    local visited = { [PlotKey(x, y)] = true }
    local queue = { { x, y } }
    local head = 1
    while head <= #queue do
        local cx, cy = queue[head][1], queue[head][2]
        head = head + 1
        local plot = Map.GetPlot(cx, cy)
        if plot ~= nil then
            for direction = 0, 5 do
                local adjacent = GetAdjacentPlot(plot, direction)
                if adjacent ~= nil then
                    local nx, ny = adjacent:GetX(), adjacent:GetY()
                    local key = PlotKey(nx, ny)
                    if not visited[key] then
                        visited[key] = true
                        -- 不把地图最外圈当入海口：边界水格在实机里会被切掉/渲染不完整。
                        if nx >= 1 and ny >= 1 and nx < width - 1 and ny < height - 1
                            and land[key] ~= true then
                            return nx, ny
                        end
                        queue[#queue + 1] = { nx, ny }
                    end
                end
            end
        end
    end
    return nil
end



-- 真正的陆地：land 掩码 + 引擎 IsWater + 地形不是海岸/深海。
-- 实机里 SetTerrain(COAST) 后 plot:IsWater() 仍可能是 false（plot type 没变），
-- 只看 IsWater 会把单位放到海里；这里再加地形判断兜底。
local function IsLandPlot(plot, land, key)
    if plot == nil or land[key] ~= true then return false end
    local water = false
    pcall(function() water = plot:IsWater() == true end)
    if water then return false end
    local terrain = nil
    pcall(function() terrain = tonumber(plot:GetTerrainType()) end)
    if terrain ~= nil and GameInfo ~= nil and GameInfo.Terrains ~= nil then
        local coast = GameInfo.Terrains["TERRAIN_COAST"]
        local ocean = GameInfo.Terrains["TERRAIN_OCEAN"]
        if (coast ~= nil and terrain == tonumber(coast.Index))
            or (ocean ~= nil and terrain == tonumber(ocean.Index)) then
            return false
        end
    end
    return true
end

local function CollectSpawns(width, height, land, spawnKey, candidateKey)
    local spawns = nil
    pcall(function() spawns = Game:GetProperty(spawnKey) end)
    if type(spawns) ~= "table" then spawns = {} end

    local claimed = {}
    local function IsValid(x, y)
        local key = PlotKey(x, y)
        if land[key] ~= true or claimed[key] == true then return false end
        local plot = Map.GetPlot(x, y)
        if plot == nil then return false end
        local water, mountain, wonder, owner = false, false, false, -1
        pcall(function() water = plot:IsWater() == true end)
        pcall(function() mountain = plot:IsMountain() == true end)
        pcall(function() wonder = plot:IsNaturalWonder() == true end)
        pcall(function() owner = plot:GetOwner() end)
        if water or mountain or wonder then return false end
        if owner ~= nil and tonumber(owner) ~= nil and tonumber(owner) >= 0 then return false end
        return true
    end
    local function Claim(x, y)
        if not IsValid(x, y) then return nil end
        claimed[PlotKey(x, y)] = true
        return { X = x, Y = y }
    end
    local function FindNearby(x, y)
        local maxRadius = math.max(width, height)
        local found = Claim(x, y)
        if found ~= nil then return found end
        for radius = 1, maxRadius do
            for dy = -radius, radius do
                for dx = -radius, radius do
                    if math.abs(dx) == radius or math.abs(dy) == radius then
                        found = Claim(x + dx, y + dy)
                        if found ~= nil then return found end
                    end
                end
            end
        end
        for scanY = 0, height - 1 do
            for scanX = 0, width - 1 do
                found = Claim(scanX, scanY)
                if found ~= nil then return found end
            end
        end
        return nil
    end

    local repaired = 0
    for playerKey, spawn in pairs(spawns) do
        if type(spawn) == "table" then
            local x, y = tonumber(spawn.X), tonumber(spawn.Y)
            local found = (x ~= nil and y ~= nil) and Claim(x, y) or nil
            if found ~= nil then
                spawns[playerKey] = found
            else
                found = FindNearby(x or math.floor(width / 2), y or math.floor(height / 2))
                if found ~= nil then
                    spawns[playerKey] = found
                    repaired = repaired + 1
                end
            end
        end
    end

    local candidates = {}
    local centerX, centerY = math.floor(width / 2), math.floor(height / 2)
    local maxRadius = math.max(width, height)
    for radius = 0, maxRadius do
        for dy = -radius, radius do
            for dx = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local found = Claim(centerX + dx, centerY + dy)
                    if found ~= nil then
                        candidates[#candidates + 1] = found
                        if #candidates >= 32 then break end
                    end
                end
            end
            if #candidates >= 32 then break end
        end
        if #candidates >= 32 then break end
    end

    pcall(function() Game:SetProperty(spawnKey, spawns) end)
    pcall(function() Game:SetProperty(candidateKey, candidates) end)
    return repaired, #candidates
end

function MR.ClearRivers(wb, width, height, wonders)
    if wb == nil or wb.EditRiver == nil then return 0 end
    local cleared = 0
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local plot = Map.GetPlot(x, y)
            if plot ~= nil and (wonders == nil or wonders[PlotKey(x, y)] ~= true) then
                -- 闪退（ForgeUI ReadTextureFromDisk）出现在改成“全地块 13680 次 EditRiver”之后，
                -- 先把清河收敛：水格必清（海洋旧河），陆地只在引擎报告有河时清。
                -- 只清引擎报告有河的格；不再对水格批量 EditRiver。
                -- 崩溃无 Lua 日志，按“减少换图期原生河网写”处理：批量水格 EditRiver
                -- 是最可疑的新增负载。
                local hasRiver = false
                if wb.DoesPlotBorderRiver ~= nil then
                    local called, value = pcall(wb.DoesPlotBorderRiver, plot:GetIndex())
                    if called then hasRiver = value == true end
                end
                if hasRiver then
                    for edge = 0, 5 do
                        local called, result = pcall(wb.EditRiver, plot:GetIndex(), edge, false, false)
                        if called and result == true then cleared = cleared + 1 end
                    end
                end
            end
        end
    end
    return cleared
end

-- ===========================================================================
-- 原版 RiversLakes（Expansion2 版）完整移植
--   参考 Civ6Data/Expansion2/Maps/Utility/RiversLakes.lua：
--     GetRiverValueAtPlot / DoRiver / AddRivers / AddLakes / AddMoreLake /
--     AdjacentToNaturalWonder / GetPlotElevation / 流向转向表。
--   对局内与地图生成环境的差异做兼容：
--     * TerrainBuilder.Set*OfRiver 可用就直接用；否则退回 WorldBuilder EditRiver；
--     * Map.FindWater / TerrainBuilder.GetInlandCorner / Area 等地图生成专用接口
--       用等价实现兜底；GlobalParameters / AreaBuilder 缺失时用默认值。
-- ===========================================================================
local DT = DirectionTypes or {
    DIRECTION_NORTHEAST = 0, DIRECTION_EAST = 1, DIRECTION_SOUTHEAST = 2,
    DIRECTION_SOUTHWEST = 3, DIRECTION_WEST = 4, DIRECTION_NORTHWEST = 5,
    NUM_DIRECTION_TYPES = 6,
}
local FD = FlowDirectionTypes or {
    NO_FLOWDIRECTION = -1,
    FLOWDIRECTION_NORTH = 0, FLOWDIRECTION_NORTHEAST = 1, FLOWDIRECTION_SOUTHEAST = 2,
    FLOWDIRECTION_SOUTH = 3, FLOWDIRECTION_SOUTHWEST = 4, FLOWDIRECTION_NORTHWEST = 5,
    NUM_FLOWDIRECTION_TYPES = 6,
}
local function TerrainIndex(name, fallback)
    local row = GameInfo ~= nil and GameInfo.Terrains ~= nil
        and GameInfo.Terrains[name] or nil
    return row ~= nil and row.Index or fallback
end
local function FeatureIndex(name, fallback)
    local row = GameInfo ~= nil and GameInfo.Features ~= nil
        and GameInfo.Features[name] or nil
    return row ~= nil and row.Index or fallback
end
local g_TERRAIN_TYPE_DESERT = TerrainIndex("TERRAIN_DESERT", 0)
local g_TERRAIN_TYPE_COAST = TerrainIndex("TERRAIN_COAST", 0)
local g_FEATURE_VOLCANO = FeatureIndex("FEATURE_VOLCANO", -1)

local m_RiverEdgeWrites = 0
-- 全局河沿预算：原版 plotsPerRiverEdge ≈ 12，即每 12 个地块约 1 条河沿。
-- 不做上限时，源头收紧到 2/1 会让整张地图铺满河（模拟器 44x26 曾出现 1683 条）。
local m_RiverBudget = 0
local m_BigRiverCells = 0
local m_LongestBigRiver = 0
local m_BigRiverPaths = {}
local m_BigRiverPlots = {}
local m_ActiveWorldBuilder = nil
-- EditRiver 的 edge 枚举与 SetWOfRiver 的 W/NW/NE 可能不是同一套；
-- 在真实地块上试探一次，把 W/NW/NE 对应的 edge 索引探出来（之后清河）。
local m_RiverEdgeMap = nil
local function ProbeRiverEdgeMap(wb, width, height)
    if m_RiverEdgeMap ~= nil or wb == nil or wb.EditRiver == nil then return end
    local probePlot = nil
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local plot = Map.GetPlot(x, y)
            if plot ~= nil then
                local water, wonder = false, false
                pcall(function() water = plot:IsWater() == true end)
                pcall(function() wonder = plot:IsNaturalWonder() == true end)
                if not water and not wonder then probePlot = plot; break end
            end
        end
        if probePlot ~= nil then break end
    end
    if probePlot == nil then return end
    local map = { W = 4, NW = 5, NE = 0 }
    for edgeIndex = 0, 5 do
        local called, result = pcall(wb.EditRiver, probePlot:GetIndex(), edgeIndex, true, false)
        if called and result ~= false then
            local w, nw, ne = false, false, false
            pcall(function() w = probePlot:IsWOfRiver() == true end)
            pcall(function() nw = probePlot:IsNWOfRiver() == true end)
            pcall(function() ne = probePlot:IsNEOfRiver() == true end)
            if w then map.W = edgeIndex end
            if nw then map.NW = edgeIndex end
            if ne then map.NE = edgeIndex end
            pcall(wb.EditRiver, probePlot:GetIndex(), edgeIndex, false, false)
        end
    end
    m_RiverEdgeMap = map
    Log("River edge probe: W=" .. tostring(map.W) .. " NW=" .. tostring(map.NW)
        .. " NE=" .. tostring(map.NE))
end

local function RiverEdgeIndex(edge)
    if m_RiverEdgeMap ~= nil and m_RiverEdgeMap[edge] ~= nil then
        return m_RiverEdgeMap[edge]
    end
    if edge == "W" then return 4 end
    if edge == "NW" then return 5 end
    return 0
end
local m_LakeCount = 0
local m_RiverPlots = {}
local m_NextRiverID = 0

local TurnRightFlowDirections = {
    [FD.FLOWDIRECTION_NORTH] = FD.FLOWDIRECTION_NORTHEAST,
    [FD.FLOWDIRECTION_NORTHEAST] = FD.FLOWDIRECTION_SOUTHEAST,
    [FD.FLOWDIRECTION_SOUTHEAST] = FD.FLOWDIRECTION_SOUTH,
    [FD.FLOWDIRECTION_SOUTH] = FD.FLOWDIRECTION_SOUTHWEST,
    [FD.FLOWDIRECTION_SOUTHWEST] = FD.FLOWDIRECTION_NORTHWEST,
    [FD.FLOWDIRECTION_NORTHWEST] = FD.FLOWDIRECTION_NORTH,
}
local TurnLeftFlowDirections = {
    [FD.FLOWDIRECTION_NORTH] = FD.FLOWDIRECTION_NORTHWEST,
    [FD.FLOWDIRECTION_NORTHEAST] = FD.FLOWDIRECTION_NORTH,
    [FD.FLOWDIRECTION_SOUTHEAST] = FD.FLOWDIRECTION_NORTHEAST,
    [FD.FLOWDIRECTION_SOUTH] = FD.FLOWDIRECTION_SOUTHEAST,
    [FD.FLOWDIRECTION_SOUTHWEST] = FD.FLOWDIRECTION_SOUTH,
    [FD.FLOWDIRECTION_NORTHWEST] = FD.FLOWDIRECTION_SOUTHWEST,
}

local function GetRandomNumber(n)
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        local ok, value = pcall(TerrainBuilder.GetRandomNumber, n, "MapRebuild")
        if ok and value ~= nil then return value end
    end
    return math.random(0, math.max(0, math.floor(n or 1) - 1))
end

local function GetPlotElevation(plot)
    local mountain, hills, water = false, false, false
    pcall(function() mountain = plot:IsMountain() == true end)
    pcall(function() hills = plot:IsHills() == true end)
    pcall(function() water = plot:IsWater() == true end)
    if mountain then return 4 end
    if hills then return 3 end
    if not water then return 2 end
    return 1
end

function GetAdjacentPlot(plot, direction)
    if plot == nil then return nil end
    if Map.GetAdjacentPlot ~= nil then
        local ok, adjacent = pcall(Map.GetAdjacentPlot, plot:GetX(), plot:GetY(), direction)
        if ok then return adjacent end
    end
    local delta = DIRECTION_DELTAS[direction]
    if delta ~= nil and Map.GetPlot ~= nil then
        return Map.GetPlot(plot:GetX() + delta[1], plot:GetY() + delta[2])
    end
    return nil
end

local function IsCliffEdge(plot, edge)
    local method = "Is" .. edge .. "OfCliff"
    if plot == nil or plot[method] == nil then return false end
    local ok, value = pcall(plot[method], plot)
    return ok and value == true
end

local function IsRiverEdge(plot, edge)
    local method = "Is" .. edge .. "OfRiver"
    if plot == nil or plot[method] == nil then return false end
    local ok, value = pcall(plot[method], plot)
    return ok and value == true
end

local function AdjacentToNaturalWonder(plot)
    for direction = 0, DT.NUM_DIRECTION_TYPES - 1 do
        local adjacent = GetAdjacentPlot(plot, direction)
        if adjacent ~= nil then
            local wonder = false
            pcall(function() wonder = adjacent:IsNaturalWonder() == true end)
            if wonder then return true end
        end
    end
    return false
end

local function GetPlotArea(plot)
    if plot == nil or plot.GetArea == nil then return nil end
    local ok, area = pcall(plot.GetArea, plot)
    if ok then return area end
    return nil
end

local function FindWaterNear(plot, range)
    if plot == nil then return true end
    if range == nil or range < 0 then return false end
    -- 方框 dx/dy 在六边形网格里不是等距邻域；改用引擎邻居做 BFS，
    -- 和 AddBigRivers 的坐标口径保持一致。
    local visited = { [plot:GetIndex()] = true }
    local queue = { plot }
    for _ = 1, range do
        local nextQueue = {}
        for _, current in ipairs(queue) do
            for direction = 0, 5 do
                local adjacent = GetAdjacentPlot(current, direction)
                if adjacent ~= nil then
                    local index = adjacent:GetIndex()
                    if not visited[index] then
                        visited[index] = true
                        local water = false
                        pcall(function() water = adjacent:IsWater() == true end)
                        if water then return true end
                        nextQueue[#nextQueue + 1] = adjacent
                    end
                end
            end
        end
        queue = nextQueue
        if #queue == 0 then break end
    end
    return false
end

local function GetInlandCorner(plot)
    if TerrainBuilder ~= nil and TerrainBuilder.GetInlandCorner ~= nil then
        local ok, corner = pcall(TerrainBuilder.GetInlandCorner, plot)
        if ok and corner ~= nil then return corner end
    end
    return plot
end

local function SetRiverEdge(wb, plot, edge, flowDirection, riverID)
    if plot == nil then return false end
    wb = wb or m_ActiveWorldBuilder
    -- 河沿绝不能加在水格上：DoRiver 的 SE/SOUTH 分支会先取相邻格再落河沿，
    -- 那个相邻格可能是海/湖；之前会在海洋里画出一条河。
    local water = false
    pcall(function() water = plot:IsWater() == true end)
    if water then return false end
    -- plot:IsWater 可能是 false（plot type 没变），但地形已是 coast/ocean：
    -- 这种“看起来是海”的格子也不能加河沿。
    local terrain = nil
    pcall(function() terrain = tonumber(plot:GetTerrainType()) end)
    if terrain ~= nil and GameInfo ~= nil and GameInfo.Terrains ~= nil then
        local coast = GameInfo.Terrains["TERRAIN_COAST"]
        local ocean = GameInfo.Terrains["TERRAIN_OCEAN"]
        if (coast ~= nil and terrain == tonumber(coast.Index))
            or (ocean ~= nil and terrain == tonumber(ocean.Index)) then
            return false
        end
    end
    if m_RiverBudget > 0 and m_RiverEdgeWrites >= m_RiverBudget then return false end

    -- 优先用原版 3 参数 TerrainBuilder.Set*OfRiver(plot, true, flowDirection)：
    -- 不传自编 riverID，引擎自己分配/沿用河网。之前 4 参数版本传 m_NextRiverID，
    -- 引擎按不存在的 riverID 查河网，崩在 SplitsRiverFromMouth（2026-10-20）。
    local method = "Set" .. edge .. "OfRiver"
    if TerrainBuilder ~= nil and TerrainBuilder[method] ~= nil then
        local called, result = pcall(TerrainBuilder[method], plot, true, flowDirection)
        if called and result ~= false then
            m_RiverEdgeWrites = m_RiverEdgeWrites + 1
            return true
        end
    end

    -- 兜底：WorldBuilder 的 EditRiver（地图编辑器路径，适合单条河沿的修补）。
    local edgeValue = RiverEdgeIndex(edge)
    if wb ~= nil and wb.EditRiver ~= nil then
        local called, result = pcall(wb.EditRiver, plot:GetIndex(), edgeValue, true, false)
        if called and result ~= false then
            m_RiverEdgeWrites = m_RiverEdgeWrites + 1
            return true
        end
    end
    return false
end

local function GetOppositeFlowDirection(direction)
    return ((direction + 3) % FD.NUM_FLOWDIRECTION_TYPES)
end

local function GetRiverValueAtPlot(plot)
    if IsCliffEdge(plot, "NW") or IsCliffEdge(plot, "W") or IsCliffEdge(plot, "NE") then
        return -1
    end
    local wonder = false
    pcall(function() wonder = plot:IsNaturalWonder() == true end)
    if wonder or AdjacentToNaturalWonder(plot) then return -1 end

    local sum = GetPlotElevation(plot) * 20
    for direction = 0, DT.NUM_DIRECTION_TYPES - 1 do
        local adjacent = GetAdjacentPlot(plot, direction)
        if adjacent ~= nil then
            sum = sum + GetPlotElevation(adjacent)
            local terrain = nil
            pcall(function() terrain = adjacent:GetTerrainType() end)
            if tonumber(terrain) == tonumber(g_TERRAIN_TYPE_DESERT) then
                sum = sum + 4
            end
        else
            sum = sum + 40
        end
    end
    sum = sum + GetRandomNumber(10)
    return sum
end

-- 大河选向模仿普通河流：在相邻格里取 GetRiverValueAtPlot 最低的一格（顺地势/河谷），
-- 不是直着走向目标。相邻水域直接作为入海口。
local function FindBigRiverNext(x, y, dirX, dirY, step, avoidX, avoidY, visited)
    local plot = Map.GetPlot(x, y)
    if plot == nil then return nil, false end
    local bestPlot, bestScore = nil, nil
    local phase = (tonumber(step) or 0) * 0.8
    local lateral = math.sin(phase) * 1.5
    for direction = 0, 5 do
        local adjacent = GetAdjacentPlot(plot, direction)
        if adjacent ~= nil then
            local ax, ay = adjacent:GetX(), adjacent:GetY()
            local adjacentIndex = adjacent:GetIndex()
            local alreadyVisited = visited ~= nil and visited[adjacentIndex] == true
            if not (ax == avoidX and ay == avoidY) and not alreadyVisited then
                local water, mountain = false, false
                pcall(function() water = adjacent:IsWater() == true end)
                pcall(function() mountain = adjacent:IsMountain() == true end)
                if water then
                    -- 湖泊算大河的一部分；另一条大河的格子也算“河道”，继续走/汇流，
                    -- 不能当成入海口（否则两条大河一撞就断头）。
                    local isLake = false
                    pcall(function() isLake = adjacent:IsLake() == true end)
                    if isLake or adjacent.BigRiver == true then
                        return adjacent, false
                    end
                    return adjacent, true
                end
                if not mountain then
                    -- 朝向随机大局方向 + 垂直正弦蜿蜒 + 少量随机；山地跳过（绕山）。
                    local dx, dy = ax - x, ay - y
                    local alignment = dx * dirX + dy * dirY
                    local cross = math.abs(dx * (-dirY) + dy * dirX)
                    local score = alignment + lateral * cross + math.random() * 0.4
                    if bestScore == nil or score > bestScore then
                        bestScore = score
                        bestPlot = adjacent
                    end
                end
            end
        end
    end
    return bestPlot, false
end

local function DoRiver(startPlot, thisFlowDirection, originalFlowDirection, riverID)
    thisFlowDirection = thisFlowDirection or FD.NO_FLOWDIRECTION
    originalFlowDirection = originalFlowDirection or FD.NO_FLOWDIRECTION
    if riverID == nil then
        riverID = m_NextRiverID
        m_NextRiverID = m_NextRiverID + 1
    end

    local otherRiverID = m_RiverPlots[startPlot]
    if otherRiverID ~= nil and otherRiverID ~= riverID
        and originalFlowDirection == FD.NO_FLOWDIRECTION then
        return
    end

    local riverPlot = nil
    local bestFlowDirection = FD.NO_FLOWDIRECTION

    if thisFlowDirection == FD.FLOWDIRECTION_NORTH then
        riverPlot = startPlot
        m_RiverPlots[riverPlot] = riverID
        SetRiverEdge(nil, riverPlot, "W", thisFlowDirection, riverID)
        riverPlot = GetAdjacentPlot(riverPlot, DT.DIRECTION_NORTHEAST)
        if riverPlot == nil or riverPlot:IsWater() or IsRiverEdge(riverPlot, "NE")
            or IsRiverEdge(riverPlot, "NW") then return end
    elseif thisFlowDirection == FD.FLOWDIRECTION_NORTHEAST then
        riverPlot = startPlot
        m_RiverPlots[riverPlot] = riverID
        SetRiverEdge(nil, riverPlot, "NW", thisFlowDirection, riverID)
        local adjacentPlot = GetAdjacentPlot(riverPlot, DT.DIRECTION_EAST)
        if adjacentPlot == nil or adjacentPlot:IsWater() or IsRiverEdge(riverPlot, "W")
            or IsRiverEdge(adjacentPlot, "NE") then return end
    elseif thisFlowDirection == FD.FLOWDIRECTION_SOUTHEAST then
        riverPlot = GetAdjacentPlot(startPlot, DT.DIRECTION_EAST)
        if riverPlot == nil then return end
        m_RiverPlots[riverPlot] = riverID
        SetRiverEdge(nil, riverPlot, "NE", thisFlowDirection, riverID)
        local adjacentPlot = GetAdjacentPlot(riverPlot, DT.DIRECTION_SOUTHEAST)
        if adjacentPlot == nil or adjacentPlot:IsWater() or IsRiverEdge(riverPlot, "NW") then return end
        local adjacentPlot2 = GetAdjacentPlot(riverPlot, DT.DIRECTION_SOUTHWEST)
        if adjacentPlot2 == nil or IsRiverEdge(adjacentPlot2, "W") then return end
    elseif thisFlowDirection == FD.FLOWDIRECTION_SOUTH then
        riverPlot = GetAdjacentPlot(startPlot, DT.DIRECTION_SOUTHWEST)
        if riverPlot == nil then return end
        m_RiverPlots[riverPlot] = riverID
        SetRiverEdge(nil, riverPlot, "W", thisFlowDirection, riverID)
        local adjacentPlot = GetAdjacentPlot(riverPlot, DT.DIRECTION_SOUTHEAST)
        if adjacentPlot == nil or adjacentPlot:IsWater() or IsRiverEdge(riverPlot, "NW") then return end
        local adjacentPlot2 = GetAdjacentPlot(riverPlot, DT.DIRECTION_EAST)
        if adjacentPlot2 == nil or IsRiverEdge(adjacentPlot2, "NE") then return end
    elseif thisFlowDirection == FD.FLOWDIRECTION_SOUTHWEST then
        riverPlot = startPlot
        m_RiverPlots[riverPlot] = riverID
        SetRiverEdge(nil, riverPlot, "NW", thisFlowDirection, riverID)
        local adjacentPlot = GetAdjacentPlot(riverPlot, DT.DIRECTION_SOUTHWEST)
        if adjacentPlot == nil or adjacentPlot:IsWater() or IsRiverEdge(adjacentPlot, "W")
            or IsRiverEdge(riverPlot, "NE") then return end
    elseif thisFlowDirection == FD.FLOWDIRECTION_NORTHWEST then
        riverPlot = startPlot
        m_RiverPlots[riverPlot] = riverID
        SetRiverEdge(nil, riverPlot, "NE", thisFlowDirection, riverID)
        riverPlot = GetAdjacentPlot(riverPlot, DT.DIRECTION_WEST)
        if riverPlot == nil or riverPlot:IsWater() or IsRiverEdge(riverPlot, "NW")
            or IsRiverEdge(riverPlot, "W") then return end
    else
        riverPlot = startPlot
    end

    if riverPlot == nil or riverPlot:IsWater() then return end

    local adjacentPlotFunctions = {
        [FD.FLOWDIRECTION_NORTH] = function() return GetAdjacentPlot(riverPlot, DT.DIRECTION_NORTHWEST) end,
        [FD.FLOWDIRECTION_NORTHEAST] = function() return GetAdjacentPlot(riverPlot, DT.DIRECTION_NORTHEAST) end,
        [FD.FLOWDIRECTION_SOUTHEAST] = function() return GetAdjacentPlot(riverPlot, DT.DIRECTION_EAST) end,
        [FD.FLOWDIRECTION_SOUTH] = function() return GetAdjacentPlot(riverPlot, DT.DIRECTION_SOUTHWEST) end,
        [FD.FLOWDIRECTION_SOUTHWEST] = function() return GetAdjacentPlot(riverPlot, DT.DIRECTION_WEST) end,
        [FD.FLOWDIRECTION_NORTHWEST] = function() return GetAdjacentPlot(riverPlot, DT.DIRECTION_NORTHWEST) end,
    }

    if bestFlowDirection == FD.NO_FLOWDIRECTION then
        local bestValue = math.huge
        for flowDirection, getAdjacentPlot in pairs(adjacentPlotFunctions) do
            if GetOppositeFlowDirection(flowDirection) ~= originalFlowDirection then
                if thisFlowDirection == FD.NO_FLOWDIRECTION
                    or flowDirection == TurnRightFlowDirections[thisFlowDirection]
                    or flowDirection == TurnLeftFlowDirections[thisFlowDirection] then
                    local adjacentPlot = getAdjacentPlot()
                    if adjacentPlot ~= nil then
                        local value = GetRiverValueAtPlot(adjacentPlot)
                        if flowDirection == originalFlowDirection then
                            value = (value * 11) / 12
                        end
                        if value < bestValue then
                            bestValue = value
                            bestFlowDirection = flowDirection
                        end
                    end
                end
            end
        end
        if bestFlowDirection == FD.NO_FLOWDIRECTION then
            if originalFlowDirection == FD.FLOWDIRECTION_NORTHEAST then
                SetRiverEdge(nil, riverPlot, "NW", FD.FLOWDIRECTION_NORTHEAST, riverID)
                SetRiverEdge(nil, riverPlot, "W", FD.FLOWDIRECTION_NORTH, riverID)
            end
        end
    end

    if bestFlowDirection ~= FD.NO_FLOWDIRECTION then
        if originalFlowDirection == FD.NO_FLOWDIRECTION then
            originalFlowDirection = bestFlowDirection
        end
        DoRiver(riverPlot, bestFlowDirection, originalFlowDirection, riverID)
    end
end

function MR.AddRivers(wb, width, height, land, targetCount)
    local before = m_RiverEdgeWrites
    -- 授权者 2026-10-20：原版河流只做短支流 ⇒ 源头离水范围从 4/3 收紧到 2/1，
    -- 深入内陆的长距离交给 AddBigRivers 的浅海大河。
    local riverSourceRangeDefault = 2
    local seaWaterRangeDefault = 1
    local budget = m_RiverBudget
    local before = m_RiverEdgeWrites
    local plotsPerRiverEdge = (GlobalParameters ~= nil
        and GlobalParameters.RIVER_PLOTS_PER_EDGE) or 12

    local passConditions = {
        function(plot) return plot:IsHills() or plot:IsMountain() end,
        function(plot)
            return (not plot:IsCoastalLand())
                and (GetRandomNumber(8) == 0)
        end,
        function(plot)
            local area = GetPlotArea(plot)
            if area == nil then return false end
            return (plot:IsHills() or plot:IsMountain())
                and (area:GetRiverEdgeCount() < ((area:GetPlotCount() / plotsPerRiverEdge) + 1))
        end,
        function(plot)
            local area = GetPlotArea(plot)
            if area == nil then return false end
            return area:GetRiverEdgeCount() < ((area:GetPlotCount() / plotsPerRiverEdge) + 1)
        end,
    }

    for passIndex, passCondition in ipairs(passConditions) do
        if budget > 0 and m_RiverEdgeWrites >= budget then break end
        local riverSourceRange, seaWaterRange
        if passIndex <= 2 then
            riverSourceRange = riverSourceRangeDefault
            seaWaterRange = seaWaterRangeDefault
        else
            riverSourceRange = riverSourceRangeDefault / 2
            seaWaterRange = seaWaterRangeDefault / 2
        end
        local mapWidth, mapHeight = Map.GetGridSize()
        for index = 0, (mapWidth * mapHeight) - 1 do
            if budget > 0 and m_RiverEdgeWrites >= budget then break end
            local plot = Map.GetPlotByIndex(index)
            if plot ~= nil and not plot:IsWater() then
                local wonder = false
                pcall(function() wonder = plot:IsNaturalWonder() == true end)
                if passCondition(plot) and not wonder and not AdjacentToNaturalWonder(plot) then
                    if not FindWaterNear(plot, riverSourceRange) then
                        if not FindWaterNear(plot, seaWaterRange) then
                            local inlandCorner = GetInlandCorner(plot)
                            if inlandCorner ~= nil and not wonder
                                and not AdjacentToNaturalWonder(inlandCorner) then
                                DoRiver(inlandCorner)
                            end
                        end
                    end
                end
            end
        end
    end
    return m_RiverEdgeWrites - before
end

local function AddMoreLake(wb, plot)
    local largeLake = 0
    local lakePlots = {}
    for direction = 0, DT.NUM_DIRECTION_TYPES - 1 do
        local adjacentPlot = GetAdjacentPlot(plot, direction)
        if adjacentPlot ~= nil and not adjacentPlot:IsWater()
            and not adjacentPlot:IsCoastalLand()
            and not adjacentPlot:IsRiver() and not adjacentPlot:IsRiverAdjacent()
            and not IsNaturalWonderPlot(adjacentPlot) then
            local feature = nil
            pcall(function() feature = adjacentPlot:GetFeatureType() end)
            if tonumber(feature) ~= tonumber(g_FEATURE_VOLCANO)
                and not AdjacentToNaturalWonder(adjacentPlot) then
                local r = GetRandomNumber(4 + largeLake)
                if r < 3 then
                    table.insert(lakePlots, adjacentPlot)
                    largeLake = largeLake + 1
                end
            end
        end
    end
    for _, lakePlot in ipairs(lakePlots) do
        if SetTerrain(wb, lakePlot, "TERRAIN_COAST") then
            m_LakeCount = m_LakeCount + 1
        end
    end
    return largeLake > 2
end

function MR.AddLakes(wb, width, height, land, targetCount, lakePlotRandOverride)
    local before = m_LakeCount
    local largeLakes = tonumber(targetCount) or 0
    local numLakesAdded = 0
    local numLargeLakesAdded = 0
    local lakePlotRand = tonumber(lakePlotRandOverride)
        or (GlobalParameters ~= nil and GlobalParameters.LAKE_PLOT_RANDOM) or 25
    local mapWidth, mapHeight = Map.GetGridSize()
    for index = 0, (mapWidth * mapHeight) - 1 do
        local plot = Map.GetPlotByIndex(index)
        if plot ~= nil and plot.BigRiver ~= true
            and not plot:IsWater() and not plot:IsCoastalLand()
            and not plot:IsRiver() and not plot:IsRiverAdjacent()
            and not IsNaturalWonderPlot(plot) then
            local feature = nil
            pcall(function() feature = plot:GetFeatureType() end)
            if tonumber(feature) ~= tonumber(g_FEATURE_VOLCANO)
                and not AdjacentToNaturalWonder(plot) then
                local r = GetRandomNumber(lakePlotRand)
                if r == 0 then
                    numLakesAdded = numLakesAdded + 1
                    m_LakeCount = m_LakeCount + 1
                    if largeLakes > numLargeLakesAdded then
                        if AddMoreLake(wb, plot) then
                            numLargeLakesAdded = numLargeLakesAdded + 1
                        end
                    end
                    SetTerrain(wb, plot, "TERRAIN_COAST")
                end
            end
        end
    end
    if numLakesAdded > 0 and AreaBuilder ~= nil and AreaBuilder.Recalculate ~= nil then
        pcall(AreaBuilder.Recalculate)
    end
    return m_LakeCount - before
end

-- 大河源头：必须在内陆（离最近水域至少 minDistance 格），否则会变成海边一小段浅水，
-- 看起来“没有大河”（授权者 2026-10-20）。
-- 大河源头：深入内陆 + 目标是最近的海/海岸（湖泊在 AddLakes 里后生成，
-- 所以此处最近水域就是海/海岸，天然保证“流入海洋”）。
-- 海向出口：地图内部、紧邻陆地的水格（海岸/海），排除湖泊与最外圈。
-- 大河目标改成从这里随机抽一个，而不是“最近水域”，避免总是横向直线。
local function CollectSeaOutlets(land, width, height)
    local outlets = {}
    for y = 1, height - 2 do
        for x = 1, width - 2 do
            if land[PlotKey(x, y)] ~= true then
                local plot = Map.GetPlot(x, y)
                if plot ~= nil then
                    local water = false
                    pcall(function() water = plot:IsWater() == true end)
                    if water then
                        local adjacentLand = false
                        for direction = 0, 5 do
                            local adjacent = GetAdjacentPlot(plot, direction)
                            if adjacent ~= nil then
                                if land[PlotKey(adjacent:GetX(), adjacent:GetY())] == true then
                                    adjacentLand = true
                                    break
                                end
                            end
                        end
                        if adjacentLand then
                            outlets[#outlets + 1] = { x, y }
                        end
                    end
                end
            end
        end
    end
    return outlets
end

local function FindBigRiverSource(land, width, height, minDistance)
    local candidates = {}
    local seaOutlets = CollectSeaOutlets(land, width, height)
    for key in pairs(land) do
        local sx, sy = string.match(key, "^(%-?%d+),(%-?%d+)$")
        if sx ~= nil then
            local x, y = tonumber(sx), tonumber(sy)
            local plot = Map.GetPlot(x, y)
            -- 源头离地图最外圈至少 3 格，避免大河贴着边界走（日志里 57,11 仍太靠边）。
            local skip = x <= 2 or y <= 2 or x >= width - 3 or y >= height - 3
            if plot ~= nil and not skip then
                local mountain, wonder = false, false
                pcall(function() mountain = plot:IsMountain() == true end)
                pcall(function() wonder = plot:IsNaturalWonder() == true end)
                -- 授权者 2026-10-21：大河源头取山脉；不再走原版河值/普通河流取向。
                skip = (not mountain) or wonder
            else
                skip = true
            end
            if not skip then
                -- 源头必须离“最近水域”就足够远；否则起点就在海边，大河只有一两格。
                local nearestX, nearestY = FindNearestWater(x, y, land, width, height)
                local nearestDistance = nil
                if nearestX ~= nil then
                    nearestDistance = math.max(math.abs(nearestX - x), math.abs(nearestY - y))
                end
                if nearestDistance ~= nil and nearestDistance >= minDistance then
                    local targetX, targetY = nil, nil
                    if #seaOutlets > 0 then
                        local outlet = seaOutlets[math.random(1, #seaOutlets)]
                        targetX, targetY = outlet[1], outlet[2]
                    else
                        targetX, targetY = nearestX, nearestY
                    end
                    local distance = math.max(math.abs(targetX - x), math.abs(targetY - y))
                    table.insert(candidates, { x, y, targetX, targetY, distance })
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    -- 授权者 2026-10-20：深入内陆交给大河 ⇒ 选离水最远的源头，而不是随机一个。
    local best = candidates[1]
    for _, candidate in ipairs(candidates) do
        if candidate[5] > best[5] then best = candidate end
    end
    return best
end

function MR.AddBigRivers(wb, width, height, land, targetCount)
    local placed = 0
    -- 大河数量：1/500 → 1/350 → 1/300 格（再略增）。
    local target = tonumber(targetCount) or math.max(1, math.floor(width * height / 300))
    -- 4 格只用于排除海边假大河；真正“深入内陆”由 FindBigRiverSource 选最远源头保证。
    -- 优先拉长大河：源头离最近水域至少 6 格；找不到再逐级放宽。
    local minSourceDistance = 4
    m_BigRiverCells, m_LongestBigRiver = 0, 0
    m_BigRiverPaths = {}
    m_BigRiverPlots = {}
    for _ = 1, target * 30 do
        if placed >= target then break end
        local source = FindBigRiverSource(land, width, height, minSourceDistance)
        if source == nil then source = FindBigRiverSource(land, width, height, 5) end
        if source == nil then source = FindBigRiverSource(land, width, height, 4) end
        if source == nil then break end
        local currentX, currentY = source[1], source[2]
        local cells = 0
        local previousX, previousY = nil, nil
        local visited = {}
        local direction = DIRECTION_DELTAS[math.random(0, 5)] or { 1, 0 }
        local dirX, dirY = direction[1], direction[2]
        local step = 0
        local sourcePlot = Map.GetPlot(currentX, currentY)
        if sourcePlot ~= nil then visited[sourcePlot:GetIndex()] = true end
        for _ = 1, width * height do
            if land[PlotKey(currentX, currentY)] ~= true then break end
            local plot = Map.GetPlot(currentX, currentY)
            if plot ~= nil then
                local wonder, alreadyWater = false, false
                pcall(function() wonder = plot:IsNaturalWonder() == true end)
                pcall(function() alreadyWater = plot:IsWater() == true end)
                if wonder then
                    -- 不覆盖自然奇观；跳过这一格继续往下走，避免整条大河从这里断开。
                elseif alreadyWater then
                    -- 已经是水的路径格也要标记/计数，否则 SetTerrain 返回 false 时会被漏掉。
                    plot.BigRiver = true
                    m_BigRiverPlots[plot:GetIndex()] = true
                    cells = cells + 1
                else
                    -- 这些每格写以前就有、没有导致闪退；闪退嫌疑在大河取向与原版河流冲突，
                    -- 新流向算法已不再走 GetRiverValueAtPlot/DoRiver，所以这里恢复原行为。
                    SetFeature(wb, plot, nil)
                    if SetTerrain(wb, plot, "TERRAIN_COAST") then
                        plot.BigRiver = true
                        m_BigRiverPlots[plot:GetIndex()] = true
                        pcall(function() plot:SetPlotType(PLOT_TYPE_OCEAN, false, false) end)
                        ClearResource(wb, plot)
                        land[PlotKey(currentX, currentY)] = nil
                        cells = cells + 1
                    end
                end
            end
            step = step + 1
            local nextPlot, isMouth = FindBigRiverNext(currentX, currentY,
                dirX, dirY, step, previousX, previousY, visited)
            if nextPlot == nil then break end
            visited[nextPlot:GetIndex()] = true
            previousX, previousY = currentX, currentY
            currentX, currentY = nextPlot:GetX(), nextPlot:GetY()
            if isMouth then
                local mouthPlot = nextPlot
                local mouthWater = false
                pcall(function() mouthWater = mouthPlot:IsWater() == true end)
                if mouthWater then
                    mouthPlot.BigRiverMouth = true
                    m_BigRiverPlots[mouthPlot:GetIndex()] = true
                end
                break
            end
            if not land[PlotKey(currentX, currentY)] then
                -- 入海口：把海/湖那一格也标记进大河，而不是停在最后一个陆地格。
                local mouthPlot = Map.GetPlot(currentX, currentY)
                if mouthPlot ~= nil then
                    local mouthWater = false
                    pcall(function() mouthWater = mouthPlot:IsWater() == true end)
                    if mouthWater then
                        mouthPlot.BigRiverMouth = true
                        m_BigRiverPlots[mouthPlot:GetIndex()] = true
                        -- 大河主体保持 1 格宽，只在入海口补一格相邻陆地，
                        -- 形成一个稍宽的河口（不是整条河加宽）。
                        for direction = 0, 5 do
                            local estuary = GetAdjacentPlot(mouthPlot, direction)
                            if estuary ~= nil then
                                local estuaryKey = PlotKey(estuary:GetX(), estuary:GetY())
                                if land[estuaryKey] == true and estuary.BigRiver ~= true then
                                    SetFeature(wb, estuary, nil)
                                    if SetTerrain(wb, estuary, "TERRAIN_COAST") then
                                        estuary.BigRiver = true
                                        m_BigRiverPlots[estuary:GetIndex()] = true
                                        land[estuaryKey] = nil
                                        cells = cells + 1
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
                break
            end
        end
        -- 太短的不算大河（否则只是海边一小段浅水）
        if cells >= 4 then
            placed = placed + 1
            m_BigRiverCells = m_BigRiverCells + cells
            if cells > m_LongestBigRiver then m_LongestBigRiver = cells end
            m_BigRiverPaths[#m_BigRiverPaths + 1] = tostring(source[1]) .. ","
                .. tostring(source[2]) .. "->" .. tostring(currentX) .. ","
                .. tostring(currentY) .. "(" .. tostring(cells) .. ")"
        end
    end
    return placed
end

-- 自然奇观：海陆地形必须保持原样（授权者 2026-10-20）。
-- 返回 { [key] = true }；同时记录它是陆地还是水域，供陆地掩码/河流生成使用。
local function CollectNaturalWonders(width, height)
    local wonders = {}
    local wonderIsLand = {}
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local plot = Map.GetPlot(x, y)
            if plot ~= nil then
                local wonder = false
                pcall(function() wonder = plot:IsNaturalWonder() == true end)
                if wonder then
                    local key = PlotKey(x, y)
                    local water = false
                    pcall(function() water = plot:IsWater() == true end)
                    wonders[key] = true
                    wonderIsLand[key] = not water
                end
            end
        end
    end
    return wonders, wonderIsLand
end


-- ===========================================================================
-- 非幽灵玩家出生地预设 + 单位平铺传送（授权者 2026-10-20）
--
--   * 地图生成时给每个非幽灵、且地图上有单位的玩家预设一个出生格；
--   * 生成完毕后用 UnitManager.PlaceUnit 把单位传送到出生格附近；
--   * 每个单位 RestoreMovement 恢复行动力；
--   * 平铺规则：同一 formationClass 不能叠在同一格；不同 formationClass 可以重叠。
--     （先铺出生格，再按半径 1、2、3… 的环向外铺；环铺完再全图扫描兜底。）
-- ===========================================================================
local function GetUnitFormationClass(unit)
    local typeIndex = nil
    pcall(function() typeIndex = unit:GetType() end)
    local row = GameInfo ~= nil and GameInfo.Units ~= nil and GameInfo.Units[typeIndex] or nil
    if row ~= nil and row.FormationClass ~= nil then
        return tostring(row.FormationClass)
    end
    return "UNKNOWN"
end

local function RestoreUnitMovement(unit)
    if UnitManager == nil then return false end
    if UnitManager.RestoreMovement ~= nil then
        local ok = pcall(UnitManager.RestoreMovement, unit)
        if ok then return true end
    end
    if UnitManager.ChangeMovesRemaining ~= nil then
        local maxMoves, remaining = 0, 0
        pcall(function() maxMoves = unit:GetMaxMoves() end)
        pcall(function() remaining = unit:GetMovesRemaining() end)
        local delta = (tonumber(maxMoves) or 0) - (tonumber(remaining) or 0)
        if delta > 0 then
            return pcall(UnitManager.ChangeMovesRemaining, unit, delta)
        end
        return true
    end
    return false
end

local function GetPlayerOnMapUnits(playerID)
    local player = Players ~= nil and Players[playerID] or nil
    if player == nil then return {} end
    local units = {}
    local ok, err = pcall(function()
        local playerUnits = player:GetUnits()
        if playerUnits == nil then return end
        for _, unit in playerUnits:Members() do
            if unit ~= nil then
                -- 【必须过滤坐标】幽灵玩家的单位在地图外（-1,-1）。不过滤的话
                -- PresetAndMoveNonGhostUnits 会把幽灵的开拓者当“图上单位”传送到出生点，
                -- 等于把幽灵拉回地图（2026-10-21 实机：外星图地形改造后城邦被拉回落地）。
                local ux, uy = -1, -1
                pcall(function() ux, uy = unit:GetX(), unit:GetY() end)
                if ux ~= nil and uy ~= nil and ux >= 0 and uy >= 0 then
                    table.insert(units, unit)
                end
            end
        end
    end)
    if not ok then
        Log("GetPlayerOnMapUnits error player=" .. tostring(playerID) .. " " .. tostring(err))
        return {}
    end
    return units
end

local function IsNonGhostPlayer(playerID)
    if IsGhostPlayer == nil and IsCityStateGhostPlayer == nil then return true end
    local isGhost = false
    if IsGhostPlayer ~= nil then
        pcall(function() isGhost = IsGhostPlayer(playerID) == true end)
    end
    -- 城邦幽灵是**另一个池子**（IsGhostPlayer 只查主流池）。不认城邦池的话，
    -- 城邦幽灵会被当成“非幽灵”预设出生格、传送回地图（2026-10-21 实机）。
    if not isGhost and IsCityStateGhostPlayer ~= nil then
        pcall(function() isGhost = IsCityStateGhostPlayer(playerID) == true end)
    end
    return not isGhost
end

local function FindUnitSpawnNear(x, y, width, height, land, claimed, wonders,
    otherSpawns, minDistance)
    local function FarEnough(sx, sy)
        if otherSpawns == nil or minDistance == nil or minDistance <= 0 then return true end
        for _, spawn in pairs(otherSpawns) do
            if type(spawn) == "table" and spawn.X ~= nil and spawn.Y ~= nil then
                if math.max(math.abs(sx - spawn.X), math.abs(sy - spawn.Y)) < minDistance then
                    return false
                end
            end
        end
        return true
    end
    local function Valid(sx, sy)
        if sx < 0 or sy < 0 or sx >= width or sy >= height then return nil end
        local key = PlotKey(sx, sy)
        if claimed[key] == true or (wonders ~= nil and wonders[key] == true) then
            return nil
        end
        local plot = Map.GetPlot(sx, sy)
        if not IsLandPlot(plot, land, key) then return nil end
        local mountain = false
        pcall(function() mountain = plot:IsMountain() == true end)
        if mountain then return nil end
        if not FarEnough(sx, sy) then return nil end
        claimed[key] = true
        return { X = sx, Y = sy }
    end
    local found = Valid(x, y)
    if found ~= nil then return found end
    local maxRadius = math.max(width, height)
    for radius = 1, maxRadius do
        for dy = -radius, radius do
            for dx = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    found = Valid(x + dx, y + dy)
                    if found ~= nil then return found end
                end
            end
        end
    end
    for sy = 0, height - 1 do
        for sx = 0, width - 1 do
            found = Valid(sx, sy)
            if found ~= nil then return found end
        end
    end
    return nil
end

local function PlaceUnitAt(unit, x, y, usedClasses, width, height, land, wonders)
    if x < 0 or y < 0 or x >= width or y >= height then return false end
    local key = PlotKey(x, y)
    if wonders ~= nil and wonders[key] == true then return false end
    local plot = Map.GetPlot(x, y)
    if not IsLandPlot(plot, land, key) then return false end
    local mountain = false
    pcall(function() mountain = plot:IsMountain() == true end)
    if mountain then return false end
    local classes = usedClasses[key]
    if classes == nil then classes = {}; usedClasses[key] = classes end
    local formationClass = GetUnitFormationClass(unit)
    if classes[formationClass] == true then return false end
    local placed = pcall(UnitManager.PlaceUnit, unit, x, y)
    if placed ~= true then return false end
    classes[formationClass] = true
    RestoreUnitMovement(unit)
    return true
end

local function TileAndMovePlayerUnits(playerID, units, spawn, width, height, land, wonders)
    local usedClasses = {}
    local moved = 0
    for _, unit in ipairs(units) do
        local ok = false
        local spawnX, spawnY = spawn.X, spawn.Y
        for radius = 0, math.max(width, height) do
            for dy = -radius, radius do
                for dx = -radius, radius do
                    if radius == 0 or math.abs(dx) == radius or math.abs(dy) == radius then
                        if PlaceUnitAt(unit, spawnX + dx, spawnY + dy,
                            usedClasses, width, height, land, wonders) then
                            ok = true
                            break
                        end
                    end
                end
                if ok then break end
            end
            if ok then break end
        end
        -- 出生点附近铺完还不够（单位很多）⇒ 全图扫描兜底
        if not ok then
            for sy = 0, height - 1 do
                for sx = 0, width - 1 do
                    if PlaceUnitAt(unit, sx, sy, usedClasses, width, height, land, wonders) then
                        ok = true
                        break
                    end
                end
                if ok then break end
            end
        end
        if ok then moved = moved + 1 end
    end
    Log("单位平铺：player=" .. tostring(playerID) .. " moved=" .. tostring(moved)
        .. "/" .. tostring(#units) .. " spawn=" .. tostring(spawn.X) .. "," .. tostring(spawn.Y))
    return moved
end

local function PresetAndMoveNonGhostUnits(width, height, land, unitSpawnKey, wonders)
    local spawns = nil
    pcall(function() spawns = Game:GetProperty(unitSpawnKey) end)
    if type(spawns) ~= "table" then spawns = {} end
    local claimed = {}
    for _, spawn in pairs(spawns) do
        if type(spawn) == "table" and spawn.X ~= nil and spawn.Y ~= nil then
            claimed[PlotKey(spawn.X, spawn.Y)] = true
        end
    end

    local playerCount, movedUnits = 0, 0
    local ghostsSkipped = 0
    for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
        if Players ~= nil and Players[playerID] ~= nil and not IsNonGhostPlayer(playerID) then
            ghostsSkipped = ghostsSkipped + 1
        end
        if Players ~= nil and Players[playerID] ~= nil and IsNonGhostPlayer(playerID) then
            local units = GetPlayerOnMapUnits(playerID)
            if #units > 0 then
                -- 出生地：旧预设（若仍有效）→ 单位中心附近 → 全图兜底
                local spawn = spawns[tostring(playerID)]
                local validSpawn = nil
                if spawn ~= nil and spawn.X ~= nil and spawn.Y ~= nil then
                    local key = PlotKey(spawn.X, spawn.Y)
                    local plot = Map.GetPlot(spawn.X, spawn.Y)
                    local water, mountain = false, false
                    pcall(function() water = plot:IsWater() == true end)
                    pcall(function() mountain = plot:IsMountain() == true end)
                    if land[key] == true and not water and not mountain
                        and (wonders == nil or wonders[key] ~= true) then
                        validSpawn = { X = spawn.X, Y = spawn.Y }
                    end
                end
                if validSpawn == nil then
                    local sumX, sumY = 0, 0
                    for _, unit in ipairs(units) do
                        local ux, uy = 0, 0
                        pcall(function() ux, uy = unit:GetX(), unit:GetY() end)
                        if ux ~= nil and uy ~= nil and ux >= 0 and uy >= 0 then
                            sumX = sumX + ux
                            sumY = sumY + uy
                        end
                    end
                    local baseX = math.floor(sumX / #units)
                    local baseY = math.floor(sumY / #units)
                    -- 玩家出生格至少隔 6 格，避免多个玩家/城邦单位挤在一起。
                    local otherSpawns = {}
                    local ownKey = tostring(playerID)
                    for key, value in pairs(spawns) do
                        if key ~= ownKey then otherSpawns[key] = value end
                    end
                    validSpawn = FindUnitSpawnNear(baseX, baseY, width, height, land, claimed,
                        wonders, otherSpawns, 6)
                end
                if validSpawn ~= nil then
                    spawns[tostring(playerID)] = validSpawn
                    playerCount = playerCount + 1
                    movedUnits = movedUnits + TileAndMovePlayerUnits(playerID, units,
                        validSpawn, width, height, land, wonders)
                end
            end
        end
    end
    pcall(function() Game:SetProperty(unitSpawnKey, spawns) end)
    Log("非幽灵出生地：players=" .. tostring(playerCount)
        .. " movedUnits=" .. tostring(movedUnits)
        .. " ghostsSkipped=" .. tostring(ghostsSkipped))
    return playerCount, movedUnits
end

-- 构建标记（只用于日志核对：确认本局加载的是哪一版 ModTool_MapRebuild）。
local MR_BUILD = "2026-10-21-spawnfix"

function MR.RebuildMap(options)
    options = options or {}
    Log("RebuildMap build=" .. MR_BUILD)
    local wb = options.WorldBuilder or WorldBuilderAPI
    if wb == nil or wb.SetTerrainType == nil then
        return false, "WorldBuilderAPI 不可用"
    end
    local width, height = nil, nil
    local sizeOk = pcall(function() width, height = Map.GetGridSize() end)
    if not sizeOk or width == nil or height == nil or width <= 0 or height <= 0 then
        return false, "Map.GetGridSize 不可用"
    end

    -- 河沿预算 = 地图地块数 / 12（原版 plotsPerRiverEdge 同量级）。
    -- 火山/热带星球河网更密（授权者 2026-10-20）：预算 ×1.7，湖泊概率也提高。
    local planetType = tostring(options.PlanetType or "none")
    local denseRivers = planetType == "volcanic" or planetType == "tropical"
    local sparseRivers = planetType == "desert"
    local riverDensity = denseRivers and 1.7 or (sparseRivers and 0.45 or 1)
    m_RiverBudget = math.max(12, math.floor((width * height) / 10 * riverDensity))
    m_RiverEdgeWrites = 0
    local layoutKey = MR.ClassifyLayout(options.Layout) or "continents"
    local layout = SEALAND_LAYOUTS[layoutKey] or SEALAND_LAYOUTS.continents
    local total = width * height
    local targetLand = math.floor(total * (1 - layout.Water))
    local wonders, wonderIsLand = CollectNaturalWonders(width, height)

    local land = {}
    local landCount = 0
    local function AddLand(x, y)
        if x < 0 or y < 0 or x >= width or y >= height then return false end
        local key = PlotKey(x, y)
        if land[key] then return false end
        land[key] = true
        landCount = landCount + 1
        return true
    end

    -- 自然奇观按原海陆状态进入陆地掩码（陆地奇观算陆地，水域奇观不算）。
    for key, isLand in pairs(wonderIsLand) do
        if isLand == true then
            land[key] = true
            landCount = landCount + 1
        else
            land[key] = nil
        end
    end

    local centers = math.max(1, tonumber(layout.Centers) or 4)
    local perCenter = math.max(1, math.floor(targetLand / centers))
    for _ = 1, centers do
        local x = math.random(0, width - 1)
        local y = math.random(0, height - 1)
        for _ = 1, perCenter do
            AddLand(x, y)
            -- 版图生长同样走引擎六边形邻居；DIRECTION_DELTAS 是棋盘格，会把大陆长歪/长断。
            local currentPlot = Map.GetPlot(x, y)
            local adjacent = GetAdjacentPlot(currentPlot, math.random(0, 5))
            if adjacent ~= nil then
                x = math.max(0, math.min(width - 1, adjacent:GetX()))
                y = math.max(0, math.min(height - 1, adjacent:GetY()))
            end
        end
    end

    local frontier = {}
    for key in pairs(land) do
        local sx, sy = string.match(key, "^(%-?%d+),(%-?%d+)$")
        if sx ~= nil then table.insert(frontier, { tonumber(sx), tonumber(sy) }) end
    end
    local guard = 0
    while landCount < targetLand and #frontier > 0 and guard < total * 8 do
        guard = guard + 1
        local cell = frontier[math.random(1, #frontier)]
        local adjacent = GetAdjacentPlot(Map.GetPlot(cell[1], cell[2]), math.random(0, 5))
        if adjacent ~= nil then
            local nx, ny = adjacent:GetX(), adjacent:GetY()
            if AddLand(nx, ny) then table.insert(frontier, { nx, ny }) end
        end
    end

    local changed = 0
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local plot = Map.GetPlot(x, y)
            if plot ~= nil then
                local key = PlotKey(x, y)
                local plotType, terrainType
                if wonders[key] == true then
                    -- 自然奇观：海陆地形/地貌/资源/改良全部保持原样
                elseif land[key] then
                    local roll = math.random()
                    if roll < 0.05 then
                        plotType, terrainType = PLOT_TYPE_MOUNTAIN, "TERRAIN_GRASS_MOUNTAIN"
                    elseif roll < 0.22 then
                        plotType, terrainType = PLOT_TYPE_HILLS, "TERRAIN_GRASS_HILLS"
                    else
                        plotType, terrainType = PLOT_TYPE_LAND, "TERRAIN_GRASS"
                    end
                else
                    plotType, terrainType = PLOT_TYPE_OCEAN, "TERRAIN_OCEAN"
                end
                if wonders[key] ~= true then
                    pcall(function() plot:SetPlotType(plotType, false, false) end)
                    -- SetFeature(nil) 修好后是真实的引擎写；不能对全图每格都清一遍，
                    -- 否则一次重建几千笔 feature/resource/improvement 写，实机容易在
                    -- UI 纹理加载（ForgeUI ReadTextureFromDisk）时闪退。
                    -- 只有地形真的变了才清旧地貌/资源/改良。
                    if SetTerrain(wb, plot, terrainType) then
                        changed = changed + 1
                        SetFeature(wb, plot, nil)
                        ClearResource(wb, plot)
                        ClearImprovement(wb, plot)
                    end
                end
            end
        end
    end

    -- 浅海：靠陆地的水格改成海岸。
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            if land[PlotKey(x, y)] ~= true and wonders[PlotKey(x, y)] ~= true then
                local isCoast = false
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        if (dx ~= 0 or dy ~= 0)
                            and land[PlotKey(x + dx, y + dy)] == true then
                            isCoast = true
                        end
                    end
                end
                if isCoast then
                    local plot = Map.GetPlot(x, y)
                    if plot ~= nil and SetTerrain(wb, plot, "TERRAIN_COAST") then
                        changed = changed + 1
                    end
                end
            end
        end
    end

    m_ActiveWorldBuilder = wb
    ProbeRiverEdgeMap(wb, width, height)
    local lakes = 0
    local rivers = 0
    local bigRivers = 0
    -- 大河**先于**旧河沿清理和原版河流生成（授权者 2026-10-21）：
    -- 先把大河浅海带铺好，再清旧河沿，最后 AddRivers 把大河当水域/入海口生成支流。
    if options.BigRivers ~= false then
        -- 沙漠图几乎没有大河；其他星球用默认目标。
        bigRivers = MR.AddBigRivers(wb, width, height, land,
            sparseRivers and 0 or options.BigRiverCount)
    end
    local clearedRivers = MR.ClearRivers(wb, width, height, wonders)
    if AreaBuilder ~= nil and AreaBuilder.Recalculate ~= nil then
        pcall(AreaBuilder.Recalculate)
    end
    if options.Rivers ~= false then
        rivers = MR.AddRivers(wb, width, height, land, options.RiverCount)
    end
    if options.Lakes ~= false then
        -- 密河星球湖泊也更多：LAKE_PLOT_RAND 25 → 16（约 1.5 倍湖密度）。
        -- 火山/热带湖泊更密（16）；沙漠更稀（40）；其他默认 25。
        local lakeRand = denseRivers and 16 or (sparseRivers and 40 or nil)
        lakes = MR.AddLakes(wb, width, height, land, options.LakeCount, lakeRand)
    end
    if AreaBuilder ~= nil and AreaBuilder.Recalculate ~= nil then
        pcall(AreaBuilder.Recalculate)
    end

    -- 大河的 plot index 写进属性，AV_EH/F flavor 后续步骤据此跳过，避免地形被盖掉。
    pcall(function() Game:SetProperty("ModMiscMapRebuild_big_river_plots", m_BigRiverPlots) end)

    local repaired, candidates = CollectSpawns(width, height, land,
        options.SpawnKey or "ModMiscMapRebuild_spawns",
        options.CandidateKey or "ModMiscMapRebuild_spawn_candidates")

    -- 非幽灵玩家：预设出生地 + PlaceUnit 平铺传送 + RestoreMovement
    local spawnedPlayers, movedUnits = PresetAndMoveNonGhostUnits(width, height, land,
        options.UnitSpawnKey or "ModMiscMapRebuild_unit_spawns", wonders)

    local details = {
        Layout = layoutKey,
        Land = landCount,
        Total = total,
        Coasts = 0,
        Lakes = lakes,
        Rivers = rivers,
        BigRivers = bigRivers,
        ClearedRivers = clearedRivers,
        SpawnRepaired = repaired,
        SpawnCandidates = candidates,
        SpawnedPlayers = spawnedPlayers,
        MovedUnits = movedUnits,
        BigRiverCells = m_BigRiverCells,
        LongestBigRiver = m_LongestBigRiver,
        PlanetType = planetType,
        RiverDensity = riverDensity,
    }
    Log("RebuildMap " .. tostring(layoutKey)
        .. " land=" .. tostring(landCount) .. "/" .. tostring(total)
        .. " lakes=" .. tostring(lakes)
        .. " rivers=" .. tostring(rivers)
        .. " bigRivers=" .. tostring(bigRivers)
        .. " clearedRivers=" .. tostring(clearedRivers)
        .. " bigRiverCells=" .. tostring(m_BigRiverCells)
        .. " longestBigRiver=" .. tostring(m_LongestBigRiver)
        .. " bigRiverPaths=" .. table.concat(m_BigRiverPaths, ";")
        .. " spawnCandidates=" .. tostring(candidates))
    return true, details
end
