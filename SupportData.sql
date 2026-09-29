INSERT OR REPLACE INTO Types 
(Type, Kind) VALUES	
('DISTRICT_KOCMOCA_DUMMY_FOR_REMOVAL', 'KIND_DISTRICT');

INSERT OR REPLACE INTO Districts 
(DistrictType,	Name,    Description,	PlunderType,	PlunderAmount,	AdvisorType,	Cost,	HitPoints,	CanAttack,	CostProgressionModel,	CostProgressionParam1,	Maintenance,	RequiresPlacement,	RequiresPopulation,	AllowsHolyCity,	ZOC,	CaptureRemovesBuildings,	CaptureRemovesCityDefenses,	Appeal,	CityStrengthModifier,	TraitType,	CaptureRemovesDistrict,	MaxPerPlayer,	CitizenSlots,	AirSlots,	PrereqTech,	NoAdjacentCity,	Aqueduct,	InternalOnly, MilitaryDomain,    OnePerCity) SELECT	
'DISTRICT_KOCMOCA_DUMMY_FOR_REMOVAL',	Name,	Description,	PlunderType,	PlunderAmount,	AdvisorType,	Cost,	HitPoints,	CanAttack,	CostProgressionModel,	CostProgressionParam1,	Maintenance,	RequiresPlacement,	RequiresPopulation,	AllowsHolyCity,	ZOC,	CaptureRemovesBuildings,	CaptureRemovesCityDefenses,	Appeal,	CityStrengthModifier,	TraitType,	CaptureRemovesDistrict,	MaxPerPlayer,	CitizenSlots,	AirSlots,	PrereqTech,	NoAdjacentCity,	Aqueduct,	InternalOnly,    MilitaryDomain,    OnePerCity
FROM Districts WHERE DistrictType = 'DISTRICT_WONDER';

--change build charge

INSERT OR REPLACE INTO Types
(Type, Kind) VALUES
('MODIFIER_MODTOOL_CHANGE_UNIT_BUILD_CHARGE', 'KIND_MODIFIER');

INSERT OR REPLACE INTO DynamicModifiers
(ModifierType, CollectionType, EffectType) VALUES
('MODIFIER_MODTOOL_CHANGE_UNIT_BUILD_CHARGE', 'COLLECTION_OWNER', 'EFFECT_ADJUST_UNIT_BUILD_CHARGES');

INSERT INTO Modifiers	
(ModifierId,	ModifierType, RunOnce, Permanent, NewOnly, OwnerRequirementSetId, SubjectRequirementSetId) VALUES	
('MODTOOL_INCREASE_UNIT_BUILD_CHARGE',	'MODIFIER_MODTOOL_CHANGE_UNIT_BUILD_CHARGE', 1, 1, 0, NULL, NULL),
('MODTOOL_DECREASE_UNIT_BUILD_CHARGE',	'MODIFIER_MODTOOL_CHANGE_UNIT_BUILD_CHARGE', 1, 1, 0, NULL, NULL);

INSERT INTO ModifierArguments
(ModifierId,	Name,	Value) VALUES	
('MODTOOL_INCREASE_UNIT_BUILD_CHARGE',	'Amount',	'1'),
('MODTOOL_DECREASE_UNIT_BUILD_CHARGE',	'Amount',	'-1');

--ability

INSERT OR REPLACE INTO Tags
(Tag,	Vocabulary)	VALUES
('CLASS_MODTOOL_ALL_UNITS',	'ABILITY_CLASS');

INSERT INTO TypeTags
(Type,	Tag)
SELECT UnitType, 'CLASS_MODTOOL_ALL_UNITS'
FROM Units;

INSERT OR REPLACE INTO Types
(Type,	Kind)	VALUES
('ABILITY_DECREASE_BUILD_CHARGE',	'KIND_ABILITY'),
('ABILITY_INCREASE_BUILD_CHARGE',	'KIND_ABILITY');

INSERT INTO TypeTags
(Type,	Tag)	VALUES
('ABILITY_DECREASE_BUILD_CHARGE',	'CLASS_MODTOOL_ALL_UNITS'),
('ABILITY_INCREASE_BUILD_CHARGE',	'CLASS_MODTOOL_ALL_UNITS');

INSERT INTO UnitAbilities
(UnitAbilityType,	Name,	Description,	Inactive,	ShowFloatTextWhenEarned	)	VALUES
('ABILITY_DECREASE_BUILD_CHARGE',	'LOC_ABILITY_DECREASE_BUILD_CHARGE_NAME',	'LOC_ABILITY_DECREASE_BUILD_CHARGE_DESCRIPTION',	'1',	'0'),
('ABILITY_INCREASE_BUILD_CHARGE',	'LOC_ABILITY_INCREASE_BUILD_CHARGE_NAME',	'LOC_ABILITY_INCREASE_BUILD_CHARGE_DESCRIPTION',	'1',	'0');

INSERT INTO UnitAbilityModifiers			
(UnitAbilityType,	ModifierId	)	VALUES
('ABILITY_INCREASE_BUILD_CHARGE', 'MODTOOL_ATTACH_INCREASE_UNIT_BUILD_CHARGE'),
('ABILITY_DECREASE_BUILD_CHARGE', 'MODTOOL_ATTACH_DECREASE_UNIT_BUILD_CHARGE');

INSERT INTO Modifiers	
(ModifierId,	ModifierType, RunOnce, Permanent, NewOnly, OwnerRequirementSetId, SubjectRequirementSetId) VALUES	
('MODTOOL_ATTACH_INCREASE_UNIT_BUILD_CHARGE',	'MODIFIER_SINGLE_UNIT_ATTACH_MODIFIER', 1, 1, 0, NULL, NULL),
('MODTOOL_ATTACH_DECREASE_UNIT_BUILD_CHARGE',	'MODIFIER_SINGLE_UNIT_ATTACH_MODIFIER', 1, 1, 0, NULL, NULL);

INSERT INTO ModifierArguments
(ModifierId,	Name,	Value) VALUES	
('MODTOOL_ATTACH_INCREASE_UNIT_BUILD_CHARGE',	'ModifierId',	'MODTOOL_INCREASE_UNIT_BUILD_CHARGE'),
('MODTOOL_ATTACH_DECREASE_UNIT_BUILD_CHARGE',	'ModifierId',	'MODTOOL_DECREASE_UNIT_BUILD_CHARGE');













