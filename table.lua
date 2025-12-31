function table.contains(table, el)
    for _, v in pairs(table) do
        if v == el then
            return true
        end
    end
    return false
end

function table.findIndex(table, needle)
    for i, v in pairs(table) do
        if v == needle then
            return i
        end
    end
    return nil
end
