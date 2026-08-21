-- RepairResupplyPlan: coordinates a distressed unit and its resupply convoy
-- meeting at a rendezvous point, then resolving native DCS ammo resupply,
-- a virtual fuel top-off timer, and (if health-critical or badly attrited)
-- a virtual repair timer - all running concurrently, resolving on whichever
-- finishes last - before releasing both back to service. See
-- src/unit-recovery.lua for the spawn/despawn/respawn mechanics this calls
-- into, and StrategicCommander for how this doctrine's
-- Operation/Objective/OperationalCommander gets set up in the first place.
--
-- Unlike the pool-based operational doctrines (ReconRallyAssaultPlan,
-- FireSupportPlan), this one coordinates exactly two specific, named,
-- non-interchangeable groups - it holds distressedGc/convoyGc as live
-- instance references from construction (same pattern DefensiveDoctrine
-- uses for self.basePosition, just extended to whole GroupCommanders) and
-- targets orders at them directly via OperationalCommander's assignTo,
-- rather than letting suitability scoring pick from a pool.
--
-- Phases: Traveling -> Resupplying -> Returning -> Restocking -> complete.
-- OperationalCommander doesn't freeze on a finished order the way
-- GroupCommander does (see that comment in group-commander.lua), so unlike
-- the tactical doctrines this session, phase transitions don't need to
-- defer their action to the next phase's handler - a trigger and its
-- resulting action can happen in the same call, same as every other
-- operational doctrine already does.

local constants = require("constants")
local Doctrine = require("doctrine")
local ForceStatusAnalyzer = require("force-status-analyzer")
local SpatialAgent = require("spatial-agent")

local taskTypes = constants.taskTypes
local alr = constants.acceptableLevelsOfRisk

-- Tunable timers, all seconds. FUEL_TOPOFF_TIME effectively floors every
-- resupply's duration (even an ammo-only distressed unit waits this long)
-- since it's the shortest of the three real-world-plausible numbers here.
local FUEL_TOPOFF_TIME = 120
local REPAIR_TIME = 300
local RESTOCK_TIME = 90
local AMMO_STABLE_CHECKS = 2 -- consecutive unchanged polls before "DCS finished rearming"
local ARRIVAL_PROXIMITY = 500
-- Matches GroupCommander's own ATTRITION_CRITICAL_RATIO threshold - if lost
-- unit-mates (not survivor health/ammo/fuel) is what flagged this unit
-- distressed in the first place, only a respawn actually fixes that;
-- nothing else in this system replaces a destroyed unit.
local ATTRITION_RESPAWN_THRESHOLD = 0.6

local RepairResupplyPlan = {}
setmetatable(RepairResupplyPlan, {__index = Doctrine})
RepairResupplyPlan.__index = RepairResupplyPlan

-- config: { distressedGc, convoyGc, unitRecovery, rendezvousZone,
--           rendezvousPoint, homeZone, homePoint }
function RepairResupplyPlan.new(commanderName, config)
    local self = Doctrine.new("RepairResupply", commanderName)
    setmetatable(self, RepairResupplyPlan)

    self.distressedGc = config.distressedGc
    self.convoyGc = config.convoyGc
    self.unitRecovery = config.unitRecovery
    self.rendezvousZone = config.rendezvousZone
    self.rendezvousPoint = config.rendezvousPoint
    self.homeZone = config.homeZone
    self.homePoint = config.homePoint

    self.needsRespawn = nil
    self.resupplyStartedAt = nil
    self.restockStartedAt = nil
    self.lastAmmoCount = nil
    self.ammoStableTicks = 0
    -- Set by checkFailure when the distressed unit is lost but the convoy
    -- isn't - restockingPhase reports this as the objective's real outcome
    -- once the convoy actually gets home, instead of a false "complete".
    self.pendingFailureReason = nil

    self:registerPhase("Traveling", RepairResupplyPlan.travelingPhase)
    self:registerPhase("Resupplying", RepairResupplyPlan.resupplyingPhase)
    self:registerPhase("Returning", RepairResupplyPlan.returningPhase)
    self:registerPhase("Restocking", RepairResupplyPlan.restockingPhase)

    return self
end

