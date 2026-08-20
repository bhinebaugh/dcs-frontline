-- RepairDoctrine: fall back to an assigned rendezvous point and hold for
-- REPAIR orders (see src/doctrines/operational/repair-resupply-plan.lua).
--
-- Unlike every other tactical doctrine, this one never marks its own order
-- complete - a dire unit's repair/respawn is resolved externally by
-- RepairResupplyPlan (the operational doctrine coordinating this unit and
-- the resupply convoy it's waiting to meet), since that decision depends on
-- state (the convoy's own position, native DCS ammo resupply progress,
-- virtual fuel/repair timers) this doctrine has no visibility into and
-- shouldn't reach for - see the doctrine-independence rule this codebase
-- follows. Advance/Hold here only ever get the unit to the rendezvous point
-- and keep it safe while it waits.

local constants = require("constants")
local Doctrine = require("doctrine")
local ForceStatusAnalyzer = require("force-status-analyzer")
local SpatialAgent = require("spatial-agent")

local dispositionTypes = constants.dispositionTypes

local RepairDoctrine = {}
setmetatable(RepairDoctrine, {__index = Doctrine})
RepairDoctrine.__index = RepairDoctrine

function RepairDoctrine.new(commanderName)
    local self = Doctrine.new("Repair", commanderName)
    setmetatable(self, RepairDoctrine)

    self:registerPhase("Advance", RepairDoctrine.advancePhase)
    self:registerPhase("Hold", RepairDoctrine.holdPhase)
    self:registerPhase("Abort", RepairDoctrine.abortPhase)

    return self
end

-- A unit already headed for repair is already in bad shape by definition -
-- this is about acute danger on the way there (something worse than the
-- condition that sent it here), not the dire condition itself.
function RepairDoctrine:considerAbort(context)
    local threat = context.threatAssessment
    local status = context.statusReport
    local totalUnits = context.totalUnits

    local retreatAssessment = 0.0

    if ForceStatusAnalyzer.isAmmoCritical(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isAmmoLow(status.ammoCount, context.initialAmmoCount) then
        retreatAssessment = retreatAssessment + 0.5
    end

    if ForceStatusAnalyzer.isHealthCritical(status.healthRatio) then
        retreatAssessment = retreatAssessment + 1.0
    elseif ForceStatusAnalyzer.isHealthLow(status.healthRatio) then
        retreatAssessment = retreatAssessment + 0.5
    end

    local attritionRate = ForceStatusAnalyzer.calculateAttritionRate(status.aliveCount, totalUnits)
    retreatAssessment = retreatAssessment + attritionRate

    if threat.count > 0 and threat.favorability < 1.0 then
        retreatAssessment = retreatAssessment + (1 - threat.favorability)
    else
        retreatAssessment = retreatAssessment - (1 / threat.favorability)
    end

    return retreatAssessment
end

-- Fallback destination if a known threat's weapon range currently reaches
-- us, or nil if already outside it (see SpatialAgent.fallbackDestination).
function RepairDoctrine:considerFallback(context)
    local threat = context.threatAssessment
    local safeDistance = threat.range and threat.range.theirReach
    if not safeDistance or not threat.center then
        return nil
    end
    return SpatialAgent.fallbackDestination(context.ownPosition, threat.center, safeDistance)
end

function RepairDoctrine:advancePhase(context)
    local ownPosition = context.ownPosition
    local rendezvous = context.orderPosition
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

    local distanceToRendezvous = SpatialAgent.distance2D(ownPosition, rendezvous)
    if distanceToRendezvous <= proximity then
        self:changePhase("Hold")
        return {
            disposition = dispositionTypes.HOLD,
            destination = nil,
            orderAction = "start",
        }
    end

    return {
        disposition = dispositionTypes.ADVANCE,
        destination = rendezvous,
        orderAction = "start",
    }
end

function RepairDoctrine:holdPhase(context)
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

    return {
        disposition = dispositionTypes.HOLD,
        destination = nil,
    }
end

-- Abort's one real shot to act() (see GroupCommander:decide, and every
-- other tactical doctrine's abortPhase this session) - the trigger that
-- got us here deliberately only transitioned phase without setting
-- orderAction, so this handler is what actually retreats and declares the
-- order aborted. RepairResupplyPlan's checkFailure notices the aborted
-- order and tears down the session rather than waiting for a repair that
-- isn't going to happen.
function RepairDoctrine:abortPhase(context)
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

return RepairDoctrine
