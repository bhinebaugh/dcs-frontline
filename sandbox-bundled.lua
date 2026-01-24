-- Bundled by luabundle {"version":"1.7.0"}
local __bundle_require, __bundle_loaded, __bundle_register, __bundle_modules = (function(superRequire)
	local loadingPlaceholder = {[{}] = true}

	local register
	local modules = {}

	local require
	local loaded = {}

	register = function(name, body)
		if not modules[name] then
			modules[name] = body
		end
	end

	require = function(name)
		local loadedModule = loaded[name]

		if loadedModule then
			if loadedModule == loadingPlaceholder then
				return nil
			end
		else
			if not modules[name] then
				if not superRequire then
					local identifier = type(name) == 'string' and '\"' .. name .. '\"' or tostring(name)
					error('Tried to require ' .. identifier .. ', but no such module has been registered')
				else
					return superRequire(name)
				end
			end

			loaded[name] = loadingPlaceholder
			loadedModule = modules[name](require, loaded, register, modules)
			loaded[name] = loadedModule
		end

		return loadedModule
	end

	return require, loaded, register, modules
end)(require)
__bundle_register("__root", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local taskTypes = constants.taskTypes

local GroupCommander = require("group-commander")
local StrategicCommander = require("strategic-commander")

local stratBlue = StrategicCommander.new({color = "blue"})
local stratRed = StrategicCommander.new({color = "red"})

local groupA = GroupCommander.new("Alpha", {
    color = "blue",
    stratcom = stratBlue
})
local groupB = GroupCommander.new("Bravo", {
    color = "red",
    stratcom = stratRed
})

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local lat = 42 + 32/60 + 1/3600
local lon = 44 + 05/60 + 38/3600
local blueDefendPosition = coord.LLtoLO(lat, lon)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
local lat = 42 + 28/60 + 0/3600
local lon = 44 + 03/60 + 30/3600
local redRepositionPosition = coord.LLtoLO(lat, lon)

-- Ideally, the strategic commander would issue these orders
-- Delay the move order until mission is fully loaded
mist.scheduleFunction(
    function()
        env.info("Delayed move order execution for Bravo")
        groupB:issueMoveOrder(redRepositionPosition)
    end,
    {},
    timer.getTime() + 5  -- Wait 5 seconds after mission start
)

stratBlue.objectives = {
    {
        type = taskTypes.DEFEND,
        position = blueDefendPosition,
        radius = 500, -- meters
    }
}

stratRed.objectives = {
    {
        type = taskTypes.RESERVE,
        position = redRepositionPosition,
    }
}

-- ## General scenario setup
-- 1. Bravo encounters Alpha overlooking the bridge
--   - Should spot them when near Kvemo-Roka villag
--   - at a fork in the road
-- 2. Bravo retreats up either branch of the fork
-- 3. Alpha pursues, but loses sight due to terrain
-- 4. Alpha breaks off pursuit and returns to defend the bridge
-- 5. Bravo reports enemy position to strategic command
-- 6. Strategic command dispatches reinforcements to assist Bravo
-- 7. Bravo attempts to continue to Kvemo-Khoshka village after the threat is removed

end)
__bundle_register("strategic-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local GroupCommander = require("group-commander")

local alr = constants.acceptableLevelsOfRisk
local oodaStates = constants.oodaStates
local roe = constants.rulesOfEngagement
local taskTypes = constants.taskTypes

local StrategicCommander = {}
StrategicCommander.__index = StrategicCommander

local oodaInterval = 30.0 -- seconds

function StrategicCommander.new(config)
    local self = setmetatable({}, StrategicCommander)

    self.color = config.color or "white"
    self.oodaState = oodaStates.OBSERVE
    self.oodaOffset = math.random() * oodaInterval
    self.threats = {}
    self.objectives = {}
    
    mist.scheduleFunction(
        StrategicCommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
    return self
end

function StrategicCommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    elseif self.oodaState == oodaStates.ORIENT then
        self:orient()
        self.oodaState = oodaStates.DECIDE
    elseif self.oodaState == oodaStates.DECIDE then
        self:decide()
        self.oodaState = oodaStates.ACT
    elseif self.oodaState == oodaStates.ACT then
        self:act()
        self.oodaState = oodaStates.OBSERVE
    end
end

function StrategicCommander:observe()
    env.info(self.color .. "StrategicCommander: OBSERVE")
    -- Known own force positions, status, and times
    -- Known enemy force positions, status, and times
    self.threats = self:getKnownThreats()
    -- Control zone statuses
    -- Existing objectives and their statuses
    -- Historical objectives and outcomes
end

function StrategicCommander:orient()
    env.info(self.color .. "StrategicCommander: ORIENT")
    -- Analyze enemy objectives and likely courses of action
    -- Assess current objectives for liklihood of success 
    -- Set one primary objective if none exists
    self.prioirtyObjective = self:assessObjectives()

    -- Assess new opportunities for objectives
    -- Identify stale information and intelligence gaps
end

function StrategicCommander:decide()
    env.info(self.color .. "StrategicCommander: DECIDE")
    -- Stale information in need of updated status
    -- Prioritize actions for each own force group
    local ownGroupCommanders = self:getOwnGroupCommanders()

    -- Retreating forces to safe locations
    self.retreatingGroups = {}
    for _, commander in pairs(ownGroupCommanders) do
        local status = commander:getStatus()
        if status.roe == roe.RETREAT then
            table.insert(self.retreatingGroups, commander)
            table.remove(ownGroupCommanders, _)
        end
    end

    -- Reserves to reinforce threatened forces
    self.reinforcementGroups = {}
    for _, retreatingCommander in pairs(self.retreatingGroups) do
        local retreatPosition = retreatingCommander:getStatus().retreatPosition
        local nearestReinforcement = nil
        local nearestDistance = math.huge
        for _, commander in pairs(ownGroupCommanders) do
            local status = commander:getStatus()
            local dist = mist.vec.mag(
                mist.vec.sub(status.position, retreatPosition)
            )
            if dist < nearestDistance then
                nearestDistance = dist
                nearestReinforcement = commander
            end
        end
        if nearestReinforcement then
            table.insert(self.reinforcementGroups, {
                reinforcingCommander = nearestReinforcement,
                retreatingCommander = retreatingCommander,
                retreatPosition = retreatPosition
            })
            for i, commander in pairs(ownGroupCommanders) do
                if commander == nearestReinforcement then
                    table.remove(ownGroupCommanders, i)
                end
            end
        end
    end

    -- Low supply groups to resupply points
    -- Reconnaissance to gather needed intelligence
    -- Reposition for coordinated action on objectives
    for _, commander in pairs(ownGroupCommanders) do
        -- Assign each remaining commander to act on primary objective
        if self.prioirtyObjective then
            env.info(
                self.color .. "StrategicCommander: ordering " ..
                commander.name .. " to act on objective " ..
                self.prioirtyObjective.type
            )
            commander:issueOrder({
                alr = alr.MEDIUM,
                position = self.prioirtyObjective.position,
                type = self.prioirtyObjective.type,
            })
        end
    end

    -- Offensive actions on objectives
    -- Logistics to resupply points needing replenishment
end

function StrategicCommander:act()
    env.info(self.color .. "StrategicCommander: ACT")
    -- Request communications updates from own forces
    -- Issue orders to own force groups based on decisions made
    for _, retreatPair in pairs(self.reinforcementGroups) do
        local reinforcingCommander = retreatPair.reinforcingCommander
        local retreatingCommander = retreatPair.retreatingCommander
        local retreatPosition = retreatPair.retreatPosition

        env.info(
            self.color .. "StrategicCommander: ordering " ..
            reinforcingCommander.name .. " to reinforce " ..
            retreatingCommander.name .. " at position " ..
            mist.vec.tostring(retreatPosition)
        )
        reinforcingCommander:issueOrder({
            alr = alr.MEDIUM,
            position = retreatPosition,
            type = taskTypes.REINFORCE,
        })
    end
end

function StrategicCommander:assesObjective(objective)
    local nearbyThreats = self:getThreatsNearPosition(
        objective.position,
        10000
    )
    local nearbyOwnForces = self:getOwnGroupsNearPosition(
        objective.position,
        10000
    )
    local liklihoodOfSuccess = #nearbyOwnForces / (#nearbyThreats + 1)
    return liklihoodOfSuccess
end

function StrategicCommander:assessObjectives()
    local highestProbabilityObjective = nil
    local highestProbability = 0
    for _, objective in pairs(self.objectives) do
        -- Evaluate each objective's likelihood of success
        -- Update objective status accordingly
        local probability = self:assesObjective(objective)
        if probability > highestProbability then
            highestProbability = probability
            highestProbabilityObjective = objective
        end
    end
    env.info(
        self.color .. "StrategicCommander: Highest probability objective is " ..
        (highestProbabilityObjective and highestProbabilityObjective.type or "none") ..
        " with probability " .. highestProbability
    )
    return highestProbabilityObjective
end

function StrategicCommander:getKnownThreats()
    local groupCommanders = self:getOwnGroupCommanders()
    local threats = {}

    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        for _, threat in pairs(status.threats) do
            threat.sightedAt = timer.getTime()
            threats[threat.name] = threat
        end
    end

    return threats
end

function StrategicCommander:getOwnGroupCommanders()
    return GroupCommander.getInstances(self.color)
end

function StrategicCommander:getOwnGroupsNearPosition(position, radius)
    local groupCommanders = self:getOwnGroupCommanders()
    local nearbyOwnForces = {}
    for _, commander in pairs(groupCommanders) do
        local status = commander:getStatus()
        local dist = mist.vec.mag(
            mist.vec.sub(status.position, position)
        )
        if dist <= radius then
            table.insert(nearbyOwnForces, commander)
        end
    end
    return nearbyOwnForces
end

function StrategicCommander:getThreatsNearPosition(position, radius)
    local nearbyThreats = {}
    for _, threat in pairs(self.threats) do
        local dist = mist.vec.mag(mist.vec.sub(threat.position, position))
        if dist <= radius then
            table.insert(nearbyThreats, threat)
        end
    end
    return nearbyThreats
end

return StrategicCommander

end)
__bundle_register("group-commander", function(require, _LOADED, __bundle_register, __bundle_modules)
local constants = require("constants")
local alr = constants.acceptableLevelsOfRisk
local dispositionTypes = constants.dispositionTypes
local formationTypes = constants.formationTypes
local oodaStates = constants.oodaStates
local roe = constants.rulesOfEngagement
local unitClassification = constants.unitClassification
local vulnerabilityMatrix = constants.vulnerabilityMatrix
local GroupCommander = {}
GroupCommander.__index = GroupCommander
GroupCommander.instances = {}

local oodaInterval = 10.0 -- seconds
local detectionRadius = 5000 -- meters



function GroupCommander.new(groupName, config)
    local self = setmetatable({}, GroupCommander)
    self.alr = alr.LOW
    self.coalition = config.color
    self.color = config.color
    self.destination = nil
    self.disposition = dispositionTypes.DEFEND
    self.formationType = formationTypes.OFF_ROAD
    self.groupName = groupName
    self.initialUnitNames = self:getOwnUnitNames()
    self.initialCollectiveStatus = self:getCollectiveStatus()
    self.oodaState = oodaStates.OBSERVE
    self.orders = nil
    self.ownForceStrength = nil
    self.roe = roe.WEAPON_HOLD
    self.threats = {}
    self.threatAnalysis = nil

    self.oodaOffset = math.random() * oodaInterval
    
    -- Register this instance
    table.insert(GroupCommander.instances, self)
    
    mist.scheduleFunction(
        GroupCommander.oodaTick,
        {self},
        timer.getTime() + self.oodaOffset,
        oodaInterval
    )
    return self
end

function GroupCommander:oodaTick()
    if self.oodaState == oodaStates.OBSERVE then
        self:observe()
        self.oodaState = oodaStates.ORIENT
    elseif self.oodaState == oodaStates.ORIENT then
        self:orient()
        self.oodaState = oodaStates.DECIDE
    elseif self.oodaState == oodaStates.DECIDE then
        self:decide()
        self.oodaState = oodaStates.ACT
    elseif self.oodaState == oodaStates.ACT then
        self:act()
        self.oodaState = oodaStates.OBSERVE
    end
end

function GroupCommander:observe()
    local detected = self:detectNearbyUnits()
    
    env.info(self.groupName .. " OBSERVE: Detected " .. #detected.threats .. " potential threats in range")
    
    -- Filter threats to only those with LOS
    local visibleThreatNames = self:filterThreatsWithLOS(detected.threats)
    
    env.info(self.groupName .. " OBSERVE: " .. #visibleThreatNames .. " threats with LOS")
    
    -- Build threat table with unit object references
    self.threats = self:buildThreatTable(visibleThreatNames)
    
    env.info(self.groupName .. " OBSERVE: " .. #self.threats .. " final threats after validation")
end

function GroupCommander:orient()
    -- Analyze own force
    self.ownForceStrength = self:analyzeOwnForce()
    
    if not self.ownForceStrength then
        env.info("ERROR: Could not analyze own force for " .. self.groupName)
        return
    end
    
    -- Analyze threats
    local threatCapabilities = self:analyzeThreatCapabilities()
    
    -- If no threats, don't calculate vulnerability/ratio
    if threatCapabilities.count == 0 then
        self.threatAnalysis = {
            capabilities = threatCapabilities,
            vulnerability = {overall = 0, fromInfantryWeapons = 0, fromArmorWeapons = 0, fromAirWeapons = 0},
            strengthRatio = 0
        }
        return
    end
    
    -- Calculate vulnerability
    local vulnerability = self:calculateVulnerability(self.ownForceStrength, threatCapabilities)
    
    -- Calculate strength ratio
    local strengthRatio = self.ownForceStrength.strength.total / threatCapabilities.totalStrength
    
    -- Log assessment
    env.info(self.groupName .. " ORIENT: Us (" .. self.ownForceStrength.strength.count .. 
             ": Inf=" .. string.format("%.1f", self.ownForceStrength.strength.infantry) .. 
             " Arm=" .. string.format("%.1f", self.ownForceStrength.strength.armor) .. 
             ") vs Them (" .. threatCapabilities.count .. 
             ": Inf=" .. threatCapabilities.composition.infantry .. 
             " Arm=" .. threatCapabilities.composition.armor .. 
             ") Ratio: " .. string.format("%.2f", strengthRatio))
    
    -- Store analysis for decision making
    self.threatAnalysis = {
        capabilities = threatCapabilities,
        vulnerability = vulnerability,
        strengthRatio = strengthRatio
    }
end

function GroupCommander:decide()
    -- Check if we have valid analysis data
    if not self.threatAnalysis or not self.ownForceStrength then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    local threatCount = self.threatAnalysis.capabilities.count
    
    -- Decision thresholds
    local strengthRatio = self.threatAnalysis.strengthRatio
    local vulnerability = self.threatAnalysis.vulnerability.overall
    local retreatThreshold = 0.6
    local advanceThreshold = 1.5
    local maxAcceptableVulnerability = 20.0
    
    -- If we have orders, use them as the basis for decisions
    if self.orders then
        local orderedPosition = self.orders.position
        local orderedALR = self.orders.alr or alr.LOW
        
        -- Adjust thresholds based on ordered ALR
        if orderedALR == alr.LOW then
            retreatThreshold = 0.8
            maxAcceptableVulnerability = 15.0
        elseif orderedALR == alr.HIGH then
            retreatThreshold = 0.4
            maxAcceptableVulnerability = 30.0
        end
        
        -- If no threats, move to ordered position
        if threatCount == 0 then
            env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION (no threats)")
            self:setDisposition(dispositionTypes.ADVANCE)
            self.destination = orderedPosition
            return
        end
        
        local threatCenter = self:calculateThreatCenter()
        if not threatCenter then
            env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION (threats eliminated)")
            self:setDisposition(dispositionTypes.ADVANCE)
            self.destination = orderedPosition
            return
        end
        
        -- Check if we need to retreat based on ALR
        if strengthRatio < retreatThreshold or vulnerability > maxAcceptableVulnerability then
            env.info(self.groupName .. " DECIDE: RETREAT (ordered, threats too strong)")
            self:setDisposition(dispositionTypes.RETREAT)
            self.destination = self:calculateDestinationRelativeToThreats(threatCenter, true)
            
        -- Check if we can advance on threats without straying too far from ordered position
        elseif strengthRatio >= advanceThreshold and vulnerability < maxAcceptableVulnerability * 0.5 then
            local ownPos = self:getOwnPosition()
            if ownPos then
                local distanceToOrdered = math.sqrt(
                    (ownPos.x - orderedPosition.x)^2 + 
                    (ownPos.z - orderedPosition.z)^2
                )
                
                -- Only advance if we're within 3km of ordered position or moving closer
                if distanceToOrdered < 3000 then
                    env.info(self.groupName .. " DECIDE: ADVANCE ON THREATS (near ordered position)")
                    self:setDisposition(dispositionTypes.ADVANCE)
                    self.destination = self:calculateDestinationRelativeToThreats(threatCenter, false)
                else
                    env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION (too far to advance)")
                    self:setDisposition(dispositionTypes.ADVANCE)
                    self.destination = orderedPosition
                end
            else
                env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION")
                self:setDisposition(dispositionTypes.ADVANCE)
                self.destination = orderedPosition
            end
            
        else
            -- Default to moving toward or defending ordered position
            env.info(self.groupName .. " DECIDE: DEFEND/MOVE TO ORDERED POSITION")
            self:setDisposition(dispositionTypes.DEFEND)
            self.destination = orderedPosition
        end
        
    else
        -- No orders - use autonomous decision-making
        
        -- If no threats, hold position
        if threatCount == 0 then
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            return
        end
        
        local threatCenter = self:calculateThreatCenter()
        
        -- If we can't calculate threat center (all threats destroyed), hold position
        if not threatCenter then
            env.info(self.groupName .. " DECIDE: HOLD (threats eliminated)")
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            return
        end
        
        -- Make decision based on strength and vulnerability
        if strengthRatio < retreatThreshold or vulnerability > maxAcceptableVulnerability then
            env.info(self.groupName .. " DECIDE: RETREAT")
            self:setDisposition(dispositionTypes.RETREAT)
            self.destination = self:calculateDestinationRelativeToThreats(threatCenter, true)
            
        elseif strengthRatio >= advanceThreshold and vulnerability < maxAcceptableVulnerability * 0.5 then
            env.info(self.groupName .. " DECIDE: ADVANCE")
            self:setDisposition(dispositionTypes.ADVANCE)
            self.destination = self:calculateDestinationRelativeToThreats(threatCenter, false)
            
        else
            env.info(self.groupName .. " DECIDE: HOLD")
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            
            -- Stop any existing movement
            local group = Group.getByName(self.groupName)
            if group and group:isExist() then
                local controller = group:getController()
                controller:setTask({
                    id = 'Hold',
                    params = {}
                })
            end
        end
    end
end

function GroupCommander:act()
    -- Set ROE based on disposition
    if self.disposition == dispositionTypes.ADVANCE then
        self:setROE(roe.WEAPON_FREE)
    elseif self.disposition == dispositionTypes.RETREAT then
        self:setROE(roe.RETURN_FIRE)
    elseif self.disposition == dispositionTypes.HOLD then
        self:setROE(roe.RETURN_FIRE)
    elseif self.disposition == dispositionTypes.DEFEND then
        self:setROE(roe.WEAPON_FREE)
    else
        self:setROE(roe.WEAPON_HOLD)
    end
    
    -- Only issue move orders for ADVANCE and RETREAT (not HOLD or DEFEND)
    if self.destination and (self.disposition == dispositionTypes.ADVANCE or self.disposition == dispositionTypes.RETREAT) then
        self:issueMoveOrder(self.destination)
    end


end

function GroupCommander:analyzeOwnForce()
    -- Get all units in our group
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return nil
    end
    
    local groupUnits = group:getUnits()
    local ownUnits = {}
    
    for _, unit in ipairs(groupUnits) do
        if unit and unit:isExist() then
            table.insert(ownUnits, {
                unit = unit,
                position = unit:getPosition().p
            })
        end
    end
    
    local strength = self:calculateForceStrength(ownUnits)
    
    -- Calculate offensive capabilities (what we can threaten)
    local offensiveCapability = {
        vsInfantry = 0,
        vsArmor = 0,
        vsAir = 0
    }
    
    for _, unitData in ipairs(ownUnits) do
        local unit = unitData.unit
        
        -- Skip dead units
        if unit and unit:isExist() then
            local typeName = self:getUnitTypeName(unit)
            local classification = self:classifyUnit(typeName)
            
            offensiveCapability.vsInfantry = offensiveCapability.vsInfantry + classification.threats.infantry
            offensiveCapability.vsArmor = offensiveCapability.vsArmor + classification.threats.armor
            offensiveCapability.vsAir = offensiveCapability.vsAir + classification.threats.air
        end
    end
    
    return {
        strength = strength,
        offensiveCapability = offensiveCapability,
        units = ownUnits
    }
end

function GroupCommander:analyzeThreatCapabilities()
    -- Analyze what the threats are armed with and their total threat rating
    local threatCapabilities = {
        vsInfantry = 0,
        vsArmor = 0,
        vsAir = 0,
        totalStrength = 0,
        count = 0,
        composition = {infantry = 0, armor = 0, air = 0}
    }
    
    for _, threatData in ipairs(self.threats) do
        local unit = threatData.unit
        
        -- Skip dead units
        if unit and unit:isExist() then
            local typeName = self:getUnitTypeName(unit)
            local classification = self:classifyUnit(typeName)
            
            threatCapabilities.vsInfantry = threatCapabilities.vsInfantry + classification.threats.infantry
            threatCapabilities.vsArmor = threatCapabilities.vsArmor + classification.threats.armor
            threatCapabilities.vsAir = threatCapabilities.vsAir + classification.threats.air
            threatCapabilities.totalStrength = threatCapabilities.totalStrength + classification.strength
            threatCapabilities.count = threatCapabilities.count + 1
            
            if classification.category == "infantry" then
                threatCapabilities.composition.infantry = threatCapabilities.composition.infantry + 1
            elseif classification.category == "armor" then
                threatCapabilities.composition.armor = threatCapabilities.composition.armor + 1
            elseif classification.category == "air" then
                threatCapabilities.composition.air = threatCapabilities.composition.air + 1
            end
        end
    end
    
    return threatCapabilities
end

function GroupCommander:buildThreatTable(threatNames)
    local threats = {}
    for _, unitName in ipairs(threatNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(threats, {
                name = unitName,
                unit = unit,
                position = unit:getPosition().p
            })
        end
    end
    return threats
end

function GroupCommander:calculateDestinationRelativeToThreats(threatCenter, retreat)
    local ownPos = self:getOwnPosition()
    if not ownPos or not threatCenter then
        env.info(self.groupName .. " Cannot calculate destination: missing position data")
        return nil
    end
    
    -- Calculate vector from threat to us
    local dx = ownPos.x - threatCenter.x
    local dz = ownPos.z - threatCenter.z
    
    -- Normalize
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < 1 then
        -- Too close, pick arbitrary direction
        dx = 1
        dz = 0
        distance = 1
    end
    
    local dirX = dx / distance
    local dirZ = dz / distance
    
    -- Set movement distance based on action
    if retreat then
        -- Move away from threats
        local retreatDistance = 2000  -- 2km retreat
        return {
            x = ownPos.x + (dirX * retreatDistance),
            z = ownPos.z + (dirZ * retreatDistance)
        }
    else
        -- Move toward threats (advance) - position at weapon range from threat center
        local weaponRange = 1000  -- 1km weapon range
        return {
            x = threatCenter.x + (dirX * weaponRange),
            z = threatCenter.z + (dirZ * weaponRange)
        }
    end
end

function GroupCommander:calculateDetectionCoefficient(distance)
    -- At half detectionRadius (1000m): coefficient = 1.0
    -- At full detectionRadius (2000m): coefficient = 0.2
    -- Linear interpolation between these points
    local halfRadius = detectionRadius / 2
    
    if distance <= halfRadius then
        return 1.0
    else
        -- Linear interpolation from 1.0 at halfRadius to 0.2 at detectionRadius
        local t = (distance - halfRadius) / (detectionRadius - halfRadius)
        return 1.0 - (t * 0.8) -- 1.0 - 0.8 = 0.2 at full distance
    end
end

function GroupCommander:calculateDistanceBetweenUnits(unit1, unit2)
    local pos1 = unit1:getPosition().p
    local pos2 = unit2:getPosition().p
    return mist.utils.get2DDist(pos1, pos2)
end

function GroupCommander:calculateForceStrength(units)
    -- Calculate total strength broken down by category
    local strength = {
        infantry = 0,
        armor = 0,
        air = 0,
        total = 0,
        count = 0
    }
    
    for _, unitData in ipairs(units) do
        local unit = unitData.unit
        
        -- Skip dead units
        if unit and unit:isExist() then
            local typeName = self:getUnitTypeName(unit)
            local classification = self:classifyUnit(typeName)
            
            strength.total = strength.total + classification.strength
            strength.count = strength.count + 1
            
            if classification.category == "infantry" then
                strength.infantry = strength.infantry + classification.strength
            elseif classification.category == "armor" then
                strength.armor = strength.armor + classification.strength
            elseif classification.category == "air" then
                strength.air = strength.air + classification.strength
            end
        end
    end
    
    return strength
end

function GroupCommander:calculateThreatCenter()
    -- Calculate the average position of all threats
    if #self.threats == 0 then
        return nil
    end
    
    local sumX = 0
    local sumZ = 0
    local validCount = 0
    
    for _, threatData in ipairs(self.threats) do
        -- Check if unit still exists (may have been destroyed since observe)
        if threatData.unit and threatData.unit:isExist() then
            local pos = threatData.unit:getPosition().p
            sumX = sumX + pos.x
            sumZ = sumZ + pos.z
            validCount = validCount + 1
        end
    end
    
    if validCount == 0 then
        return nil
    end
    
    return {
        x = sumX / validCount,
        z = sumZ / validCount
    }
end

function GroupCommander:calculateVulnerability(ownForce, threatCapabilities)
    -- Calculate how vulnerable we are to the threats based on our composition
    local vulnerability = {
        overall = 0,
        fromInfantryWeapons = 0,
        fromArmorWeapons = 0,
        fromAirWeapons = 0
    }
    
    -- Get our composition percentages
    local totalStrength = ownForce.strength.total
    if totalStrength == 0 then
        return vulnerability
    end
    
    local infantryRatio = ownForce.strength.infantry / totalStrength
    local armorRatio = ownForce.strength.armor / totalStrength
    
    -- Calculate vulnerability from infantry weapons
    vulnerability.fromInfantryWeapons = 
        (infantryRatio * vulnerabilityMatrix.infantry.infantry * threatCapabilities.vsInfantry) +
        (armorRatio * vulnerabilityMatrix.armor.infantry * threatCapabilities.vsInfantry)
    
    -- Calculate vulnerability from armor weapons
    vulnerability.fromArmorWeapons = 
        (infantryRatio * vulnerabilityMatrix.infantry.armor * threatCapabilities.vsArmor) +
        (armorRatio * vulnerabilityMatrix.armor.armor * threatCapabilities.vsArmor)
    
    -- Calculate vulnerability from air weapons
    vulnerability.fromAirWeapons = 
        (infantryRatio * vulnerabilityMatrix.infantry.air * threatCapabilities.vsAir) +
        (armorRatio * vulnerabilityMatrix.armor.air * threatCapabilities.vsAir)
    
    vulnerability.overall = vulnerability.fromInfantryWeapons + 
                           vulnerability.fromArmorWeapons + 
                           vulnerability.fromAirWeapons
    
    return vulnerability
end

function GroupCommander:classifyUnit(unitTypeName)
    if not unitTypeName then
        return {category = "unknown", threats = {infantry = 0, armor = 0, air = 0}, strength = 0}
    end
    
    local classification = unitClassification[unitTypeName]
    if classification then
        return classification
    end
    
    -- Default classification for unknown units
    return {category = "unknown", threats = {infantry = 1, armor = 1, air = 0}, strength = 1}
end

function GroupCommander:detectNearbyUnits()
    local leadUnitName = self.groupName .. "-1"
    local leadUnit = Unit.getByName(leadUnitName)
    
    if not leadUnit or not leadUnit:isExist() then
        return {allies = {}, threats = {}}
    end
    
    local myCoalition = self.coalition
    local enemyCoalition = myCoalition == "red" and "blue" or "red"
    
    -- Get all units in zone (can't filter by coalition in makeUnitTable or LOS breaks)
    local allUnits = mist.makeUnitTable({"[all]"})
    local unitsInZone = mist.getUnitsInMovingZones(
        allUnits,
        {leadUnitName},
        detectionRadius,
        "cylinder"
    )
    
    -- Extract ally and threat names by filtering on coalition
    local allies = {}
    local threats = {}
    for _, unitObject in ipairs(unitsInZone) do
        if unitObject and unitObject.getName then
            local name = unitObject:getName()
            if name ~= leadUnitName then
                local unit = Unit.getByName(name)
                if unit and unit:isExist() then
                    local unitCoalition = unit:getCoalition()
                    -- Coalition: 0=neutral, 1=red, 2=blue
                    local coalitionName = unitCoalition == 1 and "red" or (unitCoalition == 2 and "blue" or "neutral")
                    
                    if coalitionName == myCoalition then
                        table.insert(allies, name)
                    elseif coalitionName == enemyCoalition then
                        table.insert(threats, name)
                    end
                end
            end
        end
    end
    
    return {allies = allies, threats = threats}
end

function GroupCommander:filterThreatsWithLOS(threatNames)
    if not threatNames or #threatNames == 0 then
        return {}
    end
    
    -- Get all units in our group to use as observers
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return {}
    end
    
    local groupUnits = group:getUnits()
    local observerNames = {}
    for _, unit in ipairs(groupUnits) do
        if unit and unit:isExist() then
            table.insert(observerNames, unit:getName())
        end
    end
    
    if #observerNames == 0 then
        return {}
    end
    
    -- Use mist.getUnitsLOS: observers, observerAlt, targets, targetAlt
    local losResults = mist.getUnitsLOS(
        observerNames,  -- All observers, not just the first
        2,              -- Observer altitude offset (2m above unit position)
        threatNames,
        2               -- Target altitude offset (2m above unit position)
    )
    
    if not losResults or #losResults == 0 then
        return {}
    end
    
    -- Collect all visible units from all observers
    -- losResults is an array where each element has ["unit"] (observer) and ["vis"] (array of visible threats)
    local visibleThreatsSet = {}
    for _, observerResult in ipairs(losResults) do
        local observerUnit = observerResult.unit
        
        if observerUnit and observerUnit:isExist() and observerResult.vis then
            for _, threatUnit in ipairs(observerResult.vis) do
                if threatUnit and threatUnit:isExist() then
                    local distance = self:calculateDistanceBetweenUnits(observerUnit, threatUnit)
                    local coefficient = self:calculateDetectionCoefficient(distance)
                    
                    -- Use coefficient as probability to add unit to threats
                    if math.random() < coefficient then
                        visibleThreatsSet[threatUnit:getName()] = true
                    end
                end
            end
        end
    end
    
    -- Convert set to array
    local visibleThreats = {}
    for unitName, _ in pairs(visibleThreatsSet) do
        table.insert(visibleThreats, unitName)
    end
    
    return visibleThreats
end

function GroupCommander:getCollectiveStatus()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return 0
    end

    local totalCount = #self.ownUnitNames
    if totalCount == 0 then
        return 0
    end
    
    local aliveCount = 0
    local ammoCount = 0
    local ammmoLowState = nil
    local fuelQuantity = 0
    local fuelLowState = nil
    local healthPool = 0
    local healthLowState = nil
    for _, unitName in ipairs(self.ownUnitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            local unitAmmo = unit:getAmmo()
            local unitFuel = unit:getFuel()
            local unitHealth = unit:getLife()

            aliveCount = aliveCount + 1
            ammoCount = ammoCount + unitAmmo
            fuelQuantity = fuelQuantity + unitFuel
            healthPool = healthPool + unitHealth

            if unitAmmo < ammmoLowState or not ammmoLowState then
                ammmoLowState = unitAmmo
            end

            if unitFuel < fuelLowState or not fuelLowState then
                fuelLowState = unitFuel
            end

            if unitHealth < healthLowState or not healthLowState then
                healthLowState = unitHealth
            end
        end
    end
    
    return {
        aliveCount = aliveCount,
        ammoCount = ammoCount,
        ammmoLowState = ammmoLowState,
        fuelQuantity = fuelQuantity,
        fuelLowState = fuelLowState,
        healthPool = healthPool,
        healthLowState = healthLowState,
    }
end

function GroupCommander:getOwnPosition()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return nil
    end
    
    local units = group:getUnits()
    if #units == 0 then
        return nil
    end
    
    -- Use first unit position as group position
    local unit = units[1]
    if unit and unit:isExist() then
        return unit:getPosition().p
    end
    
    return nil
end

function GroupCommander:getOwnUnitNames()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return {}
    end
    
    local units = group:getUnits()
    local unitNames = {}
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            table.insert(unitNames, unit:getName())
        end
    end
    return unitNames
end

function GroupCommander:getStatus()
    local collectiveStatus = self:getCollectiveStatus()

    local status = {
        destination = self.destination,
        disposition = self.disposition,
        groupName = self.groupName,
        status = collectiveStatus,
        threats = self.threats,
    }
    return status
end

function GroupCommander.getInstances(coalition)
    if not coalition then
        return GroupCommander.instances
    end
    
    local filtered = {}
    for _, instance in ipairs(GroupCommander.instances) do
        if instance.coalition == coalition then
            table.insert(filtered, instance)
        end
    end
    return filtered
end

function GroupCommander:getUnitTypeName(unit)
    if not unit or not unit:isExist() then
        return nil
    end
    
    local typeName = unit:getTypeName()
    return typeName
end

function GroupCommander:issueMoveOrder(point)
    env.info("Issuing move order for " .. self.groupName .. " to x=" .. point.x .. " z=" .. point.z)
    
    -- Verify group exists
    local group = Group.getByName(self.groupName)
    if not group then
        env.info("ERROR: Group " .. self.groupName .. " does not exist!")
        return
    end
    
    if not group:isExist() then
        env.info("ERROR: Group " .. self.groupName .. " is not alive!")
        return
    end
    
    local destination = {
        point = point,
        radius = 100
    }
    local formation = "Cone"
    local heading = 0
    local speed = 100
    local ignoreRoads = false
    
    mist.groupToPoint(
        self.groupName,
        destination,
        formation,
        heading,
        speed,
        ignoreRoads
    )
end

function GroupCommander:issueOrder(order)
    self.orders = order
end

function GroupCommander:setALR(riskLevel)
    env.info("Setting ALR to " .. riskLevel .. " for group of color " .. self.color)
    self.alr = riskLevel
end

function GroupCommander:setDisposition(dispositionType)
    env.info("Setting disposition to " .. dispositionType .. " for group of color " .. self.color)
    self.disposition = dispositionType
end

function GroupCommander:setFormation(formationType)
    env.info("Setting formation to " .. formationType .. " for group of color " .. self.color)
    self.formationType = formationType
end

function GroupCommander:setROE(roeLevel)
    env.info("Setting ROE to " .. roeLevel .. " for group " .. self.groupName)
    local group = Group.getByName(self.groupName)
    if group and group:isExist() then
        local controller = group:getController()
        controller:setOption(AI.Option.Ground.id.ROE, roeLevel)
        self.roe = roeLevel
    else
        env.info("ERROR: Cannot set ROE, group " .. self.groupName .. " does not exist")
    end
end

return GroupCommander

end)
__bundle_register("constants", function(require, _LOADED, __bundle_register, __bundle_modules)
local acceptableLevelsOfRisk = {
    LOW = "Low", -- Accept favorable engagements only; withdraw to preserve forces
    MEDIUM = "Medium", -- Accept neutral/favorable engagements; withdraw to avoid heavy losses
    HIGH = "High", -- Accept major losses to achieve objectives
}

local dispositionTypes = {
    ADVANCE = "Advance",
    ASSAULT = "Assault",
    DEFEND = "Defend",
    EVADE = "Evade",
    HOLD = "Hold Position",
    RETREAT = "Retreat",
}

local formationTypes = {
    OFF_ROAD = "Off Road", -- moving off-road in Column formation 
    ON_ROAD = "On Road", -- moving on road in Column formation 
    RANK = "Rank", -- moving off road in Row formation 
    CONE = "Cone", -- moving in Wedge formation 
    VEE = "Vee", -- moving in Vee formation 
    DIAMOND = "Diamond", -- moving in Diamond formation 
    ECHELONL = "EchelonL", -- moving in Echelon Left formation 
    ECHELONR = "EchelonR", -- moving in Echelon Right formation  
}

local groundTemplates = { --frontline, rear, farp
    red = {
        {"KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck", "KAMAZ Truck"},
        {"MTLB", "Ural-375", "Ural-375", "GAZ-66"},
        {"BTR-80", "KAMAZ Truck", "KAMAZ Truck", "GAZ-66"},
        {"BMP-2", "BTR-80", "MTLB", "GAZ-66"},
    },
    blue = {
        {"Hummer", "M 818", "M 818", "M 818"},
        {"M-113", "Hummer", "M 818", "M 818"},
        {"M-113", "M-113", "Hummer", "Hummer"},
        {"M-2 Bradley", "M1043 HMMWV Armament", "M1043 HMMWV Armament", "Hummer"},
    }
}

local taskTypes = {
    DEFEND = 1,
    REINFORCE = 2,
    RECON = 3,
    ASSAULT = 4,
    RESERVE = 5,
    INDIRECT = 6,
    AA = 7,
}

local statusTypes = {
    HOLD = 1,
    EN_ROUTE = 2,
}

local oodaStates = {
    OBSERVE = "Observe",
    ORIENT = "Orient",
    DECIDE = "Decide",
    ACT = "Act",
}

local rgb = {
    blue = {0,0.1,0.8,0.5},
    red = {0.5,0,0.1,0.5},
    neutral = {0.1,0.1,0.1,0.5},
}

local rulesOfEngagement = {
    WEAPON_FREE = 0, -- Engage targets at will
    RETURN_FIRE = 3, -- Engage only if fired upon
    WEAPON_HOLD = 4, -- Hold fire, do not engage
}

-- Unit classification and threat ratings
-- Each unit type has threat values against infantry, armor, and air
local unitClassification = {
    -- Infantry units
    ["Soldier M4"] = {category = "infantry", threats = {infantry = 2, armor = 0.5, air = 0}, strength = 1},
    ["Soldier M249"] = {category = "infantry", threats = {infantry = 3, armor = 0.5, air = 0}, strength = 1.2},
    ["Infantry AK"] = {category = "infantry", threats = {infantry = 2, armor = 0.5, air = 0}, strength = 1},
    ["Paratrooper RPG-16"] = {category = "infantry", threats = {infantry = 1.5, armor = 4, air = 0}, strength = 1.5},
    
    -- Light vehicles / Trucks
    ["Hummer"] = {category = "infantry", threats = {infantry = 1, armor = 0.5, air = 0}, strength = 1.5},
    ["GAZ-66"] = {category = "infantry", threats = {infantry = 1, armor = 0.5, air = 0}, strength = 1.5},
    ["UAZ-469"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 0.8},
    ["M 818"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["KAMAZ Truck"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Kamaz 43101"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-375"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-4320-31"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    ["Ural-4320T"] = {category = "infantry", threats = {infantry = 0.5, armor = 0, air = 0}, strength = 1},
    
    -- Scout vehicles
    ["M1043 HMMWV Armament"] = {category = "infantry", threats = {infantry = 3, armor = 2, air = 0}, strength = 2},
    ["BRDM-2"] = {category = "infantry", threats = {infantry = 3, armor = 1.5, air = 0}, strength = 2},
    
    -- Light armor / IFVs
    ["M-113"] = {category = "armor", threats = {infantry = 3, armor = 1, air = 0}, strength = 2.5},
    ["M-2 Bradley"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
    ["BMP-2"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
    ["BTR-80"] = {category = "armor", threats = {infantry = 4, armor = 2, air = 0}, strength = 3},
    
    -- Medium armor
    ["M-1 Abrams"] = {category = "armor", threats = {infantry = 3, armor = 8, air = 0}, strength = 8},
    ["T-72B"] = {category = "armor", threats = {infantry = 3, armor = 7, air = 0}, strength = 7},
    ["T-80U"] = {category = "armor", threats = {infantry = 3, armor = 7.5, air = 0}, strength = 7.5},
    
    -- Air defense
    ["Avenger"] = {category = "armor", threats = {infantry = 1, armor = 0, air = 6}, strength = 3},
    ["Vulcan"] = {category = "armor", threats = {infantry = 2, armor = 1, air = 5}, strength = 3},
    ["Strela-10M3"] = {category = "armor", threats = {infantry = 0, armor = 0, air = 5}, strength = 3},
    ["Strela-1 9P31"] = {category = "armor", threats = {infantry = 0, armor = 0, air = 5}, strength = 3},
    
    -- Artillery
    ["M-109"] = {category = "armor", threats = {infantry = 6, armor = 4, air = 0}, strength = 5},
    ["2S9 Nona"] = {category = "armor", threats = {infantry = 5, armor = 3, air = 0}, strength = 4},
}

-- Vulnerability modifiers based on unit category
local vulnerabilityMatrix = {
    infantry = {
        infantry = 1.0,  -- Infantry vs infantry weapons
        armor = 0.3,     -- Infantry vs armor weapons (takes cover, dispersed)
        air = 0.2,        -- Infantry vs air weapons (small target)
        antiair = 0.4     -- Infantry vs anti-air weapons
    },
    armor = {
        infantry = 0.5,  -- Armor vs infantry weapons (some resistance)
        armor = 1.2,     -- Armor vs armor weapons (vulnerable to AT)
        air = 0.8,        -- Armor vs air weapons
        antiair = 0.6     -- Armor vs anti-air weapons
    },
    air = {
        infantry = 0.4,  -- Air vs infantry weapons (less effective)
        armor = 0.7,     -- Air vs armor weapons
        air = 1.0,        -- Air vs air weapons
        antiair = 1.5     -- Air vs anti-air weapons (highly vulnerable)
    },
    antiair = {
        infantry = 0.6,  -- AA vs infantry weapons
        armor = 0.9,     -- AA vs armor weapons
        air = 1.3,        -- AA vs air weapons (highly effective)
        antiair = 1.0     -- AA vs anti-air weapons
    }
}

return {
    acceptableLevelsOfRisk = acceptableLevelsOfRisk,
    dispositionTypes = dispositionTypes,
    formationTypes = formationTypes,
    groundTemplates = groundTemplates,
    rulesOfEngagement = rulesOfEngagement,
    oodaStates = oodaStates,
    rgb = rgb,
    taskTypes = taskTypes,
    statusTypes = statusTypes,
    unitClassification = unitClassification,
    vulnerabilityMatrix = vulnerabilityMatrix
}

end)
return __bundle_require("__root")