-- Reworking of AsOrderedDoctrine to emphasize occupying position
--
-- Assault a position:
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

local AssaultDoctrine = {}
setmetatable(AssaultDoctrine, {__index = Doctrine})
AssaultDoctrine.__index = AssaultDoctrine

function AssaultDoctrine.new(commanderName)
    local self = Doctrine.new("Assault", commanderName)
    setmetatable(self, AssaultDoctrine)

    self:registerPhase("Advance", AssaultDoctrine.advancePhase)
    self:registerPhase("Engage", AssaultDoctrine.engagePhase)
    self:registerPhase("Defend", AssaultDoctrine.defendPhase)
    self:registerPhase("Abort", AssaultDoctrine.abortPhase)

    return self
end

function AssaultDoctrine:considerDefend(context)
    local objectivePosition = context.orderPosition

    local defendAssessment = 0.0

    local distanceToObjective = SpatialAgent.distance2D(context.ownPosition, objectivePosition)
    if distanceToObjective and distanceToObjective < context.orderProximity then
        defendAssessment = defendAssessment + 1.0
    end

    return defendAssessment
end

function AssaultDoctrine:considerAbort(context)
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

function AssaultDoctrine:advancePhase(context)
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
            orderAction = "abort",
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

function AssaultDoctrine:defendPhase(context)
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

function AssaultDoctrine:abortPhase(context)
    -- Move away from threats toward safety
    local threat = context.threatAssessment
    local ownPosition = context.ownPosition

    -- Use directly observed threats if available (more stable)
    local retreatDest = nil

    if threat.center then
        local direction = SpatialAgent.calculateDirection(threat.center, ownPosition)
        retreatDest = SpatialAgent.calculateDestination(threat.center, direction, 1000)
    else
        self:changePhase("Hold")
    end

    return {
        disposition = dispositionTypes.RETREAT,
        destination = retreatDest,
        orderAction = "abort",
    }
end

return AssaultDoctrine
