local CommanderVisualizer = require("commander-visualizer")
local constants = require("constants")
local ExpandFrontierPlan = require("doctrines.strategic.expand-frontier-plan")
local GroupCommander = require("group-commander")
local Objective = require("objective")
local Operation = require("operation")
local OODACommander = require("ooda-commander")
local OperationalCommander = require("operational-commander")
local RepairResupplyPlan = require("doctrines.operational.repair-resupply-plan")
local SpatialAgent = require("spatial-agent")
local UnitRecovery = require("unit-recovery")

local StrategicCommander = {}
setmetatable(StrategicCommander, {__index = OODACommander})
StrategicCommander.__index = StrategicCommander

local oodaInterval = 45.0 -- seconds, same cadence as CoalitionCommander

-- StrategicCommander: coalition-level owner of "state of the game board"
-- (zones, reserves, the set of active Operations), paired with a swappable
-- StrategicDoctrine that decides what Operations to pursue. Written from
-- scratch alongside CoalitionCommander (not a refactor of it) so the two can
-- run side by side, one per coalition, for behavioral comparison - see
-- frontline.lua. See src/operation.lua for why Operations hold an
-- arbitrary-cardinality list of Objectives rather than one-per-role.
function StrategicCommander.new(parent, config)
    local self = OODACommander.new({interval = oodaInterval})
    setmetatable(self, StrategicCommander)

    self.map = parent
    self.coalition = config.color
    self.color = config.color
    self.opponent = config.color == "blue" and "red" or "blue"
    self.reserves = {}
    self.visualizer = CommanderVisualizer.new(self.map.map)
    self.doctrine = ExpandFrontierPlan.new(self.color .. "StratCom")
    self.unitRecovery = UnitRecovery.new({
        color      = self.color,
        map        = self.map,
        visualizer = self.visualizer,
        budgets    = UnitRecovery.defaultBudgets(self.color),
    })

    self.operations = {
        active  = {}, -- array of Operation
        history = {},
    }
    self.pendingOperations = {}   -- Operation templates from the doctrine, staged in decide()
    self.operationsToDisband = {} -- indices into operations.active, staged in orient()
    self.objectivesToRefresh = {} -- {operation, entry} pairs, staged in orient()

    return self
end

function StrategicCommander:addReserves(groups)
    for _, groupName in pairs(groups) do
        local gc = GroupCommander.new(groupName, {
            color = self.color,
            map   = self.map.map,
        })
        table.insert(self.reserves, gc)
    end
end

