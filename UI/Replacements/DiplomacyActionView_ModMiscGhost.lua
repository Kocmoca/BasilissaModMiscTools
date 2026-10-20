-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家外交弹窗压制（ReplaceUIScript 补丁）
--
-- 【2026-10-15 授权者】压制点是**弹窗入口**，不是弹窗里的文本：
-- 旧做法在 DiplomacySupport_ExtractStatement 里对幽灵返回空表 —— 那只压掉了弹窗里的
-- 文本与选项，弹窗本身照旧被打开 => 空弹窗卡住。
--
-- 调用链（Base/Assets/UI/DiplomacyActionView.lua；手机版 _PHONE.lua 同构）：
--     Events.DiplomacyStatement
--       -> OnDiplomacyStatement(fromPlayer, toPlayer, kVariants)   … 会话入口
--           -> handler = GetStatementHandler(statementTypeName)
--           -> handler.TestValid(sessionID, otherPlayerID)         … 会话有效性闸门
--               返回 false => 基座自己 CloseSession + return       … 连视图都不初始化
--           -> InitializeView() / SelectPlayer(...)                … 领袖弹窗在这里出现
--
-- 本补丁三层都挂（互为兜底）：
--   ① OnDiplomacyStatement：本文件在**上下文加载阶段**就覆盖它，
--      而基座是在 LateInitialize() 里按名字注册事件的 => 注册到的就是我们的版本；
--   ② 每个语句处理器的 TestValid：处理器表在 include 阶段已建好，这里直接套一层；
--   ③ SelectPlayer：视图内领袖条会把“见过的主要文明”都列出来（幽灵可能在里面），
--      点它会走 SelectPlayer，这里也挡一道（已核对：基座没有把它当回调传出）。
-- ===========================================================================
include("ModMiscGhostShared");
ModMiscToolIncludeUILayer("DiplomacyActionView",
	"DiplomacyActionView_Expansion1.lua", "DiplomacyActionView_Expansion2.lua");

local function ModMiscToolLogSuppress(fromPlayer, toPlayer, sessionID, viaWhom)
	print("[ModMiscTool][Ghost] 挡下幽灵玩家外交会话（" .. tostring(viaWhom) .. "）：from="
		.. tostring(fromPlayer) .. " to=" .. tostring(toPlayer)
		.. " session=" .. tostring(sessionID));
end

-- ---------------------------------------------------------------------------
-- ① 会话入口：幽灵参与的会话直接关掉，领袖窗根本不出现
--    基座在 LateInitialize() 里 Add(OnDiplomacyStatement)，按名字取全局 => 用我们的
-- ---------------------------------------------------------------------------
-- ⚠️ 缓存名统一 MODMISC_BASE_ 前缀：官方补丁用 BASE_<函数名> 缓存上一层，
--    而且是在调用时读全局；同名会被我们顶掉并可能自递归，所以全部前缀化。
MODMISC_BASE_OnDiplomacyStatement = OnDiplomacyStatement;

function OnDiplomacyStatement(fromPlayer : number, toPlayer : number, kVariants : table)
	if kVariants ~= nil and (ModMiscToolShouldSuppressDiplomacyPlayer(fromPlayer)
		or ModMiscToolShouldSuppressDiplomacyPlayer(toPlayer)) then
		local sessionID = kVariants.SessionID;
		if sessionID ~= nil then
			pcall(function() DiplomacyManager.CloseSession(sessionID) end);
		end
		ModMiscToolLogSuppress(fromPlayer, toPlayer, sessionID, "事件入口");
		return;
	end
	MODMISC_BASE_OnDiplomacyStatement(fromPlayer, toPlayer, kVariants);
end

