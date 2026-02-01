local constants = require("constants")
local ThreatAnalyzer = require("threat-analyzer")
local ThreatDetector = require("threat-detector")
local ThreatTracker = require("threat-tracker")
local alr = constants.acceptableLevelsOfRisk
local dispositionTypes = constants.dispositionTypes
local formationTypes = constants.formationTypes
local oodaStates = constants.oodaStates
local orderStatus = constants.orderStatus
local roe = constants.rulesOfEngagement
local taskTypes = constants.taskTypes
local GroupCommander = {}
GroupCommander.__index = GroupCommander
GroupCommander.instances = {}

local oodaInterval = 10.0 -- seconds
local detectionRadius = 8000 -- meters

function GroupCommander.new(groupName, config)
    local self = setmetatable({}, GroupCommander)
    self.alr = alr.LOW
    self.coalition = config.color
    self.color = config.color
    self.destination = nil
    self.disposition = dispositionTypes.HOLD
    self.formationType = formationTypes.OFF_ROAD
    self.groupName = groupName
    self.initialUnitNames = self:getOwnUnitNames()
    self.initialCollectiveStatus = self:getCollectiveStatus()
    self.oodaState = oodaStates.OBSERVE
    self.orders = nil
    self.lastMoveOrder = nil
    self.ownForceStrength = nil
    self.roe = roe.WEAPON_HOLD
    self.threatTracker = ThreatTracker.new(groupName)
    self.threatAnalysis = nil
    self.lastThreatCenter = nil
    self.allyIntel = nil  -- Nearby ally strength info from OpsCom

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
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        env.info("WARNING: " .. self.groupName .. " group does not exist - cannot observe")
        return
    end
    
    -- Use ThreatDetector to get visible threats
    local detected = ThreatDetector.detectUnits(
        ThreatDetector.getUnitsFromGroups({group}),
        detectionRadius,
        self.coalition,  -- "red" or "blue"
        2,  -- Observer altitude offset
        2   -- Target altitude offset
    )
    
    local visibleThreatNames = {}
    for _, unit in ipairs(detected.enemy) do
        table.insert(visibleThreatNames, unit:getName())
    end
    
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
    
    -- Check for expected threats we didn't see
    local ownPos = self:getOwnPosition()
    local expectedCount = 0
    if ownPos then
        local expectedInArea = self.threatTracker:expectedThreats(ownPos, detectionRadius)
        expectedCount = #expectedInArea
        for _, threatName in ipairs(expectedInArea) do
            -- If we expected to see it but didn't, update status
            local wasSeen = false
            for _, observed in ipairs(observedThreats) do
                if observed.name == threatName then
                    wasSeen = true
                    break
                end
            end
            if not wasSeen then
                local threat = self.threatTracker:getThreat(threatName)
                if threat then
                    -- Check distance to last known position
                    local distToLastKnown = math.sqrt(
                        (ownPos.x - threat.position.x)^2 + 
                        (ownPos.z - threat.position.z)^2
                    )
                    
                    -- If close to last known position, mark UNCONFIRMED
                    -- Otherwise just mark SUSPECTED (we haven't checked yet)
                    if distToLastKnown < 1000 then  -- Within 1km of last known position
                        if threat.status == "Observed" or threat.status == "Suspected" then
                            self.threatTracker:markThreatStatus(threatName, "Unconfirmed")
                        end
                    else
                        if threat.status == "Observed" then
                            self.threatTracker:markThreatStatus(threatName, "Suspected")
                        end
                    end
                end
            end
        end
    end
    
    -- Age threats and progress their status
    self.threatTracker:ageThreats()
    
    -- Single consolidated OBSERVE summary
    local memoryCount = self.threatTracker:count()
    local expectedStr = expectedCount > 0 and (" Exp:" .. expectedCount) or ""
    env.info(self.groupName .. " OBSERVE: LOS:" .. #visibleThreatNames .. expectedStr .. " Mem:" .. memoryCount)
end

function GroupCommander:orient()
    -- Gather situational awareness for decision making
    self:assessOwnForce()
    self:assessThreats()
    self:assessOrderContext()
end

function GroupCommander:decide()
    -- Check if we have valid assessment data
    if not self.ownForceStrength or not self.threatAssessment then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- Handle order lifecycle
    if self.orders and self.orders:isActive() then
        self:handleOrderDecisions()
    else
        self:handleAutonomousDecisions()
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
        -- Only issue if destination has changed (more than 100m tolerance)
        if not self.lastMoveOrder or 
           math.abs(self.lastMoveOrder.x - self.destination.x) > 100 or 
           math.abs(self.lastMoveOrder.z - self.destination.z) > 100 then
            self:issueMoveOrder(self.destination)
            self.lastMoveOrder = {x = self.destination.x, z = self.destination.z}
        end
    end
end

-- Assess context related to current orders
function GroupCommander:assessOrderContext()
    if not self.orders or not self.orders:isActive() then
        self.orderContext = nil
        return
    end
    
    local ownPos = self:getOwnPosition()
    if not ownPos then
        self.orderContext = nil
        return
    end
    
    local orderedPosition = self.orders.position
    local orderedRadius = self.orders.radius or 500
    
    -- Calculate distance to ordered position
    local distanceToOrdered = math.sqrt(
        (ownPos.x - orderedPosition.x)^2 + 
        (ownPos.z - orderedPosition.z)^2
    )
    
    -- Check if we're within the objective radius
    local withinObjective = distanceToOrdered <= orderedRadius
    
    -- Determine thresholds based on ALR
    local orderedALR = self.orders.alr or alr.LOW
    local retreatThreshold = 0.4
    local maxAcceptableVulnerability = 45.0
    
    if orderedALR == alr.LOW then
        retreatThreshold = 0.8
        maxAcceptableVulnerability = 15.0
    elseif orderedALR == alr.HIGH then
        retreatThreshold = 0.2
        maxAcceptableVulnerability = 60.0
    end
    
    -- Store order context
    self.orderContext = {
        position = orderedPosition,
        radius = orderedRadius,
        type = self.orders.type,
        alr = orderedALR,
        distanceToOrdered = distanceToOrdered,
        withinObjective = withinObjective,
        retreatThreshold = retreatThreshold,
        maxAcceptableVulnerability = maxAcceptableVulnerability,
        leashDistance = 3000  -- Don't pursue threats beyond 3km from ordered position
    }
end

-- Assess own force strength and capabilities
function GroupCommander:assessOwnForce()
    self.ownForceStrength = self:analyzeOwnForce()
    
    if not self.ownForceStrength then
        env.info("ERROR: Could not analyze own force for " .. self.groupName)
    end
end

function GroupCommander:analyzeOwnForce()
    -- Get all units in our group
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return nil
    end
    
    local groupUnits = group:getUnits()
    local units = {}
    
    for _, unit in ipairs(groupUnits) do
        if unit and unit:isExist() then
            table.insert(units, unit)
        end
    end
    
    -- Use ThreatAnalyzer for comprehensive force analysis
    return ThreatAnalyzer.analyzeUnits(units)
end

function GroupCommander:analyzeThreatCapabilities()
    -- Get threat units from threat tracker
    -- Only include threats that are Observed or recently Suspected (not stale)
    local threats = self.threatTracker:getThreats()
    local threatUnits = {}
    local currentTime = timer.getTime()
    
    for unitName, threatData in pairs(threats) do
        -- Only include threats that are actively relevant
        local includeInAnalysis = false
        
        if threatData.status == "Observed" then
            includeInAnalysis = true
        elseif threatData.status == "Suspected" and threatData.lastSighting then
            -- Include suspected threats if seen within last 60 seconds
            local timeSinceLastSeen = currentTime - threatData.lastSighting
            if timeSinceLastSeen < 60 then
                includeInAnalysis = true
            end
        end
        
        if includeInAnalysis then
            local unit = Unit.getByName(unitName)
            if unit and unit:isExist() then
                table.insert(threatUnits, unit)
            end
        end
    end
    
    -- Use ThreatAnalyzer for comprehensive force analysis
    return ThreatAnalyzer.analyzeUnits(threatUnits)
end

-- Assess threat situation including staleness, center of mass, and comparative strength
function GroupCommander:assessThreats()
    if not self.ownForceStrength then
        self.threatAssessment = nil
        return
    end
    
    -- Get threat status breakdown
    local threatStatuses = self:checkThreatStatuses()
    
    -- Analyze threat capabilities
    local threatAnalysis = self:analyzeThreatCapabilities()
    
    -- Calculate threat center if threats exist
    local threatCenter = nil
    if threatAnalysis.count > 0 then
        threatCenter = self:calculateThreatCenter()
    end
    
    -- Calculate vulnerability and favorability if threats exist
    local vulnerability = {overall = 0, fromInfantry = 0, fromArmor = 0, fromAir = 0}
    local favorability = 0
    
    if threatAnalysis.count > 0 then
        -- Calculate our vulnerability considering our own force
        vulnerability = ThreatAnalyzer.calculateVulnerability(self.ownForceStrength, threatAnalysis)
        
        -- If we have ally intel, include nearby allies in combined force calculation
        local combinedForce = self.ownForceStrength
        if self.allyIntel and self.allyIntel.count > 0 then
            -- Combine our force with nearby allies
            combinedForce = {
                count = self.ownForceStrength.count + self.allyIntel.count,
                composition = {
                    infantry = self.ownForceStrength.composition.infantry + self.allyIntel.composition.infantry,
                    ["light-armor"] = self.ownForceStrength.composition["light-armor"] + self.allyIntel.composition["light-armor"],
                    ["heavy-armor"] = self.ownForceStrength.composition["heavy-armor"] + self.allyIntel.composition["heavy-armor"],
                    support = self.ownForceStrength.composition.support + self.allyIntel.composition.support
                },
                offensiveCapability = {
                    vsInfantry = self.ownForceStrength.offensiveCapability.vsInfantry + self.allyIntel.offensiveCapability.vsInfantry,
                    vsArmor = self.ownForceStrength.offensiveCapability.vsArmor + self.allyIntel.offensiveCapability.vsArmor,
                    vsAir = self.ownForceStrength.offensiveCapability.vsAir + self.allyIntel.offensiveCapability.vsAir
                }
            }
        end
        
        -- Calculate favorability using combined force (enemy vulnerability / combined vulnerability)
        local enemyVulnerability = ThreatAnalyzer.calculateVulnerability(threatAnalysis, combinedForce)
        local combinedVulnerability = ThreatAnalyzer.calculateVulnerability(combinedForce, threatAnalysis)
        
        if combinedVulnerability.overall > 0 then
            favorability = enemyVulnerability.overall / combinedVulnerability.overall
        elseif enemyVulnerability.overall > 0 then
            favorability = math.huge
        end
        
        -- Log assessment in compact format with ally contribution
        local allyStr = ""
        if self.allyIntel and self.allyIntel.count > 0 then
            allyStr = " +Ally:" .. self.allyIntel.count .. 
                      "(" .. self.allyIntel.composition.infantry .. "/" .. 
                      self.allyIntel.composition["light-armor"] .. "/" .. 
                      self.allyIntel.composition["heavy-armor"] .. ")"
        end
        env.info(self.groupName .. " ORIENT: Us:" .. self.ownForceStrength.count .. 
                 "(" .. self.ownForceStrength.composition.infantry .. "/" .. 
                 self.ownForceStrength.composition["light-armor"] .. "/" .. 
                 self.ownForceStrength.composition["heavy-armor"] .. ")" .. allyStr .. 
                 " vs Them:" .. threatAnalysis.count .. 
                 "(" .. threatAnalysis.composition.infantry .. "/" .. 
                 threatAnalysis.composition["light-armor"] .. "/" .. 
                 threatAnalysis.composition["heavy-armor"] .. 
                 ") Fav:" .. string.format("%.2f", favorability))
    end
    
    -- Determine if threats are stale using ThreatTracker utility
    local threatsAreStale = self.threatTracker:isIntelStale(60)
    
    -- Store consolidated threat assessment
    self.threatAssessment = {
        count = threatAnalysis.count,
        analysis = threatAnalysis,
        statuses = threatStatuses,
        center = threatCenter,
        vulnerability = vulnerability,
        favorability = favorability,
        stale = threatsAreStale,
        hasRecentIntel = self.threatTracker:hasRecentThreats(120)  -- Any intel within 2 minutes
    }
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
        -- Move toward threats (advance)
        local optimalRange = 250   -- Close to 250m for optimal engagement
        local weaponRange = 1000   -- Max weapon range is 1km
        
        local currentDistance = math.sqrt(
            (ownPos.x - threatCenter.x)^2 + 
            (ownPos.z - threatCenter.z)^2
        )
        
        -- If beyond weapon range, move to weapon range
        -- If within weapon range, close to optimal range for better accuracy
        local targetRange = currentDistance > weaponRange and weaponRange or optimalRange
        
        -- If already at or closer than optimal range, stay put
        if currentDistance <= optimalRange then
            return nil
        end
        
        return {
            x = threatCenter.x + (dirX * targetRange),
            y = threatCenter.y or ownPos.y,
            z = threatCenter.z + (dirZ * targetRange)
        }
    end
end

function GroupCommander:calculateDistanceBetweenUnits(unit1, unit2)
    local pos1 = unit1:getPosition().p
    local pos2 = unit2:getPosition().p
    return mist.utils.get2DDist(pos1, pos2)
end

function GroupCommander:calculateThreatCenter()
    -- Calculate the average position of all threats based on last known positions
    local sumX = 0
    local sumZ = 0
    local validCount = 0
    local statusCounts = {}
    
    local threats = self.threatTracker:getThreats()
    for unitName, threatData in pairs(threats) do
        -- Use stored position from last observation
        if threatData.position then
            sumX = sumX + threatData.position.x
            sumZ = sumZ + threatData.position.z
            validCount = validCount + 1
            statusCounts[threatData.status] = (statusCounts[threatData.status] or 0) + 1
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

function GroupCommander:checkThreatStatuses()
    -- Check threat statuses and return info about whether threats are observed vs suspected/unconfirmed
    local threats = self.threatTracker:getThreats()
    local observed = 0
    local suspected = 0
    local unconfirmed = 0
    local other = 0
    local mostRecentObservation = 0
    
    for unitName, threatData in pairs(threats) do
        if threatData.status == "Observed" then
            observed = observed + 1
        elseif threatData.status == "Suspected" then
            suspected = suspected + 1
        elseif threatData.status == "Unconfirmed" then
            unconfirmed = unconfirmed + 1
        else
            other = other + 1
        end
        
        -- Track most recent observation time
        if threatData.lastSighting and threatData.lastSighting > mostRecentObservation then
            mostRecentObservation = threatData.lastSighting
        end
    end
    
    return {
        observed = observed,
        suspected = suspected,
        unconfirmed = unconfirmed,
        other = other,
        total = observed + suspected + unconfirmed + other,
        allSuspectedOrUnconfirmed = (observed == 0) and ((suspected + unconfirmed) > 0),
        hasUnconfirmed = unconfirmed > 0,
        mostRecentObservation = mostRecentObservation,
        timeSinceLastObservation = mostRecentObservation > 0 and (timer.getTime() - mostRecentObservation) or 0
    }
end

-- Decide to advance on threats (strong position)
function GroupCommander:decideAdvanceOnThreats()
    local threat = self.threatAssessment
    local context = self.orderContext
    
    env.info(self.groupName .. " DECIDE: ADVANCE (on threats, Fav:" .. string.format("%.2f", threat.favorability) .. ")")
    self:setDisposition(dispositionTypes.ADVANCE)
    
    local advanceDestination = self:calculateDestinationRelativeToThreats(threat.center, false)
    
    -- Verify advance doesn't exceed leash
    if advanceDestination then
        local destDist = math.sqrt(
            (advanceDestination.x - context.position.x)^2 + 
            (advanceDestination.z - context.position.z)^2
        )
        
        if destDist > context.leashDistance then
            env.info(self.groupName .. " DECIDE: ADVANCE (leash limit, returning)")
            self.destination = self:getDestinationToObjective(context.position, context.radius)
        else
            self.destination = advanceDestination
        end
    else
        self.destination = advanceDestination
    end
end

-- Decide to move toward ordered position (moderate threat)
function GroupCommander:decideMoveToOrdered()
    local context = self.orderContext
    
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (moving to objective)")
    else
        self:setDisposition(dispositionTypes.DEFEND)
        env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
        
        -- Complete order if defending at objective
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            self.orders:complete()
        end
    end
end

-- Decide action when no threats exist
function GroupCommander:decideWithNoThreats()
    local context = self.orderContext
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (no threats, to objective)")
    else
        self:setDisposition(dispositionTypes.DEFEND)
        env.info(self.groupName .. " DECIDE: DEFEND (at objective)")
        
        -- Complete RALLY/REINFORCE orders when arriving at position
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            self.orders:complete()
        end
    end
end

-- Decide action when threats are stale/unconfirmed
function GroupCommander:decideWithStaleThreats()
    local context = self.orderContext
    
    self.destination = self:getDestinationToObjective(context.position, context.radius)
    
    if self.destination then
        self:setDisposition(dispositionTypes.ADVANCE)
        env.info(self.groupName .. " DECIDE: ADVANCE (stale threats, to objective)")
    else
        self:setDisposition(dispositionTypes.HOLD)
        env.info(self.groupName .. " DECIDE: HOLD (stale threats, at objective)")
        
        -- Complete RALLY/REINFORCE orders when arriving at position
        if context.type == taskTypes.RALLY or context.type == taskTypes.REINFORCE then
            self.orders:complete()
        end
    end
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
        orderStatus = self.orders and self.orders.status or nil,
        position = self:getOwnPosition(),
        status = collectiveStatus,
        threats = self.threatTracker:getThreats(),
    }
    return status
end

function GroupCommander:getUnitTypeName(unit)
    if not unit or not unit:isExist() then
        return nil
    end
    
    local typeName = unit:getTypeName()
    return typeName
end

-- Make decisions when following orders
function GroupCommander:handleOrderDecisions()
    -- Start order if just assigned
    if self.orders.status == orderStatus.ASSIGNED then
        self.orders:start()
        env.info(self.groupName .. " DECIDE: Starting order " .. self:taskTypeName(self.orders.type) .. 
                 " @ " .. string.format("%.0f,%.0f", self.orders.position.x, self.orders.position.z) .. 
                 " r:" .. self.orders.radius .. " ALR:" .. self.orders.alr)
    end
    
    -- Check for order expiration
    if self.orders:isExpired() then
        self.orders:complete()
        env.info(self.groupName .. " DECIDE: Order complete (deadline)")
        return
    end
    
    local threat = self.threatAssessment
    local context = self.orderContext
    
    -- No order context means we can't make order-based decisions
    if not context then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- Decision thresholds (adjusted by ALR in orderContext)
    local advanceThreshold = 1.5
    
    -- Check if we should abort order due to threat
    if self:shouldAbortForThreat() then
        self.orders:abort("threat_retreat")
        self:setDisposition(dispositionTypes.RETREAT)
        self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
        self.lastThreatCenter = threat.center
        return
    end
    
    -- No threats or threats eliminated
    if threat.count == 0 or not threat.center then
        self:decideWithNoThreats()
        return
    end
    
    -- RECON orders complete when threats are detected (that's the point of recon!)
    if context.type == taskTypes.RECON then
        env.info(self.groupName .. " DECIDE: RECON complete - threats detected")
        self.orders:complete()
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- RALLY orders: if threats are closer than rally destination, engage them directly
    -- ASSAULT orders should commit - don't check, just fight
    if context.type == taskTypes.RALLY and threat.center then
        local ownPos = self:getOwnPosition()
        if ownPos then
            local distanceToThreat = math.sqrt(
                (ownPos.x - threat.center.x)^2 + 
                (ownPos.z - threat.center.z)^2
            )
            local distanceToDestination = math.sqrt(
                (ownPos.x - context.position.x)^2 + 
                (ownPos.z - context.position.z)^2
            )
            
            -- If threat is significantly closer than rally point, abandon rally and engage
            -- Use 70% threshold to avoid flip-flopping
            if distanceToThreat < distanceToDestination * 0.7 then
                env.info(self.groupName .. " DECIDE: Threat closer than rally point, engaging directly")
                
                -- Abort the rally order and engage autonomously
                self.orders:abort("closer_threat")
                
                -- Strong position, advance on threats
                if threat.favorability >= advanceThreshold and 
                   threat.vulnerability.overall < context.maxAcceptableVulnerability * 0.5 then
                    env.info(self.groupName .. " DECIDE: ADVANCE (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
                    self:setDisposition(dispositionTypes.ADVANCE)
                    self.destination = self:calculateDestinationRelativeToThreats(threat.center, false)
                else
                    -- Hold position and engage from here
                    env.info(self.groupName .. " DECIDE: HOLD (moderate, Fav:" .. string.format("%.2f", threat.favorability) .. ")")
                    self:setDisposition(dispositionTypes.HOLD)
                    self.destination = nil
                    self:stopMovement()
                end
                return
            end
        end
    end
    
    -- Threats are stale but maintain course if we have recent intel
    if threat.stale then
        -- If we have recent intel (within 2 minutes), maintain current course
        if threat.hasRecentIntel then
            env.info(self.groupName .. " DECIDE: Maintaining course (threat intel temporarily stale)")
            -- Continue previous action, don't change course for temporary intel gaps
            return  -- Maintain current disposition/destination
        else
            self:decideWithStaleThreats()
            return
        end
    end
    
    -- Strong position, can advance on threats
    if threat.favorability >= advanceThreshold and 
       threat.vulnerability.overall < context.maxAcceptableVulnerability * 0.5 and
       context.distanceToOrdered < context.leashDistance then
        self:decideAdvanceOnThreats()
        return
    end
    
    -- Default: move toward or defend ordered position
    self:decideMoveToOrdered()
end

-- Make decisions without orders (autonomous mode)
function GroupCommander:handleAutonomousDecisions()
    local threat = self.threatAssessment
    
    -- Decision thresholds (default/medium ALR)
    local retreatThreshold = 0.6
    local advanceThreshold = 1.5
    local maxAcceptableVulnerability = 20.0
    
    -- Add hysteresis based on current disposition to prevent rapid state changes
    -- If already retreating, make it slightly easier to continue retreating
    -- If already advancing, make it slightly easier to continue advancing
    local hysteresis = 0.15
    if self.disposition == dispositionTypes.RETREAT then
        retreatThreshold = retreatThreshold + hysteresis
    elseif self.disposition == dispositionTypes.ADVANCE then
        advanceThreshold = advanceThreshold - hysteresis
    end
    
    -- No threats, hold position
    if threat.count == 0 or not threat.center then
        env.info(self.groupName .. " DECIDE: HOLD (no threats)")
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = nil
        return
    end
    
    -- Threats are stale but maintain course if we have recent intel
    if threat.stale then
        if threat.hasRecentIntel then
            env.info(self.groupName .. " DECIDE: Maintaining course (threat intel temporarily stale)")
            -- Maintain current disposition, don't change course on temporary intel gaps
            return
        else
            env.info(self.groupName .. " DECIDE: HOLD (stale threats)")
            self:setDisposition(dispositionTypes.HOLD)
            self.destination = nil
            self:stopMovement()
            return
        end
    end
    
    -- Weak position, retreat
    if threat.favorability < retreatThreshold or threat.vulnerability.overall > maxAcceptableVulnerability then
        env.info(self.groupName .. " DECIDE: RETREAT (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
        self:setDisposition(dispositionTypes.RETREAT)
        self.destination = self:calculateDestinationRelativeToThreats(threat.center, true)
        self.lastThreatCenter = threat.center
        return
    end
    
    -- Strong position, advance
    if threat.favorability >= advanceThreshold and threat.vulnerability.overall < maxAcceptableVulnerability * 0.5 then
        env.info(self.groupName .. " DECIDE: ADVANCE (Fav:" .. string.format("%.2f", threat.favorability) .. ")")
        self:setDisposition(dispositionTypes.ADVANCE)
        self.destination = self:calculateDestinationRelativeToThreats(threat.center, false)
        return
    end
    
    -- Moderate position, hold
    env.info(self.groupName .. " DECIDE: HOLD (moderate, Fav:" .. string.format("%.2f", threat.favorability) .. ")")
    self:setDisposition(dispositionTypes.HOLD)
    self.destination = nil
    self:stopMovement()
end

function GroupCommander:issueMoveOrder(point)
    -- Convert x/z to lat/lon for logging
    local lat, lon = coord.LOtoLL({x = point.x, y = 0, z = point.z})
    env.info(self.groupName .. " DECIDE: Move to " .. string.format("%.5f", lat or 0) .. "," .. string.format("%.5f", lon or 0))
    
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
    
    -- Calculate distance to destination first (needed for road logic)
    local distance = nil
    local ownPos = self:getOwnPosition()
    if ownPos then
        distance = math.sqrt(
            (point.x - ownPos.x)^2 + 
            (point.z - ownPos.z)^2
        )
    end
    
    -- Decide whether to use roads based on situation and distance
    -- Default to ignoring roads since DCS pathfinding is often problematic
    local ignoreRoads = true
    
    -- Only use roads for long-distance movements (>15km) when not in combat
    if distance and distance > 15000 and self.disposition ~= dispositionTypes.RETREAT then
        ignoreRoads = false
    end
    
    -- Set destination radius based on whether using roads
    -- Per MIST docs: roads are auto-used if distance > 1.3 * radius
    -- So we need larger radius to prevent roads being used at medium ranges
    local destRadius = 100
    if not ignoreRoads and distance then
        -- For road movements, use larger radius (10% of distance, max 500m)
        destRadius = math.min(500, distance * 0.1)
    end
    
    local destination = {
        point = point,
        radius = destRadius
    }
    local formation = "Cone"
    local heading = 0
    local speed = 100
        
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
    -- Set initial status if not provided
    if not order.status then
        order.status = orderStatus.ASSIGNED
        order.assignedAt = timer.getTime()
    end
    self.orders = order
end

function GroupCommander:updateThreatIntel(threatIntel)
    -- Receive threat intel from operational commander
    self.threatTracker:mergeThreatIntel(threatIntel)
end

function GroupCommander:updateAllyIntel(allyIntel)
    -- Receive nearby ally strength info from operational commander
    -- allyIntel: {count, composition, offensiveCapability} from ThreatAnalyzer
    self.allyIntel = allyIntel
end

function GroupCommander:setALR(riskLevel)
    env.info("Setting ALR to " .. riskLevel .. " for group of color " .. self.color)
    self.alr = riskLevel
end

function GroupCommander:setDisposition(dispositionType)
    self.disposition = dispositionType
end
function GroupCommander:setFormation(formationType)
    env.info("Setting formation to " .. formationType .. " for group of color " .. self.color)
    self.formationType = formationType
end

function GroupCommander:setROE(roeLevel)
    local group = Group.getByName(self.groupName)
    if group and group:isExist() then
        local controller = group:getController()
        controller:setOption(AI.Option.Ground.id.ROE, roeLevel)
        self.roe = roeLevel
    else
        env.info("ERROR: Cannot set ROE, group " .. self.groupName .. " does not exist")
    end
end

-- Check if order should be aborted due to threat
function GroupCommander:shouldAbortForThreat()
    local threat = self.threatAssessment
    local context = self.orderContext
    
    if not threat or not context then
        return false
    end
    
    -- No threats, no need to abort
    if threat.count == 0 or not threat.center or threat.stale then
        return false
    end
    
    -- Check if threat exceeds acceptable risk
    local shouldAbort = threat.favorability < context.retreatThreshold or 
                       threat.vulnerability.overall > context.maxAcceptableVulnerability
    
    if shouldAbort then
        env.info(self.groupName .. " DECIDE: Aborting order due to threat (favorability=" .. 
                 string.format("%.2f", threat.favorability) .. " vuln=" .. 
                 string.format("%.1f", threat.vulnerability.overall) .. ")")
    end
    
    return shouldAbort
end

-- Helper to stop group movement
function GroupCommander:stopMovement()
    local group = Group.getByName(self.groupName)
    if group and group:isExist() then
        local controller = group:getController()
        controller:setTask({id = 'Hold', params = {}})
    end
    self.lastMoveOrder = nil
end

function GroupCommander:taskTypeName(taskType)
    for name, value in pairs(taskTypes) do
        if value == taskType then
            return name
        end
    end
    return tostring(taskType)
end

return GroupCommander
