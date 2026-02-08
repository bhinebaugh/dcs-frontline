local constants = require("constants")
local DefensivePosturePlan = require("game-plans.tactical.defensive-posture-plan")
local ForceStatusAnalyzer = require("force-status-analyzer")
local OODACommander = require("ooda-commander")
local OrderCoordinator = require("order-coordinator")
local OrderExecutionPlan = require("game-plans.tactical.order-execution-plan")
local SpatialAgent = require("spatial-agent")
local ThreatAnalyzer = require("threat-analyzer")
local ThreatDetector = require("threat-detector")
local ThreatTracker = require("threat-tracker")
local alr = constants.acceptableLevelsOfRisk
local dispositionTypes = constants.dispositionTypes
local formationTypes = constants.formationTypes
local orderStatus = constants.orderStatus
local roe = constants.rulesOfEngagement
local taskTypes = constants.taskTypes
local GroupCommander = {}

setmetatable(GroupCommander, {__index = OODACommander})
GroupCommander.__index = GroupCommander
GroupCommander.instances = {}

local oodaInterval = 10.0 -- seconds
local detectionRadius = 8000 -- meters

function GroupCommander.new(groupName, config)
    -- Initialize parent class (sets up OODA loop scheduling)
    local self = OODACommander.new({interval = oodaInterval})
    setmetatable(self, GroupCommander)
    
    -- GroupCommander-specific initialization
    self.alr = alr.LOW
    self.coalition = config.color
    self.color = config.color
    self.destination = nil
    self.disposition = dispositionTypes.HOLD
    self.formationType = formationTypes.OFF_ROAD
    self.groupName = groupName
    self.initialUnitNames = self:getOwnUnitNames()
    self.initialCollectiveStatus = self:getCollectiveStatus()
    
    -- Capture initial ammo count for percentage-based low ammo thresholds
    local initialStatus = self:getStatusReport()
    self.initialAmmoCount = initialStatus.ammoCount
    
    self.orders = nil
    self.lastMoveOrder = nil
    self.ownForceStrength = nil
    self.roe = roe.WEAPON_HOLD
    self.threatTracker = ThreatTracker.new(groupName)
    self.threatAnalysis = nil
    self.lastThreatCenter = nil
    self.allyIntel = nil  -- Nearby ally strength info from OpsCom
    self.destroyed = false  -- Tracks if group no longer exists
    
    -- Simulated fuel tracking (DCS doesn't model fuel for ground units)
    self.fuelRemaining = 1.0  -- Start at 100%
    self.lastPosition = nil
    self.lastObserveTime = timer.getTime()
    
    -- Active GamePlan (persists across OODA cycles until plan type changes)
    self.gamePlan = nil
    self.gamePlanType = nil  -- Track current plan type to detect switches
    
    -- Register this instance
    table.insert(GroupCommander.instances, self)
    
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

function GroupCommander:observe()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        -- Mark as destroyed (oodaTick will handle cancellation)
        self.destroyed = true
        self.lastObserveTime = timer.getTime()
        env.info(self.groupName .. " destroyed - marking for cleanup")
        return
    end
    
    -- Update simulated fuel consumption
    local currentTime = timer.getTime()
    local currentPos = self:getOwnPosition()

    -- Only update position/time if we have a valid currentPos
    if currentPos then
        self:updateFuelConsumption(currentTime, currentPos)
        self.lastPosition = currentPos
        self.lastObserveTime = currentTime
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
                    local distToLastKnown = SpatialAgent.distance2D(ownPos, threat.position)
                    
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
    
    -- Store direct LOS count for decision-making (to distinguish self-observed from shared intel)
    self.directLOSCount = #visibleThreatNames
    
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
    if self.orders and self.orders.status == orderStatus.ASSIGNED then
        self.gamePlan = OrderExecutionPlan.new()
    end

    if self.orders and self.orders:isFinished() then
        self.orders = nil
        self.gamePlan = DefensivePosturePlan.new()
    end

    if not self.gamePlan then
        self.gamePlan = DefensivePosturePlan.new()
    end

    -- Check if we have valid assessment data
    if not self.ownForceStrength or not self.threatAssessment then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end

    -- Get tactical planning context from OrderCoordinator
    local context = OrderCoordinator.buildTacticalContext(self)
    if not context then
        env.info("ERROR: Could not build tactical context for " .. self.groupName)
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end
        
    -- Use GamePlan to make tactical decisions
    local decision = self.gamePlan:plan(context)
    if decision then
        self:setDisposition(decision.disposition)
        self.destination = decision.destination
    else
        env.info("ERROR: GamePlan returned nil decision for " .. self.groupName)
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
    end
end

function GroupCommander:act()
    -- Set ROE based on disposition
    if self.disposition == dispositionTypes.ADVANCE then
        self:setROE(roe.WEAPON_FREE)
    elseif self.disposition == dispositionTypes.RETREAT then
        self:setROE(roe.RETURN_FIRE)
    elseif self.disposition == dispositionTypes.HOLD then
        self:setROE(roe.WEAPON_FREE)
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
    -- Use OrderCoordinator to derive context snapshot
    local ownPos = self:getOwnPosition()
    self.orderContext = OrderCoordinator.deriveOrderContext(self.orders, ownPos, self.alr)
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
    
    -- Calculate favorability if threats exist
    local favorability = 0
    
    if threatAnalysis.count > 0 then
        
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
        
        -- Calculate favorability using combined force (our power / enemy power)
        local ourPower = ThreatAnalyzer.calculateCombatPower(combinedForce, threatAnalysis)
        local enemyPower = ThreatAnalyzer.calculateCombatPower(threatAnalysis, combinedForce)
        
        if enemyPower > 0 then
            favorability = ourPower / enemyPower
        elseif ourPower > 0 then
            favorability = math.huge
        end
        
        -- Get status report for logging
        local statusReport = self:getStatusReport()
        
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
        
        -- Log detailed status report
        local avgHealth = statusReport.aliveCount > 0 and (statusReport.healthPool / statusReport.aliveCount) or 0
        env.info(self.groupName .. " STATUS: Units:" .. statusReport.aliveCount .. "/" .. #self.initialUnitNames .. 
                 " HP:" .. string.format("%.0f", avgHealth) .. 
                 " (low:" .. string.format("%.0f", statusReport.healthLowState or 0) .. ")" .. 
                 " Fuel:" .. string.format("%.0f%%", statusReport.fuelRemaining * 100) .. 
                 " Ammo:" .. statusReport.ammoCount .. 
                 " (low:" .. (statusReport.ammmoLowState or 0) .. ")")
    end
    
    -- Determine if threats are stale using ThreatTracker utility
    local threatsAreStale = self.threatTracker:isIntelStale(60)
    
    -- Store consolidated threat assessment
    self.threatAssessment = {
        count = threatAnalysis.count,
        analysis = threatAnalysis,
        statuses = threatStatuses,
        center = threatCenter,
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

    local threatDistance = SpatialAgent.distance2D(ownPos, threatCenter)
    local threatDirection = SpatialAgent.calculateDirection(ownPos, threatCenter)
    
    -- Set movement distance based on action
    if retreat then
        -- Move away from threats
        local retreatDistance = 2000  -- 2km retreat
        local retreatDirection = SpatialAgent.rotateVector(threatDirection, 180)
        return SpatialAgent.calculateDestination(ownPos, retreatDirection, retreatDistance)
    else
        -- Move toward threats (advance)
        local optimalRange = 250   -- Close to 250m for optimal engagement
        local weaponRange = 1000   -- Max weapon range is 1km
        
        -- If beyond weapon range, move to weapon range
        -- If within weapon range, close to optimal range for better accuracy
        local targetRange = threatDistance > weaponRange and weaponRange or optimalRange
        
        -- If already at or closer than optimal range, stay put
        if threatDistance <= optimalRange then
            return nil
        end
        
        return SpatialAgent.calculateDestination(ownPos, threatDirection, threatDistance - targetRange)
    end
end

function GroupCommander:calculateReturnToObjective()
    -- Calculate retreat destination back toward objective/friendly lines
    local ownPos = self:getOwnPosition()
    if not ownPos then
        return nil
    end
    
    local context = self.orderContext
    if context and context.position then
        -- Retreat toward ordered objective
        local distance = SpatialAgent.distance2D(ownPos, context.position)
        local direction = SpatialAgent.calculateDirection(ownPos, context.position)
        
        if distance and distance > 1 then
            -- Move 1km back toward objective
            local retreatDistance = math.min(1000, distance)
            return SpatialAgent.calculateDestination(ownPos, direction, retreatDistance)
        end
    end
end

function GroupCommander:calculateThreatCenter(observedOnly)
    -- Calculate the average position of threats based on last known positions
    -- observedOnly: if true, only include threats directly observed by THIS unit (not shared intel)
    local currentTime = timer.getTime()
    local threatsToInclude = {}
    
    local threats = self.threatTracker:getThreats()
    for unitName, threatData in pairs(threats) do
        -- Filter to only this unit's own observations if requested
        local includeThisThreat = true
        if observedOnly then
            -- Check if THIS unit has observed the threat recently (within last 30 seconds)
            local selfObservedRecently = false
            if threatData.sightings then
                for _, sighting in ipairs(threatData.sightings) do
                    if sighting.observedBy == self.groupName and 
                       (currentTime - sighting.observedAt) < 30 then
                        selfObservedRecently = true
                        break
                    end
                end
            end
            
            if not selfObservedRecently then
                -- Skip threats not directly observed by this unit
                includeThisThreat = false
            end
        end
        
        if includeThisThreat then
            table.insert(threatsToInclude, threatData)
        end
    end
    
    -- Use SpatialAgent to calculate center
    return SpatialAgent.calculateThreatCenter(threatsToInclude)
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

-- HELPER METHODS (used by TacticalEngagementPlan)

function GroupCommander:getStatusReport()
    return ForceStatusAnalyzer.getStatusReport(self.groupName, self.initialUnitNames, self.fuelRemaining)
end

function GroupCommander:getCollectiveStatus()
    local statusReport = self:getStatusReport()
    return ForceStatusAnalyzer.getCollectiveStatusFromReport(statusReport, #self.initialUnitNames)
end

function GroupCommander:getDestinationToObjective(objectivePosition, objectiveRadius)
    -- Check if we're within objective radius. If so, return nil (stay put).
    -- If not, return the objective position to move toward.
    local ownPos = self:getOwnPosition()
    if not ownPos then
        return objectivePosition  -- Can't determine position, default to moving
    end
    
    if SpatialAgent.isWithinRadius(ownPos, objectivePosition, objectiveRadius) then
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

function GroupCommander:getCriticalStatus(situation)
    local status = situation.statusReport
    local threat = situation.threatAssessment
    
    if not status or status.aliveCount == 0 then
        return nil  -- No decision needed
    end
    
    local totalUnits = #self.initialUnitNames
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    local low_ammo = ForceStatusAnalyzer.isAmmoLow(status.ammoCount, self.initialAmmoCount, 20)
    
    -- CRITICAL: Heavy casualties (>40%) - force retreat
    if attritionRate > 0.4 then
        return {
            level = "CRITICAL",
            reason = "HEAVY_CASUALTIES",
        }
    end
    
    -- CRITICAL: No ammunition - hold or retreat
    if self.initialAmmoCount > 0 and status.ammoCount == 0 then
        if threat.count > 0 and not threat.stale then
            return {
                level = "CRITICAL",
                reason = "NO_AMMO_WITH_THREATS",
            }
           
        else
            return {
                level = "WARNING",
                reason = "NO_AMMO_NO_THREATS",
            }
        end
    end
    
    -- WARNING: Moderate casualties (30-40%) with unfavorable situation
    if attritionRate > 0.3 and threat.favorability < 0.8 then
        return {
            level = "WARNING",
            reason = "MODERATE_CASUALTIES",
        }
    end
    
    -- WARNING: Light casualties (20-30%) with clearly unfavorable
    if attritionRate > 0.2 and threat.favorability < 0.65 then
        return {
            level = "WARNING",
            reason = "EARLY_CASUALTIES",
        }
    end
    
    -- WARNING: Low ammunition - hold unless overwhelming advantage
    if self.initialAmmoCount > 0 then
        if low_ammo and threat.favorability < 2.0 then
            return {
                level = "WARNING",
                reason = "LOW_AMMO",
            }
        end
    end
    
    return nil  -- No critical conditions
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

function GroupCommander:getSlowestUnitSpeed()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return 0
    end
    
    local units = group:getUnits()
    local slowestSpeed = nil
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            local speed = unit:getDesc().speedMax
            if not slowestSpeed or speed < slowestSpeed then
                slowestSpeed = speed
            end
        end
    end
    return slowestSpeed or 0
end

-- HELPER METHODS

function GroupCommander:issueMoveOrder(point)
    -- Validate point parameter
    if not point or not point.x or not point.z then
        env.info("ERROR: " .. self.groupName .. " received invalid move order (nil or invalid point)")
        return
    end
    
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
        distance = SpatialAgent.distance2D(point, ownPos)
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
        true
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

function GroupCommander:updateFuelConsumption(currentTime, currentPos)
    if currentPos and self.lastPosition then
        -- Calculate distance traveled
        local distanceTraveled = SpatialAgent.distance2D(currentPos, self.lastPosition)
        
        -- Calculate time elapsed
        local timeElapsed = currentTime - self.lastObserveTime
        
        -- Fuel burn rates (balanced for ground vehicles)
        -- Movement: 250 statute miles (402km) on full tank
        local movementBurnRate = 0.0000025  -- 100% fuel over 402,336m
        -- Idle: 5x the drive time at 30mph (41.7 hours idle on full tank)
        local idleBurnRate = 0.0000067  -- 100% fuel over 41.7 hours (150,012s)
        
        -- Apply fuel consumption
        local movementBurn = distanceTraveled * movementBurnRate
        local idleBurn = timeElapsed * idleBurnRate
        self.fuelRemaining = math.max(0, self.fuelRemaining - movementBurn - idleBurn)
    end
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
    local shouldAbort = threat.favorability < context.retreatThreshold
    
    if shouldAbort then
        env.info(self.groupName .. " DECIDE: Aborting order due to threat (favorability=" .. 
                 string.format("%.2f", threat.favorability) .. ")")
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

return GroupCommander
