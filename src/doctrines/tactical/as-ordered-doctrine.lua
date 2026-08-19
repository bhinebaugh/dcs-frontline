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
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits
    local ownPosition = context.ownPosition
    local objectivePosition = context.orderPosition

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
    if ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        engageAssessment = 0.0
    end

    if ForceStatusAnalyzer.isUnarmed(context.initialAmmoCount) then
        engageAssessment = 0.0
    end

    return engageAssessment
end

function AsOrderedDoctrine:considerDefend(context)
    local objectivePosition = context.orderPosition

    local defendAssessment = 0.0

    local distanceToObjective = SpatialAgent.distance2D(context.ownPosition, objectivePosition)
    if distanceToObjective and distanceToObjective < context.orderProximity then
        defendAssessment = defendAssessment + 1.0
    end

    return defendAssessment
end

function AsOrderedDoctrine:considerAbort(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    -- ammunition
    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
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

    -- suitability: if group no longer meets missionProfile, increase abort pressure
    local suitability = context.suitability
    if suitability and suitability < 0.3 then
        retreatAssessment = retreatAssessment + (0.3 - suitability) * 2
    end

    return retreatAssessment
end

function AsOrderedDoctrine:advancePhase(context)
    -- Move toward objective location
    local destination = context.orderPosition

    local engageThreshold = 0.4
    local abortThreshold = context.retreatThreshold or 0.8
    local defendThreshold = 0.2

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        self:changePhase("Engage")
        return {
            disposition = dispositionTypes.HOLD,
            destination = destination,
            orderAction = "start",
        }
    end

    if self:considerDefend(context) >= defendThreshold then
        self:changePhase("Defend")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "start",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = destination,
        orderAction = "start",
    }
end

function AsOrderedDoctrine:engagePhase(context)
    -- Engage threats encountered along route

    local threat = context.threatAssessment

    local engageThreshold = 0.3
    local abortThreshold = context.retreatThreshold or 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil
        }
    end

    if self:considerEngage(context) >= engageThreshold then
        local ownPosition      = context.ownPosition
        local standoffDistance = (threat.range and threat.range.standoffDistance) or 1000

        -- Standoff position: standoffDistance from threat, on our side of it.
        -- Computed this way rather than from ownPosition so the unit can never
        -- overshoot and pass through the threat.
        local standoffPos = SpatialAgent.pointAtDistance(ownPosition, threat.center, standoffDistance)

        if not standoffPos then
            return {
                disposition = dispositionTypes.HOLD,
                destination = ownPosition,
            }
        end

        return {
            disposition = dispositionTypes.ADVANCE,
            destination = standoffPos,
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
    local destination = context.orderPosition
    local proximity = context.orderProximity or 500

    if context.orderIsExpired or not context.orderHasDeadline then
        return {
            disposition = dispositionTypes.DEFEND,
            destination = destination,
            proximity   = proximity,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.DEFEND,
        destination = destination,
        proximity   = proximity,
    }
end

-- Abort's one real shot to act(): the triggers that got us here
-- (considerAbort tripping in Advance or Engage) deliberately only
-- transitioned phase without setting orderAction, so this handler - not the
-- trigger - is what actually retreats and declares the order aborted. Only
-- after this runs does the order become finished and GroupCommander:decide()
-- hand off to DefensiveDoctrine for continued self-preservation (see its
-- comment).
function AsOrderedDoctrine:abortPhase(context)
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    local retreatDest = nil
    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(ownPosition, direction, 1000)
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest,
        orderAction = "abort",
    }
end

return AsOrderedDoctrine
