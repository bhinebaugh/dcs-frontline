local constants = require("constants")
local Doctrine = require("doctrine")
local GroupProfiler = require("group-profiler")
local SpatialAgent = require("spatial-agent")

local taskTypes = constants.taskTypes
local alr = constants.acceptableLevelsOfRisk

-- FireSupportPlan: minimal operational doctrine for INDIRECT objectives.
-- Issues one INDIRECT order at the best available target near the
-- objective, reissues it if it resolves while the objective is still
-- needed, and marks the objective complete once its own duration elapses.
--
-- Target selection itself only happens at issuance time - once an order is
-- assigned it keeps aiming at that same point for the rest of its run
-- rather than continuously re-picking a new "best" target, since doing that
-- properly would mean letting a doctrine update an in-progress order in
-- place, which OperationalCommander:assignOrderTemplate doesn't support
-- today (it only ever considers commanders with no active order) - a
-- bigger, shared-plumbing change intentionally left for later. It does
-- still watch the order it already issued: if the specific unit it aimed at
-- is known to have left that point (targetHasLeft below), it ends the
-- mission early via objectiveComplete rather than riding out the rest of
-- `duration` on a stale point - StrategicCommander's refresh handling
-- treats that exactly like a natural completion and retasks immediately.
--
-- There's no coordination with a sibling assault objective under the same
-- Operation for WHEN to stop (e.g. ceasing fire once friendly ground forces
-- close on the target) - that needs a StrategicCommander-mediated "danger
-- close" signal. For now `duration` is what bounds how long fire support
-- runs - a placeholder for that real signal, not a substitute for it. It
-- does now get threat visibility from sibling opscoms via
-- StrategicCommander:shareThreatIntelWithinOperations, which is what makes
-- target selection below possible in the first place.
--
-- Doesn't use Doctrine's phase machinery - there's no real phase
-- progression here (issue, wait, reissue-or-complete), just a static
-- currentPhaseName so CommanderVisualizer:syncObjective has something to
-- display.
local FireSupportPlan = {}
setmetatable(FireSupportPlan, {__index = Doctrine})
FireSupportPlan.__index = FireSupportPlan

-- HE indirect fire is somewhat less reliable against heavier armor (see any
-- indirect weapon's effectiveness spread in weapons.lua, e.g. 2A64_152's
-- 9/8/5/2/0), but this is deliberately a shallow curve, not a steep one: a
-- direct hit is still highly lethal against any target, and even a miss has
-- real suppression value (buttoned-up crews, degraded sensors, disrupted
-- movement) - armor should make a target somewhat less preferred, not
-- effectively excluded. Concretely, a lone rifleman must not outscore a
-- tank just because the tank is "harder to kill" - the tank is both more
-- dangerous (much higher threatLevel below, from its gun/ATGM/MGs) and
-- still very much worth shelling for the chance and the suppression, so
-- threatLevel should dominate the score, with vulnerability only nudging it.
local vulnerabilityByArmorClass = {[0] = 1.0, [1] = 0.9, [2] = 0.75, [3] = 0.6}

