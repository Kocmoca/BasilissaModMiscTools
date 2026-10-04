-- ===========================================================================
-- Mod Misc Tool: 把城邦/玩家的数据库上限**直接拉满**
--
-- 【职责划分】本文件只做一件事：把 `MapSizes` 的天花板抬到引擎硬上限 62。
-- **具体每个地图尺寸给多少，一律交给 Lua 配置表**
-- （UI/Replacements/Civ6Common.lua 的 GHOST_CITY_STATE_BY_MAP_SIZE）。
-- 这样调策略只改 Lua 一处，不用重打数据库、也不用管 SQL 能不能对上尺寸列。
--
-- 为什么必须抬：`MapSizes.MaxCityStates` 是引擎创建城邦玩家的天花板。
-- 实测只靠 Lua 设 CITY_STATE_COUNT 顶不上去 —— 引擎仍按原版值（HUGE=24）创建，
-- 幽灵池上不去。
--
-- 为什么用“旧版同形”的写法：按 MapSizeType 分档的写法**实测没生效**
-- （三个尺寸全是原版值，而数据库报错不进 Lua.log，排查很费劲）。
-- 这条不依赖任何列值，旧版就是它、实测有效。
--
-- 62 = MAX_PLAYERS(64) − 野蛮人 − 自由城市两个固定槽位。
-- 绝对赋值（不是 +N），重复加载不会累加；条件里带 < 62 让它天然幂等。
-- ===========================================================================

UPDATE MapSizes SET MaxCityStates = 62 WHERE MaxCityStates < 62;
UPDATE MapSizes SET MaxPlayers    = 62 WHERE MaxPlayers    < 62;
