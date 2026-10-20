-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家外交条压制（ReplaceUIScript 补丁）
--
-- 官方做法（Civ6Data/Expansion1/UI/Replacements/DiplomacyRibbon_Expansion1.lua）：
--   include 上一层脚本 -> 缓存上一层函数 BASE_xxx -> 只覆盖需要改的函数。
-- 本补丁只改一个函数：AddLeader —— 幽灵玩家不进外交条。
--
-- 为什么挂 AddLeader（基座 DiplomacyRibbon.lua 第 100 行）：
--   UpdateLeaders() 先取 PlayerManager.GetAliveMajors()，对“见过的主要文明”
--   逐个调用 AddLeader(iconName, playerID, kProps)；AddLeader 里才创建图标实例
--   并登记进 m_uiLeadersByID / m_uiLeadersByPortrait。在这之前返回，
--   幽灵就既没有图标、也不占 RibbonStats 的计数。
--   基座的调用处（第 195/228 行）**不使用返回值**，所以返回 nil 是安全的
--   （官方 XP1 补丁同样有不返回的分支）。
-- ===========================================================================
include("ModMiscGhostShared");
ModMiscToolIncludeUILayer("DiplomacyRibbon",
	"DiplomacyRibbon_Expansion1.lua", "DiplomacyRibbon_Expansion2.lua");

-- 缓存上一层（资料片链已接好，这里拿到的是“当前生效的那一层”的 AddLeader）。
-- 按官方惯例**不要**声明成 local：后续覆盖要用同名全局互相查找。
-- ⚠️ 缓存名用 MODMISC_BASE_ 前缀，**不要**用官方的 BASE_AddLeader：
--    官方 XP1 补丁正是把上一层缓存成 BASE_AddLeader，而它是在**调用时**读这个全局的；
--    我们再覆盖一次会让它读到自己 -> 无限递归。前缀化后两套缓存互不干扰。
MODMISC_BASE_AddLeader = AddLeader;

function AddLeader(iconName : string, playerID : number, kProps: table)
	if ModMiscToolShouldSuppressDiplomacyPlayer(playerID) then
		return nil;
	end
	return MODMISC_BASE_AddLeader(iconName, playerID, kProps);
end
