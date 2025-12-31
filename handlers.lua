local UnitLostHandler = {}
UnitLostHandler.__index = UnitLostHandler

function UnitLostHandler.new(cz)
    local self = setmetatable({}, UnitLostHandler)
    self.cz = cz
    self.groupOfUnit = cz.groupOfUnit
    self.groundGroups = cz.groundGroups
    return self
end

function UnitLostHandler:onEvent(e)
    -- ground unit sequence seems to always be: world.event.S_EVENT_KILL then S_EVENT_DEAD (but no S_EVENT_LOST)
    -- however it needs a workaround for the dead unit not having a group,
    -- likely due to https://forum.dcs.world/topic/295922-scripting-api-eventdead-not-called-if-an-object-isnt-immediately-dead/
    if not e then return end
    if world.event.S_EVENT_KILL == e.id then
        local unitName = e.target:getName()
        if unitName and not e.target:getPlayerName() then
            local grpName = self.groupOfUnit[unitName]
            if mist.groupIsDead(grpName) then --error if player
                env.info(grpName.." is all dead now")
                env.info(mist.utils.tableShow(self.groundGroups[grpName]))
                local originZone = self.groundGroups[grpName].origin
                env.info("updating ownership of "..originZone)
                self.cz:updateZoneOwner(originZone)
            end
        end
        --register reduced strength or loss with coalition command
    end
end

return {
    UnitLostHandler = UnitLostHandler
}
