-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家池所需的城邦槽位上限
--
-- 只抬高“上限”，不改玩家/地图默认的城邦数量：
--   * 创建游戏界面的 hook（UI/Replacements/Civ6Common.lua）会在开局前把
--     CITY_STATE_COUNT 拉满到这里给的上限，并用 WriteCustomData 记下玩家原本的选择；
--   * 进游戏后 ModTool_GhostPlayers.lua 按原本的数量保留城邦，多出来的搬到地图外
--     当幽灵玩家池。
-- 62 = MAX_PLAYERS(64) 减去野蛮人与自由城市两个固定槽位后的上限；
-- 实际能创建多少仍受地图落点限制（引擎自己会取小值）。
-- ===========================================================================

UPDATE MapSizes SET MaxCityStates = 62 WHERE MaxCityStates < 62;

-- 主要文明玩家数上限同样只抬上限：设置界面里可以加更多主要文明玩家，
-- 由引擎在开局时正常创建（运行时用 PlayerConfigurations 补建玩家那条路走不通）。
UPDATE MapSizes SET MaxPlayers = 62 WHERE MaxPlayers < 62;