-- ---------------------------------------------------------------------------
-- ② 会话有效性：幽灵 => TestValid = false（基座走它自己的“会话无效”路径）
--    GetStatementHandler 对没登记的语句类型回落 DefaultHandlers，所以它也套一层
-- ---------------------------------------------------------------------------
local function ModMiscToolWrapStatementHandler(handler)
	if type(handler) ~= "table" or handler.ModMiscToolGhostGuard == true then return; end
	local originalTestValid = handler.TestValid;
	handler.TestValid = function(sessionID, otherPlayerID)
		if ModMiscToolShouldSuppressDiplomacyPlayer(otherPlayerID) then
			ModMiscToolLogSuppress(nil, otherPlayerID, sessionID, "TestValid");
			return false;
		end
		if originalTestValid ~= nil then
			return originalTestValid(sessionID, otherPlayerID);
		end
		return true;
	end
	handler.ModMiscToolGhostGuard = true;
end

if type(StatementHandlers) == "table" then
	for _, handler in pairs(StatementHandlers) do
		ModMiscToolWrapStatementHandler(handler);
	end
end
ModMiscToolWrapStatementHandler(DefaultHandlers);

-- ---------------------------------------------------------------------------
-- ③ 界面入口：**别为幽灵把这个界面开起来**
--
-- 为什么必须挡在入口：这个界面一旦显示，引擎会走
--     LuaEvents.DiplomacyActionView_HideIngameUI -> InGame.lua: BulkHide(true, "Diplomacy")
--                                                              + Input.PushActiveContext(...)
-- 关闭时才配对 `BulkHide(false)` + `PopContext`。半开（开了但选不中/建不起来）就会
-- 只 hide 不 show ⇒ HUD 五组（WorldViewControls/HUD/PartialScreens/Screens/TopLevelHUD）
-- 永久隐藏，也就是授权者看到的“UI 全部消失”。
-- 所以幽灵在**入口**就返回，连 InitializeView 都不进。
-- ---------------------------------------------------------------------------
MODMISC_BASE_OnOpenDiplomacyActionView = OnOpenDiplomacyActionView;

function OnOpenDiplomacyActionView(otherPlayerID)
	if ModMiscToolShouldSuppressDiplomacyPlayer(otherPlayerID) then
		ModMiscToolLogSuppress(nil, otherPlayerID, nil, "OnOpenDiplomacyActionView");
		-- 顺手兜底：万一上一轮已经出现过“只 hide 没 show”的半开状态（HUD 五组被隐藏），
		-- 这里把它恢复回来。RestoreInGameUI 只强制取消隐藏那五组，不动引擎的计数与输入栈，
		-- 界面上本来就没隐藏时是个空操作。注意判一下本界面自己没开着，别和别的全屏界面打架。
		if ContextPtr:IsHidden() then
			local uiMembers = ExposedMembers and ExposedMembers.ModMiscToolUI or nil;
			if uiMembers ~= nil and uiMembers.RestoreInGameUI ~= nil then
				pcall(uiMembers.RestoreInGameUI);
			end
		end
		return;
	end
	return MODMISC_BASE_OnOpenDiplomacyActionView(otherPlayerID);
end

-- ---------------------------------------------------------------------------
-- ④ 选中入口：视图内领袖条里点到幽灵 => 什么都不做（不弹领袖、不切屏）
--    ③ 已经挡住正常入口；这一层只防“界面已经开着时又有人塞幽灵进来”。
-- ---------------------------------------------------------------------------
MODMISC_BASE_SelectPlayer = SelectPlayer;

function SelectPlayer(playerID, viewMode, refresh, allowDeadPlayer)
	if ModMiscToolShouldSuppressDiplomacyPlayer(playerID) then
		ModMiscToolLogSuppress(nil, playerID, nil, "SelectPlayer");
		return;
	end
	return MODMISC_BASE_SelectPlayer(playerID, viewMode, refresh, allowDeadPlayer);
end

print("[ModMiscTool][Ghost] 外交弹窗闸门已装载（DiplomacyActionView 补丁：事件入口 + TestValid + SelectPlayer）");
