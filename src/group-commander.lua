local constants = require("constants")
local ThreatTracker = require("threat-tracker")
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
    self.threatTracker = ThreatTracker.new(groupName)
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
    
    -- Build observed unit data for threats we can see (no unit refs stored)
    local observedThreats = {}
    for _, unitName in ipairs(visibleThreatNames) do
        local unit = Unit.getByName(unitName)
        -- Only add if unit exists (error guard, not intel cheat)
        if unit and unit:isExist() then
            table.insert(observedThreats, {
                name = unitName,
                position = unit:getPosition().p
            })
        end
    end
    
    -- Update threat table with newly observed threats (keeping old ones)
    self.threatTracker:updateThreats(observedThreats)
    
    -- Check for expected threats we didn't see (mark as UNCONFIRMED)
    local ownPos = self:getOwnPosition()
    if ownPos then
        local expectedInArea = self.threatTracker:expectedThreats(ownPos, detectionRadius)
        for _, threatName in ipairs(expectedInArea) do
            -- If we expected to see it but didn't, mark unconfirmed
            local wasSeen = false
            for _, observed in ipairs(observedThreats) do
                if observed.name == threatName then
                    wasSeen = true
                    break
                end
            end
            if not wasSeen then
                self.threatTracker:markThreatStatus(threatName, "Unconfirmed")
            end
        end
    end
    
    env.info(self.groupName .. " OBSERVE: " .. self.threatTracker:count() .. " threats in memory")
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
        local orderedRadius = self.orders.radius or 500
        local orderedALR = self.orders.alr or alr.LOW
        
        -- Adjust thresholds based on ordered ALR
        if orderedALR == alr.LOW then
            retreatThreshold = 0.8
            maxAcceptableVulnerability = 15.0
        elseif orderedALR == alr.HIGH then
            retreatThreshold = 0.4
            maxAcceptableVulnerability = 30.0
        end
        
        -- If no threats, check if we need to move to ordered position
        if threatCount == 0 then
            self.destination = self:getDestinationToObjective(orderedPosition, orderedRadius)
            if self.destination then
                env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION (no threats)")
                self:setDisposition(dispositionTypes.ADVANCE)
            else
                env.info(self.groupName .. " DECIDE: DEFEND (at objective, no threats)")
                self:setDisposition(dispositionTypes.DEFEND)
            end
            return
        end
        
        local threatCenter = self:calculateThreatCenter()
        if not threatCenter then
            self.destination = self:getDestinationToObjective(orderedPosition, orderedRadius)
            if self.destination then
                env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION (threats eliminated)")
                self:setDisposition(dispositionTypes.ADVANCE)
            else
                env.info(self.groupName .. " DECIDE: DEFEND (at objective, threats eliminated)")
                self:setDisposition(dispositionTypes.DEFEND)
            end
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
                    self.destination = self:getDestinationToObjective(orderedPosition, orderedRadius)
                    if self.destination then
                        env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION (too far to advance)")
                        self:setDisposition(dispositionTypes.ADVANCE)
                    else
                        env.info(self.groupName .. " DECIDE: DEFEND (at objective, too far to advance)")
                        self:setDisposition(dispositionTypes.DEFEND)
                    end
                end
            else
                self.destination = self:getDestinationToObjective(orderedPosition, orderedRadius)
                if self.destination then
                    env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION")
                    self:setDisposition(dispositionTypes.ADVANCE)
                else
                    env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
                    self:setDisposition(dispositionTypes.DEFEND)
                end
            end
            
        else
            -- Default to moving toward or defending ordered position
            self:setDisposition(dispositionTypes.DEFEND)
            self.destination = self:getDestinationToObjective(orderedPosition, orderedRadius)
            if self.destination then
                env.info(self.groupName .. " DECIDE: MOVE TO ORDERED POSITION")
            else
                env.info(self.groupName .. " DECIDE: DEFEND (within objective radius)")
            end
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
    
    local threats = self.threatTracker:getThreats()
    for unitName, threatData in pairs(threats) do
        -- Look up unit by name when needed
        local unit = Unit.getByName(unitName)
        
        -- Only guard against nil/invalid references, not checking if unit still exists
        if unit then
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
            y = ownPos.y,
            z = ownPos.z + (dirZ * retreatDistance)
        }
    else
        -- Move toward threats (advance) - position at weapon range from threat center
        local weaponRange = 1000  -- 1km weapon range
        
        -- Check if we're already within weapon range
        local currentDistance = math.sqrt(
            (ownPos.x - threatCenter.x)^2 + 
            (ownPos.z - threatCenter.z)^2
        )
        
        -- If already within weapon range, don't move away
        if currentDistance <= weaponRange then
            return nil
        end
        
        return {
            x = threatCenter.x + (dirX * weaponRange),
            y = threatCenter.y or ownPos.y,
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

function GroupCommander:getDestinationToObjective(objectivePosition, objectiveRadius)
    -- Check if we're within objective radius. If so, return nil (stay put).
    -- If not, return the objective position to move toward.
    local ownPos = self:getOwnPosition()
    if not ownPos then
        return objectivePosition  -- Can't determine position, default to moving
    end
    
    local distanceToObjective = math.sqrt(
        (ownPos.x - objectivePosition.x)^2 + 
        (ownPos.z - objectivePosition.z)^2
    )
    
    if distanceToObjective <= objectiveRadius then
        return nil  -- Within radius, stay put
    else
        return objectivePosition  -- Outside radius, move to objective
    end
end

function GroupCommander:calculateThreatCenter()
    -- Calculate the average position of all threats based on last known positions
    local sumX = 0
    local sumZ = 0
    local validCount = 0
    
    local threats = self.threatTracker:getThreats()
    for unitName, threatData in pairs(threats) do
        -- Use stored position from last observation
        if threatData.position then
            sumX = sumX + threatData.position.x
            sumZ = sumZ + threatData.position.z
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

    local totalCount = #self.initialUnitNames
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
    for _, unitName in ipairs(self.initialUnitNames) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            local unitAmmoTable = unit:getAmmo()
            local unitFuel = unit:getFuel()
            local unitHealth = unit:getLife()
            
            -- Sum up all ammo counts from the table
            local unitAmmoTotal = 0
            if unitAmmoTable then
                for _, ammoEntry in ipairs(unitAmmoTable) do
                    if ammoEntry.count then
                        unitAmmoTotal = unitAmmoTotal + ammoEntry.count
                    end
                end
            end

            aliveCount = aliveCount + 1
            ammoCount = ammoCount + unitAmmoTotal
            fuelQuantity = fuelQuantity + unitFuel
            healthPool = healthPool + unitHealth

            if not ammmoLowState or unitAmmoTotal < ammmoLowState then
                ammmoLowState = unitAmmoTotal
            end

            if not fuelLowState or unitFuel < fuelLowState then
                fuelLowState = unitFuel
            end

            if not healthLowState or unitHealth < healthLowState then
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
        position = self:getOwnPosition(),
        status = collectiveStatus,
        threats = self.threatTracker:getThreats(),
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
    
    -- Ensure point has y coordinate for MIST
    if not point.y then
        point = {
            x = point.x,
            y = land.getHeight({x = point.x, y = point.z}),
            z = point.z
        }
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

function GroupCommander:updateThreatIntel(threatIntel)
    -- Receive threat intel from strategic commander
    self.threatTracker:mergeThreatIntel(threatIntel)
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
