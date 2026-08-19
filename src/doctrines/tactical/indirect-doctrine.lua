-- IndirectDoctrine: fire-support behavior for INDIRECT orders
--
-- Get within the group's own max weapon range of the order position, hold
-- there while DCS's AI/ROE handles the actual firing, and retreat if
-- directly threatened, low on ammo, or taking losses.
--
-- Deliberately doesn't lean on calculateFavorability for retreat pressure
-- the way the other tactical doctrines do: an artillery group's raw
-- offensiveCapability makes it look "favorable" against armor it has no way
-- to survive once the range gap closes, so considerAbort weights the range
-- advantage (is the threat closing the distance on us) instead.

local constants = require("constants")
local ForceStatusAnalyzer = require("force-status-analyzer")
local Doctrine = require("doctrine")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes
local rangeTiers = {"unarmored", "light", "medium", "heavy", "air"}

local IndirectDoctrine = {}
setmetatable(IndirectDoctrine, {__index = Doctrine})
IndirectDoctrine.__index = IndirectDoctrine

function IndirectDoctrine.new(commanderName)
    local self = Doctrine.new("Indirect", commanderName)
    setmetatable(self, IndirectDoctrine)

    self:registerPhase("Advance", IndirectDoctrine.advancePhase)
    self:registerPhase("Hold", IndirectDoctrine.holdPhase)
    self:registerPhase("Abort", IndirectDoctrine.abortPhase)

    return self
end

local function maxOwnRange(ownRange)
    local best = 0
    for _, tier in ipairs(rangeTiers) do
        local value = (ownRange and ownRange[tier]) or 0
        if value > best then best = value end
    end
    return best
end

function IndirectDoctrine:considerAbort(context)
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

    -- health: a group that hasn't lost a unit can still be battered close to
    -- death (attritionRate below wouldn't catch this - see getStatusReport's
    -- healthRatio)
    if ForceStatusAnalyzer.isHealthCritical(status.healthRatio) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isHealthLow(status.healthRatio) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- fuel
    if ForceStatusAnalyzer.isFuelCritical(status.fuelRemaining) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isFuelLow(status.fuelRemaining) then
        retreatAssessment = retreatAssessment + 0.5
    end

    -- attrition rate
    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    -- range advantage: a negative advantageRatio means the threat outreaches
    -- (or is closing the distance on) us, which matters far more here than
    -- raw favorability
    if threat.count > 0 and threat.range then
        retreatAssessment = retreatAssessment - threat.range.advantageRatio
    end

    return retreatAssessment
end

function IndirectDoctrine:advancePhase(context)
    local abortThreshold = context.retreatThreshold or 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    local destination = context.orderPosition
    local ownPosition = context.ownPosition
    local reach = maxOwnRange(context.ownRange)
    local distanceToTarget = SpatialAgent.distance2D(ownPosition, destination)

    if reach <= 0 or distanceToTarget <= reach then
        self:changePhase("Hold")
        return {
            disposition = dispositionTypes.HOLD,
            destination = ownPosition,
            orderAction = "start",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = destination,
        orderAction = "start",
    }
end

function IndirectDoctrine:holdPhase(context)
    local abortThreshold = context.retreatThreshold or 0.8

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    local ownPosition = context.ownPosition
    local destination = context.orderPosition
    local reach = maxOwnRange(context.ownRange)
    local distanceToTarget = SpatialAgent.distance2D(ownPosition, destination)

    -- Target moved out of reach (or we drifted) - go back to closing the distance.
    if reach > 0 and distanceToTarget > reach then
        self:changePhase("Advance")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    -- Unlike AsOrderedDoctrine's defendPhase, a deadline-less order does NOT
    -- auto-complete on arrival: fire support is meant to keep firing for as
    -- long as it's needed, not report "arrived" and free itself up the
    -- moment it gets in range.
    if context.orderIsExpired then
        return {
            disposition = dispositionTypes.HOLD,
            destination = ownPosition,
            orderAction = "complete",
        }
    end

    return {
        disposition = dispositionTypes.HOLD,
        destination = ownPosition,
        fireAtPoint = { position = destination, radius = context.orderProximity },
    }
end

-- Abort's one real shot to act(): the trigger that got us here (considerAbort
-- tripping in Advance or Hold) deliberately only transitioned phase without
-- setting orderAction, so this handler - not the trigger - is what actually
-- retreats and declares the order aborted. Only after this runs does the
-- order become finished and GroupCommander:decide() hand off to
-- DefensiveDoctrine for continued self-preservation (see its comment).
function IndirectDoctrine:abortPhase(context)
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

return IndirectDoctrine
