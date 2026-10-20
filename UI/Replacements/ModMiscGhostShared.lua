-- ===========================================================================
-- Mod Misc Tool: UI 补丁共用件（资料片链 + 幽灵判定）
--
-- 【为什么改成补丁】原来是把整个 UI 脚本复制一份（Civ6Common / DiplomacyRibbon /
-- DiplomacyStatementSupport），既容易和游戏版本脱节，也会把官方资料片的改动顶掉。
-- 现在按官方做法（见 Civ6Data/Expansion1|Expansion2 的 ReplaceUIScript +
-- UI/Replacements/*_Expansion*.lua）：**include 上一层脚本，再只覆盖要改的函数**。
--
-- 本文件被**外交两处补丁** include，提供两件事：
--   ① 资料片判定（按数据库表判断，不猜、不写死 DLC GUID）+ 按官方资料片链 include 上一层
--   ② 幽灵玩家判定（外交条 / 领袖弹窗共用同一份，不重复实现）
-- 注：地图尺寸解析不在本文件 —— 它随 Civ6Common 取代版一起走（2026-10-15 授权者定）。
-- ===========================================================================

-- 资料片判定：探针表按官方 Schema 核对过 —— Governors 只在 XP1/XP2 里，
-- CoastalLowlands 只在 XP2 里（基座与 XP1 都没有）。
function ModMiscToolHasExpansion1()
	return GameInfo ~= nil and GameInfo.Governors ~= nil;
end

function ModMiscToolHasExpansion2()
	return GameInfo ~= nil and GameInfo.CoastalLowlands ~= nil;
end

-- ===========================================================================
-- 按官方资料片链 include 上一层脚本
--
-- 官方链（实测文件头）：
--   XP2 的补丁 include XP1 的补丁；XP1 的补丁 include 基座。
--   例：DiplomacyActionView_Expansion2.lua -> include("DiplomacyActionView_Expansion1.lua")
--                                        -> include("DiplomacyActionView")
-- 所以补丁只能接在**当前生效的那一层**后面；直接 include 基座会把资料片的改动顶掉。
-- ===========================================================================
function ModMiscToolIncludeUILayer(contextName, xp1File, xp2File)
	local included = contextName;
	if ModMiscToolHasExpansion2() and xp2File ~= nil then
		included = xp2File;
	elseif ModMiscToolHasExpansion1() and xp1File ~= nil then
		included = xp1File;
	end
	include(included);
	print("[ModMiscTool][UILayer] " .. tostring(contextName) .. " <- include("
		.. tostring(included) .. ")  xp1=" .. tostring(ModMiscToolHasExpansion1())
		.. " xp2=" .. tostring(ModMiscToolHasExpansion2()));
	return included;
end

-- ===========================================================================
-- 幽灵玩家判定：外交条与领袖弹窗都问这一句
-- ===========================================================================
function ModMiscToolShouldSuppressDiplomacyPlayer(playerID)
	if playerID == nil then return false; end
	local members = ExposedMembers and ExposedMembers.ModMiscToolUI or nil;
	if members == nil or members.IsDiplomacyGhostPlayerUI == nil then return false; end
	local ok, result = pcall(members.IsDiplomacyGhostPlayerUI, playerID);
	return ok and result == true;
end