-- Checked at the top of every phase: either partner dying or bailing under
-- acute threat (order aborted) ends the session as a failure rather than a
-- partial success. Returns a decision table to return immediately if
-- something failed, or nil if both partners are still in play.
function RepairResupplyPlan:checkFailure()
    local distressedDestroyed = self.distressedGc.destroyed
    local distressedAborted = self.distressedGc.orders and self.distressedGc.orders.status == constants.orderStatus.ABORTED
    local distressedLost = distressedDestroyed or distressedAborted

    local convoyDestroyed = self.convoyGc.destroyed
    local convoyAborted = self.convoyGc.orders and self.convoyGc.orders.status == constants.orderStatus.ABORTED
    local convoyLost = convoyDestroyed or convoyAborted

    if not distressedLost and not convoyLost then
        return nil
    end

    local replacements = {}
    local released = {}

    if distressedLost then
        replacements[self.distressedGc.groupName] = false
        -- Unlike the convoy, an aborted-but-alive distressed unit has
        -- somewhere to go: it fled real danger, not "job's done" - release
        -- it back to reserves so it isn't orphaned (removed from this
        -- opscom's roster but never handed anywhere else) -
        -- dispatchDistressedReserves will pick it up again once it's safe.
        -- If it's destroyed there's nothing to release.
        if not distressedDestroyed then
            table.insert(released, self.distressedGc)
        end
    end

    if convoyLost then
        -- Convoy itself is gone (destroyed - no-op destroy, still checks
        -- the capacity back in - or aborted its own order while still
        -- alive) - nowhere left to send it, retire it in place. A convoy
        -- never goes back to reserves, destroyed or not (see
        -- unit-recovery.lua's despawn-on-idle philosophy).
        self.unitRecovery:despawnConvoy(self.convoyGc.groupName)
        replacements[self.convoyGc.groupName] = false

        env.info(string.format("*** %s RepairResupplyPlan: session for %s ended in failure (distressedLost=%s convoyLost=%s)",
            self.commanderName, self.distressedGc.groupName, tostring(distressedLost), tostring(convoyLost)))

        return {
            groupReplacements = replacements,
            releaseGroups = released,
            objectiveFailed = "partner_lost",
        }
    end

    -- distressedLost but the convoy is still fine - it has no one left to
    -- resupply, but it shouldn't simply cease to exist wherever it happens
    -- to be standing. Send it home via the same Returning/Restocking path
    -- the normal completion flow already uses (it doesn't care why it's
    -- heading home), and remember the real outcome for restockingPhase to
    -- report once it actually gets there - leaving groupCommanders alone
    -- for now, since this opscom still needs to route orders to it.
    self.pendingFailureReason = "partner_lost"
    self:changePhase("Returning")
    env.info(string.format("*** %s RepairResupplyPlan: %s lost, sending %s home before retiring",
        self.commanderName, self.distressedGc.groupName, self.convoyGc.groupName))

    return {
        groupReplacements = replacements,
        releaseGroups = released,
        orders = {
            {
                type      = taskTypes.RESUPPLY,
                position  = self.homePoint,
                proximity = ARRIVAL_PROXIMITY,
                alr       = alr.LOW,
                assignTo  = self.convoyGc.groupName,
            },
        },
    }
end

function RepairResupplyPlan:travelingPhase(context)
    local failure = self:checkFailure()
    if failure then return failure end

    local distressedStatus = self.distressedGc:getStatus()
    local convoyStatus = self.convoyGc:getStatus()
    local distressedArrived = distressedStatus.position
        and SpatialAgent.distance2D(distressedStatus.position, self.rendezvousPoint) <= ARRIVAL_PROXIMITY
    local convoyArrived = convoyStatus.position
        and SpatialAgent.distance2D(convoyStatus.position, self.rendezvousPoint) <= ARRIVAL_PROXIMITY

    if distressedArrived and convoyArrived then
        local distressedReport = self.distressedGc:getStatusReport()
        local totalUnits = #self.distressedGc.initialUnitNames
        -- Health-critical survivors need a respawn to fix; so does a group
        -- that's merely lost most of its unit-mates while the survivors
        -- themselves are fine - fuel/ammo top-off does nothing for either
        -- of those, only despawn+respawn actually restores a full roster.
        self.needsRespawn = ForceStatusAnalyzer.isHealthCritical(distressedReport.healthRatio)
            or ForceStatusAnalyzer.hasSignificantAttrition(distressedReport.aliveCount, totalUnits, ATTRITION_RESPAWN_THRESHOLD)
        self.resupplyStartedAt = timer.getTime()
        self.lastAmmoCount = distressedReport.ammoCount
        self:changePhase("Resupplying")
        env.info(string.format("*** %s RepairResupplyPlan: %s and %s met, resupply starting (needsRespawn=%s)",
            self.commanderName, self.distressedGc.groupName, self.convoyGc.groupName, tostring(self.needsRespawn)))
    end

    return {
        orders = {
            {
                type      = taskTypes.REPAIR,
                position  = self.rendezvousPoint,
                proximity = ARRIVAL_PROXIMITY,
                alr       = alr.LOW, -- distressed units should flee readily, not stand and fight
                assignTo  = self.distressedGc.groupName,
            },
            {
                type      = taskTypes.RESUPPLY,
                position  = self.rendezvousPoint,
                proximity = ARRIVAL_PROXIMITY,
                alr       = alr.LOW,
                assignTo  = self.convoyGc.groupName,
            },
        },
    }
end

-- Polls the three concurrent resolution conditions (native ammo, virtual
-- fuel, virtual repair) and, once all have resolved, either respawns the
-- distressed unit's group fresh (health-critical or badly attrited) or
-- releases it as-is - either way it's done and gets handed back to reserves
-- right away via releaseGroups, rather than waiting for the convoy's own
-- return trip too. Then redirects the convoy home with an updated RESUPPLY
-- order.
function RepairResupplyPlan:resupplyingPhase(context)
    local failure = self:checkFailure()
    if failure then return failure end

    local status = self.distressedGc:getStatusReport()
    if status.ammoCount == self.lastAmmoCount then
        self.ammoStableTicks = self.ammoStableTicks + 1
    else
        self.ammoStableTicks = 0
        self.lastAmmoCount = status.ammoCount
    end
    local ammoResolved = self.ammoStableTicks >= AMMO_STABLE_CHECKS

    local elapsed = timer.getTime() - self.resupplyStartedAt
    local fuelResolved = elapsed >= FUEL_TOPOFF_TIME
    local repairResolved = (not self.needsRespawn) or elapsed >= REPAIR_TIME

    if not (ammoResolved and fuelResolved and repairResolved) then
        return {
            orders = {
                {
                    type      = taskTypes.REPAIR,
                    position  = self.rendezvousPoint,
                    proximity = ARRIVAL_PROXIMITY,
                    alr       = alr.LOW,
                    assignTo  = self.distressedGc.groupName,
                },
            },
        }
    end

    local released = {}
    if self.needsRespawn then
        local freshName = self.unitRecovery:respawnGroup(self.distressedGc, self.rendezvousZone)
        if freshName then
            table.insert(released, self.unitRecovery:wrapGroupCommander(freshName))
        end
    else
        self.distressedGc.fuelRemaining = 1.0 -- virtual refuel; ammo is genuinely refilled by DCS already
        if self.distressedGc.orders and self.distressedGc.orders:isActive() then
            self.distressedGc.orders:complete()
        end
        table.insert(released, self.distressedGc)
        env.info(string.format("*** %s RepairResupplyPlan: %s resupplied in place (no respawn needed)",
            self.commanderName, self.distressedGc.groupName))
    end

    self:changePhase("Returning")

    return {
        -- The old distressedGc entry (destroyed-and-replaced or simply
        -- retired from this opscom's concern either way) comes out of
        -- groupCommanders here; the group actually going back into service
        -- - released above - is what StrategicCommander:reclaimReleasedGroups
        -- picks up next cycle. Leaving it in groupCommanders too would risk
        -- it being double-tasked once it's also sitting in reserves.
        groupReplacements = { [self.distressedGc.groupName] = false },
        releaseGroups = released,
        orders = {
            {
                type      = taskTypes.RESUPPLY,
                position  = self.homePoint,
                proximity = ARRIVAL_PROXIMITY,
                alr       = alr.LOW,
                assignTo  = self.convoyGc.groupName,
            },
        },
    }
end

function RepairResupplyPlan:returningPhase(context)
    -- Only the convoy is still being coordinated at this point -
    -- distressedGc was already released in resupplyingPhase, so
    -- checkFailure would wrongly fire on it (see its guard comment); just
    -- watch the convoy directly.
    if self.convoyGc.destroyed or
        (self.convoyGc.orders and self.convoyGc.orders.status == constants.orderStatus.ABORTED) then
        env.info(string.format("*** %s RepairResupplyPlan: convoy %s lost on the way home",
            self.commanderName, self.convoyGc.groupName))
        return {
            groupReplacements = { [self.convoyGc.groupName] = false },
            objectiveFailed = "convoy_lost_returning",
        }
    end

    local convoyStatus = self.convoyGc:getStatus()
    local arrived = convoyStatus.position
        and SpatialAgent.distance2D(convoyStatus.position, self.homePoint) <= ARRIVAL_PROXIMITY
    if arrived then
        self.restockStartedAt = timer.getTime()
        self:changePhase("Restocking")
    end

    return {
        orders = {
            {
                type      = taskTypes.RESUPPLY,
                position  = self.homePoint,
                proximity = ARRIVAL_PROXIMITY,
                alr       = alr.LOW,
                assignTo  = self.convoyGc.groupName,
            },
        },
    }
end

function RepairResupplyPlan:restockingPhase(context)
    if timer.getTime() - self.restockStartedAt < RESTOCK_TIME then
        return {}
    end

    env.info(string.format("*** %s RepairResupplyPlan: %s restocked, retiring",
        self.commanderName, self.convoyGc.groupName))
    self.unitRecovery:despawnConvoy(self.convoyGc.groupName)

    if self.pendingFailureReason then
        return {
            groupReplacements = { [self.convoyGc.groupName] = false },
            objectiveFailed = self.pendingFailureReason,
        }
    end

    return {
        groupReplacements = { [self.convoyGc.groupName] = false },
        objectiveComplete = true,
    }
end

return RepairResupplyPlan
