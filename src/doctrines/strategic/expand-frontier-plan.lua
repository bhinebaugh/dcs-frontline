local constants = require("constants")
local Doctrine = require("doctrine")
local FireSupportPlan = require("doctrines.operational.fire-support-plan")

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
                -- fireSupport listed first so it gets first pick of reserves
                -- by suitability (see StrategicCommander:createOperation) -
                -- long-range/light-armor groups get skimmed off for it
                -- before assault's proximity-only pick sees the remainder.
                objectiveTemplates = {
                    {
                        role       = "fireSupport",
                        type       = taskTypes.INDIRECT,
                        position   = target.position,
                        radius     = 500,
                        groupCount = 1,
                        -- Range, not offensiveCapability, is what actually
                        -- distinguishes artillery from a rifle squad or IFV
                        -- here (see GroupProfiler.calculateFavorability's
                        -- header) - an ideal well beyond any direct-fire
                        -- unit's reach is enough to make suitability favor
                        -- whichever reserves actually have the range for it.
                        missionProfile = {
                            range = { unarmored = 20000, light = 20000, medium = 20000, heavy = 20000, air = 0 },
                        },
                        -- Fire support needs its own operational doctrine,
                        -- not the default ReconRallyAssaultPlan every other
                        -- opscom gets - it should be issuing INDIRECT
                        -- orders, not recon/assault ones.
                        operationalDoctrine       = FireSupportPlan,
                        operationalDoctrineConfig = { duration = 600 },
                        -- Matches duration above deliberately: refreshInterval
                        -- (StrategicCommander:orient/decide's staleByInterval
                        -- handling) is what keeps this role alive for the
                        -- life of the operation at all - without it, once
                        -- FireSupportPlan's own 600s duration elapses and it
                        -- marks its objective Achieved, decide() stops
                        -- calling plan() on it entirely (only Active
                        -- objectives get planned) and the opscom just sits
                        -- idle for the rest of the operation. Setting it
                        -- shorter than duration (tried 120s, 300s) cuts
                        -- missions short before they establish - every
                        -- refresh pays the same setup latency (opscom/group
                        -- OODA cadence, travel time to range, DCS's own AI
                        -- spin-up for FireAtPoint) before firing resumes.
                        -- Equal to duration: each mission gets its full
                        -- uninterrupted run, then a new target gets picked
                        -- and it goes again, repeating for as long as the
                        -- operation's primary objective stays active.
                        refreshInterval = 600,
                    },
                    {
                        role       = "assault",
                        type       = taskTypes.ASSAULT,
                        position   = target.position,
                        radius     = 500,
                        groupCount = 3,
                        -- Primary: the operation is considered done once
                        -- this resolves, regardless of fireSupport's own
                        -- state (see Operation:getObjectiveStatusCounts and
                        -- StrategicCommander:orient) - achieving it tears
                        -- down fireSupport alongside it rather than leaving
                        -- fire support refreshing forever with nothing left
                        -- to support.
                        primary    = true,
                    },
                },
            },
        },
    }
end

return ExpandFrontierPlan
