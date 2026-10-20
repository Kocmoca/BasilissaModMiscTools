-- ===========================================================================
-- Mod Misc Tool: 官方城邦面板加固（ReplaceUIScript 补丁，2026-10-15 授权者）
--
-- 起因：授权者报“官方城邦界面按钮点不开”，而城邦面板是**回合拦截项**
--   （ActionPanel: ENDTURN_BLOCKING_GIVE_INFLUENCE_TOKEN）的出口 ⇒ 面板打不开 = 使者派不出去
--   = **无法进入下一回合**。
--
-- 面板的显示机制（逐行核对基座代码）：
--   * `InGame_PHONE.xml` 里城邦上下文是 `<LuaContext ID="CityStates" Hidden="1">`
--     ⇒ **默认隐藏**；
--   * 只有 `OpenOverview()` / `OnOpenSendEnvoys()` 的**最后一行** `m_kScreenSlideAnim.Show()`
--     会 `ContextPtr:SetHide(false)`（`AnimSidePanelSupport.lua:37-40`）；
--   * 也就是说：`Refresh()` 里**任何一行抛错**，`Show()` 就永远跑不到 ⇒ 点按钮没反应，
--     而且每次点击都重演同一个错 ⇒ 面板**永久打不开**。
--
-- 已知会抛错的点（实机日志确认）：`AddCityStateRow` → `GetRelationshipPipAtlasPieces` →
--   `DIPLO_PIP_INFO[kCityState.DiplomaticState].IconName`，某个玩家的外交状态是 -1
--   ⇒ DiplomaticState=nil ⇒ 索引 nil。
--
-- 本补丁四道兜底（只说一件事：**面板不能被一行坏数据搞死**）：
--   ① `GetBonusText`：Details/Title 为 nil 时补空串（基座行构造会无条件拼接它）；
--   ② `AddCityStateRow`：**先把缺字段补齐再渲染**（DiplomaticState 缺 → 中性态；
--      Bonuses[1/3/6/Suzerain] 缺 → 空文本；Quests/Relationships 缺 → 空表），
--      补完仍渲染不出来才跳过该行并打日志 —— 这样“已经发现的城邦”都会出现在列表里；
--   ③ `Refresh`：整体包 pcall —— **这是“点不开”的命门**，保证调用方还能走到 `Show()`；
--   ④ 打开入口：打一行日志（下次排查一眼看得出有没有被调用）+ 上下文不隐藏的最后保险；
--      并把两个事件重新登记到我们的包装版上（原版登记的是函数引用，重定义全局不影响它）。
--
-- 层链：XP2 → XP1 → 基座（XP1 覆盖 AddCityStateRow；GetBonusText 只有基座有）。
-- ⚠️ 缓存名用 MODMISC_BASE_ 前缀：官方 XP1 自己把上一层缓存成 `BASE_AddCityStateRow`
--    并在**调用时**读它，我们再覆盖一次会让它读到自己 → 无限递归。
-- ===========================================================================
include("ModMiscGhostShared");
ModMiscToolIncludeUILayer("CityStates",
	"CityStates_Expansion1.lua", "CityStates_Expansion2.lua");

MODMISC_BASE_GetBonusText = GetBonusText;
MODMISC_BASE_AddCityStateRow = AddCityStateRow;
MODMISC_BASE_Refresh = Refresh;
MODMISC_BASE_OpenOverview = OpenOverview;
MODMISC_BASE_OnOpenSendEnvoys = OnOpenSendEnvoys;
MODMISC_BASE_OnOpenCityStates = OnOpenCityStates;

-- ① 加成文本兜底：Details 为 nil 会让基座的面板行拼接报错
function GetBonusText(playerID , envoyTokenNum )
	local title, details = MODMISC_BASE_GetBonusText(playerID, envoyTokenNum);
	if title == nil then title = ""; end
	if details == nil then details = ""; end
	return title, details;
end

-- ② 行构造兜底：**先把缺的字段补齐再渲染**（能显示就显示，显示不了才跳过）
--    缺字段的成因：某个玩家的外交状态是 -1（原作 `GetData` 里 `diplomaticState = nil`），
--    或加成表里少了 1/3/6/Suzerain 项 —— 原作会在拼接处抛错，整行渲染不出来。
local PANEL_DEFAULT_DIPLO_STATE = "DIPLO_STATE_AWARE";   -- 基座 DIPLO_PIP_INFO 里有的中性项
-- 每轮列表的渲染/跳过计数：日志里直接回答“游戏里有 2 个城邦，面板里怎么只有 1 个”
local m_rowRendered, m_rowSkipped = 0, 0;
local PANEL_BONUS_KEYS = { 1, 3, 6, "Suzerain" };

