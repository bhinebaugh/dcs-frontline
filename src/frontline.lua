-- requires MIST to be loaded first
-- DO SCRIPT FILE: mist.lua
--[[ This is handy for development, so that you don't need to delete and re-add the individual scripts in the ME when you make a change.  These will not be packaged with the .miz, so you shouldn't use this script loader for packaging .miz files for other machines/users.  You'll want to add each script individually with a DO SCRIPT FILE ]]--
-- DO SCRIPT: assert(loadfile("C:\\Users\\username\\...\\bundled.lua"))()

require("table") --Load modified standard libraries

local ControlZones = require("control-zones") --Load the ControlZones class from control-zoness.lua
local CoalitionCommander = require("coalition-commander") --Load the CoalitionCommander class from coalition-commander.lua

local constants = require("constants") --Load constants

cz = ControlZones.new(nil, constants.groundTemplates)

cz:setup()
cz:constructDelaunayIndex()
cz:precalculateConnections()

cz:assignCompassMaxima()

ccBlue = CoalitionCommander.new(cz, {color = "blue", groundTemplates = constants.groundTemplates.blue})
ccRed = CoalitionCommander.new(cz, {color = "red", groundTemplates = constants.groundTemplates.red})
cz:addCommander("blue", ccBlue)
cz:addCommander("red", ccRed)
cz:kickoff()
