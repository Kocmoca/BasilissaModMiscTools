------------------------------------------------------------------------------
--	Common LUA support functions specific to Civilization 6
------------------------------------------------------------------------------

include( "ToolTipHelper" );
include( "Colors" );
include( "PortraitSupport" );


-- ===========================================================================
--	CONSTANTS
-- ===========================================================================

local TUTORIAL_UUID	:string = "17462E0F-1EE1-4819-AAAA-052B5896B02A";

ProductionType = {
	BUILDING	= "BUILDING",
	DISTRICT	= "DISTRICT",
	PROJECT		= "PROJECT",
	UNIT		= "UNIT"
}


-- ===========================================================================
--	FUNCTIONS
-- ===========================================================================


-- ===========================================================================
--	Return the height of the top panel
-- ===========================================================================
function GetTopBarHeight() 
	return 29;	-- Not height of context but where art/offset should start for content below it.
end

-- ===========================================================================
--	Return the inline text-icon for a given yield
--	yieldType	A database YIELD_TYPE
--	returns		The [ICON_yield] string
-- ===========================================================================
function GetYieldTextIcon( yieldType:string )
	local  iconString:string = "";
	if		yieldType == nil or yieldType == ""	then
		iconString="Error:NIL";
	elseif	GameInfo.Yields[yieldType] ~= nil and GameInfo.Yields[yieldType].IconString ~= nil and GameInfo.Yields[yieldType].IconString ~= "" then
		iconString=GameInfo.Yields[yieldType].IconString;
	else
		iconString = "Unknown:"..yieldType; 
	end			
	return iconString;
end


-- ===========================================================================
--	Return the inline entry for a yield's color
-- ===========================================================================
function GetYieldTextColor( yieldType:string )
	if		yieldType == nil or yieldType == "" then return "[COLOR:255,255,255,255]NIL ";
	elseif	yieldType == "YIELD_FOOD"			then return "[COLOR:ResFoodLabelCS]";
	elseif	yieldType == "YIELD_PRODUCTION"		then return "[COLOR:ResProductionLabelCS]";
	elseif	yieldType == "YIELD_GOLD"			then return "[COLOR:ResGoldLabelCS]";
	elseif	yieldType == "YIELD_SCIENCE"		then return "[COLOR:ResScienceLabelCS]";
	elseif	yieldType == "YIELD_CULTURE"		then return "[COLOR:ResCultureLabelCS]";
	elseif	yieldType == "YIELD_FAITH"			then return "[COLOR:ResFaithLabelCS]";
	else											 return "[COLOR:255,255,255,0]ERROR ";
	end				
end

-- ===========================================================================
--	Return a string with +/- or 0 based on any value.
-- ===========================================================================
function toPlusMinusString( value:number )
	if(value == 0) then
		return "0";
	else
		return Locale.ToNumber(value, "+#,###.#;-#,###.#");
	end
end

-- ===========================================================================
--	Return a string with +/- or 0 based on any value.
-- ===========================================================================
function toPlusMinusNoneString( value:number )
	if(value == 0) then
		return " ";
	else
		return Locale.ToNumber(value, "+#,###.#;-#,###.#");
	end
end


-- ===========================================================================
--	Return a string with a yield icon and a +/- based on yield amount.
-- ===========================================================================
function GetYieldString( yieldType:string, amount:number )
	return GetYieldTextIcon(yieldType)..GetYieldTextColor(yieldType)..toPlusMinusString(amount).."[ENDCOLOR]";
end

-- ===========================================================================
--	Move a unit to X,Y
-- ===========================================================================
-- ===========================================================================
--	Mod Misc Tools: generic movement interceptor probe
-- ===========================================================================
local function ModMiscTool_ShouldInterceptMovement( eAttacker, eOwner )
	if ExposedMembers == nil or ExposedMembers.ModMiscToolUI == nil
		or ExposedMembers.ModMiscToolUI.ShouldInterceptMovement == nil then
		error("[ModMiscTool] Civ6Common replacement: ShouldInterceptMovement API missing");
	end
	return ExposedMembers.ModMiscToolUI.ShouldInterceptMovement(eAttacker, eOwner) == true;
end

function MoveUnitToPlot( kUnit:table, plotX:number, plotY:number )
	if kUnit ~= nil then
		local tParameters:table = {};
		tParameters[UnitOperationTypes.PARAM_X] = plotX;
		tParameters[UnitOperationTypes.PARAM_Y] = plotY;		
		
		-- Will this start a war?  Note, we are ignoring destinations in the for that will start a war, the unit will be allowed to move until they are adjacent.
		-- We may want to also skip the war check if the move will take more than one turn to get to the destination.
		local eAttackingPlayer:number = kUnit:GetOwner();
		local eUnitComponentID:table = kUnit:GetComponentID();
		local bWillStartWar = false;
		
		local results:table;
		if (PlayersVisibility[eAttackingPlayer]:IsVisible(plotX, plotY)) then
			results = CombatManager.IsAttackChangeWarState(eUnitComponentID, plotX, plotY);
			if (results ~= nil and #results > 0) then
				bWillStartWar = true;
			end
		end

		if (bWillStartWar) then
			local eDefendingPlayer = results[1];
			-- Create the action specific parameters
			if (eDefendingPlayer ~= nil and eDefendingPlayer ~= -1) then
				-- Vanilla check says this move is blocked (would start war).
				-- Only now consult the framework: if a registered interceptor
				-- explicitly allows it, bypass vanilla; otherwise keep vanilla block.
				if ModMiscTool_ShouldInterceptMovement(eAttackingPlayer, eDefendingPlayer) then
					RequestMoveOperation(kUnit, tParameters, plotX, plotY);
				else
					print("[ModMiscTool][MILITARY_ACCESS] blocked mover="
						.. tostring(eAttackingPlayer) .. " owner=" .. tostring(eDefendingPlayer));
					LuaEvents.Civ6Common_ConfirmWarDialog(eAttackingPlayer, eDefendingPlayer, WarTypes.SURPRISE_WAR);
				end
			end
		else
			RequestMoveOperation(kUnit, tParameters, plotX, plotY);
		end
	end			
end

-- ===========================================================================
--  Requests an operation based on the type of unit and parameters
-- ===========================================================================
function RequestMoveOperation( kUnit:table, tParameters:table, plotX:number, plotY:number )
	-- Air units move and attack slightly differently than land and naval units
	if ( GameInfo.Units[kUnit:GetUnitType()].Domain == "DOMAIN_AIR" ) then
		tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK;
		if (UnitManager.CanStartOperation( kUnit, UnitOperationTypes.AIR_ATTACK, nil, tParameters) ) then
			UnitManager.RequestOperation(kUnit, UnitOperationTypes.AIR_ATTACK, tParameters);
		elseif (UnitManager.CanStartOperation( kUnit, UnitOperationTypes.DEPLOY, nil, tParameters) ) then
			UnitManager.RequestOperation(kUnit, UnitOperationTypes.DEPLOY, tParameters);
		end
	else
		tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE;
		if (UnitManager.CanStartOperation( kUnit, UnitOperationTypes.RANGE_ATTACK, nil, tParameters) and (kUnit:GetRangedCombat() > kUnit:GetCombat() or kUnit:GetBombardCombat() > kUnit:GetCombat() ) ) then
			UnitManager.RequestOperation(kUnit, UnitOperationTypes.RANGE_ATTACK, tParameters);
		else
			-- Allow for attacking and don't early out if the destination is blocked, etc., but is in the fog.
			tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.ATTACK + UnitOperationMoveModifiers.MOVE_IGNORE_UNEXPLORED_DESTINATION;
			if (UnitManager.CanStartOperation( kUnit, UnitOperationTypes.COASTAL_RAID, nil, tParameters) ) then
				UnitManager.RequestOperation( kUnit, UnitOperationTypes.COASTAL_RAID, tParameters);
			else
				-- Check that unit isn't already in the plot (essentially canceling the move),
				-- otherwise the operation will complete, and while no move is made, the next
				-- unit will auto seltect.
				if plotX ~= kUnit:GetX() or plotY ~= kUnit:GetY() then
					if (UnitManager.CanStartOperation( kUnit, UnitOperationTypes.SWAP_UNITS, nil, tParameters) ) then
						UnitManager.RequestOperation(kUnit, UnitOperationTypes.SWAP_UNITS, tParameters);
					else
						UnitManager.RequestOperation(kUnit, UnitOperationTypes.MOVE_TO, tParameters);
					end
				end
			end
		end
	end
end

-- ===========================================================================
--	Multiplier value 
--	Return a string with a colorized # and a +/- based on 1.0 based percent.
-- ===========================================================================
function GetColorPercentString( multiplier:number )
	if		multiplier > 1 then return "[COLOR:StatGoodCS]+"..tostring((multiplier-1)*100).."%[ENDCOLOR]";
	elseif	multiplier < 1 then return "[COLOR:StatBadCS]-"..tostring((1-multiplier)*100).."%[ENDCOLOR]";
	else					return "[COLOR:StatNormalCS]100%[ENDCOLOR]";
	end
end

-- ===========================================================================
--  Returns a Civ-specific format for date and time, given a total number
-- of seconds (unmodulated), and whether or not the time is approximate
-- ===========================================================================
function FormatTimeRemaining( timeRemaining:number, bIsConcrete:boolean )
	-- Format the time remaining string based on how much time we have left.
	-- We manually floor our values using floor and % operations to prevent the localization system 
	-- from rounding the values up.
	local secs = timeRemaining % 60;
	local mins = timeRemaining / 60;
	local hours = timeRemaining / 3600;
	local days = timeRemaining / 86400;
	if(days >= 1) then
		-- Days remaining
		days = math.floor(days);
		hours = hours % 24; -- cap hours
		if(bIsConcrete) then
			return Locale.Lookup("LOC_KEY_TIME_DAYS_HOURS", days, hours);
		else
			return Locale.Lookup("LOC_KEY_EST_TIME_DAYS_HOURS", days, hours);
		end
	elseif(hours >= 1) then
		-- hours left
		hours = math.floor(hours);
		mins = mins % 60; -- cap mins
		if(bIsConcrete) then
			return Locale.Lookup("LOC_KEY_TIME_HOURS_MINUTES", hours, mins);
		else
			return Locale.Lookup("LOC_KEY_EST_TIME_HOURS_MINUTES", hours, mins);
		end
	elseif(mins >= 1) then
		-- mins left
		mins = math.floor(mins);
		if(bIsConcrete) then
			return Locale.Lookup("LOC_KEY_TIME_MINS_SECONDS", mins, secs);
		else
			return Locale.Lookup("LOC_KEY_EST_TIME_MINS_SECONDS", mins, secs);
		end
	else
		-- secs left
		if(bIsConcrete) then
			return Locale.Lookup("LOC_KEY_TIME_SECONDS", secs);
		else
			return Locale.Lookup("LOC_KEY_EST_TIME_SECONDS", secs);
		end
	end
end

-- ===========================================================================
--	Obtain the stats for a unit, given it's hash or type string
--	RETURNS: nil if not found, or table o' stats
-- ===========================================================================
function GetUnitStats( hashOrType )
	local info:table= GameInfo.Units[hashOrType];
	if info == nil then
		--error("Was unable to find a Unit to get it's stats with the value \""..tostring(hashOrType).."\"");
		return nil;
	end
	return {
		Bombard		= info.Bombard,
		Combat		= info.Combat,
		Moves		= info.BaseMoves,
		RangedCombat= info.RangedCombat,
		Range		= info.Range
	}
end

-- ===========================================================================
--	Returns the icon info and shadow icon info for the passed in unit or returns default icons if those can't be found
--	RETURN 1: iconInfo - table containing textureSheet, textureOffsetX, and textureOffsetY
--	RETURN 2: iconShadowInfo - table containing textureSheetShadow, textureOffsetShadowX, and textureOffsetShadowY
-- ===========================================================================
function GetUnitIcon( pUnit:table, iconSize:number )	
	
	local iconInfo:table = {};
	if pUnit then

		local unitIcon:string = nil;

		local individual:number = pUnit:GetGreatPerson():GetIndividual();
		if individual >= 0 then
			local individualType:string = GameInfo.GreatPersonIndividuals[individual].GreatPersonIndividualType;
			local iconModifier:table = GameInfo.GreatPersonIndividualIconModifiers[individualType];
			if iconModifier then
				unitIcon = iconModifier.OverrideUnitIcon;
			end 
		end

		if not unitIcon then
			local unit:table = GameInfo.Units[pUnit:GetUnitType()];
			unitIcon = "ICON_" .. unit.UnitType;
		end
		
		iconInfo.textureOffsetX, iconInfo.textureOffsetY, iconInfo.textureSheet = IconManager:FindIconAtlas(unitIcon, iconSize);
		if (iconInfo.textureSheet == nil) then			--Check to see if the unit has an icon atlas index defined
			print("UIWARNING: Could not find icon for " .. unitIcon);
			iconInfo.textureOffsetX, iconInfo.textureOffsetY, iconInfo.textureSheet = IconManager:FindIconAtlas("ICON_UNIT_UNKNOWN", iconSize);		--If not, resolve the index to be a generic unknown index
		end
	end
	return iconInfo;
end

-- ===========================================================================
--	A helper function to size a GridButton to its string contents
--	ARG 1: gridButton (table) - expects a control of type GridButton to be resized
--	ARG 4: minX (number) - the minimum width of the button
--	ARG 5: minY (number) - the minimum height of the button
--	ARG 2: OPTIONAL padding (number) - the amount of padding which should be inserted around the text string
--	ARG 3: OPTIONAL sizeOption (string) - expects V or H - to specifiy if the button should only be sized vertically or horizontally
-- ===========================================================================
function AutoSizeGridButton(gridButton:table,minX: number, minY: number, padding:number, sizeOption:string)
	if (sizeOption == nil) then
		sizeOption = "1";
	end
	if (padding == nil) then
		padding = 0;
	end
	local labelControl =  gridButton:GetTextControl();
	local labelX = labelControl:GetSizeX() + padding*2;
	local labelY = labelControl:GetSizeY() + padding*2;
	if (minX ~= nil) then
		labelX = math.max(minX, labelX);
	end
	if (minY ~= nil) then
		labelY = math.max(minY, labelY);
	end
	if(sizeOption == "V" or sizeOption == "1") then
		gridButton:SetSizeY(labelY);
	end
	if(sizeOption == "H" or sizeOption == "1") then
		gridButton:SetSizeX(labelX);
	end
	return labelX, labelY;
end

-- ===========================================================================
function GetLeaderUniqueTraits( leaderType:string, useFullDescriptions:boolean )

	-- Gather info.
    local base_leader = GameInfo.Leaders[leaderType];
    if(base_leader == nil) then
        return;
    end           

	function AddInheritedLeaders(leaders, leader)
		local inherit = leader.InheritFrom;
        if(inherit ~= nil) then
            local parent = GameInfo.Leaders[inherit];
            if(parent) then
                table.insert(leaders, parent);
                AddInheritedLeaders(leaders, parent);
            end
        end
    end

	local leaders = {};
    table.insert(leaders, base_leader);
	AddInheritedLeaders(leaders, base_leader);

	-- Enumerate final list and index.
	local has_leader = {};
	for i,leader in ipairs(leaders) do
		has_leader[leader.LeaderType] = true;
	end

	-- Unique Abilities
	-- We're considering a unique ability to be a trait which does 
	-- not have a unique unit, building, district, or improvement associated with it.
	-- While we scrub for unique units and infrastructure, mark traits that match 
	-- so we can filter them later.
    local traits = {};
	local has_trait = {};
	local not_ability = {};
    for row in GameInfo.LeaderTraits() do
        if(has_leader[row.LeaderType] == true) then
			local trait = GameInfo.Traits[row.TraitType];
			if(trait) then
				table.insert(traits, trait);			
			end
			has_trait[row.TraitType] = true;
        end
    end

    -- Unique Units
    local uu = {};
    for row in GameInfo.Units() do
        local trait = row.TraitType;
        if(trait) then
			not_ability[trait] = true;
			if(has_trait[trait] == true) then
				local description :string = Locale.Lookup("LOC_LOADING_"..row.Domain);
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Units[row.UnitType].Description);
				end
				table.insert(uu, { Type = row.UnitType, Name = row.Name, Description = description });
			end
        end
    end
    
    -- Unique Buildings/Districts/Improvements
    local ub = {};
    for row in GameInfo.Buildings() do
        local trait = row.TraitType;
        if(trait) then
			not_ability[trait] = true;
			if(has_trait[trait] == true) then
				local districtName:string = GameInfo.Districts[row.PrereqDistrict].Name;
				local description :string = Locale.Lookup("LOC_LOADING_UNIQUE_BUILDING");
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Buildings[row.BuildingType].Description); 
				end
				table.insert(ub, {Type = row.BuildingType, Name = row.Name, Description = description});
			end
        end
    end

    for row in GameInfo.Districts() do
        local trait = row.TraitType;
        if(trait) then
			not_ability[trait] = true;
			if(has_trait[trait] == true) then
				local description :string = Locale.Lookup("LOC_LOADING_UNIQUE_DISTRICT");
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Districts[row.DistrictType].Description); 
				end
				table.insert(ub, {Type = row.DistrictType, Name = row.Name, Description = description});
			end
        end
    end

    for row in GameInfo.Improvements() do
        local trait = row.TraitType;
        if(trait) then
			not_ability[trait] = true;
			if(has_trait[trait] == true) then
				local description :string = Locale.Lookup("LOC_LOADING_UNIQUE_IMPROVEMENT");
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Improvements[row.ImprovementType].Description); 
				end
				table.insert(ub, {Type = row.ImprovementType, Name = row.Name, Description = description});
			end
        end
    end

	local unique_abilities = {};
	for i, trait in ipairs(traits) do
		print(trait.InternalOnly);
		if(not_ability[trait.TraitType] ~= true and not trait.InternalOnly) then
			table.insert(unique_abilities, trait);
		end
	end

	return unique_abilities,uu,ub;
