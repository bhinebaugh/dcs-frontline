
local GroupCommander = require("group-commander")

local groupA = GroupCommander.new("Alpha", {color = "blue"})
local groupB = GroupCommander.new("Bravo", {color = "red"})

-- Destination N 43 11.290 E 044 31.248
-- Convert DMS to decimal degrees: 43 + 11.290/60, 44 + 31.248/60
local lat = 43 + 12/60 + 21/3600
local lon = 44 + 30/60 + 56/3600
local groupBDestination = coord.LLtoLO(lat, lon)

-- Delay the move order until mission is fully loaded
mist.scheduleFunction(
    function()
        env.info("Delayed move order execution for Bravo")
        groupB:issueMoveOrder(groupBDestination)
    end,
    {},
    timer.getTime() + 5  -- Wait 5 seconds after mission start
)
