local ADDON_NAME, ns = ...

-- Options > Raid Layout (mockup/raid-style-d.html + mockup/raid-frames.html). Every control writes ns.db.raid and calls
-- ns:Changed("raid"): the real raid frames re-lay out (queued until combat ends) and the preview re-renders live.
-- Single scrolling column like Frames & Bars: labels at x = 0 (short, so they never run into the controls at x = 150),
-- sliders with the toolkit's 130 px label column.
local UI, Options = ns.UI, ns.Options

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ROOT_W = 540
local CTRL_X = 150
local ORANGE = { 1, 0.69, 0.44 }

local LAYOUT_MODES = { { text = "Auto (by group type)", value = "auto" }, { text = "Always party", value = "party" },
    { text = "Always raid", value = "raid" } }
local SORTS = { { text = "Raid order", value = "none" }, { text = "Role", value = "role" }, { text = "Class", value = "class" } }
local HEALTH_TEXTS = { { text = "Deficit (-1.2k), when hurt", value = "deficit" }, { text = "Percent", value = "percent" },
    { text = "None", value = "none" } }
local ENDING_LOOKS = { { text = "Orange + pulse", value = "pulse" }, { text = "Orange + clock sweep", value = "sweep" },
    { text = "Orange border only", value = "border" } }
local MULTI = { { text = "One icon per state", value = "state" }, { text = "First icon + count", value = "first" },
    { text = "Up to 3 icons", value = "stack" } }
local IN_COMBAT = { { text = "Hide markers", value = "hide" }, { text = "Keep last known (dim)", value = "dim" } }
local ARRANGE = { { text = "Columns", value = "columns" }, { text = "Rows", value = "rows" } }
local PER_LINE = { { text = "8", value = 8 }, { text = "4 \195\151 2", value = 4 }, { text = "2 \195\151 4", value = 2 } }
local PER_LINE_TEXT = { [8] = "all 8 groups on one line", [4] = "4 groups per line, 2 lines", [2] = "2 groups per line, 4 lines" }

local function R() return ns.db.raid end
local function RF() return ns.RaidFrames end
local function RP() return ns.RaidPreview end

local function glowSupported()
    local rf = RF()
    return not (rf and rf.glowSupported == false)
end

local function displayItems()
    local ok = glowSupported()
    local na = ok and "" or " (not available)"
    return { { text = "Glow + icons" .. na, value = "glowIcons" }, { text = "Icons", value = "icons" },
        { text = "Bar glow" .. na, value = "glow" } }
end

local function playerClass()
    local class = ns.PlayerClass and ns.PlayerClass()
    if ns.issecret(class) or type(class) ~= "string" then return nil end
    return class
end

local function playerDispels()
    local class = playerClass()
    local data = class and ns.Classes.DATA[class]
    return data and data.dispels or {}
end

-- "Now: Raid layout (in a raid of 12)" plus "switches after combat" when a switch is queued.
local function statusText()
    local rf = RF()
    local active = rf and rf.active or "party"
    local text = "Now: " .. (active == "raid" and "Raid layout" or "Party layout")
    if rf and rf.reason then text = text .. " (" .. rf.reason .. ")" end
    if rf and rf.switchQueued then
        text = text .. " - switches to " .. (rf.wanted == "raid" and "raid" or "party") .. " after combat"
    end
    return text
end