end


-- ===========================================================================
function GetCivilizationUniqueTraits( civType:string, useFullDescriptions:boolean )
    
	local traits = {};
    for row in GameInfo.CivilizationTraits() do
        if(row.CivilizationType == civType) then
            traits[row.TraitType] = true;
        end
    end

	-- Unique Abilities
	-- We're considering a unique ability to be a trait which does 
	-- not have a unique unit, building, district, or improvement associated with it.
	-- While we scrub for unique units and infrastructure, mark traits that match 
	-- so we can filter them later.
	local not_abilities = {};
	
    -- Unique Units
    local uu = {};
    for row in GameInfo.Units() do
        local trait = row.TraitType;
        if(trait) then
			not_abilities[trait] = true;
			if(traits[trait] == true) then
				local description :string = Locale.Lookup("LOC_LOADING_"..row.Domain);
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Units[row.UnitType].Description);
				end
				table.insert(uu, { Type = row.UnitType, Name = row.Name, Description = description });
			end
        end
    end
    
    -- Unique Buildings/Districts/Improvements
    local ub = {};
    for row in GameInfo.Buildings() do
        local trait = row.TraitType;
        if(trait) then
			not_abilities[trait] = true;
			if(traits[trait] == true) then
				local building	  :table  = GameInfo.Buildings[row.BuildingType];
				local description :string = Locale.Lookup("LOC_LOADING_UNIQUE_BUILDING");
				if m_isTraitsFullDescriptions or useFullDescriptions then
					if building == nil then
						UI.DataError("Could not get CIV trait as GameInfo.Buildings["..row.BuildingType.."] does not exist.");
					elseif building.Description == nil then
						UI.DataError("Could not get CIV trait description for GameInfo.Buildings["..row.BuildingType.."].  None supplied.");
					else
						description = Locale.Lookup(building.Description); 
					end				
				end
				table.insert(ub, {Type = row.BuildingType, Name = row.Name, Description = description});
			end
        end
    end

    for row in GameInfo.Districts() do
        local trait = row.TraitType;
        if(trait) then
			not_abilities[trait] = true;
			if(traits[trait] == true) then
				local description :string = Locale.Lookup("LOC_LOADING_UNIQUE_DISTRICT");
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Districts[row.DistrictType].Description); 
				end
				table.insert(ub, {Type = row.DistrictType, Name = row.Name, Description = description});
			end
        end
    end

    for row in GameInfo.Improvements() do
        local trait = row.TraitType;
        if(trait) then
			not_abilities[trait] = true;
			if(traits[trait] == true) then
				local description :string = Locale.Lookup("LOC_LOADING_UNIQUE_IMPROVEMENT");
				if m_isTraitsFullDescriptions or useFullDescriptions then
					description = Locale.Lookup(GameInfo.Improvements[row.ImprovementType].Description); 
				end
				table.insert(ub, {Type = row.ImprovementType, Name = row.Name, Description = description});
			end
        end
    end

	local unique_abilities = {};
	for row in GameInfo.CivilizationTraits() do
		if(row.CivilizationType == civType and not_abilities[row.TraitType] ~= true) then
			local trait = GameInfo.Traits[row.TraitType];
			if(trait) then
				table.insert(unique_abilities, trait);
			end			
		end
	end

	return unique_abilities, uu, ub;
end
    

-- ===========================================================================
--	Is the on-rails tutorial active?
-- ===========================================================================
function IsTutorialRunning()
	return Modding.IsModActive(TUTORIAL_UUID);
end

