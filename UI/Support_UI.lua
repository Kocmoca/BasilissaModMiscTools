include("ModTool_Support_Functions.lua")
include("ModTool_Support_UI.lua")

local allUnitPromotions = {}

function InitializeAllUnitPromotions()
	for promotionRow in GameInfo.UnitPromotions() do
		local promotionType = promotionRow.UnitPromotionType
		local promotionClass = promotionRow.PromotionClass
		if allUnitPromotions[promotionClass] == nil then
			allUnitPromotions[promotionClass] = {}
		end
		table.insert(allUnitPromotions[promotionClass], promotionType)
	end
end

function GetExperienceAndPromotionsUI(playerID, unitID)
	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil then
		return nil, nil
	end
	local unitExp = unit:GetExperience()
	if unitExp == nil then
		return nil, nil
	end
	local expPoint = unitExp:GetExperiencePoints()
	local promotions = {}
	local promoClass = GameInfo.Units[unit:GetType()].PromotionClass
	local potentialPromo = allUnitPromotions[promoClass]
	if potentialPromo == nil then
		return 0, {}
	end
	for _, promo in ipairs(potentialPromo) do
		local promoIndex = GameInfo.UnitPromotions[promo].Index
		if unitExp:HasPromotion(promoIndex) then
			table.insert(promotions, promoIndex)
		end
	end
	if promotions == nil then
		print("error, failed to get promotions")
	end
	return expPoint, promotions
end

function GetPlayerAllianceType(playerID, subPlayerID)
	local player = Players[playerID]
	if player == nil then
		return nil
	end
	local playerDiplomacy = player:GetDiplomacy()
	local allianceType = playerDiplomacy:GetAllianceType(subPlayerID)
	if allianceType == -1 then
		return nil
	end
	local allianceRow = GameInfo.Alliances[allianceType]
	if allianceRow == nil then
		return nil
	end
	return allianceRow.AllianceType
end


------------------------------------------------------------------------------
-- 通用收支账本 provider
------------------------------------------------------------------------------

local m_LedgerProvider = nil

function RegisterLedgerProvider(provider)
if provider == nil then return false end
m_LedgerProvider = provider
return true
end

function GetLedgerProvider()
return m_LedgerProvider
end

function GetLedgerSummary(playerID)
if m_LedgerProvider == nil or m_LedgerProvider.getSummary == nil then
return nil
end
return m_LedgerProvider.getSummary(playerID)
end

function GetLedgerItems(playerID, filter)
if m_LedgerProvider == nil or m_LedgerProvider.getItems == nil then
return {}
end
return m_LedgerProvider.getItems(playerID, filter)
end

function GetLocalLedgerSummary()
local localPlayerID = Game.GetLocalPlayer()
if localPlayerID == nil or localPlayerID == -1 then return nil end
return GetLedgerSummary(localPlayerID)
end

function GetLocalLedgerItems(filter)
local localPlayerID = Game.GetLocalPlayer()
if localPlayerID == nil or localPlayerID == -1 then return {} end
return GetLedgerItems(localPlayerID, filter)
end

function LedgerProviderAvailable()
return m_LedgerProvider ~= nil
end


function Initialize()
	InitializeAllUnitPromotions()
	if not ExposedMembers.ModMiscToolUI then
		ExposedMembers.ModMiscToolUI = {}
	end
	ExposedMembers.ModMiscToolUI.GetExperienceAndPromotionsUI = GetExperienceAndPromotionsUI
	ExposedMembers.ModMiscToolUI.GetBuildingsIndexAtPlotUI = GetBuildingsIndexAtPlotUI
	ExposedMembers.ModMiscToolUI.GetUnitIconAndName = GetUnitIconAndName
	ExposedMembers.ModMiscToolUI.CanUnitTypeGetExp = CanUnitTypeGetExp
	ExposedMembers.ModMiscToolUI.allUnitPromotions = allUnitPromotions
	ExposedMembers.ModMiscToolUI.GetPlayerAllianceType = GetPlayerAllianceType
ExposedMembers.ModMiscToolUI.RegisterLedgerProvider = RegisterLedgerProvider
ExposedMembers.ModMiscToolUI.GetLedgerProvider = GetLedgerProvider
ExposedMembers.ModMiscToolUI.GetLedgerSummary = GetLedgerSummary
ExposedMembers.ModMiscToolUI.GetLedgerItems = GetLedgerItems
ExposedMembers.ModMiscToolUI.GetLocalLedgerSummary = GetLocalLedgerSummary
ExposedMembers.ModMiscToolUI.GetLocalLedgerItems = GetLocalLedgerItems
ExposedMembers.ModMiscToolUI.LedgerProviderAvailable = LedgerProviderAvailable
ExposedMembers.ModMiscToolUI.ShowLoadWarningPopup = ShowLoadWarningPopup
end
Events.LoadGameViewStateDone.Add(Initialize)
