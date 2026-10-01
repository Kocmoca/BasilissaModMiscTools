-- ===========================================================================
-- Mod Misc Tool: 复制城邦文明（幽灵玩家池扩容）
--
-- 目的：引擎能创建的城邦玩家数量 = 数据库里的城邦文明条数
--       （实测：请求 62 个只创建了 36 个）。把每个城邦文明复制一份
--       （类型名加 _GHOST1），可用城邦数量翻倍，就能把 CITY_STATE_COUNT
--       拉满到槽位预算，幽灵池随之变大。
--
-- 【可选项】本文件由 modinfo 的 ModMisc_DuplicateCityStates_ON 判据控制，
--   对应创建游戏界面的选项“复制城邦以提供更多自定义玩家槽位”（默认开启）。
--   关掉该选项时，本文件完全不会加载，数据库保持原版状态。
--
-- 复制方式：全部用 INSERT ... SELECT，条件就是“当前数据库里所有城邦文明”。
--   本文件不设 LoadOrder（按用户要求）：复制范围就是“加载到这一刻数据库里已有的城邦”，
--   实测正常对局包含 Base 24 + 资料片 11 + DLC 6 = 41 个（场景专属的不在正常对局里）。
--   只复制文明/领袖/特质/城市名这些 gameplay 表的行，不碰配色、不碰图标
--   （那两个是独立数据库，见 GhostPlayers_CityStateIcons.xml）。
--
-- 涉及的表（按外键顺序）：
--   Types → Civilizations → TypeProperties → Leaders → CivilizationLeaders
--         → LeaderTraits → CityNames
--
-- 【不要复制 PlayerColors】授权者实测结论：
--   1) 配色属于**另一个数据库**（ColorManager），和 gameplay 库不互通，
--      本文件里根本访问不到 PlayerColors 表；
--   2) 就算复制进去，相同 RGBA 值同时出场时会让其中一方回退到默认颜色，
--      反而更糟。复制体沿用引擎的默认配色即可。
--   同理，图标（Icons/IconDefinitions）也是独立数据库，这里不碰。
--
-- 复制体与原城邦同质：同样的名字/描述/词缀、同样的城邦类别（CityStateCategory）、
-- 同样的领袖继承关系与城邦加成特质、同样的城市名与配色。
-- 复制体的 Type 排在原城邦之后，幽灵池“从候选末尾往前搬”的逻辑会优先搬复制体。
-- ===========================================================================

-- 1) 类型注册：文明
INSERT INTO Types (Type, Kind)
SELECT c.CivilizationType || '_GHOST1', 'KIND_CIVILIZATION'
FROM Civilizations c
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 1b) 类型注册：领袖
INSERT INTO Types (Type, Kind)
SELECT l.LeaderType || '_GHOST1', 'KIND_LEADER'
FROM Leaders l
JOIN CivilizationLeaders cl ON cl.LeaderType = l.LeaderType
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 2) 文明本体
INSERT INTO Civilizations (CivilizationType, Name, Description, Adjective,
                           RandomCityNameDepth, StartingCivilizationLevelType, Ethnicity)
SELECT c.CivilizationType || '_GHOST1', c.Name, c.Description, c.Adjective,
       c.RandomCityNameDepth, c.StartingCivilizationLevelType, c.Ethnicity
FROM Civilizations c
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 3) 城邦类别（TypeProperties: CityStateCategory = SCIENTIFIC / TRADE / ...）
INSERT INTO TypeProperties (Type, Name, Value, PropertyType)
SELECT tp.Type || '_GHOST1', tp.Name, tp.Value, tp.PropertyType
FROM TypeProperties tp
JOIN Civilizations c ON c.CivilizationType = tp.Type
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 4) 领袖本体（沿用原城邦领袖的继承关系，复制出同名领袖）
INSERT INTO Leaders (LeaderType, Name, OperationList, IsBarbarianLeader,
                     InheritFrom, SceneLayers, Sex, SameSexPercentage)
SELECT l.LeaderType || '_GHOST1', l.Name, l.OperationList, l.IsBarbarianLeader,
       l.InheritFrom, l.SceneLayers, l.Sex, l.SameSexPercentage
FROM Leaders l
JOIN CivilizationLeaders cl ON cl.LeaderType = l.LeaderType
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 5) 文明 ↔ 领袖（首都名沿用原城邦的）
INSERT INTO CivilizationLeaders (LeaderType, CivilizationType, CapitalName)
SELECT cl.LeaderType || '_GHOST1', cl.CivilizationType || '_GHOST1', cl.CapitalName
FROM CivilizationLeaders cl
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 6) 领袖特质（城邦加成特质，与原城邦共用同一条 TraitType）
INSERT INTO LeaderTraits (LeaderType, TraitType)
SELECT lt.LeaderType || '_GHOST1', lt.TraitType
FROM LeaderTraits lt
JOIN CivilizationLeaders cl ON cl.LeaderType = lt.LeaderType
JOIN Civilizations c ON c.CivilizationType = cl.CivilizationType
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';

-- 7) 城市名（城邦一般只有首都一个名字）
INSERT INTO CityNames (CivilizationType, LeaderType, ContinentType, CityName, SortIndex)
SELECT cn.CivilizationType || '_GHOST1', NULL, cn.ContinentType, cn.CityName, cn.SortIndex
FROM CityNames cn
JOIN Civilizations c ON c.CivilizationType = cn.CivilizationType
WHERE c.StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE'
  AND c.CivilizationType NOT LIKE '%\_GHOST1' ESCAPE '\';
