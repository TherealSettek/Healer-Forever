-- Shared geometry for aura spacing tests: resolves SetPoint/SetSize chains of the mock frames into rectangles
-- (y grows downward, relative to the party anchor) and checks that timers, icons, zones, bars and tiles never overlap.
local mock = require("wow_mock")
local M = {}
local function st(f) return rawget(f, "__s") end
M.st = st

local FRAC = { TOPLEFT = { 0, 0 }, TOP = { .5, 0 }, TOPRIGHT = { 1, 0 }, LEFT = { 0, .5 }, CENTER = { .5, .5 }, RIGHT = { 1, .5 },
    BOTTOMLEFT = { 0, 1 }, BOTTOM = { .5, 1 }, BOTTOMRIGHT = { 1, 1 } }

function M.rect(f, root)
    local s = st(f)
    if f == root then return { l = 0, t = 0, r = s.w or 0, b = s.h or 0 } end
    if s.allPoints and #s.points == 0 then
        local p = type(s.allPoints) == "table" and s.allPoints or s.parent
        return M.rect(p, root)
    end
    if #s.points == 0 then return nil end
    local w, h = s.w or 0, s.h or 0
    local cl, cr, ct, cb
    for _, p in ipairs(s.points) do
        local point, rel, relPoint, x, y
        if type(p[2]) == "table" then point, rel, relPoint, x, y = p[1], p[2], p[3] or p[1], p[4] or 0, p[5] or 0
        else point, x, y = p[1], p[2] or 0, p[3] or 0; rel = s.parent; relPoint = point end
        local rr = rel and M.rect(rel, root)
        if not rr or not FRAC[point] or not FRAC[relPoint] then return nil end
        local ax = rr.l + (rr.r - rr.l) * FRAC[relPoint][1] + x
        local ay = rr.t + (rr.b - rr.t) * FRAC[relPoint][2] - y
        local gx, gy = FRAC[point][1], FRAC[point][2]
        if gx == 0 then cl = ax elseif gx == 1 then cr = ax else cl = ax - w / 2 end
        if gy == 0 then ct = ay elseif gy == 1 then cb = ay else ct = ay - h / 2 end
    end
    local l = cl or (cr - w); local r = cr or (cl + w)
    local t = ct or (cb - h); local b = cb or (ct + h)
    return { l = l, t = t, r = r, b = b }
end
function M.overlap(a, b) return a.l < b.r - 1e-6 and b.l < a.r - 1e-6 and a.t < b.b - 1e-6 and b.t < a.b - 1e-6 end
function M.inside(i, o) return i.l >= o.l - 1e-6 and i.r <= o.r + 1e-6 and i.t >= o.t - 1e-6 and i.b <= o.b + 1e-6 end
function M.fmt(r) return string.format("(%.1f,%.1f)-(%.1f,%.1f)", r.l, r.t, r.r, r.b) end

-- Aura fixtures: n helpful and n harmful auras with running timers (so every icon shows its timer text).
function M.setAuras(S, units, nBuff, nDebuff)
    for _, u in ipairs(units) do
        local list = {}
        for i = 1, nBuff do
            list[#list + 1] = { spellId = 1000 + i, name = "Buff" .. i, icon = 100 + i, duration = 300, expirationTime = S.now + 200 + i, isHelpful = true,
                isHarmful = false, auraInstanceID = 100 + i, sourceUnit = "player" }
        end
        for i = 1, nDebuff do
            list[#list + 1] = { spellId = 2000 + i, name = "Debuff" .. i, icon = 200 + i, duration = 60, expirationTime = S.now + 30 + i, isHelpful = false,
                isHarmful = true, auraInstanceID = 200 + i }
        end
        S.auras[u] = list
    end
end

