-- RepairResupplyPlan: coordinates a dire unit and its resupply convoy
-- meeting at a rendezvous point, then resolving native DCS ammo resupply,
-- a virtual fuel top-off timer, and (if health-critical) a virtual repair
-- timer - all running concurrently, resolving on whichever finishes last -
-- before releasing both back to service. See src/unit-recovery.lua for the
-- spawn/despawn/respawn mechanics this calls into, and StrategicCommander
-- for how this doctrine's Operation/Objective/OperationalCommander gets
-- set up in the first place.
--
-- Unlike the pool-based operational doctrines (ReconRallyAssaultPlan,
-- FireSupportPlan), this one coordinates exactly two specific, named,
-- non-interchangeable groups - it holds direGc/convoyGc as live instance
-- references from construction (same pattern DefensiveDoctrine uses for
-- self.basePosition, just extended to whole GroupCommanders) and targets
-- orders at them directly via OperationalCommander's assignTo, rather than
-- letting suitability scoring pick from a pool.
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
-- resupply's duration (even an ammo-only dire unit waits this long) since
-- it's the shortest of the three real-world-plausible numbers here.
local FUEL_TOPOFF_TIME = 120
local REPAIR_TIME = 300
local RESTOCK_TIME = 90
local AMMO_STABLE_CHECKS = 2 -- consecutive unchanged polls before "DCS finished rearming"
local ARRIVAL_PROXIMITY = 500

local RepairResupplyPlan = {}
setmetatable(RepairResupplyPlan, {__index = Doctrine})
RepairResupplyPlan.__index = RepairResupplyPlan

-- config: { direGc, convoyGc, unitRecovery, rendezvousZone, rendezvousPoint,
--           homeZone, homePoint }
function RepairResupplyPlan.new(commanderName, config)
    local self = Doctrine.new("RepairResupply", commanderName)
    setmetatable(self, RepairResupplyPlan)

    self.direGc = config.direGc
    self.convoyGc = config.convoyGc
    self.unitRecovery = config.unitRecovery
    self.rendezvousZone = config.rendezvousZone
    self.rendezvousPoint = config.rendezvousPoint
    self.homeZone = config.homeZone
    self.homePoint = config.homePoint

    self.healthCritical = nil
    self.resupplyStartedAt = nil
    self.restockStartedAt = nil
    self.lastAmmoCount = nil
    self.ammoStableTicks = 0

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
    local direLost = self.direGc.destroyed or
        (self.direGc.orders and self.direGc.orders.status == constants.orderStatus.ABORTED)
    local convoyLost = self.convoyGc.destroyed or
        (self.convoyGc.orders and self.convoyGc.orders.status == constants.orderStatus.ABORTED)

    if not direLost and not convoyLost then
        return nil
    end

    local replacements = {}
    if convoyLost then
        -- Safe whether the convoy is already destroyed (no-op destroy,
        -- still checks the capacity back in) or merely aborted its order
        -- while still alive (genuinely despawns it).
        self.unitRecovery:despawnConvoy(self.convoyGc.groupName)
        replacements[self.convoyGc.groupName] = false
    end
    if direLost then
        replacements[self.direGc.groupName] = false
    end
    -- If only the convoy was lost, the dire unit stays in the roster (not
    -- listed in replacements) so disband() returns it to reserves once this
    -- objective completes below, same as any other survivor.

    env.info(string.format("*** %s RepairResupplyPlan: session for %s ended in failure (direLost=%s convoyLost=%s)",
        self.commanderName, self.direGc.groupName, tostring(direLost), tostring(convoyLost)))

    return {
        groupReplacements = replacements,
        objectiveFailed = "partner_lost",
    }
end

function RepairResupplyPlan:travelingPhase(context)
    local failure = self:checkFailure()
    if failure then return failure end

    local direStatus = self.direGc:getStatus()
    local convoyStatus = self.convoyGc:getStatus()
    local direArrived = direStatus.position
        and SpatialAgent.distance2D(direStatus.position, self.rendezvousPoint) <= ARRIVAL_PROXIMITY
    local convoyArrived = convoyStatus.position
        and SpatialAgent.distance2D(convoyStatus.position, self.rendezvousPoint) <= ARRIVAL_PROXIMITY

    if direArrived and convoyArrived then
        local direReport = self.direGc:getStatusReport()
        self.healthCritical = ForceStatusAnalyzer.isHealthCritical(direReport.healthRatio)
        self.resupplyStartedAt = timer.getTime()
        self.lastAmmoCount = direReport.ammoCount
        self:changePhase("Resupplying")
        env.info(string.format("*** %s RepairResupplyPlan: %s and %s met, resupply starting (healthCritical=%s)",
            self.commanderName, self.direGc.groupName, self.convoyGc.groupName, tostring(self.healthCritical)))
    end

    return {
        orders = {
            {
                type      = taskTypes.REPAIR,
                position  = self.rendezvousPoint,
                proximity = ARRIVAL_PROXIMITY,
                alr       = alr.LOW, -- dire units should flee readily, not stand and fight
                assignTo  = self.direGc.groupName,
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
-- dire unit's group fresh (health-critical) or releases it as-is - either
-- way it's done and gets to leave the roster right away via
-- groupReplacements, rather than waiting for the convoy's own return trip
-- too. Then redirects the convoy home with an updated RESUPPLY order.
function RepairResupplyPlan:resupplyingPhase(context)
    local failure = self:checkFailure()
    if failure then return failure end

    local status = self.direGc:getStatusReport()
    if status.ammoCount == self.lastAmmoCount then
        self.ammoStableTicks = self.ammoStableTicks + 1
    else
        self.ammoStableTicks = 0
        self.lastAmmoCount = status.ammoCount
    end
    local ammoResolved = self.ammoStableTicks >= AMMO_STABLE_CHECKS

    local elapsed = timer.getTime() - self.resupplyStartedAt
    local fuelResolved = elapsed >= FUEL_TOPOFF_TIME
    local repairResolved = (not self.healthCritical) or elapsed >= REPAIR_TIME

    if not (ammoResolved and fuelResolved and repairResolved) then
        return {
            orders = {
                {
                    type      = taskTypes.REPAIR,
                    position  = self.rendezvousPoint,
                    proximity = ARRIVAL_PROXIMITY,
                    alr       = alr.LOW,
                    assignTo  = self.direGc.groupName,
                },
            },
        }
    end

    local replacements = {}
    if self.healthCritical then
        local freshName = self.unitRecovery:respawnGroup(self.direGc, self.rendezvousZone)
        replacements[self.direGc.groupName] = freshName and self.unitRecovery:wrapGroupCommander(freshName) or false
    else
        -- No roster change needed - direGc just stays where it already is
        -- in groupCommanders, so it's simply omitted from replacements
        -- rather than mapped to itself.
        self.direGc.fuelRemaining = 1.0 -- virtual refuel; ammo is genuinely refilled by DCS already
        if self.direGc.orders and self.direGc.orders:isActive() then
            self.direGc.orders:complete()
        end
        env.info(string.format("*** %s RepairResupplyPlan: %s resupplied in place (no respawn needed)",
            self.commanderName, self.direGc.groupName))
    end

    self:changePhase("Returning")

    return {
        groupReplacements = replacements,
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
    -- Only the convoy is still being coordinated at this point - direGc was
    -- already released in resupplyingPhase, so checkFailure would wrongly
    -- fire on it (see its guard comment); just watch the convoy directly.
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

    return {
        groupReplacements = { [self.convoyGc.groupName] = false },
        objectiveComplete = true,
    }
end

return RepairResupplyPlan