-- Priority = how dangerous this unit is (summed offensive effectiveness, a
-- rough stand-in for "how armed is this thing") times how vulnerable it is
-- to indirect fire, times how likely it is to still be near its
-- last-reported position by the time a mission actually lands, times how
-- close it is to the objective itself - a threat right on top of what
-- we're actually assaulting is more relevant to hit than one merely
-- somewhere within the wider recon net.
local function targetPriority(threat, unit, objectivePosition)
    local classification = GroupProfiler.classifyUnit(unit)
    local eff = classification.effectiveness
    local threatLevel = eff.unarmored + eff.light + eff.medium + eff.heavy + eff.air
    local vulnerability = vulnerabilityByArmorClass[classification.armorClass] or 0.75

    -- Indirect fire is aimed at a last-known point, not a live-tracked one -
    -- a fast mover is likely to have relocated well outside the impact area
    -- by the time the mission is actually underway (opscom/group OODA
    -- cadence, travel-to-range time, DCS's own AI spin-up - see
    -- ExpandFrontierPlan's refreshInterval comment), so movement is
    -- penalized rather than assumed away. Halves priority around 5 m/s (a
    -- jogging pace) and keeps falling off for faster movers; a stationary
    -- (or unknown/stale, treated as stationary) target is unaffected.
    local speed = threat.speed or 0
    local stationaryFactor = 1 / (1 + speed / 5)

    -- Halves priority around 4000m (roughly half the 8000m recon radius
    -- threats are gathered from - see OperationalCommander.reconRadius) and
    -- keeps falling off further out, without hard-excluding anything the
    -- search already found.
    local distance = SpatialAgent.distance2D(threat.position, objectivePosition)
    local proximityFactor = 1 / (1 + distance / 4000)

    return threatLevel * vulnerability * stationaryFactor * proximityFactor
end

-- Picks the highest-priority threat from context.threats (already filtered
-- to recent sightings near the objective by
-- OperationalCommander:getThreatsNearPosition). Unit.getByName is only used
-- as an existence guard and for static type classification, not to read
-- live position/velocity - see group-commander.lua's OBSERVE comment on
-- this ("error guard, not intel cheat"); the actual aim point is the
-- last-reported intel position, same rationale as the speed penalty above.
-- Returns nil, nil if nothing currently resolves to a live unit, so callers
-- can fall back to the objective position itself.
local function selectTarget(threats, objectivePosition)
    local bestName = nil
    local bestThreat = nil
    local bestScore = -1
    for unitName, threat in pairs(threats or {}) do
        local unit = Unit.getByName(unitName)
        if unit and unit:isExist() then
            local score = targetPriority(threat, unit, objectivePosition)
            if score > bestScore then
                bestScore = score
                bestName = unitName
                bestThreat = threat
            end
        end
    end
    if bestThreat then
        return bestName, bestThreat.position
    end
    return nil, nil
end

-- True if the unit a mission is currently aimed at is no longer where it
-- was aimed - either it's dropped out of the tracked threat picture
-- entirely (eliminated, aged out, moved beyond the objective's recon
-- radius), or fresher intel now places it outside the mission's own
-- dispersion radius. Either way, continuing to fire at the old point for
-- the rest of `duration` would just be wasted rounds.
local function targetHasLeft(targetUnitName, targetPosition, threats, driftThreshold)
    local threat = threats and threats[targetUnitName]
    if not threat then
        return true
    end
    return SpatialAgent.distance2D(threat.position, targetPosition) > driftThreshold
end

function FireSupportPlan.new(commanderName, config)
    local self = Doctrine.new("FireSupport", commanderName)
    setmetatable(self, FireSupportPlan)

    self.config = {
        duration = (config and config.duration) or 600,
    }
    self.currentPhaseName = "Active"
    self.deadline = nil
    -- Which unit (if any - nil when we fell back to the bare objective
    -- position) and where we aimed at issuance time, so a later cycle can
    -- tell whether it's known to have moved on.
    self.targetUnitName = nil
    self.targetPosition = nil

    return self
end

function FireSupportPlan:plan(context)
    local statusCounts = context.statusCounts

    if not self.deadline then
        self.deadline = timer.getTime() + self.config.duration
    end

    if timer.getTime() >= self.deadline then
        return { objectiveComplete = true }
    end

    -- Wait for the current order to resolve before reissuing - unless the
    -- unit it's aimed at is known to have left, in which case there's no
    -- point riding out the rest of `duration` shelling an empty point.
    if statusCounts.assigned > 0 or statusCounts.inProgress > 0 then
        if self.targetUnitName and targetHasLeft(self.targetUnitName, self.targetPosition, context.threats, context.objectiveRadius or 500) then
            return { objectiveComplete = true }
        end
        return {}
    end

    if context.availableCommanderCount == 0 then
        return {}
    end

    local targetUnitName, targetPosition = selectTarget(context.threats, context.objectivePosition)
    self.targetUnitName = targetUnitName
    self.targetPosition = targetPosition or context.objectivePosition

    return {
        orders = {
            {
                type      = taskTypes.INDIRECT,
                position  = self.targetPosition,
                proximity = context.objectiveRadius or 500,
                alr       = alr.MEDIUM,
                count     = context.availableCommanderCount,
                deadline  = self.deadline,
            },
        },
    }
end

return FireSupportPlan
