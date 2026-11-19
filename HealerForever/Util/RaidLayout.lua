local ADDON_NAME, ns = ...

-- Raid layout: pure helpers (no WoW calls), loaded right after Util/Util.lua so Core.lua can validate ns.db.raid.
--   Normalize(r, defaults)       validates the saved raid settings in place (bad values fall back to the default)
--   DesiredLayout(ctx)           "party" | "raid" plus a readable reason
--   GroupOrder(counts, cfg)      the order the 8 groups are drawn in, and how many are visible
--   GridCells(cfg, order, vis)   pixel position of every cell (8 groups x 5 slots) and the anchor size
--   AssignCells(roster, cfg)     a bijection of the 40 raid buttons onto the 40 cells
--   TextLayout(cfg, reserve, o)  where the centre number and the name go (the number is never cut)
--   DebuffIconSize(w, max, base) icon size that fits max debuff icons in 45% of the bar width
--   Reserves(cfg, buffCount, mode) right-hand space for the buff markers (top-right) and debuff icons (bottom-right)
--   BuffItemState(item)          "miss" | "end" | nil (present) for one BuffReport item
--   BuffMarkers(report, multi, showEnding)  which of my buffs get a top-right icon (max 2 / 1 / 3 by mode)
--   NextBuffCheck(report, percent, now)     when the next marker state change is due (nil = none)
local RaidLayout = {}
ns.RaidLayout = RaidLayout

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

RaidLayout.NUM_BUTTONS = 40
RaidLayout.NUM_GROUPS = 8
RaidLayout.GROUP_SIZE = 5
RaidLayout.LABEL_H = 12   -- "G1" label above a group column
RaidLayout.LABEL_W = 20   -- "G1" label left of a group row
RaidLayout.GROUP_GAP = 6  -- extra gap between groups (added to spacing)

RaidLayout.ENUMS = {
    layoutMode = { "auto", "party", "raid" },
    groupArrange = { "columns", "rows" },
    sortWithin = { "none", "role", "class" },
    healthText = { "deficit", "percent", "none" },
    endingLook = { "pulse", "sweep", "border" },
    multi = { "state", "first", "stack" },
    inCombat = { "hide", "dim" },
    display = { "glowIcons", "icons", "glow" },
}
RaidLayout.GROUPS_PER_LINE = { 8, 4, 2 }

-- Settings validation ------------------------------------------------------------------------------------------

local function oneOf(list, value, fallback)
    for _, v in ipairs(list) do
        if v == value then return value end
    end
    return fallback
end

-- Number in [lo, hi], rounded to a multiple of step (default 1); anything else is the fallback.
local function num(v, lo, hi, fallback, step)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return fallback end
    step = step or 1
    v = floor(v / step + 0.5) * step
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function bool(v, fallback)
    if type(v) == "boolean" then return v end
    return fallback
end

local function point(p, fallback)
    if type(p) ~= "table" or type(p.point) ~= "string" or type(p.relativePoint) ~= "string"
        or type(p.x) ~= "number" or p.x ~= p.x or type(p.y) ~= "number" or p.y ~= p.y then
        return { point = fallback.point, relativePoint = fallback.relativePoint, x = fallback.x, y = fallback.y }
    end
    return p
end

