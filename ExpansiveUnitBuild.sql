-- =============================================================================
-- Basilissa Mod Misc Tools - 扩展单位建造系统数据库架构
-- Extended Unit Build System Database Schema
-- 参照 ExtensiveWMD/WMD_Weapon.sql 的规范（单引号列名、CHECK、索引、外键动作）
-- =============================================================================

-- =============================================================================
-- 建筑案例表 / Build Cases Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_Cases
(
    'CaseType'          TEXT NOT NULL,
    'Name'				TEXT,
    'Description'       TEXT,
    'Icon'				TEXT,
    'ItemType'          TEXT NOT NULL,
    'ItemCatagory'      TEXT NOT NULL
                        CHECK(ItemCatagory IN ('District', 'Building', 'Improvement', 'Route', 'Feature', 'Resource', 'Terrain')),
    'RequirementModel'  TEXT,
    'CostModel'         TEXT,
    'BuildRange'        INTEGER DEFAULT 0
                        CHECK(BuildRange >= 0),
    PRIMARY KEY(CaseType),
    FOREIGN KEY ('RequirementModel') REFERENCES 'Kocmoca_Build_RequirementModels'('RequirementModel')
        ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY ('CostModel') REFERENCES 'Kocmoca_Build_CostModels'('CostModel')
        ON DELETE SET NULL ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_build_cases_cost
    ON Kocmoca_Build_Cases(CostModel);

-- =============================================================================
-- 要求模型表 / Requirement Models Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_RequirementModels
(
    'RequirementModel'  TEXT NOT NULL,
    'TerrainList'       TEXT,
    'FeatureList'       TEXT,
    'ResourceList'      TEXT,
    'PlotOwnerList'     TEXT,
    'UnitType'          TEXT,
    'AbilityType'       TEXT,
    'TechType'			TEXT,
    'CivicType'			TEXT,
    'TraitType'         TEXT,
    PRIMARY KEY(RequirementModel)
);

-- =============================================================================
-- 要求地形列表表 / Required Terrain List Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_RequireTerrainList
(
    'ID'            INTEGER PRIMARY KEY AUTOINCREMENT,
    'TerrainList'   TEXT NOT NULL,
    'TerrainType'   TEXT NOT NULL,
    UNIQUE(TerrainList, TerrainType)
);

CREATE INDEX IF NOT EXISTS idx_require_terrain_type
    ON Kocmoca_Build_RequireTerrainList(TerrainType);

-- =============================================================================
-- 要求地貌列表表 / Required Feature List Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_RequireFeatureList
(
    'ID'            INTEGER PRIMARY KEY AUTOINCREMENT,
    'FeatureList'   TEXT NOT NULL,
    'FeatureType'   TEXT NOT NULL,
    UNIQUE(FeatureList, FeatureType)
);

CREATE INDEX IF NOT EXISTS idx_require_feature_type
    ON Kocmoca_Build_RequireFeatureList(FeatureType);

-- =============================================================================
-- 要求资源列表表 / Required Resource List Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_RequireResourceList
(
    'ID'            INTEGER PRIMARY KEY AUTOINCREMENT,
    'ResourceList'  TEXT NOT NULL,
    'ResourceType'  TEXT NOT NULL,
    UNIQUE(ResourceList, ResourceType)
);

CREATE INDEX IF NOT EXISTS idx_require_resource_type
    ON Kocmoca_Build_RequireResourceList(ResourceType);

-- =============================================================================
-- 要求地块归属列表表 / Required Plot Owner List Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_RequirePlotOwnerList
(
    'ID'            		INTEGER PRIMARY KEY AUTOINCREMENT,
    'PlotOwnerList' 		TEXT NOT NULL,
    'PlotOwnerType' 		TEXT NOT NULL,						--should be in {'Self', 'Neutral', 'Allied', 'Hostile'}
    'RequiredAllianceType'	TEXT,								--require specific alliance type if PlotOwnerType was set Allied
    UNIQUE(PlotOwnerList, PlotOwnerType, RequiredAllianceType)
);

-- =============================================================================
-- 花费模型表 / Cost Models Table
-- =============================================================================
CREATE TABLE IF NOT EXISTS Kocmoca_Build_CostModels
(
    'CostModel'             TEXT NOT NULL,
    'BuildCharge'           INTEGER,
    'GoldAmount'            INTEGER,
    'FaithAmount'           INTEGER,
    'UnitMovement'          INTEGER DEFAULT 16
                            CHECK(UnitMovement IS NULL OR UnitMovement >= 0),
    'ResourceType'          TEXT,
    'ResourceAmount'        INTEGER,
    'PlayerPropertyType'    TEXT,
    'PlayerPropertyNum'     INTEGER,
    'UnitPropertyType'      TEXT,
    'UnitPropertyNum'       INTEGER,
    'PlotPropertyType'      TEXT,
    'PlotPropertyNum'       INTEGER,
    PRIMARY KEY(CostModel)
);

-- =============================================================================
-- 样例数据 / Sample Data（演示面板功能 / demonstrate panel functionality）
-- =============================================================================

-- 花费模型 / Cost Models
INSERT OR REPLACE INTO Kocmoca_Build_CostModels
(CostModel, BuildCharge, GoldAmount, FaithAmount, ResourceType, ResourceAmount)
VALUES
('COST_FREE',         0,   0,   0,   NULL, 0),
('COST_GOLD_50',      0,  50,   0,   NULL, 0),
('COST_GOLD_200',     0, 200,   0,   NULL, 0),
('COST_CHARGE_1',     1,   0,   0,   NULL, 0),
('COST_CHARGE_3',     3,   0,   0,   NULL, 0),
('COST_FAITH_100',    0,   0, 100,   NULL, 0),
('COST_GOLD_100_FAITH_50', 0, 100, 50, NULL, 0);

-- 仅消耗移动力：用于原版中不花费金币的修复类操作（UnitMovement = NULL 表示消耗全部剩余移动力）
INSERT OR REPLACE INTO Kocmoca_Build_CostModels
(CostModel, BuildCharge, GoldAmount, FaithAmount, ResourceType, ResourceAmount, UnitMovement)
VALUES
('COST_MOVEMENT_ONLY', 0, 0, 0, NULL, 0, NULL);
/*
-- 建造方案 / Build Cases
INSERT OR REPLACE INTO Kocmoca_Build_Cases
(CaseType, Description, ItemType, ItemCatagory, CostModel, BuildRange)
VALUES
('BUILD_ROAD',         'LOC_CASE_ROAD_DESC',         'ROUTE_ANCIENT_ROAD',     'Route',       'COST_CHARGE_1', 1);

-- 测试用：现有区域 + 前置该区域的现有建筑
INSERT OR REPLACE INTO Kocmoca_Build_Cases
(CaseType, Name, Description, Icon, ItemType, ItemCatagory, CostModel, BuildRange)
VALUES
('TEST_BUILD_DISTRICT', 'LOC_DISTRICT_CAMPUS_NAME', 'LOC_DISTRICT_CAMPUS_DESCRIPTION', 'ICON_DISTRICT_CAMPUS',
 'DISTRICT_CAMPUS', 'District', 'COST_FREE', 0),
('TEST_BUILD_BUILDING', 'LOC_BUILDING_LIBRARY_NAME', 'LOC_BUILDING_LIBRARY_NAME', 'ICON_BUILDING_LIBRARY',
 'BUILDING_LIBRARY', 'Building', 'COST_FREE', 0);
 */