function StrategicCommander:observe()
    local surviving = {}
    for _, gc in ipairs(self.reserves) do
        if not gc.destroyed then
            table.insert(surviving, gc)
        end
    end
    self.reserves = surviving

    self:shareThreatIntelWithinOperations()

    env.info(string.format("****** %s StratCom OBSERVE: blue=%d red=%d zones | reserves=%d | operations=%d",
        self.color,
        #self.map:getCluster("blue"),
        #self.map:getCluster("red"),
        #self.reserves,
        #self.operations.active))
end

-- Bridges threat intel between sibling opscoms under the same Operation.
-- Each OperationalCommander's threatTracker is fed only by its own
-- groupCommanders' sightings (see OperationalCommander:aggregateThreatsFromGroups),
-- so a fire-support opscom stationed too far back to detect anything near
-- the objective itself has no visibility into what an assault opscom under
-- the same Operation has spotted there - siblings are otherwise blind to
-- each other, and StrategicCommander is the only thing holding references
-- to both.
function StrategicCommander:shareThreatIntelWithinOperations()
    for _, operation in ipairs(self.operations.active) do
        if #operation.objectives > 1 then
            for _, entry in ipairs(operation.objectives) do
                for _, other in ipairs(operation.objectives) do
                    if other ~= entry then
                        entry.opscom.threatTracker:mergeThreatIntel(other.opscom.threatTracker:getThreats())
                    end
                end
            end
        end
    end
end

function StrategicCommander:orient()
    self.operationsToDisband = {}
    self.objectivesToRefresh = {}

    for i, operation in ipairs(self.operations.active) do
        -- Whether the *operation* is done is judged only by its primary
        -- objectives (e.g. assault) - a supporting objective (e.g.
        -- fireSupport) has no natural completion of its own and would
        -- otherwise either hold the operation open forever (it just keeps
        -- refreshing) or, worse, look like "the operation is done" the
        -- instant it happened to resolve while the primary objective was
        -- still actively being pursued.
        local primaryCounts = operation:getObjectiveStatusCounts(true)
        if primaryCounts.total > 0 and primaryCounts.active == 0 then
            operation.status = (primaryCounts.failed == 0) and Operation.Status.ACHIEVED or Operation.Status.FAILED
            table.insert(self.operationsToDisband, i)
        else
            -- Supporting objectives ride along with the primary's lifecycle
            -- rather than being judged individually complete - refresh them
            -- (disband + recreate from the same template) once they're
            -- stale by their own configured interval, or if they resolved
            -- on their own (e.g. their group died) and could use a
            -- replacement. Primary objectives are never touched here; they
            -- just run their course via their own operational doctrine.
            for _, entry in ipairs(operation.objectives) do
                if not entry.primary and not entry.disbanded then
                    local interval = entry.template.refreshInterval
                    if interval then
                        local staleByInterval = (timer.getTime() - entry.createdAt) >= interval
                        if staleByInterval or entry.objective:isComplete() then
                            table.insert(self.objectivesToRefresh, {operation = operation, entry = entry})
                        end
                    end
                end
            end
        end
    end
end

function StrategicCommander:decide()
    -- Disband resolved operations (iterate in reverse to safely remove by index)
    table.sort(self.operationsToDisband, function(a, b) return a > b end)
    for _, i in ipairs(self.operationsToDisband) do
        local operation = self.operations.active[i]
        for _, entry in ipairs(operation.objectives) do
            -- Individually-retired entries (see the staleByInterval/resolved
            -- handling in orient()) were already disbanded and their groups
            -- already returned to reserves - disbanding again here would
            -- return the same groups to self.reserves a second time.
            if not entry.disbanded then
                self.visualizer:release("opscom:" .. entry.opscom.name)
                self.visualizer:releaseObjective(entry.objective)
                local survivors = entry.opscom:disband()
                for _, gc in ipairs(survivors) do
                    table.insert(self.reserves, gc)
                end
                entry.disbanded = true
            end
        end
        table.insert(self.operations.history, operation)
        table.remove(self.operations.active, i)
        env.info(string.format("****** %s StratCom DECIDE: disbanded operation (%s), groups returned to reserves",
            self.color, operation.status))
    end

    for _, refresh in ipairs(self.objectivesToRefresh) do
        local operation = refresh.operation
        local entry = refresh.entry

        self.visualizer:release("opscom:" .. entry.opscom.name)
        self.visualizer:releaseObjective(entry.objective)
        local survivors = entry.opscom:disband()
        for _, gc in ipairs(survivors) do
            table.insert(self.reserves, gc)
        end
        entry.disbanded = true

        for i, existing in ipairs(operation.objectives) do
            if existing == entry then
                table.remove(operation.objectives, i)
                break
            end
        end
        local fresh = self:instantiateObjective(entry.template, entry.target)
        if fresh then
            operation:addObjective(fresh)
        end
        env.info(string.format("****** %s StratCom DECIDE: refreshed %s objective", self.color, entry.role))
    end

    local context = self:buildStrategicContext()
    local result = self.doctrine:plan(context)
    self.pendingOperations = (result and result.operations) or {}
end

function StrategicCommander:act()
    for _, template in ipairs(self.pendingOperations) do
        self:createOperation(template)
    end

    self:dispatchDireReserves()

    for _, operation in ipairs(self.operations.active) do
        for _, entry in ipairs(operation.objectives) do
            self.visualizer:syncOpscom(entry.opscom, self.color)
        end
    end
end

-- ============================================================================
-- HELPER METHODS
-- ============================================================================

-- Hands every dire reserve to a fresh repair Operation, removing it from
-- self.reserves so it can't also be picked up by instantiateObjective in
-- the same tick (that has its own isConditionCritical floor too, belt-and-
-- suspenders, but this is what actually stops it from sitting in reserves
-- looking dire and unused). A group stays in reserves if UnitRecovery has
-- no convoy capacity for it right now - it'll be tried again next tick.
function StrategicCommander:dispatchDireReserves()
    local direReserves = {}
    for _, gc in ipairs(self.reserves) do
        if gc:isConditionCritical() then
            table.insert(direReserves, gc)
        end
    end

    for _, gc in ipairs(direReserves) do
        if self:beginRepair(gc) then
            for i, reserveGc in ipairs(self.reserves) do
                if reserveGc == gc then
                    table.remove(self.reserves, i)
                    break
                end
            end
        end
    end
end

-- Stands up a one-objective Operation pairing a dire unit with a freshly
-- spawned/dispatched resupply convoy, backed by RepairResupplyPlan (see its
-- own header for why this doctrine holds live group references rather than
-- working from a pool like every other operational doctrine). Reuses the
-- same Operation/entry machinery instantiateObjective builds for ordinary
-- objectives, so the existing orient()/decide() disband logic handles
-- returning the resolved group(s) to reserves with no special-casing here -
-- RepairResupplyPlan retires the convoy from the opscom's roster itself
-- before signaling objectiveComplete, so disband() only ever hands back
-- whichever dire-unit outcome (repaired in place, or its fresh
-- replacement) is still in groupCommanders by then.
function StrategicCommander:beginRepair(direGc)
    if not self.unitRecovery:hasConvoyCapacity() then
        return false
    end

    local direPosition = direGc:getOwnPosition()
    if not direPosition then return false end

    local rendezvousZone = self.map:selectRendezvousZone(self.color, direPosition)
    if not rendezvousZone then return false end
    local rendezvousPoint = self.map:getZone(rendezvousZone).point

    local homeZone = self.map:selectHomeZone(self.color, rendezvousPoint)
    if not homeZone then return false end
    local homePoint = self.map:getZone(homeZone).point

    local convoyGroupName = self.unitRecovery:spawnConvoy(homeZone)
    if not convoyGroupName then return false end
    local convoyGc = self.unitRecovery:wrapGroupCommander(convoyGroupName)

    local objective = Objective.new({
        type     = constants.taskTypes.REPAIR,
        position = rendezvousPoint,
        radius   = 500,
    })

    local doctrine = RepairResupplyPlan.new(self.color .. "Ops-repair", {
        direGc          = direGc,
        convoyGc        = convoyGc,
        unitRecovery    = self.unitRecovery,
        rendezvousZone  = rendezvousZone,
        rendezvousPoint = rendezvousPoint,
        homeZone        = homeZone,
        homePoint       = homePoint,
    })

    local opscom = OperationalCommander.new({
        color           = self.color,
        role            = "repair",
        groupCommanders = { direGc, convoyGc },
        visualizer      = self.visualizer,
        doctrine        = doctrine,
    })
    opscom.orderCoordinator.objectives = { objective }

    local operation = Operation.new({ target = { zoneName = rendezvousZone, position = rendezvousPoint } })
    operation:addObjective({
        objective = objective,
        role      = "repair",
        primary   = true,
        opscom    = opscom,
        template  = {},
        target    = { zoneName = rendezvousZone, position = rendezvousPoint },
        createdAt = timer.getTime(),
    })
    table.insert(self.operations.active, operation)

    env.info(string.format("****** %s StratCom ACT: dispatched %s to meet dire unit %s at %s",
        self.color, convoyGroupName, direGc.groupName, rendezvousZone))
    return true
end

-- Same "first own zone with an enemy/neutral neighbor, then choose among its
-- neighbors" target gathering CoalitionCommander used to do inline - just
-- split so the doctrine (not the commander) makes the actual choice,
-- mirroring how OperationalCommander:buildObjectiveContext gathers context
-- for its doctrine rather than deciding anything itself.
function StrategicCommander:buildStrategicContext()
    local candidateTargets = {}
    local ownZones = self.map:getCluster(self.color)
    for _, zoneName in ipairs(ownZones) do
        local enemyNeighbors = self.map:getNeighbors(zoneName, self.opponent, true)
        if enemyNeighbors and #enemyNeighbors > 0 then
            for _, neighborName in ipairs(enemyNeighbors) do
                table.insert(candidateTargets, {
                    zoneName = neighborName,
                    position = self.map:getZone(neighborName).point,
                })
            end
            break
        end
    end

    return {
        activeOperationCount = #self.operations.active,
        reserveCount         = #self.reserves,
        candidateTargets     = candidateTargets,
    }
end

-- Resolve one objective template into a real Objective + OperationalCommander,
-- allocating reserves by suitability (falling back to pure proximity when
-- the template has no missionProfile) then proximity as a tiebreak - the
-- same sort OperationalCommander:selectGroupCommanders uses one tier down.
-- Returns nil (rather than a half-filled entry) if no reserves are
-- currently available/suitable for this role - callers already tolerate
-- that gracefully, same as the original single-shot creation did.
-- Shared by createOperation and the refresh path in decide() below, since
-- "pick reserves and stand up an opscom for this role" is identical work
-- either way.
function StrategicCommander:instantiateObjective(objTemplate, target)
    local groupCount = objTemplate.groupCount or 1

    local candidates = {}
    for _, gc in ipairs(self.reserves) do
        local status = gc:getStatus()
        -- Same hard floor OperationalCommander:assignOrderTemplate applies -
        -- a dire reserve is excluded from fresh tasking entirely, not just
        -- deprioritized in the suitability sort, since dispatchDireReserves
        -- is what's responsible for it now (see StrategicCommander:act).
        if status.position and not gc:isConditionCritical() then
            local suitability = objTemplate.missionProfile and gc:getSuitability(objTemplate.missionProfile) or 1.0
            table.insert(candidates, {
                gc          = gc,
                suitability = suitability,
                dist        = SpatialAgent.distance2D(status.position, target.position),
            })
        end
    end
    table.sort(candidates, function(a, b)
        if a.suitability ~= b.suitability then
            return a.suitability > b.suitability
        end
        return a.dist < b.dist
    end)

    local selectedGroups = {}
    for i = 1, math.min(groupCount, #candidates) do
        table.insert(selectedGroups, candidates[i].gc)
    end

    if #selectedGroups == 0 then
        return nil
    end

    for _, gc in ipairs(selectedGroups) do
        for i, reserveGc in ipairs(self.reserves) do
            if reserveGc == gc then
                table.remove(self.reserves, i)
                break
            end
        end
    end

    local objective = Objective.new({
        type     = objTemplate.type,
        position = objTemplate.position,
        radius   = objTemplate.radius,
    })

    -- The strategic doctrine picks which operational doctrine a role needs
    -- (it's the only layer that knows what "fireSupport" vs "assault"
    -- actually means) - nil falls through to OperationalCommander's own
    -- ReconRallyAssaultPlan default.
    local doctrine = nil
    if objTemplate.operationalDoctrine then
        doctrine = objTemplate.operationalDoctrine.new(
            self.color .. "Ops-" .. objTemplate.role,
            objTemplate.operationalDoctrineConfig)
    end

    local opscom = OperationalCommander.new({
        color           = self.color,
        role            = objTemplate.role,
        groupCommanders = selectedGroups,
        visualizer      = self.visualizer,
        doctrine        = doctrine,
    })
    opscom.orderCoordinator.objectives = { objective }

    env.info(string.format("****** %s StratCom ACT: created objective -> targeting %s with %d groups (role=%s)",
        self.color, target.zoneName, #selectedGroups, objTemplate.role))

    return {
        objective = objective,
        role      = objTemplate.role,
        primary   = objTemplate.primary,
        opscom    = opscom,
        template  = objTemplate,
        target    = target,
        createdAt = timer.getTime(),
    }
end

-- Resolve an Operation template (from the doctrine) into a real Operation
-- and its objectives - the same selection approach CoalitionCommander used
-- for its single opscom, just per-objective-template so a doctrine can
-- request more than one objective (and role) per Operation.
function StrategicCommander:createOperation(template)
    local operation = Operation.new({ target = template.target })

    for _, objTemplate in ipairs(template.objectiveTemplates) do
        local entry = self:instantiateObjective(objTemplate, template.target)
        if entry then
            operation:addObjective(entry)
        end
    end

    if #operation.objectives > 0 then
        table.insert(self.operations.active, operation)
    end
end

return StrategicCommander
