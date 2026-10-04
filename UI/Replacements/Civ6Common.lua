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
-- 2026-10-04-A：加入前端存读档探针的调用（ModTool.lua 那份 gameplay 的标记未动）
local MODMISC_HOOK_BUILD_TAG = "2026-10-04-A"
local GHOST_CITY_STATE_CUSTOM_DATA_KEY = "ModMiscToolCityStateCount"
local GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY = "ModMiscToolMajorPlayerCount"

-- 幽灵池的槽位预算：MAX_PLAYERS(64) 减去野蛮人与自由城市两个固定槽位。
-- 主要文明和城邦抢的是同一批槽位，所以给城邦预留 GHOST_RESERVED_MINOR_SLOTS 个，
-- 剩下的才给主要文明 —— 免得“主要文明拉满”把城邦挤没（城邦数量会被挤到 0）。
-- 两个常量都可以按实测结果调整。
local GHOST_SLOT_BUDGET = 62
local GHOST_RESERVED_MINOR_SLOTS = 36

-- 【策略】扩容后优先填充城邦：不再抬高主要文明数量。
-- 原因：主要文明幽灵会参与外交，且城邦化改造（改领袖/文明）本身有风险；
-- 只抬 CITY_STATE_COUNT 时引擎会给到 36 个城邦（数据库城邦文明条数上限），
-- 玩家保留自己选的 6 个，其余 30 个进幽灵池 —— 全程零外交副作用。
-- 需要重新开启时把这里改成 true（配合 ModTool_GhostPlayers.lua 的城邦化开关）。
local GHOST_RAISE_MAJOR_CAP = false

local function ModMiscToolIsGameSetupContext()
	return MapSize_ValueChanged ~= nil
end

local m_GhostLastPollKey = nil

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

	if current == nil or maxCityStates == nil then return end
	-- current <= 0 时不处理：避免在参数还没载入时把 0 当成“玩家选择”记下来
	if current <= 0 or maxCityStates <= 0 or current >= maxCityStates then return end

	WriteCustomData(GHOST_CITY_STATE_CUSTOM_DATA_KEY, current)
	GameConfiguration.SetValue("CITY_STATE_COUNT", maxCityStates)
	print("[ModMiscTool][Ghost] city states -> max " .. tostring(maxCityStates)
		.. " (player choice " .. tostring(current) .. " saved)")
end

-- 主要文明同理：把参与玩家数抬到“预算内允许的上限”，并记下玩家原本选择的数量。
-- 引擎只在开局按这个数量创建玩家，所以这是唯一能让主要文明多出来的途径。
-- 上一次写进 CustomData 的主要文明数量（只在变化时写）
local m_GhostLastSavedMajorCount = nil

local function ModMiscToolApplyGhostMajorPlayers()
	if not ModMiscToolIsGameSetupContext() then return end

	-- 策略关闭（当前）：**不抬上限**，但要把玩家设定的人数记下来 ——
	-- 进游戏后要用“主要文明数 + 城邦数”算出槽位边界，边界之后的城邦槽位全部变幽灵。
	if not GHOST_RAISE_MAJOR_CAP then
		local configured = GameConfiguration.GetParticipatingPlayerCount()
		local hidden = GameConfiguration.GetHiddenPlayerCount()
		if configured == nil or hidden == nil then return end
		configured = configured - hidden          -- 参与人数含隐藏槽位，减掉才是玩家设定的人数
		if configured <= 0 then return end
		if configured ~= m_GhostLastSavedMajorCount then
			m_GhostLastSavedMajorCount = configured
			WriteCustomData(GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY, configured)
			print("[ModMiscTool][Ghost] major players (configured, not raised) = "
				.. tostring(configured))
		end
		return
	end

	local current = GameConfiguration.GetParticipatingPlayerCount()
	local hidden = GameConfiguration.GetHiddenPlayerCount()
	local maxMajorPlayers = MapConfiguration.GetMaxMajorPlayers()
	if current == nil or maxMajorPlayers == nil then return end
	if hidden == nil then hidden = 0 end
	if current <= 0 or maxMajorPlayers <= 0 then return end

	local majorTarget = GHOST_SLOT_BUDGET - GHOST_RESERVED_MINOR_SLOTS
	if majorTarget > maxMajorPlayers then majorTarget = maxMajorPlayers end
	if majorTarget < 2 then majorTarget = math.min(maxMajorPlayers, 2) end
	-- 参与玩家数含隐藏槽位，两边口径要一致
	majorTarget = majorTarget + hidden
	if current >= majorTarget then return end

	WriteCustomData(GHOST_MAJOR_PLAYER_CUSTOM_DATA_KEY, current)
	GameConfiguration.SetParticipatingPlayerCount(majorTarget)
	print("[ModMiscTool][Ghost] major players -> " .. tostring(majorTarget)
		.. " (player choice " .. tostring(current) .. " saved"
		.. " maxMajor=" .. tostring(maxMajorPlayers)
		.. " hidden=" .. tostring(hidden) .. ")")
end

-- 前端存档/读档探针（UI/FrontEnd_SaveProbe.lua）：认“创建场景”（ScenarioSetup）与
-- “创建游戏”（AdvancedSetup）两个界面，别的界面自己会 return。
-- 它不自带 UI、只打日志，所以复用下面这条刷新回调；
-- **不要**再给它单独 SetRefreshHandler —— 一个上下文只有一条刷新回调，
-- 再设一次会把幽灵那边的顶掉。
--
-- 本文件在创建游戏/创建场景里会被执行两次（PlayerSetupLogic 里 include 一次、
-- 界面自己再 include 一次，日志里“setup hook installed”打两行就是这个原因），
-- 所以探针用全局函数名做一次幂等，免得同一个 context 里塞进两份探针状态。
if ModMiscFrontEndProbeRefresh == nil and ModMiscToolIsGameSetupContext() then
	include("FrontEnd_SaveProbe")
end

-- [已验证失败] Events.SystemUpdateUI 在创建游戏界面根本不触发（只分辨率变化/恢复 UI/触摸输入），
-- hook 会完全静默；因此轮询只能用 ContextPtr 的刷新回调。
-- 创建游戏界面里 SystemUpdateUI 只在分辨率变化时触发，轮询要用 ContextPtr 的刷新回调
-- （AdvancedSetup 自己没有设置刷新回调，因此这里设置是安全的）
local function ModMiscToolGhostRefresh(delta)
	if not ModMiscToolIsGameSetupContext() then return end
	if not ContextPtr:IsHidden() then
		ModMiscToolApplyGhostCityStates()
		ModMiscToolApplyGhostMajorPlayers()
	end
	-- 探针在隐藏时也要跑：它靠“隐藏→显示”的那一刻判定新一轮（内部自己判界面）
	if ModMiscFrontEndProbeRefresh ~= nil then
		ModMiscFrontEndProbeRefresh()
	end
	ContextPtr:RequestRefresh()
end

if ModMiscToolIsGameSetupContext() then
	ContextPtr:SetRefreshHandler(ModMiscToolGhostRefresh)
	ContextPtr:RequestRefresh()
	print("[ModMiscTool][Ghost] setup hook installed (refresh handler) build="
		.. tostring(MODMISC_HOOK_BUILD_TAG))
end