-- Validates a (merged) raid settings table in place and returns it. Unknown keys are kept untouched (a newer version
-- may have saved them). defaults = ns.DEFAULTS.raid.
function RaidLayout.Normalize(r, defaults)
    defaults = defaults or (ns.DEFAULTS and ns.DEFAULTS.raid)
    assert(type(defaults) == "table", "RaidLayout.Normalize: no defaults")
    if type(r) ~= "table" then r = {} end
    local E, d = RaidLayout.ENUMS, defaults
    r.layoutMode = oneOf(E.layoutMode, r.layoutMode, d.layoutMode)
    r.onlyAbove5 = bool(r.onlyAbove5, d.onlyAbove5)
    r.point = point(r.point, d.point)
    r.scale = num(r.scale, 50, 150, d.scale, 5)
    r.width = num(r.width, 40, 120, d.width)
    r.height = num(r.height, 14, 40, d.height)
    r.spacing = num(r.spacing, 0, 8, d.spacing)
    r.groupArrange = oneOf(E.groupArrange, r.groupArrange, d.groupArrange)
    r.groupsPerLine = oneOf(RaidLayout.GROUPS_PER_LINE, r.groupsPerLine, d.groupsPerLine)
    r.groupLabels = bool(r.groupLabels, d.groupLabels)
    r.sortWithin = oneOf(E.sortWithin, r.sortWithin, d.sortWithin)
    r.hideEmptyGroups = bool(r.hideEmptyGroups, d.hideEmptyGroups)
    r.showNames = bool(r.showNames, d.showNames)
    r.nameSize = num(r.nameSize, 6, 10, d.nameSize)
    r.nameLength = num(r.nameLength, 3, 12, d.nameLength)
    r.healthText = oneOf(E.healthText, r.healthText, d.healthText)
    r.muteFull = bool(r.muteFull, d.muteFull)
    r.showIncoming = bool(r.showIncoming, d.showIncoming)
    r.rangeAlpha = num(r.rangeAlpha, 10, 100, d.rangeAlpha, 5)

    local b, db = type(r.buffs) == "table" and r.buffs or {}, d.buffs
    b.show = bool(b.show, db.show)
    b.size = num(b.size, 8, 16, db.size)
    b.rebuffPercent = num(b.rebuffPercent, 1, 20, db.rebuffPercent)
    b.showEnding = bool(b.showEnding, db.showEnding)
    b.endingLook = oneOf(E.endingLook, b.endingLook, db.endingLook)
    b.multi = oneOf(E.multi, b.multi, db.multi)
    b.inCombat = oneOf(E.inCombat, b.inCombat, db.inCombat)
    r.buffs = b

    local x, dx = type(r.debuffs) == "table" and r.debuffs or {}, d.debuffs
    x.show = bool(x.show, dx.show)
    x.display = oneOf(E.display, x.display, dx.display)
    x.max = num(x.max, 1, 3, dx.max)
    x.size = num(x.size, 8, 16, dx.size)
    r.debuffs = x
    return r
end

-- Which layout is wanted -----------------------------------------------------------------------------------------
-- ctx = { mode, onlyAbove5, inRaid, size, instanceType, oneSubgroup }
--   mode "party" / "raid" always win. Auto: arena -> party, battleground -> raid, not in a raid -> party; in a raid the
--   party layout is kept only when "raid layout only above 5 players" is on, the raid has 5 or fewer players and all of
--   them are in one subgroup (party1..4 then cover everyone); otherwise raid.
function RaidLayout.DesiredLayout(ctx)
    ctx = ctx or {}
    local mode = ctx.mode
    if mode == "party" then return "party", "Always party (setting)" end
    if mode == "raid" then return "raid", "Always raid (setting)" end
    if ctx.instanceType == "arena" then return "party", "arena" end
    if ctx.instanceType == "pvp" then return "raid", "battleground" end
    if not ctx.inRaid then return "party", "not in a raid" end
    local size = type(ctx.size) == "number" and ctx.size or RaidLayout.NUM_BUTTONS
    if ctx.onlyAbove5 and size <= 5 and ctx.oneSubgroup then
        return "party", "raid of " .. size .. " in one group (raid layout only above 5 players)"
    end
    return "raid", "in a raid of " .. size
end

-- Grid -------------------------------------------------------------------------------------------------------------

