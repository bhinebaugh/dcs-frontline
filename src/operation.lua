local Objective = require("objective")

-- Operation: strategic-level bundle of Objectives working toward one target.
-- Mirrors the Objective/Order relationship one level up: an Operation owns a
-- growable, arbitrary-cardinality list of Objectives (tagged by role, not
-- keyed by it), each with its own independent status - so an operation can
-- carry multiple objectives of the same role (e.g. two concurrent air
-- defense objectives), or have one objective's lifecycle (add/retire/
-- replace) proceed independently of its siblings, the same way
-- Objective.orders already supports multiple concurrent same-type orders.
--
-- Each entry is { objective = Objective, role = string, opscom = OperationalCommander }.
-- role is a free-form tag for the owning StrategicDoctrine's own bookkeeping
-- (e.g. "assault", "fireSupport") - not a unique slot key.

local Operation = {}
Operation.__index = Operation

local OperationStatus = {
    ACTIVE   = "Active",   -- Operation is being pursued
    ACHIEVED = "Achieved", -- All objectives resolved with no failures
    FAILED   = "Failed",   -- At least one objective failed
    CANCELED = "Canceled", -- Operation was canceled by the strategic commander
}

function Operation.new(config)
    local self = setmetatable({}, Operation)

    self.target = config.target -- {zoneName, position}
    self.status = OperationStatus.ACTIVE
    self.createdAt = timer.getTime()
    self.objectives = {} -- array of {objective, role, opscom}

    return self
end

-- Add an objective entry to this operation
function Operation:addObjective(entry)
    table.insert(self.objectives, entry)
end

-- Get counts of this operation's objectives by status. Pass primaryOnly=true
-- to count only entries whose template marked them primary (e.g. assault) -
-- that's what determines whether the *operation* is done, since a
-- supporting objective (e.g. fireSupport) has no natural completion of its
-- own and shouldn't be able to hold the operation open forever, nor should
-- it be treated as "the operation is done" while a primary objective is
-- still active.
function Operation:getObjectiveStatusCounts(primaryOnly)
    local counts = {active = 0, achieved = 0, failed = 0, canceled = 0, total = 0}

    for _, entry in ipairs(self.objectives) do
        if not primaryOnly or entry.primary then
            counts.total = counts.total + 1
            local status = entry.objective.status
            if status == Objective.Status.ACTIVE then
                counts.active = counts.active + 1
            elseif status == Objective.Status.ACHIEVED then
                counts.achieved = counts.achieved + 1
            elseif status == Objective.Status.FAILED then
                counts.failed = counts.failed + 1
            elseif status == Objective.Status.CANCELED then
                counts.canceled = counts.canceled + 1
            end
        end
    end

    return counts
end

-- Returns true if the operation is no longer being actively pursued
function Operation:isComplete()
    return self.status ~= OperationStatus.ACTIVE
end

Operation.Status = OperationStatus

return Operation