-- Segmented buttons (Columns | Rows, 8 | 4x2 | 2x4, 10 | 20 | 25 | 40): the selected one is highlighted and underlined.
local function segment(parent, items, width, get, set)
    local f = ns.NewFrame("Frame", nil, parent)
    f:SetSize(#items * (width + 4) - 4, 22)
    f.buttons = {}
    for i, item in ipairs(items) do
        local b = UI.Button(f, item.text, width, function()
            set(item.value)
            f:Refresh()
        end)
        b:SetPoint("TOPLEFT", (i - 1) * (width + 4), 0)
        b.value = item.value
        b.mark = b:CreateTexture(nil, "OVERLAY")
        b.mark:SetTexture(WHITE)
        b.mark:SetVertexColor(1, 0.82, 0, 1)
        b.mark:SetHeight(2)
        b.mark:SetPoint("BOTTOMLEFT", 5, 3)
        b.mark:SetPoint("BOTTOMRIGHT", -5, 3)
        f.buttons[i] = b
    end
    function f:Refresh()
        local current = get()
        for _, b in ipairs(self.buttons) do
            local on = b.value == current
            b.selected = on
            b.mark:SetShown(on)
            if on then b:LockHighlight() else b:UnlockHighlight() end
        end
    end
    f:Refresh()
    return f
end

-- Legend swatch: 10x10, a fill and/or a 1 px border.
local function swatch(parent)
    local f = ns.NewFrame("Frame", nil, parent)
    f:SetSize(10, 10)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetPoint("TOPLEFT", 1, -1)
    f.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    f.fill:SetTexture(WHITE)
    f.edges = {}
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetTexture(WHITE)
        t:SetPoint(pts[1])
        t:SetPoint(pts[2])
        if pts[3] then t:SetHeight(1) else t:SetWidth(1) end
        f.edges[i] = t
    end
    -- fill = {r,g,b} or nil (hollow); border = {r,g,b} or nil
    function f:Paint(fill, border)
        if fill then
            self.fill:SetVertexColor(fill[1], fill[2], fill[3], 1)
            self.fill:Show()
        else
            self.fill:Hide()
        end
        for _, t in ipairs(self.edges) do
            if border then
                t:SetVertexColor(border[1], border[2], border[3], 1)
                t:Show()
            else
                t:Hide()
            end
        end
    end
    return f
end

Options:RegisterPane("raid", "Raid Layout", 5.5, function(pane)
    local widgets = {}
    local function track(w) widgets[#widgets + 1] = w; return w end
    local scroll = ns.NewFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -24, 0)
    local root = ns.NewFrame("Frame", nil, scroll)
    root:SetSize(ROOT_W, 1400)
    scroll:SetScrollChild(root)
    pane.root = root
    UI.Header(root, "Raid Layout", "Raid-only settings, saved separately. The party layout is untouched.")
    local y = -44

    local function header(text)
        local h = UI.Label(root, text, "GameFontNormal")
        h:SetPoint("TOPLEFT", 0, y - 6)
        y = y - 28
        return h
    end
    local function note(text, height, color)
        local fs = UI.Label(root, text, "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", 0, y)
        fs:SetWidth(ROOT_W)
        fs:SetWordWrap(true)
        if color then fs:SetTextColor(color[1], color[2], color[3]) end
        y = y - (height or 16)
        return fs
    end
    local function place(label, widget, x)
        local l = UI.Label(root, label)
        l:SetPoint("TOPLEFT", x or 0, y)
        widget:SetPoint("TOPLEFT", (x or 0) + CTRL_X, y + 4)
        track(widget)
        y = y - 28
        widget.rowLabel = l
        return widget
    end
    local function dropdown(label, items, get, set, width)
        return place(label, UI.Dropdown(root, width or 200, type(items) == "function" and items or function() return items end,
            get, set))
    end
    local function check(label, get, set)
        local c = UI.Checkbox(root, label, get, set)
        c:SetPoint("TOPLEFT", 0, y)
        track(c)
        y = y - 24
        return c
    end
    local function slider(label, lo, hi, step, get, set)
        local s = UI.Slider(root, label, lo, hi, step, get, set, 200)
        s:SetPoint("TOPLEFT", 0, y)
        track(s)
        y = y - 28
        return s
    end
    local function get(key) return function() return R()[key] end end
    local function set(key) return function(v) R()[key] = v; ns:Changed("raid") end end
    local function getSub(sub, key) return function() return R()[sub][key] end end
    local function setSub(sub, key) return function(v) R()[sub][key] = v; ns:Changed("raid") end end

    -- Layout switching --------------------------------------------------------------------------------------------
    header("Layout switching")
    dropdown("Layout", LAYOUT_MODES, get("layoutMode"), set("layoutMode"))
    local above5 = check("Raid layout only above 5 players", get("onlyAbove5"), set("onlyAbove5"))
    local status = UI.Label(root, "", "GameFontNormalSmall")
    status:SetPoint("TOPLEFT", 0, y - 2)
    status:SetWidth(ROOT_W)
    status:SetWordWrap(true)
    y = y - 30
    pane.status = status

    -- Preview -----------------------------------------------------------------------------------------------------
    header("Preview")
    local pvButton = UI.Button(root, "Preview full raid: OFF", 220, function()
        local rp = RP()
        if not rp then return end
        if rp.on then rp:SetOn(false) else rp:SetOn(true) end
        pane:Refresh()
    end)
    pvButton:SetHeight(26)
    pvButton:SetPoint("TOPLEFT", 0, y)
    pane.previewButton = pvButton
    local sizeLabel = UI.Label(root, "Players")
    sizeLabel:SetPoint("LEFT", pvButton, "RIGHT", 14, 0)
    local sizes = {}
    for _, n in ipairs({ 10, 20, 25, 40 }) do sizes[#sizes + 1] = { text = tostring(n), value = n } end
    local sizeSeg = segment(root, sizes, 34, function() return RP() and RP().size or 40 end,
        function(v) if RP() then RP():SetSize(v) end end)
    sizeSeg:SetPoint("LEFT", sizeLabel, "RIGHT", 8, 0)
    track(sizeSeg)
    pane.sizeSegment = sizeSeg
    y = y - 32
    local pvMsg = note("", 16, ORANGE)
    pane.previewMessage = pvMsg
    note("A fake raid at your raid position. Not clickable. Turns off in combat or when you join a raid; always off after /reload.", 28)

    -- Groups ------------------------------------------------------------------------------------------------------
    header("Groups")
    -- the box is drawn with the root's own BACKGROUND / BORDER textures, so it always sits under the labels and controls
    local box = root:CreateTexture(nil, "BACKGROUND")
    box:SetTexture(WHITE)
    box:SetVertexColor(1, 0.82, 0, 0.06)
    box:SetPoint("TOPLEFT", -4, y + 4)
    box:SetWidth(ROOT_W)
    pane.groupBoxEdges = {}
    for i, pts in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
        local t = root:CreateTexture(nil, "BORDER")
        t:SetTexture(WHITE)
        t:SetVertexColor(1, 0.82, 0, 0.45)
        t:SetPoint(pts[1], box, pts[1])
        t:SetPoint(pts[2], box, pts[2])
        if pts[3] then t:SetHeight(1) else t:SetWidth(1) end
        pane.groupBoxEdges[i] = t
    end
    pane.groupBox = box
    local boxTop = y
    local arrange = segment(root, ARRANGE, 80, get("groupArrange"), set("groupArrange"))
    place("Groups", arrange)
    local perLine = segment(root, PER_LINE, 60, get("groupsPerLine"), set("groupsPerLine"))
    place("Groups per line", perLine)
    check("Group labels (G1-G8)", get("groupLabels"), set("groupLabels"))
    dropdown("Sort within group", SORTS, get("sortWithin"), set("sortWithin"), 160)
    check("Hide empty groups", get("hideEmptyGroups"), set("hideEmptyGroups"))
    local groupNote = note("", 18)
    pane.groupNote = groupNote
    box:SetHeight(boxTop - y + 8)
    y = y - 8

    -- What each corner means ------------------------------------------------------------------------------------------
    header("What each corner means")
    local legendTop = y
    -- a real raid bar (RaidStyle, the preview's worst-case player) zoomed in; plain frame, no mouse
    local holder = ns.NewFrame("Frame", nil, root)
    holder:SetSize(210, 90)
    holder:SetPoint("TOPLEFT", 0, y - 4)
    local sample = ns.NewFrame("Frame", nil, holder)
    sample:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    sample:EnableMouse(false)
    ns.RaidStyle.Build(sample)
    pane.sample = sample
    local legend = {}
    local LX, ROW = 222, 15
    local function legendRow(i)
        local sw = swatch(root)
        sw:SetPoint("TOPLEFT", LX, y - (i - 1) * ROW - 2)
        local fs = UI.Label(root, "", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", LX + 16, y - (i - 1) * ROW - 1)
        fs:SetWidth(ROOT_W - LX - 16)
        fs:SetWordWrap(false)
        legend[i] = { swatch = sw, text = fs }
    end
    for i = 1, 11 do legendRow(i) end
    pane.legend = legend
    y = legendTop - math.max(96, 11 * ROW + 6)

    -- Size ----------------------------------------------------------------------------------------------------------
    header("Size")
    slider("Scale (%)", 50, 150, 5, get("scale"), set("scale"))
    slider("Bar width", 40, 120, 1, get("width"), set("width"))
    slider("Bar height", 14, 40, 1, get("height"), set("height"))
    slider("Spacing", 0, 8, 1, get("spacing"), set("spacing"))

    -- Bar -----------------------------------------------------------------------------------------------------------
    header("Bar")
    check("Show names", get("showNames"), set("showNames"))
    slider("Name size", 6, 10, 1, get("nameSize"), set("nameSize"))
    slider("Name length", 3, 12, 1, get("nameLength"), set("nameLength"))
    dropdown("Health text", HEALTH_TEXTS, get("healthText"), set("healthText"))
    check("Mute full-health bars", get("muteFull"), set("muteFull"))
    check("Show incoming heals", get("showIncoming"), set("showIncoming"))

    -- My buffs ------------------------------------------------------------------------------------------------------
    header("My buffs")
    check("Show my buff markers (top-right)", getSub("buffs", "show"), setSub("buffs", "show"))
    slider("Marker size", 8, 16, 1, getSub("buffs", "size"), setSub("buffs", "size"))
    slider("Rebuff under (%)", 1, 20, 1, getSub("buffs", "rebuffPercent"), setSub("buffs", "rebuffPercent"))
    check("Show \"ending\" marker", getSub("buffs", "showEnding"), setSub("buffs", "showEnding"))
    dropdown("Ending look", ENDING_LOOKS, getSub("buffs", "endingLook"), setSub("buffs", "endingLook"))
    dropdown("Several buffs", MULTI, getSub("buffs", "multi"), setSub("buffs", "multi"))
    dropdown("In combat", IN_COMBAT, getSub("buffs", "inCombat"), setSub("buffs", "inCombat"))

    -- Debuffs -------------------------------------------------------------------------------------------------------
    header("Debuffs")
    check("Show debuffs you can dispel", getSub("debuffs", "show"), setSub("debuffs", "show"))
    local display = dropdown("Display", displayItems, getSub("debuffs", "display"), function(v)
        if v ~= "icons" and not glowSupported() then
            pane:Refresh()
            return
        end
        R().debuffs.display = v
        ns:Changed("raid")
    end)
    pane.displayDropdown = display
    local glowNote = note("", 16)
    pane.glowNote = glowNote
    slider("Max debuff icons", 1, 3, 1, getSub("debuffs", "max"), setSub("debuffs", "max"))
    slider("Debuff icon size", 8, 16, 1, getSub("debuffs", "size"), setSub("debuffs", "size"))
    local shrinkNote = note("", 18)
    pane.shrinkNote = shrinkNote

    -- Range ---------------------------------------------------------------------------------------------------------
    header("Range")
    slider("Out of range alpha", 10, 100, 5, get("rangeAlpha"), set("rangeAlpha"))

    y = y - 8
    local reset = UI.Button(root, "Reset raid defaults", 160, function()
        local r = R()
        local keep = ns.Util.DeepCopy(r.point)
        local fresh = ns.Util.DeepCopy(ns.DEFAULTS.raid)
        for k in pairs(r) do r[k] = nil end
        for k, v in pairs(fresh) do r[k] = v end
        r.point = keep
        ns.RaidLayout.Normalize(r, ns.DEFAULTS.raid)
        ns:Changed("raid")
        pane:Refresh()
    end)
    reset:SetPoint("TOPLEFT", 0, y)
    pane.resetButton = reset
    local resetNote = UI.Label(root, "Keeps the raid position.", "GameFontDisableSmall")
    resetNote:SetPoint("LEFT", reset, "RIGHT", 10, 0)
    y = y - 30

    root:SetHeight(-y + 20)
    pane.contentHeight = -y + 20

    local function paintLegend()
        local c = R()
        local C = ns.RaidStyle.COLORS
        local dispels = playerDispels()
        local first = dispels[1] and ns.Classes.DISPEL_COLORS[dispels[1]]
        local dcol = first and { first.r, first.g, first.b } or { 0.4, 0.4, 0.4 }
        local cls = ns.Classes.GetColor(playerClass() or "PALADIN")
        local mr, mg, mb = ns.RaidStyle.Muted(cls.r, cls.g, cls.b)
        local look = ({ pulse = "pulse", sweep = "clock sweep", border = "border" })[c.buffs.endingLook] or "pulse"
        local mode = ns.RaidStyle.DebuffMode(c)
        local rows = {
            { { 0.78, 0.78, 0.78 }, nil, "Top-left: name (cut first)" },
            { C.deficit, nil, "Centre: missing HP, DEAD, OFFLINE, ?" },
            { nil, C.buffMissing, "Top-right: my buff missing (gold)" },
            { nil, C.buffEnding, "Orange + " .. look .. ": ending, under " .. c.buffs.rebuffPercent .. "%" },
            { { dcol[1] * 0.45, dcol[2] * 0.45, dcol[3] * 0.45 }, dcol,
                #dispels > 0 and ("Bottom-right: debuffs you dispel, max " .. c.debuffs.max)
                    or "Bottom-right: none (your class can't dispel)" },
            { nil, dcol, mode == "icons" and "Bar edge glow: off (icons only)" or "Bar edge glow: first dispellable type" },
            { nil, C.target, "White outline: your target" },
            { nil, C.aggro, "Red outline: aggro" },
            { nil, { C.outOfRange.r, C.outOfRange.g, C.outOfRange.b }, "Dashed outline: out of range (dimmed)" },
            { nil, { C.notVisible.r, C.notVisible.g, C.notVisible.b }, "Dotted outline: not visible (?)" },
            { { mr, mg, mb }, nil, "Muted colour: full health" },
        }
        for i, row in ipairs(rows) do
            legend[i].swatch:Paint(row[1], row[2])
            legend[i].text:SetText(row[3])
        end
    end

    local function paintSample()
        local c = R()
        local rp = RP()
        if not rp or not rp.FakeData then return end
        local data = rp.FakeData(9, c)
        data.name, data.target = "Sample", true
        local s = math.min(2.5, 200 / c.width, 84 / c.height)
        sample:SetScale(s)
        ns.RaidStyle.Apply(sample, c)
        ns.RaidStyle.Render(sample, data, c)
    end

    function pane:Refresh()
        for _, w in ipairs(widgets) do
            if w.Refresh then w:Refresh() end
        end
        local c = R()
        local auto = c.layoutMode == "auto"
        if above5.SetEnabled then above5:SetEnabled(auto) end
        if above5.label then
            local col = auto and 1 or 0.5
            above5.label:SetTextColor(col, col, col)
        end
        status:SetText(statusText())
        local rp = RP()
        local on = rp and rp.on
        pvButton:SetText("Preview full raid: " .. (on and "ON" or "OFF"))
        pvMsg:SetText(rp and rp.message or "")
        groupNote:SetText((c.groupArrange == "rows" and "Each group is a row of 5; " or "Each group is a column of 5; ")
            .. (PER_LINE_TEXT[c.groupsPerLine] or "") .. ". Changes in combat apply after combat.")
        if glowSupported() then
            glowNote:SetText("The bar glow needs checking in game; if it fails, icons are shown instead.")
            glowNote:SetTextColor(0.5, 0.5, 0.5)
        else
            glowNote:SetText("Bar glow isn't available on this client: icons are shown (see /hf debug raid).")
            glowNote:SetTextColor(ORANGE[1], ORANGE[2], ORANGE[3])
        end
        local d = c.debuffs
        local isz = ns.RaidLayout.DebuffIconSize(c.width, d.max, math.min(d.size, c.height - 2))
        if isz < d.size then
            shrinkNote:SetText(d.max .. " icons on a " .. c.width .. " px bar shrink to " .. isz
                .. " px (debuffs never take more than 45% of the bar).")
        else
            shrinkNote:SetText(d.max .. (d.max > 1 and " icons fit" or " icon fits") .. " at " .. d.size .. " px.")
        end
        paintLegend()
        paintSample()
    end
end)

-- Status, preview state and glow support can change without a settings change.
local function refresh()
    if ns.Options and ns.Options.Refresh then ns.Options:Refresh() end
end
ns:On("RAID_LAYOUT_CHANGED", refresh)
ns:On("RAID_PREVIEW_CHANGED", refresh)
ns:RegisterEvent("GROUP_ROSTER_UPDATE", refresh)
ns:RegisterEvent("PLAYER_REGEN_DISABLED", refresh)
ns:On("COMBAT_ENDED", refresh)
