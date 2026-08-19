local constants = require("constants")
local DefensiveDoctrine = require("doctrines.tactical.defensive-doctrine")
local EngagementAnalyzer = require("engagement-analyzer")
local ForceStatusAnalyzer = require("force-status-analyzer")
local GroupProfiler = require("group-profiler")
local OODACommander = require("ooda-commander")
local AsOrderedDoctrine = require("doctrines.tactical.as-ordered-doctrine")
local AssaultDoctrine = require("doctrines.tactical.assault-doctrine")
local CommanderVisualizer = require("commander-visualizer")
local IndirectDoctrine = require("doctrines.tactical.indirect-doctrine")
local PatrolDoctrine = require("doctrines.tactical.patrol-doctrine")
local ReconDoctrine = require("doctrines.tactical.recon-doctrine")
local RallyDoctrine = require("doctrines.tactical.rally-doctrine")
local SpatialAgent = require("spatial-agent")
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
    self.lastFireOrder = nil
    self.pendingOrderAction = nil
    self.pendingFireAtPoint = nil
    self.groupProfile = nil
    self.suitability = nil
    self.ownForceStrength = nil
    self.roe = roe.WEAPON_HOLD
    self.threatTracker = ThreatTracker.new(groupName)
    self.threatAnalysis = nil
    self.lastThreatCenter = nil
    self.allyIntel = nil  -- Nearby ally strength info from OpsCom
    self.destroyed = false  -- Tracks if group no longer exists
    -- self.visualizer = config.visualizer
    self.visualizer = CommanderVisualizer.new(config.map)
    
    -- Simulated fuel tracking (DCS doesn't model fuel for ground units)
    self.fuelRemaining = 1.0  -- Start at 100%
    self.lastPosition = nil
    self.lastObserveTime = timer.getTime()
    
    -- Active Doctrine (persists across OODA cycles until a new order is assigned)
    -- Default to groups defending their current position until tasked to an opscom
    self.doctrine = DefensiveDoctrine.new(self.groupName)
    self.doctrineOrder = nil
    
    -- Register this instance
    table.insert(GroupCommander.instances, self)
    
    return self
end

function GroupCommander.getInstance(groupName)
    for _, instance in ipairs(GroupCommander.instances) do
        if instance.groupName == groupName then
            return instance
        end
    end
    return nil
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

-- Returns a group to a clean slate before it's handed to a new opscom.
-- Must reset doctrine (not just orders) - a group returning from an
-- in-progress order still has its old doctrine instance (e.g. IndirectDoctrine
-- mid-Hold-phase) referencing an order that's about to vanish. Leaving that
-- stale would crash on the next tick: the doctrine reads context.orderPosition
-- expecting an active order, but with self.orders nil buildDecisionContext
-- never populates it. Resetting to DefensiveDoctrine mirrors what a brand
-- new GroupCommander already starts with.
function GroupCommander:clearOrders()
    if self.orders and self.orders:isActive() then
        self.orders:abort("reassigned")
    end
    self.orders = nil
    self.doctrine = DefensiveDoctrine.new(self.groupName)
    self.doctrineOrder = nil
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
            -- Speed captured now, at observation time, same as position -
            -- it's time-sensitive intel (how fast was it moving when last
            -- seen), not something a consumer should query live later (see
            -- FireSupportPlan, which uses this to avoid wasting a fire
            -- mission on a target that's likely relocated by the time
            -- rounds land).
            local velocity = unit:getVelocity()
            local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z)
            table.insert(observedThreats, {
                name = unitName,
                position = unit:getPosition().p,
                speed = speed,
            })
        end
    end
    
    -- Update threat table with newly observed threats (keeping old ones)
    self.threatTracker:updateThreats(observedThreats)
    self.threatTracker:updateExpectedThreats(observedThreats, currentPos, detectionRadius)
    
    -- Age threats and progress their status
    self.threatTracker:ageThreats()
    
    -- Store direct LOS count for decision-making (to distinguish self-observed from shared intel)
    self.directLOSCount = #visibleThreatNames
    
    -- Single consolidated OBSERVE summary
    local memoryCount = self.threatTracker:count()
    local expectedCount = #self.threatTracker:expectedThreats(currentPos, detectionRadius)
    local expectedStr = expectedCount > 0 and (" Exp:" .. expectedCount) or ""
    env.info("* " .. self.groupName .. " OBSERVE: LOS:" .. #visibleThreatNames .. expectedStr .. " Mem:" .. memoryCount)
end

function GroupCommander:orient()
    -- Gather situational awareness for decision making
    self.ownForceStrength = self:analyzeOwnForce()

    self.threatAssessment = self:assessThreats()

    -- Derive group profile
    local ownPos = self:getOwnPosition()
    self.groupProfile = GroupProfiler.profileGroup(self.groupName, self.initialUnitNames, self.initialAmmoCount, self.fuelRemaining)

    -- Update suitability against current order's mission profile
    if self.orders and self.orders.missionProfile then
        self.suitability = self:getSuitability(self.orders.missionProfile)
    else
        self.suitability = nil
    end
end

--- @class TacticalContext
--- @field groupName string
--- @field ownPosition table
--- @field totalUnits number
--- @field initialAmmoCount number
--- @field threatAssessment table
--- @field statusReport table
--- @field suitability number|nil
--- @field ownRange table|nil
--- @field hasActiveOrders boolean
--- @field orderType string|nil
--- @field orderPosition table|nil
--- @field orderProximity number|nil
--- @field orderAlr string|nil
--- @field distanceToOrdered number|nil
--- @field withinObjective boolean|nil
--- @field retreatThreshold number|nil
--- @field orderIsExpired boolean|nil
--- @field orderHasDeadline boolean|nil
--- @return TacticalContext|nil
function GroupCommander:buildDecisionContext()
    local ownPosition = self:getOwnPosition()
    if not ownPosition then return nil end

    local hasActiveOrders = self.orders ~= nil and self.orders:isActive()

    local orderType, orderPosition, orderProximity, orderAlr
    local distanceToOrdered, withinObjective, retreatThreshold
    local orderIsExpired, orderHasDeadline

    if hasActiveOrders then
        orderType     = self.orders.type
        orderPosition = self.orders.position
        orderProximity   = self.orders.proximity or 500
        orderAlr      = self.orders.alr or alr.LOW

        distanceToOrdered = SpatialAgent.distance2D(ownPosition, orderPosition)
        withinObjective   = distanceToOrdered <= orderProximity

        retreatThreshold = 0.4
        if orderAlr == alr.LOW then
            retreatThreshold = 0.2
        elseif orderAlr == alr.HIGH then
            retreatThreshold = 0.8
        end

        orderHasDeadline = self.orders.deadline ~= nil
        orderIsExpired   = self.orders:isExpired() or false
    end

    return {
        groupName        = self.groupName,
        ownAlr           = self.alr,
        ownPosition      = ownPosition,
        totalUnits       = #self.initialUnitNames,
        initialAmmoCount = self.initialAmmoCount,
        threatAssessment = self.threatAssessment,
        statusReport     = self:getStatusReport(),
        suitability      = self.suitability,
        -- The group's own reach, independent of any currently-detected
        -- threat (threatAssessment.range is two-sided and needs a known
        -- target composition) - lets a doctrine position itself relative to
        -- the order position alone, e.g. IndirectDoctrine standing off at
        -- its own max weapon range regardless of whether a threat has been
        -- spotted there yet.
        ownRange         = self.groupProfile and self.groupProfile.range,
        hasActiveOrders  = hasActiveOrders or false,
        orderType        = orderType,
        orderPosition    = orderPosition,
        orderProximity   = orderProximity,
        orderAlr         = orderAlr,
        distanceToOrdered = distanceToOrdered,
        withinObjective  = withinObjective,
        retreatThreshold = retreatThreshold,
        orderIsExpired   = orderIsExpired,
        orderHasDeadline = orderHasDeadline,
    }
end

function GroupCommander:decide()
    -- If an order resolved (completed/aborted) last tick via act(),
    -- doctrine instance may still be awaiting reassignment by the operational layer.
    -- In this case hold in place rather than planning against a finished order's stale context
    -- (e.g. orderPosition is no longer populated).
    if self.orders and self.orders:isFinished() then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        self.pendingOrderAction = nil
        return
    end

    -- Build a fresh doctrine only when a genuinely new order has been assigned
    -- (identity check, not status) so in-progress phase state isn't discarded
    -- while a doctrine is still working an order that hasn't called orderAction "start" yet.
    if self.orders and self.orders ~= self.doctrineOrder then
        self.doctrineOrder = self.orders
        self.visualizer:syncGroupMove(self, self.color) --reset movement arrows
        if self.orders.type == taskTypes.PATROL then
            self.doctrine = PatrolDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.RECON then
            self.doctrine = ReconDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.RALLY then
            self.doctrine = RallyDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.ASSAULT then
            self.doctrine = AssaultDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.DEFEND then
            self.doctrine = DefensiveDoctrine.new(self.groupName)
        elseif self.orders.type == taskTypes.INDIRECT then
            self.doctrine = IndirectDoctrine.new(self.groupName)
        else
            self.doctrine = AsOrderedDoctrine.new(self.groupName)
        end
    end

    -- TODO decide if it makes sense to reenable this compared to first block above
    -- // it would be one way of tying up residual orders after opscom disbands
    -- if self.orders and self.orders:isFinished() then
    --     self.orders = nil
    --     self.doctrine = DefensiveDoctrine.new(self.groupName)
    -- end

    -- if not self.doctrine then
    --     self.doctrine = DefensiveDoctrine.new(self.groupName)
    -- end

    -- Check if we have valid assessment data
    if not self.ownForceStrength or not self.threatAssessment then
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end

    -- Build decision context snapshot
    local context = self:buildDecisionContext()
    if not context then
        env.info("ERROR: Could not build tactical context for " .. self.groupName)
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        return
    end
        
    -- Use Doctrine to make tactical decisions
    if not self.doctrine then return end
    local decision = self.doctrine:plan(context)
    if decision then
        self:setDisposition(decision.disposition)
        self.destination = decision.destination
        self.pendingOrderAction = decision.orderAction
        self.pendingFireAtPoint = decision.fireAtPoint
    else
        env.info("ERROR: Doctrine returned nil decision for " .. self.groupName)
        self.pendingFireAtPoint = nil
        self:setDisposition(dispositionTypes.HOLD)
        self.destination = self:getOwnPosition()
        self.pendingOrderAction = nil
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
    
    -- Apply order lifecycle action returned by Doctrine
    if self.pendingOrderAction and self.orders then
        if self.pendingOrderAction == "start" then
            self.orders:start()
        elseif self.pendingOrderAction == "complete" then
            self.orders:complete()
        elseif self.pendingOrderAction == "abort" then
            self.orders:abort("doctrine_abort")
        end
        self.pendingOrderAction = nil
    end

    -- A pending fire-at-point task (IndirectDoctrine's Hold phase) takes
    -- over movement dispatch entirely rather than running alongside it -
    -- stopMovement()'s {id='Hold'} task would otherwise replace/cancel the
    -- fire mission every single cycle, since DCS's setTask always replaces
    -- whatever task is currently active.
    if self.pendingFireAtPoint then
        local point = self.pendingFireAtPoint.position
        -- Only reissue if the target has moved (more than 100m tolerance) -
        -- FireAtPoint is meant to be a standing task the AI keeps executing
        -- on its own, so reissuing it every cycle risks restarting the fire
        -- mission instead of letting it run continuously.
        if not self.lastFireOrder or
        math.abs(self.lastFireOrder.x - point.x) > 100 or
        math.abs(self.lastFireOrder.z - point.z) > 100 then
            self:issueFireAtPoint(point, self.pendingFireAtPoint.radius)
            self.lastFireOrder = {x = point.x, z = point.z}
        end
    -- Only issue move orders for ADVANCE and RETREAT (not HOLD or DEFEND)
    -- If destination has been set to nil, stop the group where they are
    elseif self.destination then
        if (self.disposition == dispositionTypes.ADVANCE or self.disposition == dispositionTypes.RETREAT) then
            -- Only issue if destination has changed (more than 100m tolerance)
            if not self.lastMoveOrder or
            math.abs(self.lastMoveOrder.x - self.destination.x) > 100 or
            math.abs(self.lastMoveOrder.z - self.destination.z) > 100 then
                self:issueMoveOrder(self.destination)
                self.lastMoveOrder = {x = self.destination.x, z = self.destination.z}
                if self.visualizer then
                    self.visualizer:appendGroupMove(self, self.color)
                end
            end
        else
            self:stopMovement()
        end
    else
        self:stopMovement()
    end

    if self.visualizer then
        self.visualizer:syncGroupOrder(self, self.color)
    end
end

function GroupCommander:analyzeOwnForce()
    return GroupProfiler.profileUnits(self:getOwnUnits())
end

function GroupCommander:analyzeThreatCapabilities()
    -- Scoped to detectionRadius of our own current position - unlike
    -- OperationalCommander's threatTracker (deliberately unscoped, since it
    -- aggregates broadly for later position-scoped lookups elsewhere), this
    -- feeds this specific group's own favorability/range/standoff decisions,
    -- which should react to what's actually nearby right now, not every
    -- threat we've personally seen anywhere on our route in the last two
    -- minutes (see EngagementAnalyzer.assessRange, considerAbort/considerEngage).
    local threats = self.threatTracker:getRecentThreats(nil, self:getOwnPosition(), detectionRadius)
    local threatUnits = {}
    for unitName, _ in pairs(threats) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            table.insert(threatUnits, unit)
        end
    end
    return GroupProfiler.profileUnits(threatUnits)
end

-- Assess threat situation including staleness, center of mass, and comparative strength
function GroupCommander:assessThreats()
    local threatAnalysis = self:analyzeThreatCapabilities()

    -- Calculate threat center if threats exist - same scoping as
    -- analyzeThreatCapabilities, so the center is drawn from the same
    -- nearby set the favorability/range figures above it were built from.
    local threatCenter = nil
    local recentThreats = self.threatTracker:getRecentThreats(nil, self:getOwnPosition(), detectionRadius)
    if threatAnalysis.unitCount > 0 then
        threatCenter = SpatialAgent.calculateCenterOfObjects(recentThreats)
    end

    -- Combine own force with ally intel for favorability calculation
    local combinedForce = self.ownForceStrength
    if self.allyIntel and self.allyIntel.unitCount and self.allyIntel.unitCount > 0 then
        -- minRange belongs to whichever side's weapon just won that tier's
        -- range below (not independently maxed/minned) - same pairing
        -- GroupProfiler keeps within a single force's own profile.
        local function pairedMinRange(tier)
            if self.ownForceStrength.range[tier] >= self.allyIntel.range[tier] then
                return self.ownForceStrength.minRange[tier]
            end
            return self.allyIntel.minRange[tier]
        end

        combinedForce = {
            unitCount = self.ownForceStrength.unitCount + self.allyIntel.unitCount,
            offensiveCapability = {
                vsUnarmored = self.ownForceStrength.offensiveCapability.vsUnarmored + self.allyIntel.offensiveCapability.vsUnarmored,
                vsLight     = self.ownForceStrength.offensiveCapability.vsLight     + self.allyIntel.offensiveCapability.vsLight,
                vsMedium    = self.ownForceStrength.offensiveCapability.vsMedium    + self.allyIntel.offensiveCapability.vsMedium,
                vsHeavy     = self.ownForceStrength.offensiveCapability.vsHeavy     + self.allyIntel.offensiveCapability.vsHeavy,
                vsAir       = self.ownForceStrength.offensiveCapability.vsAir       + self.allyIntel.offensiveCapability.vsAir,
            },
            composition = {
                unarmored = self.ownForceStrength.composition.unarmored + self.allyIntel.composition.unarmored,
                light     = self.ownForceStrength.composition.light     + self.allyIntel.composition.light,
                medium    = self.ownForceStrength.composition.medium    + self.allyIntel.composition.medium,
                heavy     = self.ownForceStrength.composition.heavy     + self.allyIntel.composition.heavy,
                air       = self.ownForceStrength.composition.air       + self.allyIntel.composition.air,
            },
            -- Range doesn't add up like firepower - the longest-reaching
            -- contributor (own or ally) sets the combined force's reach.
            range = {
                unarmored = math.max(self.ownForceStrength.range.unarmored, self.allyIntel.range.unarmored),
                light     = math.max(self.ownForceStrength.range.light,     self.allyIntel.range.light),
                medium    = math.max(self.ownForceStrength.range.medium,    self.allyIntel.range.medium),
                heavy     = math.max(self.ownForceStrength.range.heavy,     self.allyIntel.range.heavy),
                air       = math.max(self.ownForceStrength.range.air,       self.allyIntel.range.air),
            },
            minRange = {
                unarmored = pairedMinRange("unarmored"),
                light     = pairedMinRange("light"),
                medium    = pairedMinRange("medium"),
                heavy     = pairedMinRange("heavy"),
                air       = pairedMinRange("air"),
            },
        }
    end

    -- How far apart we and the threat actually are right now - lets
    -- assessRange treat a weapon as unable to engage while we're inside its
    -- own dead zone (see GroupProfile.minRange), rather than always judging
    -- reach by nominal max range alone.
    local currentDistance = threatCenter and SpatialAgent.distance2D(self:getOwnPosition(), threatCenter)

    local favorability = GroupProfiler.calculateFavorability(combinedForce, threatAnalysis)
    local range = EngagementAnalyzer.assessRange(combinedForce, threatAnalysis, currentDistance)

    return {
        count        = threatAnalysis.unitCount,
        analysis     = threatAnalysis,
        center       = threatCenter,
        favorability = favorability,
        range        = range,
    }
end

function GroupCommander:getSuitability(missionProfile)
    if not missionProfile then return 1.0 end
    local profile = self.groupProfile
    if not profile then return 0.0 end

    -- Proximity score: 1.0 = perfect match, approaches 0 as difference grows.
    -- Handles unbounded capability values (which are summed across unit count).
    local function proximity(actual, ideal)
        return 1 / (1 + math.abs((actual or 0) - ideal))
    end

    local score = 0.0
    local count = 0

    if missionProfile.offensiveCapability then
        local idealCap = missionProfile.offensiveCapability
        local ownCap   = profile.offensiveCapability
        for _, field in ipairs({"vsUnarmored", "vsLight", "vsMedium", "vsHeavy", "vsAir"}) do
            if idealCap[field] ~= nil then
                score = score + proximity(ownCap[field], idealCap[field])
                count = count + 1
            end
        end
    end

    if missionProfile.range then
        local idealRange = missionProfile.range
        local ownRange   = profile.range
        for _, field in ipairs({"unarmored", "light", "medium", "heavy", "air"}) do
            if idealRange[field] ~= nil then
                score = score + proximity(ownRange[field], idealRange[field])
                count = count + 1
            end
        end
    end

    if missionProfile.attritionRate ~= nil then
        score = score + proximity(profile.attritionRate, missionProfile.attritionRate)
        count = count + 1
    end

    if missionProfile.ammoRatio ~= nil then
        score = score + proximity(profile.ammoRatio, missionProfile.ammoRatio)
        count = count + 1
    end

    if count == 0 then return 1.0 end
    return score / count
end

-- Static: remove destroyed instances from the global instances list
function GroupCommander.removeDestroyed()
    local surviving = {}
    local removed = 0
    for _, instance in ipairs(GroupCommander.instances) do
        if not instance.destroyed then
            table.insert(surviving, instance)
        else
            removed = removed + 1
            env.info(string.format("* GroupCommander: Removing destroyed group %s from memory",
                instance.groupName or "unknown"))
        end
    end
    if removed > 0 then
        GroupCommander.instances = surviving
    end
end

function GroupCommander:getStatusReport()
    return ForceStatusAnalyzer.getStatusReport(self.groupName, self.initialUnitNames, self.fuelRemaining)
end

function GroupCommander:getCriticalStatus()
    return ForceStatusAnalyzer.getCriticalStatusReport(self.groupName, self.initialUnitNames, self.fuelRemaining)
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
    local units = self:getOwnUnits()
    local positions = {}
    for _, unit in ipairs(units) do
        local pos = unit:getPosition().p
        table.insert(positions, pos)
    end
    return SpatialAgent.calculateCenter(positions)
end

function GroupCommander:getOwnUnits()
    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        return {}
    end
    
    local units = group:getUnits()
    local validUnits = {}
    for _, unit in ipairs(units) do
        if unit and unit:isExist() then
            table.insert(validUnits, unit)
        end
    end
    return validUnits
end

function GroupCommander:getOwnUnitNames()
    local units = self:getOwnUnits()
    local unitNames = {}
    for _, unit in ipairs(units) do
        table.insert(unitNames, unit:getName())
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
        threats = self.threatTracker:getRecentThreats(),
    }
    return status