-- ===========================================================================
--	DifferentiateCiv
-- ===========================================================================	
--	This is a fix for duplicate civs.  If you feed it a control, it will generate a tooltip which lists the cities for that civ, to help differentiate which civ you are currently viewing.
--	Note: This function does NOT contain the IsDuplicate? check.  Use this function once you have already determined whether or not you wish to differentiate the civ.
--	Additionally, you can pass icon backing/icon controls to be colored with the civ's colors.
--	ARG1 playerID	(number)						The player id of the civ in question
--	ARG2 tooltipControl (table)			OPTIONAL	This is the control that should receive the tooltip
--	ARG3 icon (table)					OPTIONAL	The icon control which will receive the foreground color for the civ
--	ARG4 iconBacking (table)			OPTIONAL	The image behind the icon which will receive the background color for the civ
--	ARG5 iconBackingDarker (table)		OPTIONAL	If you are making a fancy icon with more depth, you can additionally pass the layer to be darkened
--	ARG6 iconBackingLighter (table)		OPTIONAL	.. and also the layer to be lightened
--	ARG7 observerPlayerID (number)		OPTIONAL	Checks if the players met 
--	RETURNS (string)								String to be used as a tooltip which lists Civ name, Leader/Player name, list of cities
function DifferentiateCiv(playerID:number, tooltipControl:table, icon:table, iconBacking:table, iconBackingDarker:table, iconBackingLighter:table, observerPlayerID:number)
	
	local player:table = Players[playerID];
	local playerConfig:table = PlayerConfigurations[playerID];
	
	local hasMet:boolean = true;
	if player ~= nil and observerPlayerID ~= nil and playerID ~= observerPlayerID then
		hasMet = player:GetDiplomacy():HasMet(observerPlayerID);
	end

	if (player ~= nil and hasMet and iconBacking ~= nil and icon ~= nil) then
		m_primaryColor, m_secondaryColor  = UI.GetPlayerColors( playerID );
		iconBacking:SetColor(m_primaryColor);
		if(iconBackingLighter ~= nil and iconBackingDarker ~= nil) then
			local darkerBackColor = UI.DarkenLightenColor(m_primaryColor,(-85),100);
			local brighterBackColor = UI.DarkenLightenColor(m_primaryColor,90,255);
			iconBackingLighter:SetColor(brighterBackColor);
			iconBackingDarker:SetColor(darkerBackColor);
		end
		icon:SetColor(m_secondaryColor);
	end

	-- Set the leader name, civ name, and civ icon data
	local civTypeName = playerConfig:GetCivilizationTypeName();
	if civTypeName ~= nil then
		local civIcon:string;
		local civTooltip:string;
		if hasMet then
			civIcon = "ICON_"..civTypeName;

			local leaderTypeName:string = playerConfig:GetLeaderTypeName();
			if leaderTypeName ~= nil then
				local leaderName = Locale.Lookup(GameInfo.Leaders[leaderTypeName].Name);
				if GameConfiguration.IsAnyMultiplayer() and player:IsHuman() then
					local playerName = Locale.Lookup(playerConfig:GetPlayerName());
					leaderName = leaderName .. " ("..Locale.Lookup(playerName)..")"
				end

				--Create a tooltip which shows a list of this Civ's cities
				local civName = Locale.Lookup(GameInfo.Civilizations[civTypeName].Name);
				civTooltip = civName .. "[NEWLINE]".. leaderName;
				local playerCities = player:GetCities();
				if(playerCities ~= nil) then
					civTooltip = civTooltip .. "[NEWLINE]"..Locale.Lookup("LOC_PEDIA_CONCEPTS_PAGEGROUP_CITIES_NAME").. ":";
					for i,city in playerCities:Members() do
						civTooltip = civTooltip.. "[NEWLINE]".. Locale.Lookup(city:GetName());
					end
				end
			else
				UI.DataError("Invalid type name returned by GetLeaderTypeName");
			end
		else
			civIcon = "ICON_LEADER_DEFAULT";
			civTooltip = Locale.Lookup("LOC_DIPLOPANEL_UNMET_PLAYER");
			if GameConfiguration.IsAnyMultiplayer() and player:IsHuman() then
				local playerName = Locale.Lookup(playerConfig:GetPlayerName());
				civTooltip = civTooltip .. " ("..Locale.Lookup(playerName)..")";
			end
		end
			
		if (icon ~= nil) then
			icon:SetIcon(civIcon);
		end
		if (tooltipControl ~= nil) then
			tooltipControl:SetToolTipString(Locale.Lookup(civTooltip));
		end
		return civTooltip
	else
		UI.DataError("Invalid type name returned by GetCivilizationTypeName");
	end
end


-- ===========================================================================
function GetGreatWorksForCity( pCity:table )
	local result:table = {};
	if pCity then
		local pCityBldgs:table = pCity:GetBuildings();
		for buildingInfo in GameInfo.Buildings() do
			local buildingIndex:number = buildingInfo.Index;
			local buildingType:string = buildingInfo.BuildingType;
			if(pCityBldgs:HasBuilding(buildingIndex)) then
				local numSlots:number = pCityBldgs:GetNumGreatWorkSlots(buildingIndex);
				if (numSlots ~= nil and numSlots > 0) then
					local greatWorksInBuilding:table = {};

					-- populate great works
					for index:number=0, numSlots - 1 do
						local greatWorkIndex:number = pCityBldgs:GetGreatWorkInSlot(buildingIndex, index);
						if greatWorkIndex ~= -1 then
							local greatWorkType:number = pCityBldgs:GetGreatWorkTypeFromIndex(greatWorkIndex);
							table.insert(greatWorksInBuilding, GameInfo.GreatWorks[greatWorkType]);
						end
					end

					-- create association between building type and great works
					if table.count(greatWorksInBuilding) > 0 then
						result[buildingType] = greatWorksInBuilding;
					end
				end
			end
		end
	end
	return result;
end

-- ===========================================================================
--	Is a diplomacy for the local player.
-- ===========================================================================
function IsDiplomacyPending()
	local localPlayerId:number = Game.GetLocalPlayer();
	if localPlayerId == -1 then
		return false;
	end
	if (DiplomacyManager.HasQueuedSession(localPlayerId) ) then
		return true;
	end
	return false;
end

-- ===========================================================================
--	Is diplomacy open for thelocal player.
-- ===========================================================================
function IsDiplomacyOpen()
	local localPlayerId:number = Game.GetLocalPlayer();
	if localPlayerId == -1 then
		return false;
	end
	
	local localPlayer :table = Players[localPlayerId];
	local pOtherPlayer:table = nil;
	
	-- Loop through all the players whom could have 
	for iPlayer = 0,63,1 do
		local pPlayerConfig = PlayerConfigurations[iPlayer];

		pOtherPlayer = Players[iPlayer];
		if pOtherPlayer then
			local sessionID :number = DiplomacyManager.FindOpenSessionID( localPlayerId, pOtherPlayer:GetID());
			if sessionID ~= nil then
				return true;
			end
		end
	end
	return false;
end

-- ===========================================================================
--	RETURNS: true if a player does not have any cities.
-- ===========================================================================
function IsPlayerCityless( playerID:number )
	if playerID < 0 then return true; end
	local pPlayer		:table = Players[playerID];
	local pPlayerCities	:table = pPlayer:GetCities();
	for i, pCity in pPlayerCities:Members() do
		return false;
	end
	return true;
end

-- ===========================================================================
--	Serialize custom data in the custom data table.
--	key		must be a string
--	value	can be anything
-- ===========================================================================
function WriteCustomData( key:string, value )
	local pParameters :table = UI.GetGameParameters():Add("CustomData");
	if pParameters ~= nil then
		pParameters:Remove( key );
		local pData:table = pParameters:Add( key );
		pData:AppendValue( value );
	else
		UI.DataError("Could not write CustomData: ",key,value);
	end
end

