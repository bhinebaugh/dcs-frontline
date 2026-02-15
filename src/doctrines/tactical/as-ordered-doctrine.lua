-- OrderExecutionPlan: Assault-oriented behavior for executing orders
--
-- Assumes any order is essentially an assault mission:
-- - Move to destination
-- - Destroy threats near objective
-- - Defend position without pursuing too far
-- - Handle order lifecycle (start, complete, abort)
--
-- Critical status checks override normal behavior to force retreats when heavily damaged.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes
local orderStatus = constants.orderStatus
local taskTypes = constants.taskTypes

local AsOrderedDoctrine = {}
setmetatable(AsOrderedDoctrine, {__index = Doctrine})
AsOrderedDoctrine.__index = AsOrderedDoctrine

function AsOrderedDoctrine.new(commanderName)
    local self = Doctrine.new("AsOrdered", commanderName)
    setmetatable(self, AsOrderedDoctrine)

    self:registerPhase("Advance", AsOrderedDoctrine.advancePhase)
    self:registerPhase("Engage", AsOrderedDoctrine.engagePhase)
    self:registerPhase("Defend", AsOrderedDoctrine.defendPhase)
    self:registerPhase("Abort", AsOrderedDoctrine.abortPhase)
    
    return self
end

function AsOrderedDoctrine:considerEngage(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames
    local ownPosition = commander:getOwnPosition()
    local objectivePosition = situation.orderContext and situation.orderContext.position or nil

    local engageAssessment = 0.0

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        engageAssessment = engageAssessment + threat.favorability
    else
        engageAssessment = engageAssessment + threat.favorability / 2
    end

    -- distance
    local distanceToThreat = SpatialAgent.distance2D(ownPosition, threat.center)
    local distanceToObjective = SpatialAgent.distance2D(ownPosition, objectivePosition)
    if distanceToObjective and distanceToThreat and distanceToObjective > 0 and distanceToThreat < distanceToObjective then
        engageAssessment = engageAssessment + distanceToThreat / distanceToObjective
    end
    
    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    engageAssessment = engageAssessment - attritionRate

    -- ammunition
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
        engageAssessment = 0.0
    end

    if ForceStatusAnalyzer.isUnarmed(commander.initialAmmoCount) then
        engageAssessment = 0.0
    end
    
    return engageAssessment
end

function AsOrderedDoctrine:considerDefend(context)
    local commander = context.commander
    local situation = context.situation
    local objectivePosition = situation.orderContext and situation.orderContext.position or nil

    local defendAssessment = 0.0

    local distanceToObjective = SpatialAgent.distance2D(commander:getOwnPosition(), objectivePosition)
    if distanceToObjective and distanceToObjective < situation.orderContext.radius then
        defendAssessment = defendAssessment + 1.0
    end

    return defendAssessment
end

function AsOrderedDoctrine:considerAbort(context)
    local commander = context.commander
    local situation = context.situation
    local threat = situation.threatAssessment
    local status = situation.statusReport
    local totalUnits = #commander.initialUnitNames

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, commander.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, commander.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- threat favorability
    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    return retreatAssessment
end

function AsOrderedDoctrine:advancePhase(context)
    -- Move toward objective location
    local commander = context.commander
    local orders = commander.orders
    local destination = orders and orders.position or nil

    local engageThreshold = 0.4
    local abortThreshold = 0.8
    local defendThreshold = 0.2

    if orders.status == constants.orderStatus.ASSIGNED then
        orders:start()
    end

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        self:changePhase("Engage")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerDefend(context) >= defendThreshold then
        self:changePhase("Defend")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = destination
    }
end

function AsOrderedDoctrine:engagePhase(context)
    -- Engage threats encountered along route

    local threat = context.situation.threatAssessment

    local engageThreshold = 0.3
    local abortThreshold = 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        local ownPosition = context.commander:getOwnPosition()
        local threatDistance = SpatialAgent.distance2D(ownPosition, threat.center)
        local standoffDistance = 300
        local direction = SpatialAgent.calculateDirection(ownPosition, threat.center)
        local engageDest = SpatialAgent.calculateDestination(ownPosition, direction, threatDistance - standoffDistance)
        return {
            disposition = dispositionTypes.ADVANCE,
            destination = engageDest
        }
    end

    self:changePhase("Advance")
    return {
        disposition = dispositionTypes.HOLD,
        destination = nil
    }

end

function AsOrderedDoctrine:defendPhase(context)
    -- Hold position and defend against nearby threats
    local commander = context.commander
    local destination = context.situation.orderContext.position
    local radius = context.situation.orderContext.radius or 500

    local hasExpiration = commander.orders and commander.orders.expirationTime
    local isExpired = context.commander.orders:isExpired()

    if isExpired or not hasExpiration then
        commander.orders:complete()
    end

    return {
        disposition = dispositionTypes.DEFEND,
        destination = destination,
        radius = radius
    }
end

function AsOrderedDoctrine:abortPhase(context)
    -- Move away from threats toward safety
    local commander = context.commander
    local situation = context.situation

    local threat = situation.threatAssessment
    local ownPosition = commander:getOwnPosition()

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(threat.center, direction, 1000)
    else
        self:changePhase("Hold")
    end

    commander.orders:abort("threat_retreat")

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest
    }
end

return AsOrderedDoctrine
