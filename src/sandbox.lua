local constants = require("constants")
local taskTypes = constants.taskTypes

local GroupCommander = require("group-commander")
local Objective = require("objective")
local StrategicCommander = require("strategic-commander")

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local blueDefendPosition = coord.LLtoLO(
    42 + 32/60 + 1/3600,
    44 + 05/60 + 38/3600
)

-- Known safe rally point for Blue forces
local blueRallyPosition = coord.LLtoLO(
    42 + 25/60 + 30/3600,
    44 + 00/60 + 26/3600
)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
local redRepositionPosition = coord.LLtoLO(
    42 + 27/60 + 53/3600,
    44 + 03/60 + 37/3600
)

-- Known safe rally point for Red forces
local redRallyPosition = coord.LLtoLO(
    42 + 34/60 + 0/3600,
    44 + 06/60 + 30/3600
)

local stratBlue = StrategicCommander.new({color = "blue"})
local stratRed = StrategicCommander.new({color = "red"})

-- Assign rally points to strategic commanders
stratBlue.rallyPoints = {
    {position = blueRallyPosition, radius = 500}
}

stratRed.rallyPoints = {
    {position = redRallyPosition, radius = 500}
}

-- Create and assign objectives directly
stratBlue.objectives = {
    Objective.new({
        type = taskTypes.DEFEND,
        position = blueDefendPosition,
        radius = 500,
    })
}

stratRed.objectives = {
    Objective.new({
        type = taskTypes.REPOSITION,
        position = redRepositionPosition,
        deadline = timer.getTime() + 1800,  -- 30 minute deadline
    })
}

local groupA = GroupCommander.new("Alpha", {
    color = "blue",
    stratcom = stratBlue
})
local groupB = GroupCommander.new("Bravo", {
    color = "red",
    stratcom = stratRed
})
local groupC = GroupCommander.new("Charlie", {
    color = "red",
    stratcom = stratRed
})

-- ## General scenario setup
-- 1. Bravo encounters Alpha overlooking the bridge
--   - Should spot them when near Kvemo-Roka villag
--   - at a fork in the road
-- 2. Bravo retreats up either branch of the fork
-- 3. Alpha pursues, but loses sight due to terrain
-- 4. Alpha breaks off pursuit and returns to defend the bridge
-- 5. Bravo reports enemy position to strategic command
-- 6. Strategic command dispatches reinforcements to assist Bravo
-- 7. Bravo attempts to continue to Kvemo-Khoshka village after the threat is removed
