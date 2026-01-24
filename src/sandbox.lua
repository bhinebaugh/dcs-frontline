local constants = require("constants")
local taskTypes = constants.taskTypes

local GroupCommander = require("group-commander")
local StrategicCommander = require("strategic-commander")

local stratBlue = StrategicCommander.new({color = "blue"})
local stratRed = StrategicCommander.new({color = "red"})

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

-- Initial objective for Alpha is to defend the bridge
-- near the coordinates:
local lat = 42 + 32/60 + 1/3600
local lon = 44 + 05/60 + 38/3600
local blueDefendPosition = coord.LLtoLO(lat, lon)

-- Initial objective for Bravo is to reposition to the
-- Kvemo-Khoshka village at these coordinates:
local lat = 42 + 28/60 + 0/3600
local lon = 44 + 03/60 + 30/3600
local redRepositionPosition = coord.LLtoLO(lat, lon)

-- Ideally, the strategic commander would issue these orders
-- Delay the move order until mission is fully loaded
-- mist.scheduleFunction(
--     function()
--         env.info("Delayed move order execution for Bravo")
--         groupB:issueMoveOrder(redRepositionPosition)
--     end,
--     {},
--     timer.getTime() + 5  -- Wait 5 seconds after mission start
-- )

stratBlue.objectives = {
    {
        type = taskTypes.DEFEND,
        position = blueDefendPosition,
        radius = 500, -- meters
    }
}

stratRed.objectives = {
    {
        type = taskTypes.RESERVE,
        position = redRepositionPosition,
    }
}

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