local function ModMiscToolFillMissingRowFields(kCityState)
	if kCityState == nil then return end;
	if kCityState.DiplomaticState == nil then
		kCityState.DiplomaticState = PANEL_DEFAULT_DIPLO_STATE;
	end
	if kCityState.Bonuses == nil then kCityState.Bonuses = {}; end
	for _, key in ipairs(PANEL_BONUS_KEYS) do
		local bonus = kCityState.Bonuses[key];
		if bonus == nil then
			kCityState.Bonuses[key] = { Title = "", Details = "" };
		else
			if bonus.Title == nil then bonus.Title = ""; end
			if bonus.Details == nil then bonus.Details = ""; end
		end
	end
	if kCityState.Quests == nil then kCityState.Quests = {}; end
	if kCityState.Relationships == nil then kCityState.Relationships = {}; end
end

function AddCityStateRow(kCityState )
	ModMiscToolFillMissingRowFields(kCityState);
	-- ⚠️ 返回值必须**原样透传**：基座 `ViewList` 里是
	--    `local kInst = AddCityStateRow( kCityState );` —— 游戏 Lua 会**运行时检查**这个
	--    `:table` 注解，返回布尔/nil 会直接抛 “Type check failed: (expected 'table', but got 'boolean')”
	--    并中断整个列表循环（实机就是这个：只渲染出 1 行、另一个城邦整行消失）。
	local ok, kInst = pcall(MODMISC_BASE_AddCityStateRow, kCityState);
	if not ok then
		m_rowSkipped = m_rowSkipped + 1;
		print("[ModMiscTool][CityStates] 跳过一行坏数据 player="
			.. tostring(kCityState ~= nil and kCityState.iPlayer or "?")
			.. "：" .. tostring(kInst));
		-- 这一行渲染不出来，但**必须回一个表**，否则类型检查会掐断后面的所有行
		return {};
	end
	m_rowRendered = m_rowRendered + 1;
	return kInst;
end

-- ③ 取数据/刷列表整体兜底：抛错也放行，让调用方走到 `m_kScreenSlideAnim.Show()`
function Refresh()
	m_rowRendered, m_rowSkipped = 0, 0;
	local ok, err = pcall(MODMISC_BASE_Refresh);
	print("[ModMiscTool][CityStates] 本轮列表：渲染 " .. tostring(m_rowRendered)
		.. " 行、跳过 " .. tostring(m_rowSkipped) .. " 行"
		.. (ok and "" or ("（Refresh 出错已兜住：" .. tostring(err) .. "）")));
end

-- 只打一行日志（有没有被调用、进来时上下文是不是隐藏着，一眼可判）+ 上下文不隐藏的保险
local function ModMiscToolNotePanelOpen(where)
	local wasHidden = nil;
	if ContextPtr ~= nil and ContextPtr.IsHidden ~= nil then
		wasHidden = ContextPtr:IsHidden();
		if wasHidden == true then
			ContextPtr:SetHide(false);
		end
	end
	print("[ModMiscTool][CityStates] 打开面板入口=" .. tostring(where)
		.. " 进来时上下文隐藏=" .. tostring(wasHidden));
end

-- ④ 打开入口的包装版（日志 + pcall）；`OnOpenCityStates` 内部调用的是全局 `OpenOverview`，
--    所以它也会走到我们这版。
function OpenOverview(iPlayer )
	ModMiscToolNotePanelOpen("OpenOverview");
	local ok, err = pcall(MODMISC_BASE_OpenOverview, iPlayer);
	if not ok then
		print("[ModMiscTool][CityStates] OpenOverview 出错（已兜住）：" .. tostring(err));
	end
end

function OnOpenSendEnvoys(iPlayer )
	ModMiscToolNotePanelOpen("OnOpenSendEnvoys（派使者/回合拦截）");
	local ok, err = pcall(MODMISC_BASE_OnOpenSendEnvoys, iPlayer);
	if not ok then
		print("[ModMiscTool][CityStates] OnOpenSendEnvoys 出错（已兜住）：" .. tostring(err));
	end
end

-- 原版登记的是**函数引用**，重定义全局不会替换它 ⇒ 这里把两个事件改成我们的包装版
if LuaEvents ~= nil then
	pcall(function()
		LuaEvents.PartialScreenHooks_OpenCityStates.Remove(MODMISC_BASE_OnOpenCityStates);
		LuaEvents.PartialScreenHooks_OpenCityStates.Add(OnOpenCityStates);
	end);
	pcall(function()
		LuaEvents.NotificationPanel_OpenCityStatesSendEnvoys.Remove(MODMISC_BASE_OnOpenSendEnvoys);
		LuaEvents.NotificationPanel_OpenCityStatesSendEnvoys.Add(OnOpenSendEnvoys);
	end);
end