-- counts[g] = members in group g. Returns the 8 group numbers in drawing order and how many of them are visible.
-- "Hide empty groups": non-empty groups first (ascending), empty groups last and not counted as visible.
function RaidLayout.GroupOrder(counts, cfg)
    counts = counts or {}
    local order = {}
    if cfg and cfg.hideEmptyGroups then
        local empty = {}
        for g = 1, RaidLayout.NUM_GROUPS do
            if (counts[g] or 0) > 0 then order[#order + 1] = g else empty[#empty + 1] = g end
        end
        local visible = #order
        for _, g in ipairs(empty) do order[#order + 1] = g end
        return order, max(1, visible)
    end
    for g = 1, RaidLayout.NUM_GROUPS do order[g] = g end
    return order, RaidLayout.NUM_GROUPS
end

-- Pixel layout (unscaled, origin TOPLEFT, y grows downwards) for every group in `order`. The first `visible` groups
-- size the anchor; the others continue the same grid (their cells stay unique so a late joiner never covers a bar).
-- Returns { cells = { [g] = { [slot] = { x, y, group, slot } } }, labels = { [g] = { x, y, shown } }, width, height,
--           blockW, blockH, perLine }.
function RaidLayout.GridCells(cfg, order, visible)
    order = order or { 1, 2, 3, 4, 5, 6, 7, 8 }
    visible = max(1, min(visible or #order, #order))
    local W, H, sp = cfg.width, cfg.height, cfg.spacing
    local gap = sp + RaidLayout.GROUP_GAP
    local columns = cfg.groupArrange ~= "rows"
    local labels = cfg.groupLabels and true or false
    local per = max(1, min(cfg.groupsPerLine or 8, visible))
    local n = RaidLayout.GROUP_SIZE
    local labelH = (columns and labels) and RaidLayout.LABEL_H or 0
    local labelW = (not columns and labels) and RaidLayout.LABEL_W or 0
    local blockW, blockH
    if columns then
        blockW, blockH = W, labelH + n * H + (n - 1) * sp
    else
        blockW, blockH = labelW + n * W + (n - 1) * sp, H
    end
    local out = { cells = {}, labels = {}, blockW = blockW, blockH = blockH, perLine = per }
    local width, height = 0, 0
    for k, g in ipairs(order) do
        local i = k - 1
        local col, row
        if columns then col, row = i % per, floor(i / per) else row, col = i % per, floor(i / per) end
        local bx, by = col * (blockW + gap), row * (blockH + gap)
        local cells = {}
        for s = 1, n do
            if columns then
                cells[s] = { x = bx, y = by + labelH + (s - 1) * (H + sp), group = g, slot = s }
            else
                cells[s] = { x = bx + labelW + (s - 1) * (W + sp), y = by, group = g, slot = s }
            end
        end
        out.cells[g] = cells
        out.labels[g] = { x = bx, y = by, shown = labels and k <= visible }
        if k <= visible then
            width = max(width, bx + blockW)
            height = max(height, by + blockH)
        end
    end
    out.width, out.height = width, height
    return out
end

local ROLE_RANK = { TANK = 1, HEALER = 2, DAMAGER = 3 }

-- Sort key for "sort within groups": unknown values last, ties by raid index.
local function sortKey(entry, mode)
    if mode == "role" then return ROLE_RANK[entry.role] or 4 end
    if mode == "class" then return type(entry.class) == "string" and entry.class or "~" end
    return 0
end

-- roster = list of { index = 1..40 (button), group = 1..8, role = ?, class = ? } for the members that exist.
-- Every button 1..40 gets exactly one cell (bijection): members fill their group's cells in sort order; a group with
-- more than 5 entries (bad roster data) overflows into the free cells; the unused buttons take the remaining free
-- cells in order. Returns { byButton = { [i] = cell }, order, visible, grid, counts }.
function RaidLayout.AssignCells(roster, cfg)
    local N, G, n = RaidLayout.NUM_BUTTONS, RaidLayout.NUM_GROUPS, RaidLayout.GROUP_SIZE
    local groups, seen, overflow = {}, {}, {}
    for g = 1, G do groups[g] = {} end
    for _, e in ipairs(roster or {}) do
        local i = type(e) == "table" and e.index
        if type(i) == "number" and i >= 1 and i <= N and i == floor(i) and not seen[i] then
            seen[i] = true
            local g = e.group
            if type(g) ~= "number" or g < 1 or g > G or g ~= floor(g) then g = ceil(i / n) end
            local list = groups[g]
            list[#list + 1] = { index = i, group = g, key = sortKey(e, cfg.sortWithin) }
        end
    end
    local counts = {}
    for g = 1, G do
        local list = groups[g]
        table.sort(list, function(a, b)
            if a.key ~= b.key then return a.key < b.key end
            return a.index < b.index
        end)
        while #list > n do overflow[#overflow + 1] = table.remove(list) end
        counts[g] = #list
    end
    local order, visible = RaidLayout.GroupOrder(counts, cfg)
    local grid = RaidLayout.GridCells(cfg, order, visible)
    local byButton, used = {}, {}
    for g = 1, G do
        for s, e in ipairs(groups[g]) do
            local cell = grid.cells[g][s]
            byButton[e.index] = cell
            used[cell] = true
        end
    end
    local free = {}
    for _, g in ipairs(order) do
        for s = 1, n do
            local cell = grid.cells[g][s]
            if not used[cell] then free[#free + 1] = cell end
        end
    end
    table.sort(overflow, function(a, b) return a.index < b.index end)
    local k = 1
    for _, e in ipairs(overflow) do byButton[e.index] = free[k]; k = k + 1 end
    for i = 1, N do
        if not byButton[i] then byButton[i] = free[k]; k = k + 1 end
    end
    return { byButton = byButton, order = order, visible = visible, grid = grid, counts = counts }
end

-- Text layout ----------------------------------------------------------------------------------------------------
-- Rule: the centre number keeps its size (never below 10 px when it is the health number, never cut); the name is
-- cut first and dropped below 6 px. rightReserve = pixels on the right taken by icons (debuffs).
-- opts = { len = characters of the centre text (default 5, e.g. "-12.3k"), big = health number (default true),
--          buffW = width of the top-right buff markers }.
-- Returns { tfs, top, numLeft, numW, nameW, stacked }.
function RaidLayout.TextLayout(cfg, rightReserve, opts)
    opts = opts or {}
    local w, h = cfg.width, cfg.height
    local names = cfg.showNames and true or false
    local nameH = names and (cfg.nameSize + 2) or 0
    local len = opts.len or 5
    local big = opts.big ~= false
    local buffW = opts.buffW or 0
    local areaR = w - (rightReserve or 0)
    -- width per character in font-size units. Numbers: "-1.8k" digits ~0.55 em, outline included. State texts are
    -- capitals ("OFFLINE", "CAN'T RES", "GHOST") at ~0.7 em, outline included: 0.75 so they are never wider than planned.
    local k = big and 0.6 or 0.75
    local tfs
    if big then
        tfs = max(9, min(18, floor(h * 0.5 + 0.5)))
        if len > 0 then
            tfs = max(min(tfs, 10), min(tfs, floor((areaR - 3) / (len * k))))
        end
    else
        -- state text shrinks to the free area (down to 6 px) instead of running past the bar's left edge
        tfs = max(7, min(11, floor(h * 0.36 + 0.5)))
        if len > 0 then tfs = max(6, min(tfs, floor((areaR - 3) / (len * k)))) end
    end
    local numW = len > 0 and ceil(len * tfs * k) or 0
    -- stacked needs a 2 px gap between the name line and the number
    local stacked = len == 0 or not names or (h - nameH - 2 >= tfs)
    local top, numLeft
    local nameW = names and (w - 4 - buffW) or 0
    if stacked then
        if len > 0 and names then
            top = floor(nameH + (h - nameH - tfs) / 2 + 0.5)
        else
            top = floor((h - tfs) / 2 + 0.5)
        end
        numLeft = floor((areaR - numW) / 2 + 0.5)
    else
        top = floor((h - tfs) / 2 + 0.5)
        numLeft = floor(areaR - 2 - numW + 0.5)
    end
    -- never left of the bar's inner edge (1 px border + 1 px pad); a text wider than the free area runs right,
    -- over the icons (last resort), but stays inside the bar when it fits the bar at all
    if numLeft + numW > w - 2 then numLeft = w - 2 - numW end
    numLeft = max(2, numLeft)
    if not stacked then
        -- the name ends 3 px left of the number and starts at the inner edge + 1 px pad (2 px)
        nameW = min(nameW, numLeft - 5)
    end
    if nameW < 6 then nameW = 0 end
    return { tfs = tfs, top = top, numLeft = numLeft, numW = numW, nameW = nameW, stacked = stacked }
end

-- Debuff icons: max icons fit in 45% of the bar width, never below 7 px, never above the chosen size.
function RaidLayout.DebuffIconSize(width, count, base)
    count = max(1, count or 1)
    return max(7, min(base, floor((floor(width * 0.45) - 1) / count) - 1))
end

-- Right-hand areas the texts must leave free (mockup raid-style-d cell()):
--   top-right    my buff markers: buffCount icons of bsz px (1 px gaps), only while markers are shown
--   bottom-right dispellable debuff icons: always reserved for debuffs.max icons while debuff icons are on (the game
--                draws them in combat, so their count is unknown to us). When markers and icons can't share the
--                bar height the icon row moves left of the markers (shift).
-- mode = the debuff display actually in use (RaidStyle.DebuffMode: "icons" after a glow failure); nil = cfg's setting.
-- Returns { buffW, bsz, debW, isz, shift, right = max(buffW, debW) }.
function RaidLayout.Reserves(cfg, buffCount, mode)
    local w, h = cfg.width, cfg.height
    local b, d = cfg.buffs or {}, cfg.debuffs or {}
    local n = (b.show ~= false and buffCount and buffCount > 0) and floor(buffCount) or 0
    local bsz = min(b.size or 10, h - 2)
    local buffW = n > 0 and (n * (bsz + 1) + 1) or 0
    local cnt = 0
    if d.show ~= false and (mode or d.display) ~= "glow" then cnt = max(0, d.max or 0) end
    local isz = RaidLayout.DebuffIconSize(w, cnt, min(d.size or 10, h - 2))
    local shift = (n > 0 and cnt > 0 and bsz + isz + 3 > h) and buffW or 0
    local debW = cnt > 0 and (shift + cnt * (isz + 1) + 1) or 0
    return { buffW = buffW, bsz = bsz, debW = debW, isz = isz, shift = shift, right = max(buffW, debW) }
end

-- My buff markers ----------------------------------------------------------------------------------------------
-- report = BuffReport items of MY buffs for one member (BuffButtons.EvaluateUnit diag.report):
--   { key, missing, auraName, remaining, pct, duration? }. "missing" covers both gone and running out (rebuff %).

-- "miss" = gone, "end" = still on but under the rebuff % (time left > 0), nil = fine.
function RaidLayout.BuffItemState(item)
    if type(item) ~= "table" or not item.missing then return nil end
    if item.auraName ~= nil and type(item.remaining) == "number" and item.remaining > 0 then return "end" end
    return "miss"
end

-- Total duration of an item's aura: the explicit field, else derived from the time left and the percentage left.
function RaidLayout.ItemDuration(item)
    if type(item) ~= "table" then return nil end
    if type(item.duration) == "number" and item.duration > 0 then return item.duration end
    local rem, pct = item.remaining, item.pct
    if type(rem) == "number" and rem > 0 and type(pct) == "number" and pct > 0 then return rem * 100 / pct end
    return nil
end

-- multi = "state" (default): first missing (count = all missing) + first ending (count = all ending), max 2
--         "first": one icon only: the first missing (with count), else the first ending
--         "stack": one icon per buff (missing first, then ending), max 3, no counts
-- showEnding false: ending buffs get no icon. Returns { { kind = "miss"|"end", key, count, item } ... }.
function RaidLayout.BuffMarkers(report, multi, showEnding)
    local miss, ending = {}, {}
    for _, item in ipairs(report or {}) do
        local s = RaidLayout.BuffItemState(item)
        if s == "miss" then
            miss[#miss + 1] = item
        elseif s == "end" and showEnding ~= false then
            ending[#ending + 1] = item
        end
    end
    local function marker(kind, item, count) return { kind = kind, key = item.key, count = count, item = item } end
    local out = {}
    if multi == "stack" then
        for _, item in ipairs(miss) do out[#out + 1] = marker("miss", item, 1) end
        for _, item in ipairs(ending) do out[#out + 1] = marker("end", item, 1) end
        while #out > 3 do table.remove(out) end
        return out
    end
    local M = #miss > 0 and marker("miss", miss[1], #miss) or nil
    local E = #ending > 0 and marker("end", ending[1], #ending) or nil
    if multi == "first" then
        out[1] = M or E
        return out
    end
    if M then out[#out + 1] = M end
    if E then out[#out + 1] = E end
    return out
end

-- The earliest moment a marker can change without any aura event: a present buff crossing into its rebuff window
-- (time left = percent % of its duration; without a known duration: when it runs out), or an ending buff running
-- out. now = GetTime(). nil when nothing is timed.
function RaidLayout.NextBuffCheck(report, percent, now)
    now = now or 0
    percent = type(percent) == "number" and percent or 0
    local best
    for _, item in ipairs(report or {}) do
        local rem = type(item) == "table" and item.remaining
        if type(rem) == "number" and rem > 0 then
            local s = RaidLayout.BuffItemState(item)
            local t
            if s == "end" then
                t = now + rem
            elseif s == nil then
                local dur = RaidLayout.ItemDuration(item)
                if dur and percent > 0 then t = now + rem - dur * percent / 100 else t = now + rem end
                if t < now then t = now end
            end
            if t and (not best or t < best) then best = t end
        end
    end
    return best
end