-- Every rectangle of one member tile. Returns { items = {...}, bar = rect } or nil, err.
function M.tile(ns, unit, root)
    local UF = ns.UnitFrames
    local b = UF.byUnit[unit]
    local rb = M.rect(b, root)
    if not rb then return nil, unit .. " button not positioned" end
    local cfg = ns.db.auras
    local items = { { kind = "bar", rect = rb, owner = unit } }
    local problems = {}
    for kind, zone in pairs(b.zones or {}) do
        local zs = st(zone)
        if zs.shown and #zs.points > 0 then
            local pos = kind == "buff" and cfg.buffPosition or cfg.debuffPosition
            local rz = M.rect(zone, root)
            if not rz then problems[#problems + 1] = kind .. " zone not positioned"
            else
                items[#items + 1] = { kind = "zone", rect = rz, owner = unit, zoneKind = kind, pos = pos }
                local list = kind == "buff" and b.buffIcons or b.debuffIcons
                local timerH = (cfg.timerPos == "inside" or pos == "inside") and 0 or ns.Util.TIMER_HEIGHT
                for i, icon in ipairs(list or {}) do
                    if st(icon).shown then
                        local ri = M.rect(icon, root)
                        if not ri then problems[#problems + 1] = kind .. " icon " .. i .. " not positioned"
                        else
                            items[#items + 1] = { kind = "icon", rect = ri, owner = unit, zoneKind = kind, pos = pos, id = kind .. i }
                            local ts = icon.time and st(icon.time)
                            if ts and ts.shown ~= false and #ts.points > 0 then
                                local p = ts.points[1]
                                local tr
                                if timerH > 0 then
                                    -- below: TOP of the text on the BOTTOM of the icon, 1px lower; text height = reserved line - 1
                                    if not (p[1] == "TOP" and p[2] == icon and p[3] == "BOTTOM" and p[5] == -1) then
                                        problems[#problems + 1] = kind .. " icon " .. i .. ": timer is not anchored below the icon"
                                    end
                                    tr = { l = ri.l, r = ri.r, t = ri.b + 1, b = ri.b + 1 + (timerH - 1) }
                                else
                                    if not (p[1] == "BOTTOM" and p[2] == icon and p[3] == "BOTTOM") then
                                        problems[#problems + 1] = kind .. " icon " .. i .. ": inside timer is not anchored to the icon bottom"
                                    end
                                    tr = { l = ri.l, r = ri.r, t = ri.b - 1 - 8, b = ri.b - 1 }
                                end
                                items[#items + 1] = { kind = "timer", rect = tr, owner = unit, zoneKind = kind, pos = pos, id = kind .. i, below = timerH > 0 }
                            end
                        end
                    end
                end
            end
        end
    end
    return { items = items, bar = rb, problems = problems }
end

-- Checks a set of tiles; returns an array of problem strings.
function M.check(ns, units, label)
    local UF = ns.UnitFrames
    local root = UF.anchor
    local problems = {}
    local tiles = {}
    for _, u in ipairs(units) do
        local t, err = M.tile(ns, u, root)
        if not t then problems[#problems + 1] = label .. ": " .. err else
            tiles[#tiles + 1] = t
            for _, p in ipairs(t.problems) do problems[#problems + 1] = label .. " " .. u .. ": " .. p end
        end
    end
    local function name(it) return it.owner .. ":" .. it.kind .. (it.id and ("/" .. it.id) or it.zoneKind and ("/" .. it.zoneKind) or "") end
    for _, t in ipairs(tiles) do
        -- inside one tile
        local zoneOf = {}
        for _, it in ipairs(t.items) do if it.kind == "zone" then zoneOf[it.zoneKind] = it end end
        for _, it in ipairs(t.items) do
            if it.kind == "icon" or it.kind == "timer" then
                local z = zoneOf[it.zoneKind]
                if it.pos == "inside" then
                    if not M.inside(it.rect, t.bar) then problems[#problems + 1] = label .. " " .. name(it) .. " leaves its bar " .. M.fmt(it.rect) end
                elseif z and not M.inside(it.rect, z.rect) then
                    problems[#problems + 1] = label .. " " .. name(it) .. " leaves its zone " .. M.fmt(it.rect) .. " vs " .. M.fmt(z.rect)
                end
                if it.pos ~= "inside" and M.overlap(it.rect, t.bar) then
                    problems[#problems + 1] = label .. " " .. name(it) .. " overlaps its bar " .. M.fmt(it.rect) .. " vs " .. M.fmt(t.bar)
                end
            end
        end
        for i = 1, #t.items do
            for j = i + 1, #t.items do
                local a, b = t.items[i], t.items[j]
                local skip = a.kind == "bar" or b.kind == "bar"                       -- handled above
                    or a.kind == "zone" or b.kind == "zone"                           -- icons/timers vs their zone handled above
                    or (a.id and a.id == b.id and a.zoneKind == b.zoneKind)           -- an icon and its own timer touch by design
                    or (a.pos == "inside" and b.pos == "inside")                     -- two in-bar zones share the bar by design
                if not skip and M.overlap(a.rect, b.rect) then
                    problems[#problems + 1] = label .. " " .. name(a) .. " overlaps " .. name(b) .. " " .. M.fmt(a.rect) .. " " .. M.fmt(b.rect)
                end
            end
        end
        -- zones of one tile: only the outside ones must be disjoint from each other
        local zb, zd = zoneOf.buff, zoneOf.debuff
        if zb and zd and not (zb.pos == "inside" and zd.pos == "inside") and zb.pos ~= "inside" and zd.pos ~= "inside" and M.overlap(zb.rect, zd.rect) then
            problems[#problems + 1] = label .. " zones of " .. zb.owner .. " overlap " .. M.fmt(zb.rect) .. " " .. M.fmt(zd.rect)
        end
    end
    -- across tiles: nothing of one member may touch anything of the next (outside zones, icons, timers, bar)
    for i = 1, #tiles do
        for j = i + 1, #tiles do
            for _, a in ipairs(tiles[i].items) do
                for _, b in ipairs(tiles[j].items) do
                    if (a.pos ~= "inside" or a.kind == "bar") and (b.pos ~= "inside" or b.kind == "bar") and M.overlap(a.rect, b.rect) then
                        problems[#problems + 1] = label .. " " .. name(a) .. " overlaps " .. name(b) .. " " .. M.fmt(a.rect) .. " " .. M.fmt(b.rect)
                    end
                end
            end
        end
    end
    return problems
end

return M
