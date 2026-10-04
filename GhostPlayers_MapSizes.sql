-- ===========================================================================
-- Mod Misc Tool: 城邦上限（按地图尺寸分档，大幅抬高）
--
-- 为什么必须有这个文件：`MapSizes.MaxCityStates` 是引擎创建城邦玩家的**天花板**。
-- 只靠 Lua 把 CITY_STATE_COUNT 设成 62 是没用的 —— 实测引擎仍按原版值（HUGE=24）创建，
-- 幽灵池顶不上去。所以上限只能在这里抬。
--
-- 与 Lua 的分工（重要）：
--   * 本文件 = **天花板**（同时决定创建游戏界面能选多少）；
--   * UI/Replacements/Civ6Common.lua 的 GHOST_CITY_STATE_CAP_BY_MAP_SIZE = 运行时**安全阀**，
--     留空就用这里的天花板；想在不重打数据库的前提下单独收某个尺寸，才在那里写一个更小的数。
--
-- 数值口径（授权者 2026-10-04）：大地图/巨大地图吃满最高档 62；
-- 其余尺寸也**大幅提升**（原版是 6/10/14/18/22/24）。
-- 62 = MAX_PLAYERS(64) − 野蛮人 − 自由城市两个固定槽位。
--
-- 绝对赋值（不是 +N），所以重复加载不会累加。
-- 校验：本地用 sqlite3 建临时表跑过，连跑三遍结果一致。
-- 要调档只改下面的数字；开局日志会打
--   [ModMiscTool][Ghost] city states -> N (… vanillaMax=… )
-- 注意：vanillaMax 会被本文件改掉，所以那行显示的是**改后**的天花板。
-- ===========================================================================

-- 城邦上限：按尺寸分档
UPDATE MapSizes SET MaxCityStates = 16 WHERE MapSizeType = 'MAPSIZE_DUEL';      -- 原版 6
UPDATE MapSizes SET MaxCityStates = 28 WHERE MapSizeType = 'MAPSIZE_TINY';      -- 原版 10
UPDATE MapSizes SET MaxCityStates = 40 WHERE MapSizeType = 'MAPSIZE_SMALL';     -- 原版 14
UPDATE MapSizes SET MaxCityStates = 52 WHERE MapSizeType = 'MAPSIZE_STANDARD';  -- 原版 18
UPDATE MapSizes SET MaxCityStates = 62 WHERE MapSizeType = 'MAPSIZE_LARGE';     -- 原版 22，顶格
UPDATE MapSizes SET MaxCityStates = 62 WHERE MapSizeType = 'MAPSIZE_HUGE';      -- 原版 24，顶格

-- 兜底：尺寸名不在上面六类里的（自定义地图脚本）给个中等值，别停在小数值上
UPDATE MapSizes SET MaxCityStates = 28
WHERE MapSizeType NOT IN ('MAPSIZE_DUEL', 'MAPSIZE_TINY', 'MAPSIZE_SMALL',
                          'MAPSIZE_STANDARD', 'MAPSIZE_LARGE', 'MAPSIZE_HUGE');

-- 主要文明上限：同样按尺寸抬，但幅度小一些（幽灵池靠城邦，主要文明只是让玩家能多加人）
UPDATE MapSizes SET MaxPlayers = 8  WHERE MapSizeType = 'MAPSIZE_DUEL'     AND MaxPlayers < 8;
UPDATE MapSizes SET MaxPlayers = 12 WHERE MapSizeType = 'MAPSIZE_TINY'     AND MaxPlayers < 12;
UPDATE MapSizes SET MaxPlayers = 16 WHERE MapSizeType = 'MAPSIZE_SMALL'    AND MaxPlayers < 16;
UPDATE MapSizes SET MaxPlayers = 24 WHERE MapSizeType = 'MAPSIZE_STANDARD' AND MaxPlayers < 24;
UPDATE MapSizes SET MaxPlayers = 32 WHERE MapSizeType = 'MAPSIZE_LARGE'    AND MaxPlayers < 32;
UPDATE MapSizes SET MaxPlayers = 40 WHERE MapSizeType = 'MAPSIZE_HUGE'     AND MaxPlayers < 40;

-- 非标准地图脚本（Earth / Balance 这类自带 Domain 的）按**它自己的**玩家容量收一道：
-- 城邦上限不超过 MaxPlayers + 12。这些图往往比同尺寸随机图小得多（例：Balanced4 是 4 人图）。
-- 【必须放在 MaxPlayers 更新之后】，否则第二遍加载时按新的 MaxPlayers 再收一次 → 不幂等。
UPDATE MapSizes SET MaxCityStates = MaxPlayers + 12
WHERE Domain <> 'StandardMapSizes' AND MaxCityStates > MaxPlayers + 12;
