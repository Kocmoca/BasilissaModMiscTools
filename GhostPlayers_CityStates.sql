-- ⚠️【未验证、已停用】本文件没有登记在 modinfo 里，从未在设备上跑过（仅做过 SQLite 静态校验）。
--
--    当初的两条备选路线现状：
--      * 运行时“补建幽灵槽位”（CreateGhostPlayerFromEmptySlot）—— 【已验证失败】，
--        引擎不会为运行时改过配置的槽位生成玩家对象（Players[slot] 恒为 nil）；
--      * 本文件（复制数据库城邦文明）—— 未验证，但它对应的是“引擎城邦数量上限 = 城邦文明条数”
--        这个已验证的硬限制，是唯一能突破 36 个城邦的手段。
--
--    当前采用“抬上限”路线（已验证可用，玩家选 4 + 6 → 幽灵池 52，主要文明 26 + 城邦 36）。
--    将来若确实需要更多城邦，把本文件登记到 InGameActions → UpdateDatabase 再实测即可。
-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家池 —— 复制城邦文明（让城邦数量能“拉满”）
--
-- 引擎能创建的城邦玩家数量受“数据库里有多少个不同的城邦文明”限制
-- （实测：请求 62 个只创建了 36 个，正好等于当前启用的城邦文明数量）。
-- 这里把每个城邦文明再复制两份（类型名加 _GHOST1 / _GHOST2），把可用城邦数量
-- 扩到约三倍，够填满 MAX_PLAYERS 级别的幽灵池。
--
-- 复制体与原城邦完全同质：同样的文明名/描述/词缀、同样的城邦类别
-- （TypeProperties: CityStateCategory）、同样的领袖复制体与其特质、同样的城市名。
-- 因为复制体的 Type 名带 _GHOST 后缀、ID 也排在原始城邦之后，幽灵池“从候选末尾
-- 往前搬”的逻辑会优先把复制体搬到地图外，原始城邦仍然留在地图上。
--
-- 涉及的表（按外键顺序）：Types → Civilizations → TypeProperties → Leaders
--                          → CivilizationLeaders → LeaderTraits → CityNames
-- ===========================================================================

-- 1) 类型注册：文明 + 领袖（两份复制一起做）
INSERT INTO Types (Type, Kind)
SELECT c.CivilizationType || s.Suffix, 'KIND_CIVILIZATION'
FROM Civilizations c
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

INSERT INTO Types (Type, Kind)
SELECT l.LeaderType || s.Suffix, 'KIND_LEADER'
FROM Leaders l
JOIN CivilizationLeaders cl ON cl.LeaderType = l.LeaderType
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

-- 2) 文明本体
INSERT INTO Civilizations (CivilizationType, Name, Description, Adjective,
                           RandomCityNameDepth, StartingCivilizationLevelType, Ethnicity)
SELECT c.CivilizationType || s.Suffix, c.Name, c.Description, c.Adjective,
       c.RandomCityNameDepth, c.StartingCivilizationLevelType, c.Ethnicity
FROM Civilizations c
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

-- 3) 城邦类别（CityStateCategory = SCIENTIFIC / TRADE / ...）
INSERT INTO TypeProperties (Type, Name, Value, PropertyType)
SELECT tp.Type || s.Suffix, tp.Name, tp.Value, tp.PropertyType
FROM TypeProperties tp
JOIN Civilizations c ON c.CivilizationType = tp.Type
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

-- 4) 领袖本体（沿用原城邦领袖的继承关系，复制出同名领袖）
INSERT INTO Leaders (LeaderType, Name, OperationList, IsBarbarianLeader,
                     InheritFrom, SceneLayers, Sex, SameSexPercentage)
SELECT l.LeaderType || s.Suffix, l.Name, l.OperationList, l.IsBarbarianLeader,
       l.InheritFrom, l.SceneLayers, l.Sex, l.SameSexPercentage
FROM Leaders l
JOIN CivilizationLeaders cl ON cl.LeaderType = l.LeaderType
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

-- 5) 文明 ↔ 领袖（首都名沿用原城邦的）
INSERT INTO CivilizationLeaders (LeaderType, CivilizationType, CapitalName)
SELECT cl.LeaderType || s.Suffix, cl.CivilizationType || s.Suffix, cl.CapitalName
FROM CivilizationLeaders cl
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

-- 6) 领袖特质（城邦加成特质，与原城邦共用）
INSERT INTO LeaderTraits (LeaderType, TraitType)
SELECT lt.LeaderType || s.Suffix, lt.TraitType
FROM LeaderTraits lt
JOIN CivilizationLeaders cl ON cl.LeaderType = lt.LeaderType
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';

-- 7) 城市名（城邦一般只有首都一个名字，一并复制）
INSERT INTO CityNames (CivilizationType, LeaderType, ContinentType, CityName, SortIndex)
SELECT cn.CivilizationType || s.Suffix, NULL, cn.ContinentType, cn.CityName, cn.SortIndex
FROM CityNames cn
JOIN Civilizations c ON c.CivilizationType = cn.CivilizationType
CROSS JOIN (SELECT '_GHOST1' AS Suffix UNION ALL SELECT '_GHOST2') s
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%_GHOST1'
  AND c.CivilizationType NOT LIKE '%_GHOST2';
