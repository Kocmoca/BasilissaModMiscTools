-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家池所需的上限（按地图尺寸分档）
--
-- 只抬「上限」，不改默认数量：
--   * 创建游戏界面的 hook（UI/Replacements/Civ6Common.lua）在开局前把
--     CITY_STATE_COUNT 抬到这里给的上限，并用 WriteCustomData 记下玩家原本的选择；
--   * 进游戏后 ModTool_GhostPlayers.lua 按原本的数量保留城邦，多出来的搬到地图外
--     当幽灵玩家池。
--
-- 【为什么不再一律 62】授权者实机：进入游戏**小概率加载失败**，推测是幽灵机制
-- 让场上玩家过多、出生位置重叠。原来的做法把每个尺寸都抬到 62
-- （MAX_PLAYERS(64) 减去野蛮人/自由城市两个固定槽位），而原版各尺寸的容量是：
--
--     尺寸       原版 MaxPlayers   原版 MaxCityStates   原版总容量
--     MAPSIZE_DUEL        4                6               10
--     MAPSIZE_TINY        6               10               16
--     MAPSIZE_SMALL      10               14               24
--     MAPSIZE_STANDARD   14               18               32
--     MAPSIZE_LARGE      16               22               38
--     MAPSIZE_HUGE       20               24               44
--
-- 引擎在**地图生成阶段**就要给所有这些玩家找出生点，塞不下就会开局失败。
-- 所以改成按尺寸分档：**原版城邦上限 + 8**，总容量仍贴近原版水平，
-- 幽灵池（= 创建的城邦数 − 玩家保留数）照样够用。
--
-- 每档都是绝对赋值（不是 +N），所以这个文件重复加载也不会累加。
-- 要调档只改下面的数字即可；开局日志会打
--   [ModMiscTool][Ghost] poll: CITY_STATE_COUNT=n maxMinor=<本档上限>
-- 可直接核对生效值。
-- ===========================================================================

UPDATE MapSizes SET MaxCityStates = 14 WHERE MapSizeType = 'MAPSIZE_DUEL';      -- 原版 6
UPDATE MapSizes SET MaxCityStates = 18 WHERE MapSizeType = 'MAPSIZE_TINY';      -- 原版 10
UPDATE MapSizes SET MaxCityStates = 22 WHERE MapSizeType = 'MAPSIZE_SMALL';     -- 原版 14
UPDATE MapSizes SET MaxCityStates = 26 WHERE MapSizeType = 'MAPSIZE_STANDARD';  -- 原版 18
UPDATE MapSizes SET MaxCityStates = 30 WHERE MapSizeType = 'MAPSIZE_LARGE';     -- 原版 22
UPDATE MapSizes SET MaxCityStates = 32 WHERE MapSizeType = 'MAPSIZE_HUGE';      -- 原版 24

-- 兜底：自定义地图脚本用的尺寸名不在上面六类里（真遇到新名字给个保守值，别又变成 62）
UPDATE MapSizes SET MaxCityStates = 18
WHERE MapSizeType NOT IN ('MAPSIZE_DUEL', 'MAPSIZE_TINY', 'MAPSIZE_SMALL',
                          'MAPSIZE_STANDARD', 'MAPSIZE_LARGE', 'MAPSIZE_HUGE');


-- 主要文明玩家数：原版 + 2，让创建游戏界面能多加两个主要文明，
-- 但同样不再抬到 62（主要文明幽灵那条路已经放弃，这个上限只是给玩家手动加人用）
UPDATE MapSizes SET MaxPlayers = 6  WHERE MaxPlayers = 4  AND MapSizeType = 'MAPSIZE_DUEL';
UPDATE MapSizes SET MaxPlayers = 8  WHERE MaxPlayers = 6  AND MapSizeType = 'MAPSIZE_TINY';
UPDATE MapSizes SET MaxPlayers = 12 WHERE MaxPlayers = 10 AND MapSizeType = 'MAPSIZE_SMALL';
UPDATE MapSizes SET MaxPlayers = 16 WHERE MaxPlayers = 14 AND MapSizeType = 'MAPSIZE_STANDARD';
UPDATE MapSizes SET MaxPlayers = 18 WHERE MaxPlayers = 16 AND MapSizeType = 'MAPSIZE_LARGE';
UPDATE MapSizes SET MaxPlayers = 22 WHERE MaxPlayers = 20 AND MapSizeType = 'MAPSIZE_HUGE';

-- 非标准地图脚本（Earth / Balance 这类自带 Domain 的）再按它**自己的玩家容量**收一道：
-- 城邦上限不超过 MaxPlayers + 6。这些脚本的图往往比同尺寸的随机图小得多
-- （例：Balanced4 是 4 人图，给它 18 个城邦明显过量），按自己的容量算才安全。
UPDATE MapSizes SET MaxCityStates = MaxPlayers + 6
WHERE Domain <> 'StandardMapSizes' AND MaxCityStates > MaxPlayers + 6;
