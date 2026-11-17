local ADDON_NAME, ns = ...

local UI, Options = ns.UI, ns.Options
local Util = ns.Util

local function collect()
    local widgets = {}
    return widgets, function(w) widgets[#widgets + 1] = w; return w end
end

local function refreshAll(widgets)
    for _, w in ipairs(widgets) do
        if w.Refresh then w:Refresh() end
    end
end

local function presetItems()
    local items = {}
    for i, p in ipairs(ns.db.presets) do
        local text = i .. ". " .. p.name
        if i == ns.db.activePreset then text = text .. " |cff33ff33(active)|r" end
        items[#items + 1] = { text = text, value = i }
    end
    return items
end

-- General ------------------------------------------------------------------------

Options:RegisterPane("general", "General", 1, function(pane)
    local widgets, track = collect()
    UI.Header(pane, "General", "Global behaviour. Changes apply live (out of combat).")
    local add = Options.Stack(pane, -52)

    add(track(UI.Checkbox(pane, "Show minimap button",
        function() return not ns.db.minimap.hide end,
        function(v) ns.db.minimap.hide = not v; ns:Changed("minimap") end)))
    add(track(UI.Checkbox(pane, "Show minimap button status badges (buff dot, lock, preset)",
        function() return ns.db.minimap.badges ~= false end,
        function(v) ns.db.minimap.badges = v; ns:Changed("minimap") end)))
    add(track(UI.Checkbox(pane, "Lock minimap button position",
        function() return ns.db.minimap.lockPos end,
        function(v) ns.db.minimap.lockPos = v and true or false; ns:Changed("minimap") end)))
    add(track(UI.Checkbox(pane, "Lock frames (hide move handle)",
        function() return ns.db.frames.locked end,
        function(v) ns.UnitFrames:SetLocked(v) end)))
    add(track(UI.Checkbox(pane, "Show player (yourself) in the party frames",
        function() return ns.db.frames.showPlayer end,
        function(v) ns.db.frames.showPlayer = v; ns:Changed("frames") end)))
    add(track(UI.Checkbox(pane, "Show pets",
        function() return ns.db.frames.showPets end,
        function(v) ns.db.frames.showPets = v; ns:Changed("frames") end)))
    add(track(UI.Checkbox(pane, "Click on dead member = Resurrect",
        function() return ns.db.resurrectOnClick end,
        function(v) ns.db.resurrectOnClick = v; ns:Changed("general") end)))

    local label = UI.Label(pane, "Active buff preset")
    add(label, 0, 18)
    local dd = track(UI.Dropdown(pane, 240, presetItems,
        function() return ns.db.activePreset end,
        function(v) ns:SetActivePreset(v) end))
    add(dd, 0, 22)

    local res = UI.Label(pane, "", "GameFontDisable")
    res:SetWidth(540)
    res:SetWordWrap(true)
    add(res, 0, 40)
    function res:Refresh()
        local spell = ns.PlayerRes and ns.PlayerRes()
        self:SetText(spell and ("Resurrection spell detected: " .. spell .. ". Dead members show DEAD/GHOST and every click casts it.")
            or "No resurrection spell known for your class: normal bindings stay active on dead members.")
    end
    track(res)

    local about = UI.Label(pane, "About", "GameFontNormal")
    add(about, 0, 18)
    local aboutText = UI.Label(pane, "Healer Forever, created by trtg\nVersion " .. ns.AddonVersion() .. " - settings schema v" .. ns.SchemaVersion(), "GameFontDisable")
    aboutText:SetWidth(540)
    add(aboutText, 0, 30)

    local hideNote = UI.Label(pane, "To hide Blizzard's party frames use Blizzard Settings > Edit Mode / Interface (turn Raid-style party frames off).", "GameFontDisable")
    hideNote:SetWidth(540)
    hideNote:SetWordWrap(true)
    add(hideNote, 0, 30)

    local note = UI.Label(pane, "Minimap button: Left-click options, Right-click lock/unlock frames, Shift+click cycle buff preset.", "GameFontDisable")
    note:SetWidth(540)
    note:SetWordWrap(true)
    add(note, 0, 30)

    function pane:Refresh() refreshAll(widgets) end
end)

-- Frames & Bars ---------------------------------------------------------------------

local LAYOUTS = { { text = "Horizontal (pet below)", value = "horizontal" }, { text = "Vertical (pet right)", value = "vertical" } }
local COLORS = { { text = "Class colours", value = "class" }, { text = "Custom", value = "custom" }, { text = "Health gradient", value = "gradient" } }
local TEXTS = { { text = "Percent", value = "percent" }, { text = "Current", value = "current" },
    { text = "Deficit", value = "deficit" }, { text = "None", value = "none" } }
local SORTS = { { text = "Manual", value = "manual" }, { text = "Role", value = "role" },
    { text = "Class", value = "class" }, { text = "Name", value = "name" } }

local BORDER_STYLES = { { text = "None", value = "none" }, { text = "Thin", value = "thin" },
    { text = "Tooltip", value = "tooltip" }, { text = "Vanilla gold", value = "gold" } }
local BORDER_COLORS = { { text = "Class colour", value = "class" }, { text = "Black", value = "black" },
    { text = "Gold", value = "gold" }, { text = "Custom", value = "custom" } }
local RANGE_STYLES = { { text = "B. Range badge", value = "badge" }, { text = "Old dim (fade the whole frame)", value = "dim" } }
local POSITIONS = { { text = "Top", value = "top" }, { text = "Bottom", value = "bottom" }, { text = "Left", value = "left" },
    { text = "Right", value = "right" }, { text = "Inside bar", value = "inside" } }
local TIMER_POSITIONS = { { text = "Below icon", value = "below" }, { text = "Inside icon", value = "inside" } }
local GROWS = { { text = "Right", value = "right" }, { text = "Left", value = "left" },
    { text = "Down", value = "down" }, { text = "Up", value = "up" } }

local function setFrames(key)
    return function(v) ns.db.frames[key] = v; ns:Changed("frames") end
end

local function unitLabel(unit)
    local fallback = unit == "player" and "Player" or ("Party " .. unit:sub(6))
    if UnitExists and ns.Exists(unit) then
        return (UnitName(unit) or fallback) .. " (" .. fallback .. ")"
    end
    return fallback
end

Options:RegisterPane("frames", "Frames & Bars", 5, function(pane)
    local widgets, track = collect()
    local scroll = ns.NewFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    local root = ns.NewFrame("Frame", nil, scroll)
    root:SetSize(540, 900)
    scroll:SetScrollChild(root)
    UI.Header(root, "Frames & Bars", "Changes apply live to the frames.")
    local rowY = -44
    local function place(label, widget)
        local l = UI.Label(root, label)
        l:SetPoint("TOPLEFT", 0, rowY)
        widget:SetPoint("TOPLEFT", 150, rowY + 4)
        track(widget)
        rowY = rowY - 28
        return widget
    end

    place("Layout", UI.Dropdown(root, 200, function() return LAYOUTS end,
        function() return ns.db.frames.layout end, setFrames("layout")))
    local colorDD = place("Health bar colour", UI.Dropdown(root, 200, function() return COLORS end,
        function() return ns.db.frames.colorMode end, setFrames("colorMode")))
    local swatch = UI.ColorSwatch(root,
        function() return ns.db.frames.customColor end,
        function(c) ns.db.frames.customColor = c; ns:Changed("frames") end)
    swatch:SetPoint("LEFT", colorDD, "RIGHT", 8, 0)
    track(swatch)
    place("Health text", UI.Dropdown(root, 200, function() return TEXTS end,
        function() return ns.db.frames.healthText end, setFrames("healthText")))
    place("Sort mode", UI.Dropdown(root, 200, function() return SORTS end,
        function() return ns.db.frames.sortMode end, setFrames("sortMode")))

    local function borderSet(key)
        return function(v)
            local b = Util.NormalizeBorder(ns.db.frames.border)
            b[key] = v
            ns.db.frames.border = b
            ns:Changed("frames")
        end
    end
    place("Bar border style", UI.Dropdown(root, 200, function() return BORDER_STYLES end,
        function() return Util.NormalizeBorder(ns.db.frames.border).style end, borderSet("style")))
    local borderColorDD = place("Bar border colour", UI.Dropdown(root, 200, function() return BORDER_COLORS end,
        function() return Util.NormalizeBorder(ns.db.frames.border).color end, borderSet("color")))
    local borderSwatch = UI.ColorSwatch(root,
        function() return Util.NormalizeBorder(ns.db.frames.border).custom end, borderSet("custom"))
    borderSwatch:SetPoint("LEFT", borderColorDD, "RIGHT", 8, 0)
    track(borderSwatch)

    local function slider(label, lo, hi, step, key)
        local s = UI.Slider(root, label, lo, hi, step, function() return ns.db.frames[key] end, setFrames(key), 200)
        s:SetPoint("TOPLEFT", 0, rowY)
        track(s)
        rowY = rowY - 28
    end
    slider("Frame width", 100, 260, 2, "width")
    slider("Health bar height", 24, 80, 2, "height")
    slider("Spacing between frames", 0, 24, 1, "spacing")
    do
        local s = UI.Slider(root, "Bar border thickness", 1, 4, 1,
            function() return Util.NormalizeBorder(ns.db.frames.border).width end, borderSet("width"), 200)
        s:SetPoint("TOPLEFT", 0, rowY)
        track(s)
        rowY = rowY - 28
    end

    local function check(label, get, set)
        local c = UI.Checkbox(root, label, get, set)
        c:SetPoint("TOPLEFT", 0, rowY)
        track(c)
        rowY = rowY - 24
    end
    check("Show mana / rage / energy bar", function() return ns.db.frames.showPower end, setFrames("showPower"))
    check("Show role icons on frames", function() return ns.db.frames.showRoleIcon end, setFrames("showRoleIcon"))
    check("Show incoming heal (prediction)", function() return ns.db.frames.showPrediction end, setFrames("showPrediction"))
    check("Show overheal", function() return ns.db.frames.showOverheal end, setFrames("showOverheal"))
    check("Low-HP pulse (only when health is readable)", function() return ns.db.frames.lowHpPulse end, setFrames("lowHpPulse"))

    -- Range -------------------------------------------------------------------------------------------------
    local rangeTitle = UI.Label(root, "Range", "GameFontNormal")
    rangeTitle:SetPoint("TOPLEFT", 0, rowY - 4)
    rowY = rowY - 28
    local function rangeSet(key)
        return function(v)
            local r = Util.NormalizeRange(ns.db.frames.range)
            r[key] = v
            ns.db.frames.range = r
            ns:Changed("frames")
        end
    end
    local function rangeGet(key) return function() return Util.NormalizeRange(ns.db.frames.range)[key] end end
    place("Out-of-range style", UI.Dropdown(root, 200, function() return RANGE_STYLES end,
        rangeGet("style"), rangeSet("style")))
    do
        local s = UI.Slider(root, "Dim alpha (%)", 10, 100, 1, rangeGet("dim"), rangeSet("dim"), 200)
        s:SetPoint("TOPLEFT", 0, rowY)
        track(s)
        rowY = rowY - 28
    end
    check("Show OUT OF RANGE / NOT VISIBLE badge", rangeGet("badge"), rangeSet("badge"))
    check("Healable green edge on in-range bars", rangeGet("healable"), rangeSet("healable"))
    for _, entry in ipairs({ { "Healable colour", "healableColor" }, { "Out-of-range colour", "outColor" },
        { "Not-visible colour", "hiddenColor" } }) do
        local l = UI.Label(root, entry[1])
        l:SetPoint("TOPLEFT", 0, rowY)
        local sw = UI.ColorSwatch(root, rangeGet(entry[2]), rangeSet(entry[2]))
        sw:SetPoint("TOPLEFT", 150, rowY + 4)
        track(sw)
        rowY = rowY - 26
    end

    local orderLabel = UI.Label(root, "Member order (used when sort mode is Manual)", "GameFontNormal")
    orderLabel:SetPoint("TOPLEFT", 0, rowY - 4)
    rowY = rowY - 26
    local orderRows = {}
    local function swap(i, j)
        local order = ns.db.frames.order
        if not order[j] then return end
        order[i], order[j] = order[j], order[i]
        ns:Changed("frames")
        pane:Refresh()
    end
    for i = 1, 5 do
        local fs = UI.Label(root, "")
        fs:SetPoint("TOPLEFT", 0, rowY)
        local up = UI.Button(root, "Up", 40, function() swap(i, i - 1) end)
        up:SetPoint("TOPLEFT", 260, rowY + 4)
        local down = UI.Button(root, "Down", 50, function() swap(i, i + 1) end)
        down:SetPoint("LEFT", up, "RIGHT", 4, 0)
        orderRows[i] = fs
        rowY = rowY - 24
    end

    root:SetHeight(-rowY + 20)

    function pane:Refresh()
        refreshAll(widgets)
        for i, fs in ipairs(orderRows) do
            local unit = ns.db.frames.order[i]
            fs:SetText(unit and (i .. ". " .. unitLabel(unit)) or "")
        end
    end
end)

-- Buffs & Debuffs --------------------------------------------------------------------

Options:RegisterPane("auras", "Buffs & Debuffs", 6, function(pane)
    local widgets, track = collect()
    local scroll = ns.NewFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    local root = ns.NewFrame("Frame", nil, scroll)
    root:SetSize(540, 900)
    scroll:SetScrollChild(root)
    UI.Header(root, "Buffs & Debuffs", "Timers show minutes above 60s and seconds below; under 10s they turn red.")
    local y = -52
    local function check(label, get, set)
        local c = UI.Checkbox(root, label, get, set)
        c:SetPoint("TOPLEFT", 0, y)
        track(c)
        y = y - 26
    end
    local function set(key)
        return function(v) ns.db.auras[key] = v; ns:Changed("frames") end
    end
    check("Show buffs", function() return ns.db.auras.showBuffs end, set("showBuffs"))
    check("Only buffs cast by me", function() return ns.db.auras.onlyMine end, set("onlyMine"))
    check("Show debuffs", function() return ns.db.auras.showDebuffs end, set("showDebuffs"))
    check("Only debuffs I can dispel", function() return ns.db.auras.onlyDispellable end, set("onlyDispellable"))
    check("Colour debuff border by type", function() return ns.db.auras.colorDebuffBorder end, set("colorDebuffBorder"))
    check("Show debuff list in hover tooltip", function() return ns.db.auras.tooltipDebuffs end,
        function(v) ns.db.auras.tooltipDebuffs = v end)
    check("Show tooltip when hovering buff/debuff icons", function() return ns.db.auras.tooltipIcons end,
        function(v) ns.db.auras.tooltipIcons = v; ns:Changed("frames") end)
    check("Also list buffs in hover tooltip", function() return ns.db.auras.tooltipBuffs end,
        function(v) ns.db.auras.tooltipBuffs = v end)
    y = y - 6
    local function slider(label, lo, hi, get, setter)
        local s = UI.Slider(root, label, lo, hi, 1, get, setter, 200)
        s:SetPoint("TOPLEFT", 0, y)
        track(s)
        y = y - 28
    end
    slider("Max buffs", 1, 20, function() return ns.db.auras.maxBuffs end, set("maxBuffs"))
    slider("Max debuffs", 1, 12, function() return ns.db.auras.maxDebuffs end, set("maxDebuffs"))
    local function layoutDropdown(label, list, key)
        local l = UI.Label(root, label)
        l:SetPoint("TOPLEFT", 0, y)
        local dd = UI.Dropdown(root, 160, function() return list end,
            function() return ns.db.auras[key] end, function(v) ns.db.auras[key] = v; ns:Changed("frames") end)
        dd:SetPoint("TOPLEFT", 150, y + 4)
        track(dd)
        y = y - 28
    end
    layoutDropdown("Buff position", POSITIONS, "buffPosition")
    layoutDropdown("Debuff position", POSITIONS, "debuffPosition")
    layoutDropdown("Grow direction", GROWS, "grow")
    slider("Buff icon size", 10, 28, function() return ns.db.auras.buffSize end,
        function(v) ns.db.auras.buffSize = v; ns:Changed("frames") end)
    slider("Debuff icon size", 12, 32, function() return ns.db.auras.debuffSize end,
        function(v) ns.db.auras.debuffSize = v; ns:Changed("frames") end)
    local perRowAuto = UI.Checkbox(root, "Auto: fit as many icons per row as the bar is wide",
        function() return ns.db.auras.perRow == 0 end,
        function(v) ns.db.auras.perRow = v and 0 or 6; ns:Changed("frames") end)
    perRowAuto:SetPoint("TOPLEFT", 0, y)
    track(perRowAuto)
    y = y - 28
    slider("Max per row", 2, 10, function() return math.max(2, ns.db.auras.perRow) end,
        function(v) ns.db.auras.perRow = v; ns:Changed("frames") end)
    slider("Spacing between buffs/debuffs and bar", 0, 12, function() return ns.db.auras.zoneGap end,
        function(v) ns.db.auras.zoneGap = v; ns:Changed("frames") end)
    layoutDropdown("Timer position", TIMER_POSITIONS, "timerPos")
    y = y - 4
    local warn = UI.Checkbox(root, "Rebuff early (uncheck: only when a buff is gone)",
        function() return ns.db.buffs.warn end,
        function(v) ns.db.buffs.warn = v; ns:Changed("presets") end)
    warn:SetPoint("TOPLEFT", 0, y)
    track(warn)
    y = y - 28
    local solo = UI.Checkbox(root, "Show buff button also while solo (for yourself)",
        function() return ns.db.buffs.showSolo end,
        function(v) ns.db.buffs.showSolo = v; ns:Changed("presets") end)
    solo:SetPoint("TOPLEFT", 0, y)
    track(solo)
    y = y - 28
    local smartCB = UI.Checkbox(root, "Show 'Buff next' button (macro: /click HealerForeverSmartBuff)",
        function() return ns.db.smartButton.show end,
        function(v) ns.db.smartButton.show = v; ns:Changed("presets") end)
    smartCB:SetPoint("TOPLEFT", 0, y)
    track(smartCB)
    y = y - 28
    local pct = UI.Slider(root, "Class buffs: rebuff below (% left)", 0, 50, 1,
        function() return ns.db.buffs.rebuffPercent end,
        function(v) ns.db.buffs.rebuffPercent = v; ns:Changed("presets") end, 200)
    pct:SetPoint("TOPLEFT", 0, y)
    track(pct)
    y = y - 28
    local thr = UI.Slider(root, "Role buffs: rebuff below (s left)", 10, 300, 10,
        function() return ns.db.buffs.threshold end,
        function(v) ns.db.buffs.threshold = v; ns:Changed("presets") end, 200)
    thr:SetPoint("TOPLEFT", 0, y)
    track(thr)
    y = y - 28
    local note = UI.Label(root, "Dispellable-only uses Blizzard's RAID_PLAYER_DISPELLABLE aura filter. Aura icons have no tooltips so they never block click-casting.", "GameFontDisable")
    note:SetPoint("TOPLEFT", 0, y - 6)
    note:SetWidth(540)
    note:SetWordWrap(true)
    root:SetHeight(-y + 40)
    function pane:Refresh() refreshAll(widgets) end
end)

-- About ---------------------------------------------------------------------------------

Options:RegisterPane("about", "About / Forever API", 7, function(pane)
    UI.Header(pane, "WoW Forever API notes", "WoW Forever runs on the modern (Midnight-era) addon API, so some things differ from old Classic addons.")
    local text = UI.Label(pane,
        "Works: custom party frames, class colours, moving/resizing, minimap button and pins, click-casting through secure buttons, health and power bars, hiding Blizzard party frames, aura icons with countdowns.\n\n" ..
        "Restricted in combat (secret values): the addon can display health, heals and auras through Blizzard widgets but cannot calculate with them.\n" ..
        "- Heal prediction uses Blizzard's heal-prediction calculator; overheal text is only shown when values are readable.\n" ..
        "- Missing-buff buttons are evaluated out of combat; in combat they are hidden.\n" ..
        "- Aura timers fall back to Blizzard's Cooldown countdown when values are secret.\n" ..
        "- The Cmd (meta) modifier and mouse buttons 6+ use hover override bindings, because secure clicks only know Alt, Ctrl and Shift. Verify Cmd in game.\n" ..
        "- Dead members: every click casts your resurrection spell through secure macro conditionals, which work in combat.\n\n" ..
        "Slash commands: /hf, /hf lock, /hf unlock, /hf preset <n>, /hf reset", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 0, -70)
    text:SetWidth(560)
    text:SetWordWrap(true)
end)
