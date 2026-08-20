-- ResupplyDoctrine: travel to an assigned point and hold, for RESUPPLY
-- orders (see src/doctrines/operational/repair-resupply-plan.lua) - used by
-- the convoy on both legs of its trip (out to the rendezvous point, then
-- back to its origin to restock).
--
-- Like RepairDoctrine, this never marks its own order complete - the
-- operational doctrine drives that externally, issuing a fresh RESUPPLY
-- order (new position, same type) to redirect the convoy home once
-- resupply resolves. That's a genuinely new Order object, which
-- GroupCommander:decide() already treats as "new order assigned" and hands
-- a fresh doctrine instance starting at Advance - so in practice this
-- convoy never actually sits in Hold while its destination quietly changes
-- out from under it. holdPhase's own distance recheck below is a defensive
-- fallback for that case anyway, in case a future caller redirects a
-- convoy by mutating an existing order's position instead of reissuing.

local constants = require("constants")
local Doctrine = require("doctrine")
local ForceStatusAnalyzer = require("force-status-analyzer")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local ResupplyDoctrine = {}
setmetatable(ResupplyDoctrine, {__index = Doctrine})
ResupplyDoctrine.__index = ResupplyDoctrine

function ResupplyDoctrine.new(commanderName)
    local self = Doctrine.new("Resupply", commanderName)
    setmetatable(self, ResupplyDoctrine)

    self:registerPhase("Advance", ResupplyDoctrine.advancePhase)
    self:registerPhase("Hold", ResupplyDoctrine.holdPhase)
    self:registerPhase("Abort", ResupplyDoctrine.abortPhase)

    return self
end

-- An unarmed convoy has nothing to fight with, so any detected threat
-- alone (favorability pinned near 0) is reason enough to bolt - see
-- considerAbort's favorability term below, which already produces that
-- without needing a special case.
function ResupplyDoctrine:considerAbort(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    return retreatAssessment
end

function ResupplyDoctrine:considerFallback(context)
    local threat = context.threatAssessment
    local safeDistance = threat.range and threat.range.theirReach
    if not safeDistance or not threat.center then
        return nil
    end
    return SpatialAgent.fallbackDestination(context.ownPosition, threat.center, safeDistance)
end

function ResupplyDoctrine:advancePhase(context)
    local ownPosition = context.ownPosition
    local destination = context.orderPosition
    local proximity = context.orderProximity or 500

    local abortThreshold = context.retreatThreshold or 0.4

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    local fallback = self:considerFallback(context)
    if fallback then
        return {
            disposition = dispositionTypes.RETREAT,
            destination = fallback,
            orderAction = "start",
        }
    end

    local distanceToDestination = SpatialAgent.distance2D(ownPosition, destination)
    if distanceToDestination <= proximity then
        self:changePhase("Hold")
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

function ResupplyDoctrine:holdPhase(context)
    local abortThreshold = context.retreatThreshold or 0.4

    if self:considerAbort(context) >= abortThreshold then
        self:changePhase("Abort")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    local fallback = self:considerFallback(context)
    if fallback then
        return {
            disposition = dispositionTypes.RETREAT,
            destination = fallback,
        }
    end

    -- Defensive fallback (see header) in case orderPosition ever changes
    -- without a fresh order/doctrine instance - notice that and resume
    -- advancing instead of sitting at the old point forever.
    local proximity = context.orderProximity or 500
    local distanceToDestination = SpatialAgent.distance2D(context.ownPosition, context.orderPosition)
    if distanceToDestination and distanceToDestination > proximity then
        self:changePhase("Advance")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
        }
    end

    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
    }
end

function ResupplyDoctrine:abortPhase(context)
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

return ResupplyDoctrine
