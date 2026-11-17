local ADDON_NAME, ns = ...

ns.Util = ns.Util or {}
local Util = ns.Util

local floor, ceil = math.floor, math.ceil

function Util.FormatAuraTime(seconds)
    if not seconds or seconds <= 0 then
        return ""
    end
    if seconds >= 3600 then
        return floor(seconds / 3600) .. "h"
    elseif seconds >= 60 then
        return ceil(seconds / 60) .. "m"
    elseif seconds >= 10 then
        return tostring(floor(seconds))
    end
    return string.format("%.1f", seconds)
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = deepCopy(v)
    end
    return copy
end
Util.DeepCopy = deepCopy

local function mergeDefaults(saved, defaults)
    if saved == nil then
        return deepCopy(defaults)
    end
    if type(saved) ~= "table" or type(defaults) ~= "table" then
        return saved
    end
    for k, v in pairs(defaults) do
        local current = saved[k]
        if current == nil then
            saved[k] = deepCopy(v)
        elseif type(current) == "table" and type(v) == "table" then
            mergeDefaults(current, v)
        end
    end
    return saved
end
Util.MergeDefaults = mergeDefaults

function Util.ModifierKey(shift, ctrl, alt, meta)
    local parts = {}
    if alt then parts[#parts + 1] = "alt" end
    if ctrl then parts[#parts + 1] = "ctrl" end
    if meta then parts[#parts + 1] = "meta" end
    if shift then parts[#parts + 1] = "shift" end
    return table.concat(parts, "-")
end

function Util.Trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Frame appearance helpers (pure) ----------------------------------------------------------------------------

Util.BORDER_STYLES = { "none", "thin", "tooltip", "gold" }
Util.BORDER_COLORS = { "class", "black", "gold", "custom" }
Util.POSITIONS = { "top", "bottom", "left", "right", "inside" }
Util.GROWS = { "right", "left", "down", "up" }

local function oneOf(list, value, fallback)
    for _, v in ipairs(list) do
        if v == value then return value end
    end
    return fallback
end

local function clampNumber(v, lo, hi, fallback)
    if type(v) ~= "number" or v ~= v then return fallback end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
Util.ClampNumber = clampNumber

-- Validated copy of frames.border: { style, width (1-4), color, custom = {r,g,b} }
function Util.NormalizeBorder(b)
    b = type(b) == "table" and b or {}
    local c = type(b.custom) == "table" and b.custom or {}
    return {
        style = oneOf(Util.BORDER_STYLES, b.style, "tooltip"),
        width = clampNumber(b.width, 1, 4, 2),
        color = oneOf(Util.BORDER_COLORS, b.color, "black"),
        custom = { r = clampNumber(c.r, 0, 1, 1), g = clampNumber(c.g, 0, 1, 0.82), b = clampNumber(c.b, 0, 1, 0) },
    }
end

-- Border style -> backdrop edge. "thin" is always 1px; thickness 1-4 scales the textured edges.
function Util.BorderSpec(style, thickness)
    local w = clampNumber(thickness, 1, 4, 2)
    if style == "none" then
        return { edgeFile = nil, edgeSize = 0, outset = 0 }
    elseif style == "thin" then
        return { edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1, outset = 0 }
    end
    local file = style == "gold" and "Interface\\DialogFrame\\UI-DialogBox-Gold-Border"
        or "Interface\\Tooltips\\UI-Tooltip-Border"
    local size = math.max(4, w * 4)
    return { edgeFile = file, edgeSize = size, outset = math.floor(size / 4) }
end

local STEEL = { r = 0.54, g = 0.54, b = 0.63 }

-- Border colour; "black" keeps the textured borders steel grey (as in the mockup). classColor = {r,g,b}.
function Util.BarBorderColor(border, classColor)
    border = border or {}
    if border.color == "class" then return classColor or { r = 1, g = 1, b = 1 } end
    if border.color == "gold" then return { r = 1, g = 0.82, b = 0 } end
    if border.color == "custom" and type(border.custom) == "table" then return border.custom end
    if border.style == "tooltip" or border.style == "gold" then return STEEL end
    return { r = 0, g = 0, b = 0 }
end

Util.TIMER_HEIGHT = 11   -- room for the timer text under an icon
Util.ICON_GAP = 3        -- space between neighbouring icons

-- Icons per row that fit a bar of `barWidth` (zone width = icons * (size + gap) + 4).
function Util.AutoPerRow(barWidth, size, gap)
    return math.max(1, math.floor(((barWidth or 180) - 4) / ((size or 16) + (gap or 2))))
end

-- Aura zone size in pixels for `count` icons of size `sz`, `perRow` per row, given the grow direction.
-- timerH = extra height reserved under every icon for its timer text; gap = space between icons.
function Util.ZoneSize(sz, perRow, count, grow, extra, timerH, gap)
    sz = sz or 16
    perRow = math.max(1, perRow or 1)
    count = math.max(1, count or 1)
    timerH, gap = timerH or 0, gap or 2
    local step = sz + gap
    local lineStep = sz + gap + timerH
    local lines = math.ceil(count / perRow)
    local along = math.min(count, perRow)
    if grow == "down" or grow == "up" then
        return lines * step + 4, along * lineStep + 4 + (extra or 0)
    end
    return along * step + 4, lines * lineStep + 4 + (extra or 0)
end

-- Corner and offset of icon i (1-based) inside its zone for the grow direction.
function Util.IconOffset(i, sz, perRow, grow, timerH, gap)
    timerH, gap = timerH or 0, gap or 2
    local step = sz + gap
    local lineStep = sz + gap + timerH
    local along = (i - 1) % perRow
    local line = math.floor((i - 1) / perRow)
    if grow == "left" then return "TOPRIGHT", -2 - along * step, -2 - line * lineStep end
    if grow == "down" then return "TOPLEFT", 2 + line * step, -2 - along * lineStep end
    if grow == "up" then return "BOTTOMLEFT", 2 + line * step, 2 + timerH + along * lineStep end
    return "TOPLEFT", 2 + along * step, -2 - line * lineStep
end

-- Reserved aura zones around a frame: zones = array of { pos, w, h }. Zones on one side stack vertically.
function Util.CellLayout(frameW, frameH, zones, gap)
    gap = gap or 2
    frameW, frameH = frameW or 0, frameH or 0
    local side = { top = 0, bottom = 0, left = 0, right = 0 }
    local stackH = { left = 0, right = 0 }
    local needW, needSide = 0, 0
    for _, zone in ipairs(zones or {}) do
        local z = type(zone) == "table" and { pos = zone.pos, w = zone.w or 0, h = zone.h or 0 } or {}
        if side[z.pos] ~= nil then
            if z.pos == "top" or z.pos == "bottom" then
                side[z.pos] = side[z.pos] + z.h + gap
                if z.w > needW then needW = z.w end
            else
                side[z.pos] = math.max(side[z.pos], z.w + gap)
                stackH[z.pos] = stackH[z.pos] + z.h + gap
                if stackH[z.pos] > needSide then needSide = stackH[z.pos] end
            end
        end
    end
    -- left/right zones are anchored at the frame top, which sits `top` below the cell top
    local width = math.max(side.left + frameW + side.right, needW)
    local height = side.top + math.max(frameH + side.bottom, needSide)
    return { left = side.left, right = side.right, top = side.top, bottom = side.bottom, width = width, height = height }
end

-- Sparse saving (pure) ----------------------------------------------------------------------------------------

function Util.DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not Util.DeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function isArray(t)
    return type(t) == "table" and t[1] ~= nil
end

-- Returns only the parts of `value` that differ from `defaults` (nil when identical). Arrays and the table
-- keys listed in `atomic` (a set of key names) are compared and saved as whole values.
function Util.DiffFromDefaults(value, defaults, atomic)
    atomic = atomic or {}
    local function diff(v, d, key)
        if type(v) ~= "table" or type(d) ~= "table" or atomic[key] or isArray(v) or isArray(d) then
            if Util.DeepEqual(v, d) then return nil end
            return Util.DeepCopy(v)
        end
        local out
        for k, val in pairs(v) do
            local r = diff(val, d[k], k)
            if r ~= nil then
                out = out or {}
                out[k] = r
            end
        end
        return out
    end
    return diff(value, defaults, nil) or {}
end

-- Validated copy of frames.range (out-of-range / not-visible presentation).
function Util.NormalizeRange(r)
    r = type(r) == "table" and r or {}
    local function color(c, fallback)
        c = type(c) == "table" and c or {}
        return { r = clampNumber(c.r, 0, 1, fallback.r), g = clampNumber(c.g, 0, 1, fallback.g),
            b = clampNumber(c.b, 0, 1, fallback.b) }
    end
    return {
        style = r.style == "dim" and "dim" or "badge",
        dim = clampNumber(r.dim, 10, 100, 72),
        badge = r.badge ~= false,
        healable = r.healable ~= false,
        healableColor = color(r.healableColor, { r = 0.3, g = 0.9, b = 0.4 }),
        outColor = color(r.outColor, { r = 0.6, g = 0.6, b = 0.6 }),
        hiddenColor = color(r.hiddenColor, { r = 0.5, g = 0.6, b = 0.75 }),
    }
end
