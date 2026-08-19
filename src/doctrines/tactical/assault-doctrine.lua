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

-- How long to keep trading fire with a threat blocking the route before
-- giving up on winning that fight and pushing through to the objective
-- anyway - capturing the zone takes priority over resolving every
-- engagement first. Only relevant at all once considerEngage's corridor
-- gate has already established the threat is genuinely in the way.
local engagePatience = 180 -- seconds

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

-- Seconds since entering the current phase, or 0 if we haven't changed
-- phase yet (phaseHistory empty). Doctrine:changePhase records a
-- {name, changedAt} entry for the phase being *left* at the moment of
-- transition, so the last entry's changedAt is when the current phase was
-- entered.
function AssaultDoctrine:timeInPhase()
    local last = self.phaseHistory[#self.phaseHistory]
    if not last then
        return 0
    end
    return timer.getTime() - last.changedAt
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

function AssaultDoctrine:considerEngage(context)
    local threat = context.threatAssessment

    if threat.count == 0 or not threat.center then
        return 0.0
    end

    -- Only engage a threat actually standing between us and the objective -
    -- something nearby but off to the side isn't worth diverting an assault
    -- for; capturing the zone is the job, not clearing everything within
    -- detection range on the way. corridorWidth uses the threat's own reach
    -- (theirReach) rather than a fixed width, since a threat close enough to
    -- hit us in passing is "in the way" even when not directly on the line.
    local ownPosition = context.ownPosition
    local objectivePosition = context.orderPosition
    local corridorWidth = (threat.range and threat.range.theirReach) or 1000
    if not SpatialAgent.isBetween(threat.center, ownPosition, objectivePosition, corridorWidth) then
        return 0.0
    end

    local status = context.statusReport
    local totalUnits = context.totalUnits

    local engageAssessment = 0.0

    -- threat favorability
    if threat.favorability < 1.0 then
        engageAssessment = engageAssessment + threat.favorability
    else
        engageAssessment = engageAssessment + threat.favorability / 2
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

    -- range advantage: outranging the threat reduces retreat pressure,
    -- being outranged increases it (see EngagementAnalyzer.assessRange)
    if threat.range then
        retreatAssessment = retreatAssessment - threat.range.advantageRatio
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

function AssaultDoctrine:engagePhase(context)
    local threat = context.threatAssessment

    local engageThreshold = 0.3
    local abortThreshold = context.retreatThreshold or 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "abort",
        }
    end

    local patienceExpired = self:timeInPhase() >= engagePatience

    if not patienceExpired and self:considerEngage(context) >= engageThreshold then
        local ownPosition      = context.ownPosition
        local standoffDistance = (threat.range and threat.range.standoffDistance) or 1000

        -- Positioning at an advantageous range: stop within our own reach
        -- but outside the threat's if we outrange them, otherwise rush to
        -- our own effective range rather than loitering somewhere we can't
        -- return fire (see EngagementAnalyzer.assessRange's standoffDistance).
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

    -- Reached either by considerEngage dropping below threshold (threat no
    -- longer blocking the route, or beaten badly enough to stop mattering)
    -- or by patienceExpired (still blocking, but capturing the objective
    -- wins out over continuing to slug it out) - same outcome either way.
    self:changePhase("Advance")
    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
    }
end

function AssaultDoctrine:defendPhase(context)
    -- Hold position and defend against nearby threats
    local destination = context.orderPosition
    local proximity = context.orderProximity or 500
    local distanceToObjective = SpatialAgent.distance2D(context.ownPosition, destination)

    local isExpired = context.orderIsExpired or not context.orderHasDeadline
    local isCloseEnough = distanceToObjective <= proximity
    local isComplete = isExpired or isCloseEnough

    if isComplete then
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

-- Never actually invoked: the OODA cadence means orderAction="abort" (set
-- above, in whichever phase's considerAbort check tripped) is always
-- processed by act() before this doctrine's plan() would run again, so
-- GroupCommander:decide() hands off to DefensiveDoctrine's own retreat
-- handling before Abort's own phase handler ever gets a turn (see
-- GroupCommander:decide). Kept registered as a safe fallback rather than
-- removed outright, in case that assumption ever stops holding - this used
-- to call self:changePhase("Hold") in one branch, which crashed since
-- AssaultDoctrine has never registered a "Hold" phase; unreachable in
-- practice, but worth not leaving as a landmine.
function AssaultDoctrine:abortPhase(context)
    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
    }
end

return AssaultDoctrine
