local UnitLostHandler = {}
UnitLostHandler.__index = UnitLostHandler

function UnitLostHandler.new(cz)
    local self = setmetatable({}, UnitLostHandler)
    self.cz = cz
    return self
end

function UnitLostHandler:onEvent(e)
    -- ground unit sequence seems to always be: world.event.S_EVENT_KILL then S_EVENT_DEAD (but no S_EVENT_LOST)
    -- however it needs a workaround for the dead unit not having a group,
    -- likely due to https://forum.dcs.world/topic/295922-scripting-api-eventdead-not-called-if-an-object-isnt-immediately-dead/
    if not e then return end
    if world.event.S_EVENT_KILL == e.id then
        local unitName = e.target:getName()
        --event initiator
        if unitName and not e.target:getPlayerName() then
            --register reduced strength or loss with coalition command
            self.cz:processDeadUnit(unitName)
        end
    end
end

return {
    UnitLostHandler = UnitLostHandler
}
