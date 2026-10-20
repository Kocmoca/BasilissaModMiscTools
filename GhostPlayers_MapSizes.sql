-- ===========================================================================
-- Mod Misc Tool: 玩家/城邦数据库上限
--
-- 城邦复制已废弃、城邦幽灵需求下降，因此不再把 MaxCityStates 拉满：
-- 只抬到 36（数据库原有城邦文明数量上限）。MaxPlayers 仍需抬到 62，
-- 否则主流幽灵槽位没有引擎侧空间。
--
-- 绝对赋值（不是 +N），重复加载不会累加；条件里带 < 目标值 让它天然幂等。
-- ===========================================================================

UPDATE MapSizes SET MaxCityStates = 36 WHERE MaxCityStates < 36;
UPDATE MapSizes SET MaxPlayers    = 62 WHERE MaxPlayers    < 62;

-- ===========================================================================
-- 【幽灵需求声明表】框架建表，**声明方插行**（Mod Misc Tool 只负责读表 + 汇总）
--
-- 为什么用表：幽灵数量必须在“创建游戏”界面就确定，而消费者 mod 没有前端执行路径
-- （官方 FrontEndActions 只有 AddMap/UpdateArt/UpdateColors/UpdateDatabase/UpdateIcons/UpdateText，
--  没有任何能跑 Lua 的动作）。所以走数据：声明方在自己的
-- FrontEndActions → UpdateDatabase 里建同名表（IF NOT EXISTS）再插行，
-- 谁先谁后都不会报错。范例见 Vassal System/Vassal_GhostDemand.sql。
--
--   Source          : 声明方标识（同一个 Source 只取一条）
--   MapSizeType     : 'MAPSIZE_XXX' 精确行；'*' 兜底行（尺寸认不出时用）
--   MajorGhosts     : 主流幽灵数（正常附庸行为池）
--   CityStateGhosts : 城邦幽灵数（保守附庸行为池；0 = 该池不产生）
-- 没有行 = 该类幽灵 0（本工具自己不申报任何数量）。
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ModMiscGhostDemand (
    Source          TEXT    NOT NULL,
    MapSizeType     TEXT    NOT NULL,
    MajorGhosts     INTEGER NOT NULL DEFAULT 0,
    CityStateGhosts INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (Source, MapSizeType)
);
