local ADDON_NAME, ns = ...

local UI, Options = ns.UI, ns.Options

Options:RegisterPane("minimap", "Minimap", 5.7, function(pane)
    UI.Header(pane, "Minimap", "Class-coloured party orbs on the minimap. Positions are unavailable inside instances.")
    local widgets = {}
    local y = -52

    local function check(label, key)
        local c = UI.Checkbox(pane, label, function() return ns.db.pins[key] end,
            function(v) ns.db.pins[key] = v; ns:Changed("pins") end)
        c:SetPoint("TOPLEFT", 0, y)
        widgets[#widgets + 1] = c
        y = y - 26
    end

    check("Show class-coloured party pins on the minimap", "enabled")
    local size = UI.Slider(pane, "Pin size", 10, 28, 1, function() return ns.db.pins.size end,
        function(v) ns.db.pins.size = v; ns:Changed("pins") end, 200)
    size:SetPoint("TOPLEFT", 0, y)
    widgets[#widgets + 1] = size
    y = y - 32
    check("Show role glyph inside the orb", "showRole")
    check("Show names on hover (tooltip)", "showNames")
    check("Show pets (smaller orbs)", "showPets")
    check("Edge pointers when out of range", "showEdge")
    check("Low-HP pulse (only when health is readable)", "pulse")
    check("Mark corpse with a red X where a member died", "markCorpse")

    function pane:Refresh()
        for _, w in ipairs(widgets) do w:Refresh() end
    end
end)