end

function GroupCommander:getSlowestUnitSpeed()
    local units = self:getOwnUnits()
    local slowestSpeed = nil
    for _, unit in ipairs(units) do
        local speed = unit:getDesc().speedMax
        if not slowestSpeed or speed < slowestSpeed then
            slowestSpeed = speed
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
    env.info("* " .. self.groupName .. " DECIDE: Move to " .. string.format("%.5f", lat or 0) .. "," .. string.format("%.5f", lon or 0))
    
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
    
    -- TODO use 'crosscountry' boolean in precalculated control zone edge table to help decide
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

-- Issues DCS's FireAtPoint task, the actual mechanism for indirect/area
-- fire - ROE alone only governs whether AI auto-engages targets it directly
-- perceives, it doesn't make artillery shell a map point. radius is the
-- task's dispersion radius (how tightly rounds land around the point), not
-- an engagement/detection range.
function GroupCommander:issueFireAtPoint(point, radius)
    if not point or not point.x or not point.z then
        env.info("ERROR: " .. self.groupName .. " received invalid fire-at-point order (nil or invalid point)")
        return
    end

    local group = Group.getByName(self.groupName)
    if not group or not group:isExist() then
        env.info("ERROR: Cannot issue fire-at-point, group " .. self.groupName .. " does not exist")
        return
    end

    local lat, lon = coord.LOtoLL({x = point.x, y = 0, z = point.z})
    env.info("* " .. self.groupName .. " ACT: Fire at point " .. string.format("%.5f", lat or 0) .. "," .. string.format("%.5f", lon or 0))

    local controller = group:getController()
    controller:setTask({
        id = 'FireAtPoint',
        params = {
            point  = {x = point.x, y = point.z}, -- DCS Vec2: y is the world's z axis
            radius = radius or 100,
        },
    })
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
    -- allyIntel: GroupProfile from GroupProfiler.profileUnits
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
