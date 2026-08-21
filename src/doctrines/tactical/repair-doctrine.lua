-- RepairDoctrine: fall back to an assigned rendezvous point and hold for
-- REPAIR orders (see src/doctrines/operational/repair-resupply-plan.lua).
--
-- Unlike every other tactical doctrine, this one never marks its own order
-- complete - a distressed unit's repair/respawn is resolved externally by
-- RepairResupplyPlan (the operational doctrine coordinating this unit and
-- the resupply convoy it's waiting to meet), since that decision depends on
-- state (the convoy's own position, native DCS ammo resupply progress,
-- virtual fuel/repair timers) this doctrine has no visibility into and
-- shouldn't reach for - see the doctrine-independence rule this codebase
-- follows. Advance/Hold here only ever get the unit to the rendezvous point
-- and keep it safe while it waits.
--
-- Also unlike every other tactical doctrine, there's no Abort phase here: a
-- distressed unit's order already *is* "get to safety" - giving up on it
-- under threat and handing off to DefensiveDoctrine would just swap one
-- flight response for a different one, with a dead standing-still tick in
-- between (the trigger-then-terminal-phase pattern every other doctrine's
-- Abort uses this session) at exactly the moment the unit needed to be
-- moving. A distressed unit is also, by definition, already weak, so
-- scoring threat favorability the way Rally/Assault do would trip
-- constantly on ordinary contact. Threat just makes it retreat harder via
-- considerFallback - it never gives up on the order.

local constants = require("constants")
local Doctrine = require("doctrine")
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

    return self
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

return RepairDoctrine
