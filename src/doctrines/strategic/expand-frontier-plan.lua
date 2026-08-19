local constants = require("constants")
local Doctrine = require("doctrine")

local taskTypes = constants.taskTypes

-- ExpandFrontierPlan: first strategic doctrine, modeled directly on the
-- target-selection/resourcing logic that used to be baked into
-- CoalitionCommander - pick a random enemy-adjacent zone once no operation
-- is active, and commit up to 3 nearest reserve groups to assault it.
--
-- Unlike tactical/operational doctrines, this doesn't use Doctrine's phase
-- machinery (registerPhase/changePhase) - there's no single linear
-- progression to be "in a phase" of once multiple independent Operations
-- and Objectives can exist concurrently (see StrategicCommander/Operation).
-- It still extends Doctrine for the shared name/commanderName bookkeeping
-- and to keep the same swappable-strategy shape as the other two tiers, but
-- overrides plan() entirely with a one-shot reconciliation pass instead of
-- phase dispatch: given the current game-board state, decide what
-- Operations (if any) should be started this cycle.
local ExpandFrontierPlan = {}
setmetatable(ExpandFrontierPlan, {__index = Doctrine})
ExpandFrontierPlan.__index = ExpandFrontierPlan

function ExpandFrontierPlan.new(commanderName)
    local self = Doctrine.new("ExpandFrontier", commanderName)
    setmetatable(self, ExpandFrontierPlan)
    return self
end

-- context: { activeOperationCount, reserveCount, candidateTargets = {{zoneName, position}, ...} }
-- returns { operations = { { target = {...}, objectiveTemplates = {...} } } }
function ExpandFrontierPlan:plan(context)
    -- Only pursue one operation at a time for now - same serialization
    -- CoalitionCommander used (`activeCount == 0`). Nothing about Operation
    -- or StrategicCommander requires this; it's just this doctrine's choice.
    if context.activeOperationCount > 0 then
        return {}
    end

    if context.reserveCount == 0 or #context.candidateTargets == 0 then
        return {}
    end

    local target = context.candidateTargets[math.random(#context.candidateTargets)]

    return {
        operations = {
            {
                target = target,
                objectiveTemplates = {
                    {
                        role       = "assault",
                        type       = taskTypes.ASSAULT,
                        position   = target.position,
                        radius     = 500,
                        groupCount = 3,
                        -- Primary: the operation is considered done once
                        -- this resolves (see Operation:getObjectiveStatusCounts
                        -- and StrategicCommander:orient).
                        primary    = true,
                    },
                },
            },
        },
    }
end

return ExpandFrontierPlan
