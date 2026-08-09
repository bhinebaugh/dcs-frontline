local settings = {
    -- whether UI elements will show on the map at all
    draw = {
        edges = true,
        zones = true,
        frontlines = true,
        directives = true,
        groupOrders = true,
        groupMovement = true,
        objectives = true,
    },
    -- whether they will be visible to the other coalition
    displayToAll = {
        zones = true,
        frontlines = true,
        directives = true,
        groupOrders = false,
        groupMovement = false,
        objectives = false,
    }
}

return settings