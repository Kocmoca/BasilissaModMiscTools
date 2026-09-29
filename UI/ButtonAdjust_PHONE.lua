-- Phone-only UI adjustments.
-- The engine loads this file instead of ButtonAdjust.lua on phone UI.
-- Only adjust ExpandSecondaryActionsButton position; do not change button sizes.

local m_DidAdjustExpandButton = false

local function AdjustExpandSecondaryActionsButton()
    local button = ContextPtr:LookUpControl("/InGame/UnitPanel/ExpandSecondaryActionsButton")
    if button == nil then return false end

    -- Move the expand button upward so it does not overlap the custom
    -- unit-action buttons at the bottom. Prefer the actual ExtensiveUnitGrid
    -- height when available, otherwise use the phone unit-action height.
    local grid = ContextPtr:LookUpControl("/InGame/UnitPanel/StandardActionsStack/ExtensiveUnitGrid")
    local gridHeight = 135
    if grid ~= nil then
        local sizeY = grid:GetSizeY()
        if sizeY ~= nil and sizeY > 0 then
            gridHeight = sizeY
        end
    end
    button:SetOffsetY(120)
    return true
end

local function AdjustPhoneUI(force)
    if force or not m_DidAdjustExpandButton then
        m_DidAdjustExpandButton = AdjustExpandSecondaryActionsButton()
    end
end

function OnButtonAdjustSystemUpdateUI()
    AdjustPhoneUI()
end

function Initialize()
    AdjustPhoneUI()
    Events.SystemUpdateUI.Add(OnButtonAdjustSystemUpdateUI)
    LuaEvents.ModMiscToolExtensiveUnitPanelReady.Add(function()
        AdjustPhoneUI(true)
    end)
end
Events.LoadGameViewStateDone.Add(Initialize)