-- ===========================================================================
--	Read back custom data, returns NIL if not found.
--	key		must be a string
--	RETURNS: all values from the associated key (or nil if key isn't found)
-- ===========================================================================
function ReadCustomData( key:string )
	local pParameters	:table = UI.GetGameParameters():Get("CustomData");
	local kReturn		:table = {};
	if pParameters ~= nil then
		local pValues:table = pParameters:Get( key );		
		-- No key or empty key?  Return nil...
		if pValues == nil then
			return nil;
		end
		local count:number = pValues:GetCount();
		if count == 0 then
			return nil;
		end
		for i = 1, count, 1 do
			local value = pValues:GetValueAt(i-1);
			table.insert(kReturn, value);
		end
	else
		return nil;
	end
	return unpack(kReturn);
end

-- ===========================================================================
--	If the official Civ6 Expansion "Rise and Fall" (XP1) is active.
-- ===========================================================================
function IsExpansion1Active()
	local isActive:boolean  = Modding.IsModActive("1B28771A-C749-434B-9053-D1380C553DE9");
	return isActive;
end

-- ===========================================================================
--	If the official Civ6 Expansion "Gathering Storm" (XP2) is active.
-- ===========================================================================
function IsExpansion2Active()
	local isActive:boolean  = Modding.IsModActive("4873eb62-8ccc-4574-b784-dda455e74e68");
	return isActive;
end

-- ===========================================================================
--	If the official Civ6 Expansion "Rise and Fall" (XP1) is enabled.
-- ===========================================================================
function IsExpansion1Enabled()
	local isActive:boolean  = Modding.IsModEnabled("1B28771A-C749-434B-9053-D1380C553DE9");
	return isActive;
end

-- ===========================================================================
--	If the official Civ6 Expansion "Gathering Storm" (XP2) is enabled.
-- ===========================================================================
function IsExpansion2Enabled()
	local isActive:boolean  = Modding.IsModEnabled("4873eb62-8ccc-4574-b784-dda455e74e68");
	return isActive;
end

-- ASPYR -- Don't just attack/move, use confirmation dialog first
function AspyrConfirmThenRequestAttack(pSelectedUnit, tParameters)
	-- taken from UnitRangeAttack (wish could share the code but it's not too easily done here)
	local rangeAttackFunc = function()
		UnitManager.RequestOperation( pSelectedUnit, UnitOperationTypes.RANGE_ATTACK, tParameters);
		LuaEvents.WorldInput_UnitConfirmationShown();
		LuaEvents.ShowAttackPreview(false);
	end;
	local cancelFunc = function()
		LuaEvents.WorldInput_UnitConfirmationShown();
		LuaEvents.ShowAttackPreview(false);
		--UI.DeselectUnit( pSelectedUnit );
		--UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
	end;

	local bShowConfirmation = false;

	local unitConfirmationLevel = UserConfiguration.UnitConfirmationLevel();

	if IsTutorialRunning() and not m_bTutorialFreeMode then
		unitConfirmationLevel = UnitConfirmationLevel.CONFIRMATION_LEVEL_NONE;
	end
	if (unitConfirmationLevel ~= UnitConfirmationLevel.CONFIRMATION_LEVEL_NONE) then
		if (unitConfirmationLevel == UnitConfirmationLevel.CONFIRMATION_LEVEL_ALWAYS) or (unitConfirmationLevel == UnitConfirmationLevel.CONFIRMATION_LEVEL_COMBAT) then
			bShowConfirmation = true;
		end
	end

	if (not bShowConfirmation) then
		UnitManager.RequestOperation( pSelectedUnit, UnitOperationTypes.RANGE_ATTACK, tParameters);
	else
		local plotID = Map.GetPlotIndex(tParameters[UnitOperationTypes.PARAM_X], tParameters[UnitOperationTypes.PARAM_Y]);
		LuaEvents.ShowAttackPreview(true, cancelFunc, rangeAttackFunc, plotID);
	end
end
-- END ASPYR

-- ===========================================================================
-- Mod Misc Tool: 创建游戏时把城邦数量拉满，并记录玩家原本选择的城邦数量
--
-- 只在“创建游戏”（AdvancedSetup / ScenarioSetup）上下文生效：这些界面会先
-- include GameSetupLogic（其中定义了全局函数 MapSize_ValueChanged），其它
-- 上下文（如 InGame）没有这个全局函数，因此不会误改对局内的设置。
--
-- 幽灵玩家池需要富余的城邦槽位，但不该真的改掉玩家选的城邦数量：
-- 这里把 GameConfiguration 的 CITY_STATE_COUNT 拉满，同时用 WriteCustomData
-- 记下玩家最后选择的数量；进游戏后由 ModTool_GhostPlayers.lua 按这个数量把
-- 多出来的城邦搬到地图外（保持玩家原本的城邦数量不变）。
--
-- [部分可用] WriteCustomData / ReadCustomData 的生命周期 = 进程内：
--   同进程“设置界面 → 对局内”读得到（本 hook 正是靠它工作）；
--   完全退出进程后重开新局读不到（实测两次启动探针均为 VERDICT=first-write）。
--   所以只能当传递通道，不能当持久化存储。
-- ===========================================================================

-- 构建标记：前端与 gameplay 是不同 context，各自带一份字面量
-- A…E 见历史；F：存储探针；G：封装成模块；H：键值清单+遗留档清理；I：暴露接口；J：修外来查询污染
-- K：城邦幽灵也要 mod 申报（申报表/闸门/池计划）；L：高级选项改开关后立即重算申报
-- M：撤高级选项；**本工具只接受申报**，数量由声明方（Vassal System）给，新增动态申报接口
-- RELEASE：2026-10-15 发布态（调试面板侧栏入口关闭；城邦面板加固补丁 + 界面自愈随发）
local MODMISC_HOOK_BUILD_TAG = "2026-10-15-RELEASE"
local GHOST_CITY_STATE_CUSTOM_DATA_KEY = "ModMiscToolCityStateCount"
local GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY = "ModMiscToolMajorPlayerCount"

-- ===========================================================================
-- 【2026-10-15 授权者】本工具**只负责接受申报**，幽灵数量由其它 mod 决定
--
-- 申报渠道（本工具自己**不申报任何数量**，只汇总声明方的值）：
--   ① 数据通道（默认）：声明方在自己的 FrontEndActions → UpdateDatabase 里往
--      ModMiscGhostDemand 表插行（表由本框架建；范例 Vassal System/Vassal_GhostDemand.sql）。
--   ② 动态通道（ExposedMembers，给能在前端跑代码的 mod）：RegisterGhostDemand /
--      RegisterCityStateGhostDemand（一次性）、RegisterGhostDemandProvider（每次刷新调一次，
--      返回 主流数, 城邦数；契约：必须便宜）。
--   没人申报 ⇒ 该类幽灵为 0（这是硬规则，见下方“幽灵玩家需求申报”一节）。
--
-- 数量策略属于**声明方**：默认 Vassal System 按地图尺寸声明 4..24（见 §2.8b），
-- 要改数量改那边的 SQL，不用动本文件。
-- 本工具只做两件事：汇总申报值 + 用两个既有闸门夹住：
--   * 幽灵总预算：该尺寸能多要多少城邦槽位（GHOST_CITY_STATE_BY_MAP_SIZE）；
--   * 槽位余量：MaxPlayers − 玩家自选主流 − 玩家自选城邦 − 城邦幽灵（防开局被挤爆）。
-- ⚠️ 申报方别把数量开太大：引擎在地图生成阶段要给这些玩家找出生点，塞不下会开局失败。
-- ===========================================================================

-- 【策略】重建幽灵池：**主流与城邦两类都只有 mod 申报需求时才产生**。
-- 复制城邦文明已废弃，城邦侧用数据库原有的 36 个城邦文明。
local GHOST_RAISE_MAJOR_CAP = true
local m_GhostNextCityStateTarget = nil
local m_GhostPlanApplied = false
local m_GhostPlanMajorTarget = nil
local m_GhostPlanCityTarget = nil
-- 这份计划是按哪一组申报需求算的（主流/城邦各一个数）；申报一变就要重算
local m_GhostPlanDemandKey = nil
-- 上次由**我们**抬上去的城邦数 / 参与玩家数（nil = 当前没抬过），以及那之前玩家自己
-- 选的数量。分开记是因为这两个设置都会被本 hook 改写：算幽灵预算必须用“玩家自己选的数”，
-- 用被抬过的值当基数会层层加码；撤销申报（计划归零）时也要把玩家自己的选择还回去。
local m_GhostAppliedCityCount = nil
local m_GhostPlanCityPlayerChoice = nil
local m_GhostAppliedMajorCount = nil
local m_GhostPlanMajorPlayerChoice = nil

-- 玩家自己选的城邦数：若当前值正是我们上次抬上去的那个，就沿用当时记下的选择值。
local function ModMiscToolGetPlayerCityStateChoice()
	local current = GameConfiguration.GetValue("CITY_STATE_COUNT") or 0
	if m_GhostAppliedCityCount ~= nil and current == m_GhostAppliedCityCount
		and m_GhostPlanCityPlayerChoice ~= nil then
		return m_GhostPlanCityPlayerChoice
	end
	return current
end

-- 玩家自己选的主要文明人数（不含隐藏槽位）：判定同上（参与人数也会被本 hook 抬）。
local function ModMiscToolGetPlayerMajorChoice(participatingCount, hiddenCount)
	if m_GhostAppliedMajorCount ~= nil and participatingCount == m_GhostAppliedMajorCount
		and m_GhostPlanMajorPlayerChoice ~= nil then
		return m_GhostPlanMajorPlayerChoice
	end
	return participatingCount - (hiddenCount or 0)
end

-- ===========================================================================
-- 幽灵玩家需求申报（前端 setup 上下文）
--
-- 其它 mod 在 FrontEndActions 里调用：
--   ModMiscToolRegisterGhostDemand(source, count)            申报**主流**幽灵槽位
--   ModMiscToolRegisterCityStateGhostDemand(source, count)   申报**城邦**幽灵槽位
-- Mod Misc Tool 汇总后再决定抬多少主要文明数量 / 城邦数量。
--
-- 【硬规则】两类幽灵都必须申报才产生：没申报 ⇒ 该类幽灵数为 0。
--   城邦侧因此连城邦槽位都不会多要（CITY_STATE_COUNT 保持玩家自己的选择），
--   进游戏后的城邦幽灵 pass 自然也搬不出玩家来。
-- ===========================================================================
ModMiscToolGhostDemands = ModMiscToolGhostDemands or {}
ModMiscToolCityStateGhostDemands = ModMiscToolCityStateGhostDemands or {}

-- 两张申报表共用同一套登记/汇总逻辑（同一功能不重复实现）
local function ModMiscToolRegisterDemand(registry, source, count)
	local key = tostring(source or "anonymous")
	registry[key] = math.max(0, math.floor(tonumber(count) or 0))
end

local function ModMiscToolGetDemandTotal(registry)
	local total = 0
	for _, count in pairs(registry) do
		total = total + (tonumber(count) or 0)
	end
	return total
end

function ModMiscToolRegisterGhostDemand(source, count)
	ModMiscToolRegisterDemand(ModMiscToolGhostDemands, source, count)
end

function ModMiscToolRegisterCityStateGhostDemand(source, count)
	ModMiscToolRegisterDemand(ModMiscToolCityStateGhostDemands, source, count)
end

function ModMiscToolGetGhostDemandTotal()
	return ModMiscToolGetDemandTotal(ModMiscToolGhostDemands)
end

function ModMiscToolGetCityStateGhostDemandTotal()
	return ModMiscToolGetDemandTotal(ModMiscToolCityStateGhostDemands)
end

-- 当前申报汇总（主流/城邦各一个数）：用来判断“这份幽灵计划还算不算数”。
-- 必须定义在**所有**调用点之前（Lua 5.1 里后定义的 local 在函数体里会解析成全局 nil）。
local function ModMiscToolGhostDemandKey()
	return tostring(ModMiscToolGetGhostDemandTotal()) .. "/"
		.. tostring(ModMiscToolGetCityStateGhostDemandTotal())
end

if ExposedMembers ~= nil then
	if ExposedMembers.ModMiscToolUI == nil then
		ExposedMembers.ModMiscToolUI = {}
	end
	ExposedMembers.ModMiscToolUI.RegisterGhostDemand = ModMiscToolRegisterGhostDemand
	ExposedMembers.ModMiscToolUI.RegisterCityStateGhostDemand =
		ModMiscToolRegisterCityStateGhostDemand
	ExposedMembers.ModMiscToolUI.GetGhostDemandTotal = ModMiscToolGetGhostDemandTotal
	ExposedMembers.ModMiscToolUI.GetCityStateGhostDemandTotal =
		ModMiscToolGetCityStateGhostDemandTotal
end

local function ModMiscToolIsGameSetupContext()
	return MapSize_ValueChanged ~= nil
end

-- 前端界面识别：三个界面各有一个只属于自己的控件。
-- 两个前端探针（配置档 / 普通存档）都要用它，所以放这里共用，别在各处再抄一遍。
function ModMiscToolFrontEndContextKind()
	if Controls == nil then return nil end
	if Controls.ScenarioDescription ~= nil then return "ScenarioSetup" end
	if Controls.SaveConfig ~= nil then return "AdvancedSetup" end
	if Controls.MainMenuOptionStack ~= nil then return "MainMenu" end
	return nil
end

local m_GhostLastPollKey = nil

-- ===========================================================================
-- 城邦数量策略：**按地图尺寸，唯一来源就是这张表**
--
-- 分工（2026-10-04 授权者定）：数据库（GhostPlayers_MapSizes.sql）只负责把天花板
-- 拉满到 62；**每个尺寸具体请求多少城邦玩家，全部由这张表决定**。
-- 调策略只改这里，不用重打数据库，也不依赖 SQL 能不能对上尺寸列。
--
-- 【幽灵池】池子 = 请求的城邦数 − 玩家自己选择的城邦数。
-- 例：HUGE 配 62、玩家选 6 → 请求 62 → 开局后 56 个城邦被搬到地图外当幽灵。
--
-- 【硬上限】62 = MAX_PLAYERS(64) − 野蛮人 − 自由城市两个固定槽位。
-- 请求值最终会被夹到 min(表里的值, 数据库天花板, 62)，并且不会低于玩家自己的选择。
-- ===========================================================================
local GHOST_CITY_STATE_BY_MAP_SIZE = {
	MAPSIZE_DUEL     = 16,
	MAPSIZE_TINY     = 28,
	MAPSIZE_SMALL    = 40,
	MAPSIZE_STANDARD = 52,
	MAPSIZE_LARGE    = 62,
	MAPSIZE_HUGE     = 62,
}
-- 尺寸名认不出时的兜底（宁可保守；诊断日志会把真实取值打出来，照实补表即可）
local GHOST_CITY_STATE_DEFAULT = 40
local GHOST_CITY_STATE_HARD_LIMIT = 62

-- 把各种形态的“地图尺寸”值规范成 MAPSIZE_XXX：
--   * 字符串且含 "MAPSIZE_" → 直接用
--   * 表（GameSetupLogic 里是 p.Value.Domain / p.Value.Value）→ 取 .Value / .MapSizeType
--   * 其它（例如地图文件名）→ 认不出，返回 nil
local function ModMiscToolNormalizeMapSizeKey(value)
	if value == nil then return nil end
	if type(value) == "table" then
		value = value.Value or value.MapSizeType or value.MapSize
	end
	if value == nil then return nil end
	local text = tostring(value)
	if string.find(text, "MAPSIZE_") ~= nil then return text end
	-- 原版 map 脚本（Continents.lua）把 Map.GetMapSize() 的返回值直接当 MapSizeType
	-- 字符串用，所以这里也认“MAPSIZE_”开头的写法；大写后再判一次，防大小写差异
	local upper = string.upper(text)
	if string.find(upper, "MAPSIZE_") ~= nil then return upper end
	return nil
end

-- ===========================================================================
-- [诊断] 把 MapSizes 的真实内容 + 三种“取地图尺寸”的写法都打出来
--
-- 背景：按 MapSizeType 分档抬上限的 SQL **实测没生效**（三个尺寸全是原版值），
-- 而数据库报错不会进 Lua.log —— 所以只能让 mod 自己把真东西读出来看。
-- mapSize=nil 说明 MapConfiguration.GetValue("MapSize") 不是我们以为的形态，
-- 这里把三种候选写法的返回值（类型 + 内容）一并打出来，下次照实修即可。
-- 只在前端“创建游戏”界面里、值变化时打一次，不刷屏。
-- ===========================================================================
-- 当前地图尺寸的标识（"MAPSIZE_HUGE" 之类）。
--
-- 实测（2026-10-04 诊断探针）：
--   MapConfiguration.GetValue("MapSize")  -> nil
--   GameConfiguration.GetValue("MapSize") -> nil
--   MapConfiguration.GetMapSize()         -> **数字**（-601637951），是尺寸名的哈希
-- 所以先用字符串来源试；拿不到就用 GetMapSize() 的哈希去和六个尺寸名的哈希比对 ——
-- `DB.MakeHash` 用的是引擎自己的哈希，能对上就没问题。
local GHOST_MAP_SIZE_TEXT_BY_KEY = {
	MAPSIZE_DUEL     = "MAPSIZE_DUEL",
	MAPSIZE_TINY     = "MAPSIZE_TINY",
	MAPSIZE_SMALL    = "MAPSIZE_SMALL",
	MAPSIZE_STANDARD = "MAPSIZE_STANDARD",
	MAPSIZE_LARGE    = "MAPSIZE_LARGE",
	MAPSIZE_HUGE     = "MAPSIZE_HUGE",
}

-- 返回：key, 诊断信息（认不出时给出原始哈希与六个候选哈希，便于事后比对）
local function ModMiscToolGetMapSizeKey()
	-- ① 字符串来源
	local candidates = {
		function()
			if MapConfiguration == nil or MapConfiguration.GetValue == nil then return nil end
			return MapConfiguration.GetValue("MapSize")
		end,
		function()
			if GameConfiguration == nil or GameConfiguration.GetValue == nil then return nil end
			return GameConfiguration.GetValue("MapSize")
		end,
	}
	for _, getter in ipairs(candidates) do
		local ok, value = pcall(getter)
		if ok then
			local key = ModMiscToolNormalizeMapSizeKey(value)
			if key ~= nil then return key, "string" end
		end
	end

	-- ② 哈希来源：MapConfiguration.GetMapSize()
	if MapConfiguration == nil or MapConfiguration.GetMapSize == nil then
		return nil, "no GetMapSize"
	end
	local ok, raw = pcall(function() return MapConfiguration.GetMapSize() end)
	if not ok or raw == nil then
		return nil, "GetMapSize 取不到"
	end
	if DB == nil or DB.MakeHash == nil then
		return nil, "raw=" .. tostring(raw) .. "（DB.MakeHash 不可用，无法比对）"
	end
	local hashes = {}
	for key, text in pairs(GHOST_MAP_SIZE_TEXT_BY_KEY) do
		local hashOk, hash = pcall(function() return DB.MakeHash(text) end)
		if hashOk then
			hashes[key] = hash
			if hash == raw then return key, "hash" end
		end
	end
	local parts = {}
	for key, hash in pairs(hashes) do
		table.insert(parts, key .. "=" .. tostring(hash))
	end
	return nil, "raw=" .. tostring(raw) .. " 不等于任何候选（" .. table.concat(parts, " ") .. "）"
end

-- 取地图尺寸的逻辑**只此一份**：这里是 local function，别的文件用不到，
-- 所以显式导出成全局给其它模块复用（例：UI/ModMiscCreateGame.lua 的指纹要用它读尺寸）。
-- 需要在别处再用一次时请调这个全局，不要在别的文件里重写一遍哈希比对。
ModMiscToolResolveMapSizeKey = ModMiscToolGetMapSizeKey

-- 【开关】地图尺寸诊断：排查“尺寸识别/上限没生效”时打开。
-- 曾经默认开着，但每个 context 会刷 30+ 行（整张 MapSizes 逐行打），
-- 2026-10-04 确认尺寸识别与分档都正常后改回默认关闭。
-- 打开方式：改成 true，重新打包；只在“创建游戏”界面里打。
local MODMISC_MAPSIZE_DIAG_ENABLED = false

-- 每个 context 各打一次（原来一次性开关只在 MainMenu 打过，而那里地图还没配置）
local m_MapSizeDiagByContext = {}

local function ModMiscToolDumpMapSizeDiagnostics()
	if not MODMISC_MAPSIZE_DIAG_ENABLED then return end
	local contextID = "?"
	if ContextPtr ~= nil and ContextPtr.GetID ~= nil then
		local ok, id = pcall(function() return ContextPtr:GetID() end)
		if ok and id ~= nil then contextID = tostring(id) end
	end
	if m_MapSizeDiagByContext[contextID] then return end
	m_MapSizeDiagByContext[contextID] = true
	print("[ModMiscTool][MapSizeDiag] === 上下文 " .. contextID .. " ===")

	local function Describe(label, getter)
		local ok, value = pcall(getter)
		if not ok then
			print("[ModMiscTool][MapSizeDiag] " .. label .. " -> 调用失败: " .. tostring(value))
			return
		end
		local kind = type(value)
		local text = tostring(value)
		if kind == "table" then
			local parts = {}
			for k, v in pairs(value) do
				table.insert(parts, tostring(k) .. "=" .. tostring(v))
			end
			text = "{" .. table.concat(parts, ", ") .. "}"
		end
		print("[ModMiscTool][MapSizeDiag] " .. label .. " -> " .. kind .. " : " .. text)
	end

	Describe("MapConfiguration.GetValue(\"MapSize\")", function()
		return MapConfiguration.GetValue("MapSize")
	end)
	Describe("GameConfiguration.GetValue(\"MapSize\")", function()
		return GameConfiguration.GetValue("MapSize")
	end)
	Describe("MapConfiguration.GetMapSize()", function()
		return MapConfiguration.GetMapSize()
	end)
	Describe("MapConfiguration.GetMaxMinorPlayers()", function()
		return MapConfiguration.GetMaxMinorPlayers()
	end)

	-- GetMapSize() 实测返回数字；这里把六个尺寸名的哈希、以及当前地图文件的哈希
	-- 一并算出来，直接对照就知道它到底是什么
	if DB ~= nil and DB.MakeHash ~= nil then
		local hashes = {}
		for key, text in pairs(GHOST_MAP_SIZE_TEXT_BY_KEY) do
			local ok, hash = pcall(function() return DB.MakeHash(text) end)
			if ok then table.insert(hashes, key .. "=" .. tostring(hash)) end
		end
		print("[ModMiscTool][MapSizeDiag] DB.MakeHash 六个尺寸：" .. table.concat(hashes, " "))

		local mapOk, mapValue = pcall(function() return MapConfiguration.GetValue("Map") end)
		if mapOk and mapValue ~= nil then
			local mapText = tostring(mapValue)
			local hashOk, mapHash = pcall(function() return DB.MakeHash(mapText) end)
			print("[ModMiscTool][MapSizeDiag] 当前地图=" .. mapText
				.. " 其哈希=" .. (hashOk and tostring(mapHash) or "?"))
		else
			print("[ModMiscTool][MapSizeDiag] MapConfiguration.GetValue(\"Map\") 取不到")
		end
	end
	Describe("MapConfiguration.GetMaxMajorPlayers()", function()
		return MapConfiguration.GetMaxMajorPlayers()
	end)

	-- 数据库里到底存了什么：把 MapSizes 逐行打出来（只看城邦/玩家上限两个关键列）
	if DB == nil or DB.ConfigurationQuery == nil then
		print("[ModMiscTool][MapSizeDiag] DB.ConfigurationQuery 不可用")
		return
	end
	local ok, rows = pcall(function()
		return DB.ConfigurationQuery("SELECT Domain, MapSizeType, MaxPlayers, MaxCityStates FROM MapSizes")
	end)
	if not ok or rows == nil then
		print("[ModMiscTool][MapSizeDiag] 查询 MapSizes 失败: " .. tostring(rows))
		return
	end
	print("[ModMiscTool][MapSizeDiag] MapSizes 共 " .. tostring(#rows) .. " 行：")
	for _, row in ipairs(rows) do
		print("[ModMiscTool][MapSizeDiag]   domain=" .. tostring(row.Domain)
			.. " type=" .. tostring(row.MapSizeType)
			.. " maxPlayers=" .. tostring(row.MaxPlayers)
			.. " maxCityStates=" .. tostring(row.MaxCityStates))
	end
end

-- 计算“旧策略下会多出来的城邦幽灵总数”，再按申报需求和地图上限拆成主流/城邦两部分。
-- 【硬规则】两类幽灵**各自都要有申报**才分到数量：没申报的那一类就是 0。
-- cityStateChoice：**玩家自己选**的城邦数（不是本 hook 抬上去的值），由调用方传入。
local function ModMiscToolGetGhostSplit(cityStateChoice, majorChoice)
	local current = cityStateChoice
	local maxCityStates = MapConfiguration.GetMaxMinorPlayers()
	if current == nil or maxCityStates == nil or current <= 0 or maxCityStates <= 0 then
		return 0, 0, 0
	end
	if current >= maxCityStates then return 0, 0, 0 end

	local mapSizeKey = ModMiscToolGetMapSizeKey()
	-- 这张表只负责“幽灵总预算”（该尺寸下最多能多要多少城邦槽位），不区分幽灵类型。
	local target = GHOST_CITY_STATE_BY_MAP_SIZE[mapSizeKey]
	if target == nil then target = GHOST_CITY_STATE_DEFAULT end
	if target > maxCityStates then target = maxCityStates end
	if target > GHOST_CITY_STATE_HARD_LIMIT then target = GHOST_CITY_STATE_HARD_LIMIT end
	if target < current then target = current end

	local totalGhosts = target - current
	local declaredMajorGhosts = ModMiscToolGetGhostDemandTotal()
	local declaredCityStateGhosts = ModMiscToolGetCityStateGhostDemandTotal()
	-- 主流幽灵：申报多少就是多少（申报值来自声明方，见 ModMiscToolRefreshGhostDemandProviders），
	-- 这里只受“幽灵总预算”限制 —— 没有第二套上限/拉满逻辑。
	local majorGhosts = 0
	if declaredMajorGhosts > 0 then
		majorGhosts = math.min(declaredMajorGhosts, totalGhosts)
	end
	-- 城邦幽灵同样必须申报：没申报 ⇒ 0（前端不多要城邦槽位，局内也就没有城邦幽灵可搬）。
	local cityStateGhosts = 0
	if declaredCityStateGhosts > 0 then
		cityStateGhosts = math.min(declaredCityStateGhosts, totalGhosts - majorGhosts)
	end

	-- “总槽位”闸：主流幽灵 + 城邦幽灵 + 玩家自选的两项不能超过引擎的 MaxPlayers，
	-- 否则开局会被挤爆（申报值不大，这道闸只在极端配置下才夹到人）。
	local maxMajorPlayers = MapConfiguration.GetMaxMajorPlayers() or 62
	local slotRoom = maxMajorPlayers - (majorChoice or 0) - current - cityStateGhosts
	if slotRoom < 0 then slotRoom = 0 end
	local slotNote = "槽位余量=" .. tostring(slotRoom)
	if majorGhosts > slotRoom then
		majorGhosts = slotRoom
		slotNote = slotNote .. " ⇒ 主流幽灵夹到 " .. tostring(majorGhosts)
	end
	print("[ModMiscTool][Ghost][MajorPlan] 地图=" .. tostring(mapSizeKey)
		.. " 申报=" .. tostring(declaredMajorGhosts)
		.. " 玩家自选 major=" .. tostring(majorChoice) .. " cityState=" .. tostring(current)
		.. " maxPlayers=" .. tostring(maxMajorPlayers)
		.. " 总预算=" .. tostring(totalGhosts)
		.. " ⇒ 主流幽灵=" .. tostring(majorGhosts) .. " 城邦幽灵=" .. tostring(cityStateGhosts)
		.. " " .. slotNote)

	return totalGhosts, majorGhosts, cityStateGhosts
end

-- 城邦幽灵池计划（本局打算产生多少个城邦幽灵槽位）：
-- 只在变化时写进随档协议，供对局内的城邦幽灵 pass 当作**申报上限**（0 = 不产生城邦幽灵）。
local m_GhostLastSavedCityGhostPool = nil

local function ModMiscToolSaveCityStateGhostPool(count)
	count = math.max(0, math.floor(tonumber(count) or 0))
	if count == m_GhostLastSavedCityGhostPool then return end
	m_GhostLastSavedCityGhostPool = count
	local ok, err = DataProtocol.Save("ghost_citystatepool", tostring(count))
	if not ok then
		print("[ModMiscTool][Ghost] 城邦幽灵池计划写入失败 -> " .. tostring(err))
		return
	end
	print("[ModMiscTool][Ghost] 城邦幽灵池计划 = " .. tostring(count))
end

-- 城邦侧计划日志去重键（必须在城邦 pass 之前声明：Lua 5.1 里后定义的 local 在
-- 函数体里会解析成全局 nil，去重就会失效、变成每帧刷屏）
local m_GhostLastCityPlanLogKey = nil

-- 玩家自己选的城邦数：同样随档写下来（进游戏后靠它算“哪些城邦槽位是幽灵”）。
-- 与“池计划”分开：池计划可能因为申报/预算变成 0，但边界基数始终要用玩家自己的选择。
local m_GhostLastSavedCityStateChoice = nil

local function ModMiscToolSavePlayerCityStateChoice(choice)
	choice = math.max(0, math.floor(tonumber(choice) or 0))
	if choice == m_GhostLastSavedCityStateChoice then return end
	m_GhostLastSavedCityStateChoice = choice
	local ok, err = DataProtocol.Save("ghost_citystates", tostring(choice))
	if not ok then
		print("[ModMiscTool][Ghost] 城邦数量写入失败 -> " .. tostring(err))
	end
end

-- 主流侧同理：ghost_majorpool = 本局主流幽灵的申报上限（0 = 一个都不产生），
-- ghost_majorplayers = 玩家自己选的主要文明人数（局内算槽位边界）。
local m_GhostLastSavedMajorGhostPool = nil
local m_GhostLastSavedMajorChoice = nil

local function ModMiscToolSaveMajorGhostPool(count)
	count = math.max(0, math.floor(tonumber(count) or 0))
	if count == m_GhostLastSavedMajorGhostPool then return end
	m_GhostLastSavedMajorGhostPool = count
	local ok, err = DataProtocol.Save("ghost_majorpool", tostring(count))
	if not ok then
		print("[ModMiscTool][Ghost] 主流幽灵池计划写入失败 -> " .. tostring(err))
		return
	end
	print("[ModMiscTool][Ghost] 主流幽灵池计划 = " .. tostring(count))
end

local function ModMiscToolSavePlayerMajorChoice(choice)
	choice = math.max(0, math.floor(tonumber(choice) or 0))
	if choice == m_GhostLastSavedMajorChoice then return end
	m_GhostLastSavedMajorChoice = choice
	local ok, err = DataProtocol.Save("ghost_majorplayers", tostring(choice))
	if not ok then
		print("[ModMiscTool][Ghost] 主要文明人数写入失败 -> " .. tostring(err))
		return
	end
	print("[ModMiscTool][Ghost] major player choice saved = " .. tostring(choice))
end

local function ModMiscToolApplyGhostCityStates()
	if not ModMiscToolIsGameSetupContext() then return end

	local current = GameConfiguration.GetValue("CITY_STATE_COUNT")
	local maxCityStates = MapConfiguration.GetMaxMinorPlayers()

	-- 诊断：值有变化就打一行，方便确认 hook 到底有没有跑到、读到什么
	local pollKey = tostring(current) .. "/" .. tostring(maxCityStates)
	if pollKey ~= m_GhostLastPollKey then
		m_GhostLastPollKey = pollKey
		print("[ModMiscTool][Ghost] poll: CITY_STATE_COUNT=" .. tostring(current)
			.. " maxMinor=" .. tostring(maxCityStates))
	end

	-- 诊断用 pcall 兜住：它是观察工具，绝不能因为自身报错把主逻辑带崩
	-- （2026-10-04 就栽过一次：诊断里前向引用了一个后声明的 local，
	--   pairs(nil) 报错冒泡，导致整个“设置 CITY_STATE_COUNT”被跳过）
	pcall(ModMiscToolDumpMapSizeDiagnostics)

	if current == nil or maxCityStates == nil then return end
	-- 结论没变就直接返回（申报一变，主流 pass 会把 m_GhostPlanCityTarget 清空 ⇒ 自动重算）
	if m_GhostPlanCityTarget == current
		and m_GhostPlanDemandKey == ModMiscToolGhostDemandKey() then
		return end
	-- current <= 0 时不处理：避免在参数还没载入时把 0 当成“玩家选择”记下来
	if current <= 0 or maxCityStates <= 0 then return end
	if current >= maxCityStates then
		-- 城邦数已拉满 ⇒ 不可能有多余槽位，一个城邦幽灵都不产生。
		-- 边界基数也刷新成当前值，免得局内拿着旧基数去搬玩家。
		m_GhostPlanCityTarget = current
		m_GhostAppliedCityCount = nil
		ModMiscToolSaveCityStateGhostPool(0)
		ModMiscToolSavePlayerCityStateChoice(current)
		return
	end

	-- 城邦幽灵数**只认“申报分账”**：主流幽灵 pass 算好后放进 m_GhostNextCityStateTarget。
	-- 没有分账（= 没有 mod 申报城邦幽灵需求 / 预算为 0）就是 0 个 —— 不再回落到地图尺寸表：
	-- 那张表只用来算“幽灵总预算”，绝不能当成“默认产生城邦幽灵”的开关。
	--
	-- 计划值一律以**玩家自己选的城邦数**为基数：current 可能是本 hook 上一轮抬上去的值，
	-- 拿它当基数会层层加码（14 → 22 → 30…），撤销申报时也还原不回去。
	local mapSizeKey = ModMiscToolGetMapSizeKey()
	local choice = ModMiscToolGetPlayerCityStateChoice()
	local target = m_GhostNextCityStateTarget
	m_GhostNextCityStateTarget = nil

	local plannedGhosts = 0
	if target ~= nil then
		if target > maxCityStates then target = maxCityStates end
		if target > GHOST_CITY_STATE_HARD_LIMIT then target = GHOST_CITY_STATE_HARD_LIMIT end
		plannedGhosts = math.max(0, target - choice)
	end
	-- 池计划按“申报分到的数量”写（执行层无条件照办）：局内城邦 pass 拿它当申报上限
	ModMiscToolSaveCityStateGhostPool(plannedGhosts)

	if plannedGhosts <= 0 then
		-- 不产生城邦幽灵。若上一轮已经被我们抬过，这里要把玩家自己的选择**还回去**，
		-- 否则关掉申报会凭空多出一批城邦（多出来的槽位没人用）。
		ModMiscToolSavePlayerCityStateChoice(choice)
		local needRestore = (m_GhostAppliedCityCount ~= nil and current == m_GhostAppliedCityCount
			and choice ~= current)
		if needRestore then
			GameConfiguration.SetValue("CITY_STATE_COUNT", choice)
			-- 只有引擎真的接受了还原才清账本；否则保留（下一帧继续按玩家自己的选择算）
			if (GameConfiguration.GetValue("CITY_STATE_COUNT") or 0) == choice then
				m_GhostAppliedCityCount = nil
			end
			m_GhostPlanCityTarget = choice
		else
			m_GhostPlanCityTarget = current
		end
		-- 归零这条路径每帧都会走到（结论没变时由上面的守卫早退），提示按结论去重
		local cityLogKey = tostring(needRestore) .. "/" .. tostring(choice) .. "/"
			.. tostring(current)
		if cityLogKey ~= m_GhostLastCityPlanLogKey then
			m_GhostLastCityPlanLogKey = cityLogKey
			if needRestore then
				print("[ModMiscTool][Ghost] 城邦幽灵计划归零 → 城邦数还原为玩家选择 "
					.. tostring(choice) .. "（原被抬到 " .. tostring(current) .. "）")
			else
				print("[ModMiscTool][Ghost] 城邦幽灵未申报 → 不产生城邦幽灵"
					.. "（keep CITY_STATE_COUNT=" .. tostring(current) .. "）")
			end
		end
		return
	end

	target = choice + plannedGhosts
	if target > maxCityStates then target = maxCityStates end
	if target > GHOST_CITY_STATE_HARD_LIMIT then target = GHOST_CITY_STATE_HARD_LIMIT end
	plannedGhosts = math.max(0, target - choice)
	if plannedGhosts <= 0 then
		m_GhostPlanCityTarget = current
		ModMiscToolSavePlayerCityStateChoice(choice)
		return
	end
	m_GhostPlanCityTarget = target
	m_GhostAppliedCityCount = target
	m_GhostPlanCityPlayerChoice = choice
	ModMiscToolSaveCityStateGhostPool(plannedGhosts)

	-- 走协议（登记项 ghost_citystates 是 persave：随档走、新局不继承）
	-- 记的是**玩家自己选的数**：进游戏后靠它算“哪些城邦槽位是幽灵”
	--（只在变化时写，见 ModMiscToolSavePlayerCityStateChoice）。
	ModMiscToolSavePlayerCityStateChoice(choice)
	if target ~= current then
		GameConfiguration.SetValue("CITY_STATE_COUNT", target)
	end
	local tableValue = GHOST_CITY_STATE_BY_MAP_SIZE[mapSizeKey]
	print("[ModMiscTool][Ghost] city states -> " .. tostring(target)
		.. " (player choice " .. tostring(choice) .. " saved"
		.. " | mapSize=" .. tostring(mapSizeKey)
		.. " tableValue=" .. tostring(tableValue)
		.. " dbCeiling=" .. tostring(maxCityStates)
		.. " -> 幽灵池 " .. tostring(plannedGhosts) .. ")")
end

-- 主要文明同理：把参与玩家数抬到“预算内允许的上限”，并记下玩家原本选择的数量。
-- 引擎只在开局按这个数量创建玩家，所以这是唯一能让主要文明多出来的途径。
-- 计划日志去重键（结论没变就不重复打）
local m_GhostLastMajorPlanLogKey = nil

-- ===========================================================================
-- 幽灵申报（**本工具只接受，数量由其它 mod 决定**，2026-10-15 授权者）
--
-- 高级选项那一行在手机/平板布局下溢出屏幕 ⇒ 已从 modinfo 里撤掉，数量也不由选项决定。
-- 声明方在前端上下文里二选一：
--   * 一次性申报：ModMiscToolRegisterGhostDemand(source, count)
--     （城邦侧：ModMiscToolRegisterCityStateGhostDemand(source, count)）
--   * 动态申报：ModMiscToolRegisterGhostDemandProvider(source, fn)，见下方刷新函数。
-- 默认声明方 = Vassal System 的 Vassal_GhostDemand.sql（主流按地图尺寸 4..24、城邦 0，
-- 要测保守行为把那边改成 8）；它由本文件末尾的“声明方清单”include 进本上下文。
-- 没人申报 ⇒ 该类幽灵为 0。
-- ===========================================================================
-- 【2026-10-15 授权者】两个池子 = 两种**附庸行为**（Vassal System 里区分开）：
--   * 主流幽灵池 = 正常玩家行为（会扩张、正常建造）；
--   * 城邦幽灵池 = 保守玩家行为（不扩张、建造的区域也少）。
--   玩家在面板里选文明时看到的主流/城邦分组只是为了找文明方便，**行为**才是选池子的依据。
-- 城邦幽灵池默认**不申报**（0）：它会把创建游戏界面的城邦数量抬高，很多玩家只看那个数字就投诉；
-- 但框架按“城邦幽灵池存在”来写 —— 声明方把它申报成一个正数（例如 8）就能开回来测保守行为。
-- ===========================================================================

-- ===========================================================================
-- 数据通道：**声明表**（数量由声明方决定，本工具只读表 + 汇总）
--
-- 表结构由本框架建（GhostPlayers_MapSizes.sql），声明方在自己的
-- FrontEndActions → UpdateDatabase 里插行（范例：Vassal System/Vassal_GhostDemand.sql）：
--   ModMiscGhostDemand(Source TEXT, MapSizeType TEXT, MajorGhosts INTEGER, CityStateGhosts INTEGER)
--   MapSizeType = 'MAPSIZE_XXX'（精确行，对应尺寸）/ '*'（兜底行，尺寸认不出时用）
-- 同一个 Source 只取一条：有精确行就用精确行，否则用 '*' 兜底行。
-- 【性能】按地图尺寸**原始值**缓存：值没变就不重查（每帧成本 = 一次 GetMapSize + 一次比较）。
-- 表不存在（没装声明方 / 没建表）⇒ 视为没人申报，只记一行日志。
-- ===========================================================================
local m_GhostDemandTableRawSize = nil
local m_GhostDemandTableSizeKey = nil
local m_GhostDemandTableRows = nil      -- { [source] = { major = n, cityState = m } }

-- 拼接进 SQL 的动态部分只有地图尺寸名；洗成 [A-Za-z0-9_] 后再用（表名/列名都是常量）
local function ModMiscToolSanitizeSqlToken(text)
	return (tostring(text or ""):gsub("[^A-Za-z0-9_]", ""))
end

-- 返回：bySource 表, 查询是否成功（成功但没有行也是成功）
local function ModMiscToolQueryGhostDemandTable(mapSizeKey)
	if DB == nil then return nil, false end
	local query = DB.ConfigurationQuery or DB.Query
	if query == nil then return nil, false end
	local sql = "SELECT Source, MapSizeType, MajorGhosts, CityStateGhosts FROM ModMiscGhostDemand"
		.. " WHERE MapSizeType = '" .. ModMiscToolSanitizeSqlToken(mapSizeKey) .. "' OR MapSizeType = '*'"
	local ok, rows = pcall(function() return query(sql) end)
	if not ok or type(rows) ~= "table" then return nil, false end
	local bySource = {}
	for _, row in ipairs(rows) do
		local source = tostring(row.Source or "anonymous")
		local isExact = (mapSizeKey ~= nil and tostring(row.MapSizeType) == tostring(mapSizeKey))
		local entry = bySource[source]
		-- 精确行优先：先来的兜底行会被后来的精确行顶掉，反之不顶
		if entry == nil or isExact then
			bySource[source] = {
				major = math.max(0, math.floor(tonumber(row.MajorGhosts) or 0)),
				cityState = math.max(0, math.floor(tonumber(row.CityStateGhosts) or 0)),
			}
		end
	end
	return bySource, true
end

local function ModMiscToolLoadGhostDemandTable()
	local raw = nil
	if MapConfiguration ~= nil and MapConfiguration.GetMapSize ~= nil then
		local ok, value = pcall(function() return MapConfiguration.GetMapSize() end)
		if ok then raw = value end
	end
	-- 尺寸没变 ⇒ 直接用上次读到的行（这是“不每帧查表”的关键）
	if m_GhostDemandTableRows ~= nil and raw ~= nil and raw == m_GhostDemandTableRawSize then
		return m_GhostDemandTableRows
	end
	local mapSizeKey = ModMiscToolGetMapSizeKey()
	if m_GhostDemandTableRows ~= nil and raw == nil and mapSizeKey == m_GhostDemandTableSizeKey then
		return m_GhostDemandTableRows
	end

	local bySource, queryOk = ModMiscToolQueryGhostDemandTable(mapSizeKey)
	if not queryOk then
		bySource = {}
		print("[ModMiscTool][Ghost][DemandTable] 声明表不可用（没装声明方或没建表）⇒ 本轮按 0 算")
	else
		local parts = {}
		for source, demand in pairs(bySource) do
			table.insert(parts, source .. " major=" .. tostring(demand.major)
				.. " city=" .. tostring(demand.cityState))
		end
		table.sort(parts)
		print("[ModMiscTool][Ghost][DemandTable] 地图=" .. tostring(mapSizeKey)
			.. " 声明 " .. tostring(#parts) .. " 条"
			.. (#parts > 0 and ("：" .. table.concat(parts, "、")) or "（没有声明行）"))
	end
	m_GhostDemandTableRawSize = raw
	m_GhostDemandTableSizeKey = mapSizeKey
	m_GhostDemandTableRows = bySource
	return bySource
end

-- 把声明表的行写进申报表（在动态申报方之前调用，动态值可以覆盖它）
local function ModMiscToolApplyGhostDemandTable()
	local bySource = ModMiscToolLoadGhostDemandTable()
	for source, demand in pairs(bySource) do
		ModMiscToolRegisterGhostDemand(source, demand.major)
		ModMiscToolRegisterCityStateGhostDemand(source, demand.cityState)
	end
end

-- 动态申报表：source → fn()，fn 返回 主流数, 城邦数（nil = 这一类不变）。
-- 【契约】fn 每次前端刷新都会被调一次，所以必须便宜（查表/比较级别）；
--   需要地图尺寸的，请自己按“原始值变化”缓存（声明表通道就是这么做的）。
ModMiscToolGhostDemandProviders = ModMiscToolGhostDemandProviders or {}

function ModMiscToolRegisterGhostDemandProvider(source, provider)
	local key = tostring(source or "anonymous")
	if type(provider) ~= "function" then
		ModMiscToolGhostDemandProviders[key] = nil
		return nil
	end
	ModMiscToolGhostDemandProviders[key] = provider
	print("[ModMiscTool][Ghost] 已登记动态申报方：" .. key)
	return key
end

if ExposedMembers ~= nil then
	if ExposedMembers.ModMiscToolUI == nil then
		ExposedMembers.ModMiscToolUI = {}
	end
	ExposedMembers.ModMiscToolUI.RegisterGhostDemandProvider = ModMiscToolRegisterGhostDemandProvider
end

-- 把动态申报方的最新值写进申报表（在算幽灵计划之前调用）
local function ModMiscToolRefreshGhostDemandProviders()
	for source, provider in pairs(ModMiscToolGhostDemandProviders) do
		local ok, major, cityState = pcall(provider)
		if not ok then
			print("[ModMiscTool][Ghost] 申报函数报错（本轮跳过）：" .. tostring(source)
				.. " -> " .. tostring(major))
		else
			if tonumber(major) ~= nil then
				ModMiscToolRegisterGhostDemand(source, major)
			end
			if tonumber(cityState) ~= nil then
				ModMiscToolRegisterCityStateGhostDemand(source, cityState)
			end
		end
	end
end


local function ModMiscToolApplyGhostMajorPlayers()
	if not ModMiscToolIsGameSetupContext() then return end

	local current = GameConfiguration.GetParticipatingPlayerCount()
	local hidden = GameConfiguration.GetHiddenPlayerCount()
	local maxMajorPlayers = MapConfiguration.GetMaxMajorPlayers()
	if current == nil or hidden == nil or maxMajorPlayers == nil then return end
	if current <= 0 or maxMajorPlayers <= 0 then return end

	-- 玩家自己选的人数：current 可能是上一轮被本 hook 抬上去的值，不能直接当“玩家选择”。
	local configured = ModMiscToolGetPlayerMajorChoice(current, hidden)
	if configured <= 0 then return end

	-- 取声明方的最新申报值：① 数据通道（ModMiscGhostDemand 声明表，默认）
	-- ② 动态通道（ExposedMembers 接口，可覆盖声明表）。都放在比对计划之前，
	-- 这样申报一变（例如换了地图尺寸）计划就自动重算。
	ModMiscToolApplyGhostDemandTable()
	ModMiscToolRefreshGhostDemandProviders()

	local currentCityStates = GameConfiguration.GetValue("CITY_STATE_COUNT") or 0
	local demandKey = ModMiscToolGhostDemandKey()
	-- 同一组“玩家选择 + 申报需求”只执行一次；任一项变了都自动重算。
	if m_GhostPlanApplied and m_GhostPlanMajorTarget == current
		and m_GhostPlanCityTarget == currentCityStates
		and m_GhostPlanDemandKey == demandKey then
		return
	end
	m_GhostPlanApplied = false
	m_GhostPlanCityTarget = nil
	-- 本轮申报汇总（主流/城邦各一个数）：城邦侧也用同一把尺子判断结论是否过期
	m_GhostPlanDemandKey = demandKey

	-- 无论是否真正抬高，都记下玩家原本选择的主要文明人数，供进游戏后算边界
	--（记的是**玩家自己的选择**，不是被本 hook 抬过的值）。
	ModMiscToolSavePlayerMajorChoice(configured)

	-- 定制附庸入口常开（选项已撤，对局内 IsVassalCustomVassalEnabledUI 读到 "1" 即启用）
	if DataProtocol ~= nil and DataProtocol.Save ~= nil then
		pcall(function() DataProtocol.Save("vassal_custom_vassal_enabled", "1") end)
	end

	-- 幽灵总预算沿用旧策略的“多出来的城邦数”，再按申报需求/地图上限分给主流/城邦。
	-- 【硬规则】两类幽灵各自都要申报，没申报的那一类是 0（判定都在 ModMiscToolGetGhostSplit 里）。
	-- 基数用**玩家自己选的城邦数**：currentCityStates 可能是上一轮被本 hook 抬上去的值。
	local cityStateChoice = ModMiscToolGetPlayerCityStateChoice()
	local totalGhosts, majorGhosts, cityGhosts = ModMiscToolGetGhostSplit(cityStateChoice, configured)
	if totalGhosts <= 0 then return end

	-- 主流上限开关关掉时主流幽灵数为 0；它没用的预算**不自动退回城邦**
	--（城邦侧只按自己的申报值走），否则关掉主流反而会凭空多出城邦幽灵。
	if not GHOST_RAISE_MAJOR_CAP then majorGhosts = 0 end

	local desiredMajorTarget = configured + majorGhosts
	if desiredMajorTarget > maxMajorPlayers then desiredMajorTarget = maxMajorPlayers end
	if desiredMajorTarget < configured then desiredMajorTarget = configured end
	local actualMajorGhosts = desiredMajorTarget - configured

	-- 主流放不下/没放完的部分可以退回城邦，但城邦侧同样不得超过它自己的申报值。
	-- 目标值以**玩家自己选的城邦数**为基数（不能用被抬过的 currentCityStates）。
	local remainingCityGhosts = math.max(0, math.min(cityGhosts, totalGhosts - actualMajorGhosts))
	m_GhostNextCityStateTarget = cityStateChoice + remainingCityGhosts

	-- 主流幽灵池计划（0 = 不产生）：局内主流 pass 拿它当申报上限
	ModMiscToolSaveMajorGhostPool(actualMajorGhosts)

	-- 参与人数（含隐藏）最终落到哪个值：
	--   * 有主流幽灵 ⇒ 玩家选择 + 幽灵数；
	--   * 计划归零（没申报/开关关掉）且当前值正是我们抬上去的 ⇒ **还原**成玩家自己的选择，
	--     否则玩家关掉申报后仍会拿到一堆多出来的主要文明。
	local targetWithHidden = desiredMajorTarget + hidden
	if actualMajorGhosts <= 0 and m_GhostAppliedMajorCount ~= nil
		and current == m_GhostAppliedMajorCount and configured + hidden ~= current then
		targetWithHidden = configured + hidden
	end

	local changed = false
	local restoreRejected = false
	if current ~= targetWithHidden then
		-- pcall 兜住：万一引擎不接受这个值就保持现状（局内还有申报上限这道闸门）
		local ok = pcall(function()
			GameConfiguration.SetParticipatingPlayerCount(targetWithHidden)
		end)
		if ok then
			changed = true
		else
			print("[ModMiscTool][Ghost] 参与人数设置失败，保持 " .. tostring(current))
			targetWithHidden = current
		end
	end
	if actualMajorGhosts > 0 or targetWithHidden == current then
		-- 真的抬上去了，或者计划本来就没动这个值 ⇒ 账本按现状记
		m_GhostAppliedMajorCount = (actualMajorGhosts > 0) and targetWithHidden or nil
	else
		-- 还原/下调没被引擎接受：**保留账本**，下一帧继续按“玩家自己的选择”算，
		-- 不然后面会把我们抬上去的值当成玩家的新选择（ghost_majorplayers 被写坏）。
		-- 提示放到下面那个去重块里打（这条路径每帧都会走到，不能在这里直接打）。
		restoreRejected = true
	end
	m_GhostPlanMajorPlayerChoice = configured
	m_GhostPlanMajorTarget = targetWithHidden
	m_GhostPlanApplied = true

	-- 计划每帧都会重算到“结论没变就早退”，这里按结论去重，避免刷屏
	local planKey = tostring(desiredMajorTarget) .. "/" .. tostring(actualMajorGhosts)
		.. "/" .. tostring(targetWithHidden) .. "/" .. tostring(demandKey)
	if planKey ~= m_GhostLastMajorPlanLogKey then
		m_GhostLastMajorPlanLogKey = planKey
		print("[ModMiscTool][Ghost] major players -> " .. tostring(desiredMajorTarget)
			.. " (player choice " .. tostring(configured) .. " saved"
			.. " | maxMajor=" .. tostring(maxMajorPlayers)
			.. " hidden=" .. tostring(hidden)
			.. " applied=" .. tostring(targetWithHidden)
			.. " | totalGhost=" .. tostring(totalGhosts)
			.. " majorGhost=" .. tostring(actualMajorGhosts)
			.. " cityGhost=" .. tostring(remainingCityGhosts)
			.. " demand=" .. tostring(demandKey)
			.. " changed=" .. tostring(changed) .. ")")
		if restoreRejected then
			print("[ModMiscTool][Ghost] 参与人数仍是 " .. tostring(current) .. "（目标是 "
				.. tostring(targetWithHidden) .. "），保留玩家选择 "
				.. tostring(configured))
		end
	end
end

-- ===========================================================================
-- 【发布态 2026-10-06 授权者要求】三个实验探针文件已移除：
--   UI/FrontEnd_SaveProbe.lua（前端配置档）/ UI/FrontEnd_GameSaveProbe.lua（前端普通存档）
--   / UI/LoadTime_SaveProbe.lua（载入期存档）
-- 结论保留在 API_Verification_Status.md 第 17 / 32-37 / 73 节：那三条路都实机闪退，不可行。
-- 这里不再有 include 与刷新钩子；要看历史实现请查 git（v3.10 之前）。
-- ===========================================================================

-- 跨存档数据存储（UI/ModMiscStore.lua）：把数据编进「配置档的文件名」，
-- 下一轮从存档列表读回来。**已实机验证**（写一轮 → 杀进程 → 下一轮读回，payload 逐字一致）。
-- 与上面那个探针不同，这个默认开着 —— 它是目前唯一可用的跨存档通道。
if ModMiscStore == nil and ModMiscToolIsGameSetupContext() then
	include("ModMiscStore")
end

-- 「模组配置组名字」跨存档存储（UI/ModMiscModGroupStore.lua，授权者 2026-10-05 提的方向）：
-- 写进模组框架数据库 ModGroups.Name —— 自由文本，不受存档名 255 字节限制；
-- Modding 组接口前端与对局内都能调。必须排在 ModMiscStore 之后（复用它的 hex 编解码）。
if ModMiscModGroupStore == nil then
	include("ModMiscModGroupStore")
end

-- 数据协议 + 登记表也要在前端/建局上下文里可用：
-- 建局时要往 CustomData 写城邦数量（随档数据），读它的是对局内的 Support_UI；
-- 两边都走协议，形状与校验（数据集名/校验和）才统一。
if ModMiscBigStore == nil then
	include("ModMiscBigStore")
end
if DataProtocol == nil then
	include("ModMiscDataProtocol")
	include("ModMiscDataRegistry")
end

-- 【2026-10-06 授权者结论：前端与对局内是**两套环境**】前端这里**不做任何存储写入**。
-- 原先这里跑 AutoGC（会删过期键 ⇒ 模组配置组/配置档的写），是前端侧唯一的写路径；
-- 现在清理只在**对局内**做（Support_UI 的 after-load AutoGC + 协议自己的 TTL 判定）。
-- 读取仍然允许（下面的 ExposedMembers 导出、ModMiscStore.Refresh 的扫描）。
if DataProtocol ~= nil and DataProtocol.AutoGC ~= nil and ModMiscToolDataAutoGCDone == nil then
	ModMiscToolDataAutoGCDone = true
	print("[ModMiscTool][DataProtocol] 前端上下文：按“前端零写入”策略**跳过** AutoGC"
		.. "（过期清理在对局内做）")
end

-- 前端侧也把同一套接口挂到 ExposedMembers 上（前端 context 里别的 mod 也能直接用）
if ModMiscStore ~= nil and ExposedMembers ~= nil then
	if ExposedMembers.ModMiscToolUI == nil then
		ExposedMembers.ModMiscToolUI = {}
	end
	ExposedMembers.ModMiscToolUI.SaveData = ModMiscStore.Save
	ExposedMembers.ModMiscToolUI.GetData = ModMiscStore.Get
	ExposedMembers.ModMiscToolUI.GetAllData = ModMiscStore.GetAll
	ExposedMembers.ModMiscToolUI.RemoveData = ModMiscStore.Remove
	ExposedMembers.ModMiscToolUI.RefreshData = ModMiscStore.Refresh
	ExposedMembers.ModMiscToolUI.IsDataReady = ModMiscStore.IsReady
	ExposedMembers.ModMiscToolUI.OnDataReady = ModMiscStore.OnReady
end

-- [已验证失败] Events.SystemUpdateUI 在创建游戏界面根本不触发（只分辨率变化/恢复 UI/触摸输入），
-- hook 会完全静默；因此轮询只能用 ContextPtr 的刷新回调。
-- 创建游戏界面里 SystemUpdateUI 只在分辨率变化时触发，轮询要用 ContextPtr 的刷新回调
-- （AdvancedSetup 自己没有设置刷新回调，因此这里设置是安全的）
-- ===========================================================================
-- [MapConfigProbe] 对局内写的地图/年代配置，能不能活到前端？
--
-- 背景（2026-10-05 实机）：对局内写 MAP_SCRIPT / GAME_START_ERA 之后再
-- `Network.RestartGame()`，**配置没被采纳** —— 新局还是原来的地图脚本，只是换了生成种子。
-- 但「退到主菜单 → 回创建游戏界面重新开局」是**另一条路**：那条路的配置由前端读，
-- 而这个配置对象是进程级的，所以对局内写进去的值**有可能**还在。
--
-- 所以这里在创建游戏界面把当前看到的配置打一行：
--   * 打出的是对局内写进去的目标图 ⇒ 那条路能把地图换掉（退主菜单再创建即可）
--   * 还是原来那张          ⇒ 离开对局时配置被重置，换图只能靠重启换种子
-- 只在“值变化”时打一行（隐藏时清空，重新打开界面会再打一次）；全程 pcall，
-- 出错绝不影响幽灵 hook。
-- ===========================================================================
local m_MapConfigProbeLastKey = nil

local function ModMiscToolProbeMapConfig()
	if ContextPtr:IsHidden() then
		m_MapConfigProbeLastKey = nil	-- 关掉界面就清掉，下次打开再打一行
		return
	end
	-- 主设置界面（创建游戏 / 创建场景）才有 StartButton；PC 的选择器子上下文没有
	if Controls.StartButton == nil then return end

	local parts = {}
	local function Add(label, getter)
		local ok, value = pcall(getter)
		table.insert(parts, label .. "=" .. tostring(ok and value or "err"))
	end
	Add("MAP_SCRIPT", function() return MapConfiguration.GetValue("MAP_SCRIPT") end)
	Add("GetScript", function() return MapConfiguration.GetScript() end)
	Add("MAP_SIZE", function() return MapConfiguration.GetMapSize() end)
	Add("SEED", function() return MapConfiguration.GetValue("RANDOM_SEED") end)
	Add("START_ERA", function() return GameConfiguration.GetStartEra() end)
	Add("START_TURN", function() return GameConfiguration.GetStartTurn() end)

	local key = table.concat(parts, " ")
	if key == m_MapConfigProbeLastKey then return end
	m_MapConfigProbeLastKey = key
	print("[ModMiscTool][MapConfigProbe] 创建游戏界面看到的配置: " .. key)
end


local function ModMiscToolGhostRefresh(delta)
	if not ModMiscToolIsGameSetupContext() then return end
	if not ContextPtr:IsHidden() then
		ModMiscToolApplyGhostMajorPlayers()
		ModMiscToolApplyGhostCityStates()
		ModMiscToolProbeMapConfig()
	end
	-- 探针在隐藏时也要跑：它靠“隐藏→显示”的那一刻判定新一轮（内部自己判界面）
	-- （发布态：前端探针已移除，这里不再有钩子）
	-- （发布态：前端普通存档探针已移除 —— 那条路实机闪退，结论见第 73 条）
	-- 【2026-10-06 授权者结论：前端与对局内是两套环境；前端一律不做存储副作用】
	-- 这里原先会在前端首次刷新时扫一遍存档列表（UI.QuerySaveGameList + 挂 LuaEvents 回调）。
	-- 那既没用（前端读到的跨存档数据对局内用不上），又给“退出到主界面”的拆卸期留了一个
	-- 可能在飞的引擎查询 + 已注册回调 —— 正是拆卸期崩溃的常见来源。现在**不扫**，只记一行。
	if ModMiscStore ~= nil and ModMiscStoreAutoRefreshed == nil then
		ModMiscStoreAutoRefreshed = true
		print("[ModMiscTool][Store] 前端上下文：按“前端零副作用”策略**跳过**存档列表扫描"
			.. "（要跨存档数据请在对局内看）")
	end
	ContextPtr:RequestRefresh()
end

-- 【框架边界】本工具**不去 include 任何其它 mod 的文件**（那会让框架依赖消费者，
-- 也会把别人的代码拖进本上下文）：申报只通过 ExposedMembers 上公开的接口进来
-- （RegisterGhostDemand / RegisterCityStateGhostDemand / RegisterGhostDemandProvider）。
if ModMiscToolIsGameSetupContext() then
	ContextPtr:SetRefreshHandler(ModMiscToolGhostRefresh)
	ContextPtr:RequestRefresh()
	print("[ModMiscTool][Ghost] setup hook installed (refresh handler) build="
		.. tostring(MODMISC_HOOK_BUILD_TAG))
end
