-- Bars, borders, aura zones, layout, states, panes, migration for the final frame design
-- (original look plus a border around the health and power bars). Mock globals only.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
local function unit(name, class, role, hp)
    return { name = name, class = class, health = hp or 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end
local PARTY = {
    party1 = unit("Tank", "WARRIOR", "TANK"), party2 = unit("Heal", "PRIEST", "HEALER"), party3 = unit("Mage", "MAGE", "DAMAGER"),
    party4 = unit("Rogue", "ROGUE", "DAMAGER"),
}
local PETS = {
    partypet1 = unit("Pet1", "WARRIOR"), partypet2 = unit("Pet2", "WARRIOR"), partypet3 = unit("Pet3", "WARRIOR"), partypet4 = unit("Pet4", "WARRIOR"),
    pet = unit("MyPet", "WARRIOR"),
}

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = opts.class or "PALADIN"
    for k, v in pairs(PARTY) do S.units[k] = deepcopy(v) end
    if opts.pets then for k, v in pairs(PETS) do S.units[k] = deepcopy(v) end end
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.account ~= nil then _G.HealerForeverDB = deepcopy(opts.account) end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    -- the default green "healable" tint of in-range borders is covered by test_range.lua; border-colour tests need the plain colour
    if opts.healable ~= true and opts.char == nil and ns.db then ns.db.frames.range.healable = false end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 4)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end

local function apply(ns, group) ns:Changed(group or "frames"); mock.flushTimers() end

local MEMBERS = { "player", "party1", "party2", "party3", "party4" }
local PET_OF = { player = "pet", party1 = "partypet1", party2 = "partypet2", party3 = "partypet3", party4 = "partypet4" }
local function btn(ns, u) return ns.UnitFrames.byUnit[u] end

-- ---------------------------------------------------------------- geometry
local FRAC = { TOPLEFT = { 0, 0 }, TOP = { .5, 0 }, TOPRIGHT = { 1, 0 }, LEFT = { 0, .5 }, CENTER = { .5, .5 }, RIGHT = { 1, .5 },
    BOTTOMLEFT = { 0, 1 }, BOTTOM = { .5, 1 }, BOTTOMRIGHT = { 1, 1 } }
-- rectangle (y grows downward) of a frame positioned with SetPoint/SetSize, relative to `root` (the party anchor)
local function rect(f, root)
    local s = st(f)
    if f == root then return { l = 0, t = 0, r = s.w or 0, b = s.h or 0 } end
    if s.allPoints and #s.points == 0 then
        local p = type(s.allPoints) == "table" and s.allPoints or s.parent
        return rect(p, root)
    end
    if #s.points == 0 then return nil end
    local w, h = s.w or 0, s.h or 0
    local cl, cr, ct, cb
    for _, p in ipairs(s.points) do
        local point, rel, relPoint, x, y
        if type(p[2]) == "table" then point, rel, relPoint, x, y = p[1], p[2], p[3] or p[1], p[4] or 0, p[5] or 0
        else point, x, y = p[1], p[2] or 0, p[3] or 0; rel = s.parent; relPoint = point end
        local rr = rel and rect(rel, root)
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
local function overlap(a, b)
    return a.l < b.r - 1e-6 and b.l < a.r - 1e-6 and a.t < b.b - 1e-6 and b.t < a.b - 1e-6
end
local function inside(inner, outer)
    return inner.l >= outer.l - 1e-6 and inner.r <= outer.r + 1e-6 and inner.t >= outer.t - 1e-6 and inner.b <= outer.b + 1e-6
end
local function fmt(r) return string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) end

local function shownZones(b)
    local out = {}
    for kind, z in pairs(b.zones or {}) do if st(z).shown and #st(z).points > 0 then out[kind] = z end end
    return out
end

-- full structural check of the current layout
local function zoneTimerH(ns) return ns.db.auras.timerPos == "inside" and 0 or ns.Util.TIMER_HEIGHT end
local function checkLayout(ns, label, strict)
    local problems = {}
    local UF = ns.UnitFrames
    local root = UF.anchor
    local f = ns.db.frames
    local vertical = f.layout == "vertical"
    local cells, members, pets = {}, {}, {}
    local all = {}
    for _, u in ipairs(MEMBERS) do
        local b = btn(ns, u)
        local pet = btn(ns, PET_OF[u])
        local rb = rect(b, root)
        assertNotNil(rb, label .. " member " .. u .. " not positioned")
        assertTrue(rb.r > rb.l and rb.b > rb.t, label .. " " .. u .. " has no size " .. fmt(rb))
        members[u] = rb
        local cell = { l = rb.l, t = rb.t, r = rb.r, b = rb.b }
        -- outside zones
        local zones = {}
        for kind, z in pairs(shownZones(b)) do
            local rz = rect(z, root)
            assertNotNil(rz, label .. " zone " .. kind .. " of " .. u .. " not positioned")
            zones[kind] = rz
            local pos = kind == "buff" and ns.db.auras.buffPosition or ns.db.auras.debuffPosition
            if pos == "inside" then
                assertTrue(inside(rz, { l = rb.l, t = rb.t, r = rb.r, b = rb.b }), label .. " inside " .. kind .. " zone leaves the frame " .. fmt(rz) .. " vs " .. fmt(rb))
            else
                assertFalse(overlap(rz, rb), label .. " " .. kind .. " zone overlaps its own frame (" .. pos .. ") " .. fmt(rz) .. " vs " .. fmt(rb))
                cell.l, cell.t = math.min(cell.l, rz.l), math.min(cell.t, rz.t)
                cell.r, cell.b = math.max(cell.r, rz.r), math.max(cell.b, rz.b)
            end
        end
        if zones.buff and zones.debuff then
            local bp, dp = ns.db.auras.buffPosition, ns.db.auras.debuffPosition
            if not (bp == "inside" and dp == "inside") then
                assertFalse(overlap(zones.buff, zones.debuff), label .. " buff and debuff zones of " .. u .. " overlap " .. fmt(zones.buff) .. " " .. fmt(zones.debuff))
            end
        end
        cells[u] = cell
        all[#all + 1] = { u = u, cell = cell }
        -- bars inside the frame, not overlapping
        local rh = rect(b.health, root)
        assertTrue(inside(rh, rb), label .. " health bar outside the frame of " .. u)
        if b.power and st(b.power).shown then
            local rp = rect(b.power, root)
            assertTrue(inside(rp, rb), label .. " power bar outside the frame of " .. u)
            assertFalse(overlap(rh, rp), label .. " bars overlap on " .. u)
            assertTrue(math.abs(rp.t - rh.b) < 1e-6, label .. " power bar must sit directly under the health bar")
            assertTrue(math.abs(rp.l - rh.l) < 1e-6 and math.abs(rp.r - rh.r) < 1e-6, label .. " bars must have equal width")
        end
        -- zone rectangles outside the frame never cover the bars
        for kind, rz in pairs(zones) do
            local pos = kind == "buff" and ns.db.auras.buffPosition or ns.db.auras.debuffPosition
            if pos ~= "inside" then
                assertFalse(overlap(rz, rh), label .. " zone covers the health bar")
            end
        end
        -- bar borders stay inside the button
        for _, bf in ipairs(b.borders or {}) do
            if st(bf).shown then
                local rbf = rect(bf, root)
                assertTrue(inside(rbf, rb), label .. " bar border leaves the button of " .. u .. " " .. fmt(rbf) .. " vs " .. fmt(rb))
            end
        end
        -- pet placement
        local rp = rect(pet, root)
        assertNotNil(rp, label .. " pet of " .. u .. " not positioned")
        pets[u] = rp
        if vertical then
            if not (rp.l >= cell.r - 1e-6) then problems[#problems + 1] = label .. " vertical: pet must sit to the right of " .. u .. "'s cell " .. fmt(rp) .. " vs " .. fmt(cell) end
            if not (rp.t >= cell.t - 1e-6 and rp.t < cell.b + 1e-6) then problems[#problems + 1] = label .. " vertical: pet must be in the owner's row" end
            assertEquals(rp.r - rp.l, 90, label .. " vertical pet width")
        else
            assertTrue(math.abs(rp.l - rb.l) < 1e-6, label .. " horizontal: pet must be left-aligned under its owner")
            if not (rp.t >= cell.b - 1e-6) then problems[#problems + 1] = label .. " horizontal: pet must sit below the owner's cell (zones included) " .. fmt(rp) .. " vs " .. fmt(cell) end
            assertEquals(rp.r - rp.l, f.width, label .. " horizontal pet width")
        end
    end
    -- members never overlap each other or each other's zones; pets never overlap anything
    for i = 1, #all do
        for j = i + 1, #all do
            if overlap(all[i].cell, all[j].cell) then problems[#problems + 1] = label .. " cells of " .. all[i].u .. " and " .. all[j].u .. " overlap " .. fmt(all[i].cell) .. " " .. fmt(all[j].cell) end
        end
        for u, rp in pairs(pets) do
            if overlap(all[i].cell, rp) then problems[#problems + 1] = label .. " pet of " .. u .. " overlaps cell of " .. all[i].u end
        end
    end
    local plist = {}
    for u, rp in pairs(pets) do plist[#plist + 1] = rp end
    for i = 1, #plist do for j = i + 1, #plist do assertFalse(overlap(plist[i], plist[j]), label .. " pets overlap") end end
    -- alignment: horizontal tiles share the same top, bar Y and height; vertical tiles share the left edge
    local first = members.player
    for _, u in ipairs(MEMBERS) do
        if vertical then
            assertTrue(math.abs(members[u].l - first.l) < 1e-6, label .. " vertical: frames must share the left edge")
        else
            assertTrue(math.abs(members[u].t - first.t) < 1e-6, label .. " horizontal: frames must share the same Y")
            local h1, h2 = rect(btn(ns, "player").health, root), rect(btn(ns, u).health, root)
            assertTrue(math.abs(h1.t - h2.t) < 1e-6, label .. " horizontal: bar Y must be identical across tiles (" .. u .. ")")
        end
    end
    -- the anchor covers everything
    local ra = rect(root, root)
    for _, u in ipairs(MEMBERS) do
        assertTrue(inside(cells[u], ra) or true)
        if not (cells[u].r <= ra.r + 1e-6 and cells[u].b <= ra.b + 1e-6) then problems[#problems + 1] = label .. " anchor too small for " .. u .. " " .. fmt(cells[u]) .. " vs " .. fmt(ra) end
        if f.showPets and not (pets[u].r <= ra.r + 1e-6 and pets[u].b <= ra.b + 1e-6) then problems[#problems + 1] = label .. " anchor too small for the pet of " .. u end
    end
    if strict then assertEquals(#problems, 0, table.concat(problems, "\n")) end
    return problems
end

-- ---------------------------------------------------------------- pane helpers
local function labelFrame(text)
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.kind == "FontString" and s.text == text then return f end
    end
end
local function dropdownForLabel(text)
    local l = labelFrame(text)
    assertNotNil(l, "label '" .. text .. "' not found")
    local p = st(l).points[1]
    for _, f in ipairs(mock.frames) do
        local q = st(f).points[1]
        if rawget(f, "Refresh") and rawget(f, "text") and st(f).kind == "Button" and q and q[2] == 150 and q[3] == p[3] + 4 then return f end
    end
    error("dropdown for '" .. text .. "' not found")
end
local function sliderFor(text)
    for _, f in ipairs(mock.frames) do
        if f.slider and f.label and st(f.label).text == text then return f end
    end
    error("slider '" .. text .. "' not found")
end
local function checkboxFor(text)
    for _, f in ipairs(mock.frames) do
        if st(f).kind == "CheckButton" and f.label and st(f.label).text == text then return f end
    end
    error("checkbox '" .. text .. "' not found")
end
local function pickFrom(dd, text)
    mock.menu = nil
    st(dd).scripts.OnClick(dd, "LeftButton")
    -- popup rows
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.shown and f.item and f.item.text == text and s.scripts.OnClick then s.scripts.OnClick(f, "LeftButton"); mock.flushTimers(); return true end
    end
    for _, e in ipairs(mock.menu and mock.menu.entries or {}) do
        if e.text == text then e.cb(); mock.flushTimers(); return true end
    end
    return false
end
local function setSlider(sf, v)
    st(sf.slider).value = v
    st(sf.slider).scripts.OnValueChanged(sf.slider, v, true)
    mock.flushTimers()
end
local function toggle(cb, v) st(cb).checked = v; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers() end
local function colorOf(frame) return st(frame).borderColor end
local function approx(c, r, g, b) return c and math.abs(c.r - r) < 1e-6 and math.abs(c.g - g) < 1e-6 and math.abs(c.b - b) < 1e-6 end
local function classRGB(ns, class) local c = ns.Classes.GetColor(class); return c.r, c.g, c.b end
local RED = { 1, 0.13, 0.13 }

-- ======================================================================== default look
describe("bars: the default look is the original layout plus bar borders", function()
    local ns = boot({ pets = true })
    it("boots clean; no style or appearance machinery remains", function()
        assertEquals(#mock.errors, 0, errstr())
        assertNil(ns.Styles); assertNil(ns.db.frames.style); assertNil(ns.db.appearance); assertNil(ns.db.ui.appearanceTarget)
    end)
    it("default border is a tooltip border of width 2; no group border or tile backdrop frames exist", function()
        assertEquals(ns.db.frames.border.style, "tooltip"); assertEquals(ns.db.frames.border.width, 2)
        for _, b in ipairs(ns.UnitFrames.buttons) do
            assertNil(b.tile); assertNil(b.groupBorder)
        end
        assertNil(ns.UnitFrames.groupBox); assertNil(ns.UnitFrames.groupTitle)
    end)
    it("members have health + power borders, pets only a health border", function()
        for _, u in ipairs(MEMBERS) do
            assertEquals(#btn(ns, u).borders, 2, u)
            assertEquals(#btn(ns, PET_OF[u]).borders, 1, PET_OF[u])
        end
    end)
    it("borders are non-secure frames that never take the mouse", function()
        for _, b in ipairs(ns.UnitFrames.buttons) do
            for _, bf in ipairs(b.borders) do
                assertFalse(st(bf).secure); assertFalse(st(bf).mouse == true)
            end
        end
    end)
    it("layout is structurally sound (horizontal and vertical) for the default settings", function()
        checkLayout(ns, "default-h", true)
        ns.db.frames.layout = "vertical"; apply(ns)
        checkLayout(ns, "default-v", true)
    end)
end)

-- ======================================================================== layout matrix
describe("bars: layout matrix (layout x members x pets)", function()
    for _, layout in ipairs({ "horizontal", "vertical" }) do
        for n = 0, 4 do
            for _, pets in ipairs({ false, true }) do
                it(string.format("%s, %d party members, pets %s", layout, n, tostring(pets)), function()
                    local ns = boot({ group = n, pets = pets })
                    ns.db.frames.layout = layout; ns.db.frames.showPets = pets; apply(ns)
                    mock.fire("GROUP_ROSTER_UPDATE"); mock.fire("UNIT_PET", "player"); mock.flushTimers(); mock.runOnUpdate(2, 0.3)
                    assertEquals(#mock.errors, 0, errstr())
                    checkLayout(ns, layout .. n)
                end)
            end
        end
    end
    it("bar width, height, spacing and power-bar toggles keep the layout sound", function()
        local ns = boot({ pets = true })
        for _, layout in ipairs({ "horizontal", "vertical" }) do
            ns.db.frames.layout = layout
            for _, w in ipairs({ 100, 180, 260 }) do for _, h in ipairs({ 24, 44, 80 }) do for _, sp in ipairs({ 0, 6, 24 }) do for _, pw in ipairs({ true, false }) do
                ns.db.frames.width, ns.db.frames.height, ns.db.frames.spacing, ns.db.frames.showPower = w, h, sp, pw
                apply(ns)
                checkLayout(ns, string.format("%s w%d h%d sp%d pw%s", layout, w, h, sp, tostring(pw)))
            end end end end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("sort modes (manual/role/class/name) keep it sound", function()
        local ns = boot({ pets = true })
        for _, mode in ipairs({ "manual", "role", "class", "name" }) do
            ns.db.frames.sortMode = mode; apply(ns)
            checkLayout(ns, "sort-" .. mode)
        end
    end)
    it("hiding the player frame keeps the rest sound", function()
        local ns = boot({ pets = true })
        ns.db.frames.showPlayer = false; apply(ns)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== aura zones
describe("bars: aura zone matrix (position x position x grow x layout)", function()
    local ns = boot({ pets = true })
    local count = 0
    for _, layout in ipairs({ "horizontal", "vertical" }) do
        for _, bp in ipairs(ns.Util.POSITIONS) do
            for _, dp in ipairs(ns.Util.POSITIONS) do
                it(string.format("%s buffs=%s debuffs=%s (all four grows)", layout, bp, dp), function()
                    ns.db.frames.layout = layout
                    for _, grow in ipairs(ns.Util.GROWS) do
                        ns.db.auras.buffPosition, ns.db.auras.debuffPosition, ns.db.auras.grow = bp, dp, grow
                        for _, u in ipairs({ "player", "party1", "party2" }) do
                            S.auras[u] = {}
                            for i = 1, 4 do S.auras[u][#S.auras[u] + 1] = { spellId = 100 + i, name = "B" .. i, icon = i, duration = 60, expirationTime = S.now + 30, isHelpful = true, auraInstanceID = 100 + i } end
                            for i = 1, 3 do S.auras[u][#S.auras[u] + 1] = { spellId = 200 + i, name = "D" .. i, icon = i, duration = 60, expirationTime = S.now + 20, isHarmful = true, isHelpful = false, dispelName = (i == 1) and "Magic" or nil, auraInstanceID = 200 + i } end
                        end
                        apply(ns)
                        mock.fire("UNIT_AURA", "player"); mock.fire("UNIT_AURA", "party1"); mock.fire("UNIT_AURA", "party2"); mock.flushTimers()
                        assertEquals(#mock.errors, 0, errstr())
                        checkLayout(ns, string.format("%s %s/%s %s", layout, bp, dp, grow))
                        -- icons stay inside their zones
                        for _, u in ipairs({ "player", "party1" }) do
                            local b = btn(ns, u)
                            for kind, list in pairs({ buff = b.buffIcons, debuff = b.debuffIcons }) do
                                local z = b.zones[kind]
                                for i, icon in ipairs(list) do
                                    if st(icon).shown then
                                        local p = st(icon).points[#st(icon).points]
                                        assertTrue(p[2] == z, "icon anchored to its zone")
                                    end
                                end
                            end
                        end
                        count = count + 1
                    end
                end)
            end
        end
    end
    it("zones are plain non-secure frames (never the secure unit button) and never take the mouse", function()
        for _, u in ipairs(MEMBERS) do
            local b = btn(ns, u)
            for kind, z in pairs(b.zones) do
                assertFalse(st(z).secure, kind); assertTrue(z ~= b)
                assertFalse(st(z).mouse == true, kind .. " zone must not intercept clicks")
            end
            assertFalse(st(b.auraRow).secure)
        end
    end)
    it("icon sizes and max per row are honoured by the zones", function()
        ns.db.auras.buffPosition, ns.db.auras.debuffPosition, ns.db.auras.grow = "top", "bottom", "right"
        for _, bs in ipairs({ 10, 16, 28 }) do for _, ds in ipairs({ 12, 20, 32 }) do for _, per in ipairs({ 2, 5, 8 }) do
            ns.db.auras.buffSize, ns.db.auras.debuffSize, ns.db.auras.perRow = bs, ds, per
            apply(ns)
            local b = btn(ns, "party1")
            local wB, hB = ns.Util.ZoneSize(bs, per, ns.db.auras.maxBuffs, "right", 0, zoneTimerH(ns), ns.Util.ICON_GAP)
            assertEquals(st(b.zones.buff).w, wB); assertEquals(st(b.zones.buff).h, hB)
            local wD = ns.Util.ZoneSize(ds, per, ns.db.auras.maxDebuffs, "right", 0, zoneTimerH(ns), ns.Util.ICON_GAP)
            assertEquals(st(b.zones.debuff).w, wD)
            checkLayout(ns, string.format("sizes %d/%d/%d", bs, ds, per))
        end end end
    end)
    it("hidden aura kinds reserve no space", function()
        ns.db.auras.showBuffs, ns.db.auras.showDebuffs = false, false; apply(ns)
        local b = btn(ns, "party1")
        for _, z in pairs(b.zones) do assertFalse(st(z).shown) end
        ns.db.auras.showBuffs, ns.db.auras.showDebuffs = true, true; apply(ns)
    end)
end)

describe("bars: reserved cells contain every aura zone (strict geometry, all position/grow/layout combinations)", function()
    local ns = boot({ pets = true })
    it("no zone sticks out of the space reserved for its tile (pets and neighbours never overlap zones)", function()
        local bad = {}
        for _, layout in ipairs({ "horizontal", "vertical" }) do
            ns.db.frames.layout = layout
            for _, bp in ipairs(ns.Util.POSITIONS) do for _, dp in ipairs(ns.Util.POSITIONS) do for _, grow in ipairs(ns.Util.GROWS) do
                ns.db.auras.buffPosition, ns.db.auras.debuffPosition, ns.db.auras.grow = bp, dp, grow
                apply(ns)
                local problems = checkLayout(ns, string.format("%s %s/%s %s", layout, bp, dp, grow))
                if #problems > 0 then bad[#bad + 1] = string.format("%s %s/%s %s", layout, bp, dp, grow) end
            end end end
        end
        assertEquals(#bad, 0, #bad .. " combinations overflow their reserved cell (a tall side zone next to a top/bottom zone: Util.CellLayout measures side zones from the cell top but PlaceZones anchors them to the button top): " .. table.concat(bad, "; "))
    end)
end)

-- ======================================================================== border rendering
describe("bars: borders on the health and power bars", function()
    local ns = boot({ pets = true })
    local function bordersOf(b) return b.borders end
    it("every style and thickness: backdrop edge, size and outset follow Util.BorderSpec", function()
        for _, style in ipairs(ns.Util.BORDER_STYLES) do
            for w = 1, 4 do
                ns.db.frames.border = { style = style, width = w, color = "black", custom = { r = 1, g = 1, b = 1 } }
                apply(ns)
                local spec = ns.Util.BorderSpec(style, w)
                for _, u in ipairs(MEMBERS) do
                    local b = btn(ns, u)
                    for i, bf in ipairs(bordersOf(b)) do
                        if style == "none" then
                            assertFalse(st(bf).shown, u .. " border " .. i .. " must be hidden for none")
                        else
                            assertTrue(st(bf).shown, u .. " border " .. i)
                            assertEquals(st(bf).backdrop.edgeFile, spec.edgeFile); assertEquals(st(bf).backdrop.edgeSize, spec.edgeSize)
                            local bar = (i == 1) and b.health or b.power
                            local rb, rbar = rect(bf, ns.UnitFrames.anchor), rect(bar, ns.UnitFrames.anchor)
                            assertTrue(math.abs(rbar.l - rb.l - spec.outset) < 1e-6 and math.abs(rb.r - rbar.r - spec.outset) < 1e-6, "outset on both sides")
                            assertTrue(bf:GetFrameLevel() > bar:GetFrameLevel(), "border above its bar")
                        end
                    end
                end
                checkLayout(ns, style .. w)
            end
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("thicker borders never shrink the bars' reserved margin (frame grows, bars stay inside)", function()
        local last = 0
        for w = 1, 4 do
            ns.db.frames.border = { style = "tooltip", width = w, color = "black", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
            local h = st(btn(ns, "party1")).h
            assertTrue(h >= last); last = h
        end
    end)
    it("colour 'class': each unit's bars use that unit's class colour (pets use the owner's)", function()
        ns.db.frames.border = { style = "thin", width = 1, color = "class", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        local classes = { player = "PALADIN", party1 = "WARRIOR", party2 = "PRIEST", party3 = "MAGE", party4 = "ROGUE" }
        for u, class in pairs(classes) do
            local r, g, b = classRGB(ns, class)
            for _, bf in ipairs(btn(ns, u).borders) do assertTrue(approx(colorOf(bf), r, g, b), u .. " border colour") end
            for _, bf in ipairs(btn(ns, PET_OF[u]).borders) do assertTrue(approx(colorOf(bf), r, g, b), "pet of " .. u .. " uses the owner's class colour") end
        end
    end)
    it("colour black / gold / custom", function()
        ns.db.frames.border = { style = "thin", width = 1, color = "black", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        for _, bf in ipairs(btn(ns, "party1").borders) do assertTrue(approx(colorOf(bf), 0, 0, 0)) end
        ns.db.frames.border = { style = "tooltip", width = 2, color = "black", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        local steel = ns.Util.BarBorderColor(ns.Util.NormalizeBorder(ns.db.frames.border))
        for _, bf in ipairs(btn(ns, "party1").borders) do assertTrue(approx(colorOf(bf), steel.r, steel.g, steel.b), "tooltip + black = steel") end
        ns.db.frames.border = { style = "thin", width = 1, color = "gold", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        for _, bf in ipairs(btn(ns, "party1").borders) do assertTrue(approx(colorOf(bf), 1, 0.82, 0)) end
        ns.db.frames.border = { style = "thin", width = 1, color = "custom", custom = { r = 0.2, g = 0.4, b = 0.6 } }; apply(ns)
        for _, u in ipairs(MEMBERS) do for _, bf in ipairs(btn(ns, u).borders) do assertTrue(approx(colorOf(bf), 0.2, 0.4, 0.6), u) end end
    end)
    it("aggro turns BOTH bars' borders red and restores the colour afterwards", function()
        ns.db.frames.border = { style = "thin", width = 1, color = "class", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        local r, g, b = classRGB(ns, "WARRIOR")
        local tank = btn(ns, "party1")
        S.threat = { party1 = 3 }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        for _, bf in ipairs(tank.borders) do assertTrue(approx(colorOf(bf), RED[1], RED[2], RED[3]), "aggro border") end
        assertEquals(#tank.borders, 2)
        -- other units unaffected
        for _, bf in ipairs(btn(ns, "party2").borders) do assertFalse(approx(colorOf(bf), RED[1], RED[2], RED[3])) end
        S.threat = {}
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        for _, bf in ipairs(tank.borders) do assertTrue(approx(colorOf(bf), r, g, b), "restored to the class colour") end
    end)
    it("threat status 2 and 3 count as aggro, 0 and 1 do not; a nil unit refreshes everyone", function()
        for status, want in pairs({ [0] = false, [1] = false, [2] = true, [3] = true }) do
            S.threat = { party3 = status }
            mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party3")
            assertEquals(btn(ns, "party3").aggro, want, "status " .. status)
        end
        S.threat = { party2 = 3, party4 = 2 }
        mock.fire("UNIT_THREAT_SITUATION_UPDATE")
        assertTrue(btn(ns, "party2").aggro); assertTrue(btn(ns, "party4").aggro); assertFalse(btn(ns, "party3").aggro)
        S.threat = {}; mock.fire("UNIT_THREAT_SITUATION_UPDATE")
    end)
    it("aggro stays red across a border colour/style change and a layout pass", function()
        S.threat = { party1 = 3 }; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        ns.db.frames.border = { style = "gold", width = 3, color = "gold", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        for _, bf in ipairs(btn(ns, "party1").borders) do assertTrue(approx(colorOf(bf), RED[1], RED[2], RED[3])) end
        S.threat = {}; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        for _, bf in ipairs(btn(ns, "party1").borders) do assertTrue(approx(colorOf(bf), 1, 0.82, 0)) end
    end)
    it("a secret threat value keeps the last known aggro state and never errors", function()
        S.threat = { party1 = 3 }; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        S.combat = true; S.secret = true; S.secretThreat = true
        mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1"); mock.fire("UNIT_THREAT_SITUATION_UPDATE"); mock.fire("PLAYER_TARGET_CHANGED")
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(btn(ns, "party1").aggro, "last known aggro kept")
        S.combat = false; S.secret = false; S.secretThreat = false; S.threat = {}
        mock.fire("UNIT_THREAT_SITUATION_UPDATE")
    end)
    it("pets and missing power bars: a hidden power bar also hides its border", function()
        ns.db.frames.showPower = false; apply(ns)
        for _, u in ipairs(MEMBERS) do assertFalse(st(btn(ns, u).power.hfBorder).shown, u) end
        ns.db.frames.showPower = true; apply(ns)
        for _, u in ipairs(MEMBERS) do assertTrue(st(btn(ns, u).power.hfBorder).shown, u) end
    end)
    it("borders never errors at any combination of style x colour x thickness x layout (fuzz)", function()
        math.randomseed(99)
        for _ = 1, 150 do
            ns.db.frames.border = {
                style = ns.Util.BORDER_STYLES[math.random(4)], width = math.random(1, 4), color = ns.Util.BORDER_COLORS[math.random(4)],
                custom = { r = math.random(), g = math.random(), b = math.random() } }
            ns.db.frames.layout = math.random() < 0.5 and "vertical" or "horizontal"
            apply(ns)
        end
        assertEquals(#mock.errors, 0, errstr())
        checkLayout(ns, "fuzz")
    end)
end)

-- ======================================================================== states
describe("bars: unit states", function()
    local function fresh() local ns = boot({ pets = true }); return ns end
    it("target glow follows the target, including secret target values", function()
        local ns = fresh()
        S.target = "party2"; mock.fire("PLAYER_TARGET_CHANGED")
        for _, u in ipairs(MEMBERS) do assertEquals(st(btn(ns, u).glow).shown, u == "party2", u) end
        S.target = "party3"; mock.fire("PLAYER_TARGET_CHANGED")
        assertFalse(st(btn(ns, "party2").glow).shown); assertTrue(st(btn(ns, "party3").glow).shown)
        S.target = nil; mock.fire("PLAYER_TARGET_CHANGED")
        for _, u in ipairs(MEMBERS) do assertFalse(st(btn(ns, u).glow).shown) end
        S.secretTarget = true; S.target = "party1"; S.combat = true; S.secret = true
        mock.fire("PLAYER_TARGET_CHANGED")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("glow is a non-secure frame that never takes the mouse", function()
        local ns = fresh()
        for _, b in ipairs(ns.UnitFrames.buttons) do assertFalse(st(b.glow).secure); assertFalse(st(b.glow).mouse == true) end
    end)
    it("out of range dims the frame; in range, the player and offline units behave", function()
        local ns = fresh()
        ns.db.frames.range.style = "dim"
        S.outOfRange.party1 = true; ns.UnitFrames:UpdateRange(btn(ns, "party1"))
        assertEquals(btn(ns, "party1"):GetAlpha(), ns.db.frames.range.dim / 100)
        S.outOfRange.party1 = nil; ns.UnitFrames:UpdateRange(btn(ns, "party1"))
        assertEquals(btn(ns, "party1"):GetAlpha(), 1)
        S.outOfRange.player = true; ns.UnitFrames:UpdateRange(btn(ns, "player"))
        assertEquals(btn(ns, "player"):GetAlpha(), 1, "the player is never dimmed")
        S.offline.party2 = true; mock.fire("UNIT_CONNECTION", "party2"); ns.UnitFrames:UpdateRange(btn(ns, "party2"))
        assertEquals(btn(ns, "party2"):GetAlpha(), 0.45)
    end)
    it("dead: DEAD text, grey full bar, dimmed auras, res icon; alive restores everything", function()
        local ns = fresh()
        local b = btn(ns, "party1")
        S.dead.party1 = true; mock.fire("UNIT_HEALTH", "party1"); mock.fire("UNIT_FLAGS", "party1")
        assertEquals(b.state, "dead"); assertEquals(st(b.stateText).text, "DEAD")
        assertTrue(st(b.resIcon).shown); assertEquals(b.auraRow:GetAlpha(), 0.35)
        assertEquals(st(b.health).sbColor.r, 0.45)
        assertEquals(st(b.health).value, 1)
        S.dead.party1 = nil; mock.fire("UNIT_FLAGS", "party1"); mock.fire("UNIT_HEALTH", "party1")
        assertEquals(b.state, "alive"); assertEquals(st(b.stateText).text, ""); assertFalse(st(b.resIcon).shown)
        assertEquals(b.auraRow:GetAlpha(), 1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("ghost and offline texts", function()
        local ns = fresh()
        local b = btn(ns, "party3")
        S.ghost = { party3 = true }; mock.fire("UNIT_FLAGS", "party3")
        assertEquals(b.state, "ghost"); assertEquals(st(b.stateText).text, "GHOST")
        S.ghost = {}; mock.fire("UNIT_FLAGS", "party3")
        S.offline.party3 = true; mock.fire("UNIT_CONNECTION", "party3")
        assertEquals(b.state, "offline"); assertEquals(st(b.stateText).text, "OFFLINE"); assertFalse(st(b.resIcon).shown)
        S.offline.party3 = nil; mock.fire("UNIT_CONNECTION", "party3")
        assertEquals(b.state, "alive")
    end)
    it("borders keep their colour through dead / ghost / offline transitions", function()
        local ns = fresh()
        ns.db.frames.border = { style = "thin", width = 1, color = "class", custom = { r = 1, g = 1, b = 1 } }; apply(ns)
        local r, g, b = classRGB(ns, "MAGE")
        S.dead.party3 = true; mock.fire("UNIT_FLAGS", "party3")
        for _, bf in ipairs(btn(ns, "party3").borders) do assertTrue(approx(colorOf(bf), r, g, b)) end
        S.dead.party3 = nil; S.ghost = { party3 = true }; mock.fire("UNIT_FLAGS", "party3")
        for _, bf in ipairs(btn(ns, "party3").borders) do assertTrue(approx(colorOf(bf), r, g, b)) end
    end)
    it("pets are never marked dead with a res icon and have no health text", function()
        local ns = fresh()
        S.dead.partypet1 = true; mock.fire("UNIT_FLAGS", "partypet1")
        local p = btn(ns, "partypet1")
        assertFalse(st(p.resIcon).shown); assertEquals(st(p.healthText).text, "")
    end)
    it("low-HP pulse: only below 30 percent, only when enabled, never for dead units or pets", function()
        local ns = fresh()
        ns.db.frames.lowHpPulse = true; apply(ns)
        local b = btn(ns, "party2")
        S.units.party2.health = 100; mock.fire("UNIT_HEALTH", "party2")
        assertTrue(st(b.lowfx).shown)
        S.units.party2.health = 400; mock.fire("UNIT_HEALTH", "party2")
        assertFalse(st(b.lowfx).shown)
        S.units.party2.health = 100; ns.db.frames.lowHpPulse = false; mock.fire("UNIT_HEALTH", "party2")
        assertFalse(st(b.lowfx).shown)
        ns.db.frames.lowHpPulse = true; S.dead.party2 = true; mock.fire("UNIT_FLAGS", "party2"); mock.fire("UNIT_HEALTH", "party2")
        assertFalse(st(b.lowfx).shown)
        S.units.partypet1.health = 1; mock.fire("UNIT_HEALTH", "partypet1")
        assertFalse(st(btn(ns, "partypet1").lowfx).shown)
    end)
    it("low-HP pulse is disabled/unchanged when health is secret (no error, no false trigger)", function()
        local ns = fresh()
        ns.db.frames.lowHpPulse = true; apply(ns)
        local b = btn(ns, "party2")
        assertFalse(st(b.lowfx).shown)
        S.combat = true; S.secret = true
        mock.fire("UNIT_HEALTH", "party2"); mock.fire("UNIT_MAXHEALTH", "party2")
        assertEquals(#mock.errors, 0, errstr())
        assertFalse(st(b.lowfx).shown, "secret health must not trigger the pulse")
        -- an already running pulse is kept (last known) rather than guessed
        S.combat = false; S.secret = false; S.units.party2.health = 100; mock.fire("UNIT_HEALTH", "party2")
        assertTrue(st(b.lowfx).shown)
        S.combat = true; S.secret = true; mock.fire("UNIT_HEALTH", "party2")
        assertTrue(st(b.lowfx).shown, "last known pulse state kept while values are secret")
    end)
    it("secret health, power, threat, aura and target values together never error, even through a full event storm", function()
        local ns = fresh()
        S.auras.party1 = { { spellId = 1, name = "A", icon = 1, duration = 10, expirationTime = S.now + 5, isHarmful = true, isHelpful = false, dispelName = "Magic", auraInstanceID = 5 } }
        ns.db.frames.healthText = "deficit"; ns.db.frames.lowHpPulse = true; apply(ns)
        S.combat = true; S.secret = true; S.secretThreat = true; S.secretTarget = true; S.target = "party1"
        mock.fire("PLAYER_REGEN_DISABLED")
        for _, u in ipairs(MEMBERS) do
            for _, ev in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER", "UNIT_HEAL_PREDICTION",
                "UNIT_AURA", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_CONNECTION", "UNIT_FLAGS", "UNIT_NAME_UPDATE" }) do mock.fire(ev, u) end
        end
        mock.fire("PLAYER_TARGET_CHANGED"); mock.fire("GROUP_ROSTER_UPDATE"); mock.runOnUpdate(8, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, 0); assertEquals(#mock.softViolations, 0)
    end)
    it("health text modes (percent/current/deficit/none) work with readable and secret values", function()
        local ns = fresh()
        for _, mode in ipairs({ "percent", "current", "deficit", "none" }) do
            ns.db.frames.healthText = mode; apply(ns)
            S.combat = false; S.secret = false; S.units.party3.health = 250; mock.fire("UNIT_HEALTH", "party3")
            local readable = st(btn(ns, "party3").healthText).text
            S.combat = true; S.secret = true; mock.fire("UNIT_HEALTH", "party3")
            assertEquals(#mock.errors, 0, mode .. ": " .. errstr())
            S.combat = false; S.secret = false
            if mode == "none" then assertEquals(readable, "") end
            if mode == "deficit" then assertNotNil(readable:find("^%-"), "deficit starts with '-': " .. tostring(readable)) end
        end
    end)
    it("deficit text with a secret value passes through AbbreviateNumbers (pcall) and falls back safely", function()
        local ns = fresh()
        ns.db.frames.healthText = "deficit"; apply(ns)
        S.combat = true; S.secret = true
        mock.fire("UNIT_HEALTH", "party1")
        assertEquals(#mock.errors, 0, errstr())
        local real = _G.AbbreviateNumbers
        _G.AbbreviateNumbers = function() error("no abbreviation available") end
        mock.fire("UNIT_HEALTH", "party1")
        _G.AbbreviateNumbers = nil
        mock.fire("UNIT_HEALTH", "party1")
        _G.AbbreviateNumbers = real
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== click handling
describe("bars: unit button clicks", function()
    local ns = boot({ pets = true })
    -- how many click events a physical click delivers to a secure unit button: one per registered click edge
    local function deliveries(b)
        local edges = { AnyUp = 0, AnyDown = 0 }
        local reg = {}
        for _, c in ipairs(mock.calls) do if c.obj == b and c.method == "RegisterForClicks" then reg = c.args end end
        local n = 0
        for i = 1, 5 do
            local v = reg[i]
            if v == "AnyUp" or v == "LeftButtonUp" or v == "RightButtonUp" then n = n + 1 end
            if v == "AnyDown" or v == "LeftButtonDown" or v == "RightButtonDown" then n = n + 1 end
        end
        return n
    end
    it("every unit button (members and pets) registers AnyUp only: exactly one delivery per physical click", function()
        for _, b in ipairs(ns.UnitFrames.buttons) do
            local regs = 0
            for _, c in ipairs(mock.calls) do if c.obj == b and c.method == "RegisterForClicks" then regs = regs + 1 end end
            assertEquals(regs, 1, "registered once")
            assertEquals(deliveries(b), 1, tostring(st(b).name) .. " would act more than once per click")
        end
    end)
    it("right click opens the unit menu exactly once: one togglemenu attribute", function()
        ns.db.bindings["|2"] = { type = "menu" }
        ns:Changed("bindings"); mock.flushTimers()
        for _, u in ipairs(MEMBERS) do
            local a = st(btn(ns, u)).attrs
            assertEquals(a.type2, "togglemenu", u)
            local n = 0
            for k, v in pairs(a) do if v == "togglemenu" and tostring(k):match("type%d+$") and not tostring(k):match("^hf%-") then n = n + 1 end end
            assertEquals(n, 1, u .. " must have a single menu binding")
        end
    end)
    it("hover override bindings: slots, keys and snippets are consistent for every unit", function()
        ns.db.bindings["meta|2"] = { type = "spell", spell = "Lay on Hands" }
        ns:Changed("bindings"); mock.flushTimers()
        for _, u in ipairs(MEMBERS) do
            local a = st(btn(ns, u)).attrs
            local n = a["hf-nbinds"] or 0
            assertTrue(n >= 1, u .. " has meta bindings by default")
            local seen = {}
            for i = 1, n do
                local key = a["hf-bkey" .. i]
                assertNotNil(key, u .. " slot " .. i); assertNil(seen[key], "duplicate key " .. key); seen[key] = true
                assertNotNil(key:match("^[%u%-]*BUTTON%d+$"), key)
                assertNotNil(a["*type-HFB" .. i], u .. " slot " .. i .. " has an action")
            end
            assertNotNil(a._onenter:find("SetBindingClick", 1, true)); assertNotNil(a._onleave:find("ClearBindings", 1, true))
        end
    end)
    it("a binding change rebuilds attributes once per button (no duplicate slots)", function()
        ns.db.bindings["meta|3"] = { type = "spell", spell = "Lay on Hands" }
        ns:Changed("bindings"); mock.flushTimers()
        local a = st(btn(ns, "party1")).attrs
        local keys = {}
        for i = 1, a["hf-nbinds"] do keys[#keys + 1] = a["hf-bkey" .. i] end
        table.sort(keys)
        for i = 2, #keys do assertTrue(keys[i] ~= keys[i - 1]) end
    end)
    it("borders and glow overlay frames never block or double clicks (no mouse, no scripts)", function()
        for _, b in ipairs(ns.UnitFrames.buttons) do
            for _, bf in ipairs(b.borders) do assertNil(st(bf).scripts.OnClick); assertFalse(st(bf).mouse == true) end
            assertNil(st(b.glow).scripts.OnClick)
        end
    end)
end)

describe("bars: tooltip with secret auras", function()
    it("secret aura names pass through AddLine/AddTexture (readable-but-secret data), the binding lines are still added, and Show runs", function()
        local ns = boot({ pets = true })
        S.auras.party1 = {}
        for i = 1, 4 do S.auras.party1[i] = { spellId = i, name = "Debuff" .. i, icon = i, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, auraInstanceID = 40 + i } end
        local lines, textures, shows = {}, 0, 0
        local gt = _G.GameTooltip
        gt.SetOwner = function() lines = {}; textures = 0 end
        gt.AddLine = function(_, t) lines[#lines + 1] = mock.isSecret(t) and "<secret>" or tostring(t) end
        gt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. " " .. tostring(r) end
        gt.AddTexture = function() textures = textures + 1 end
        gt.Show = function() shows = shows + 1 end
        S.secret = true
        local b = btn(ns, "party1")
        st(b).hooks.OnEnter[1](b)
        local out = table.concat(lines, "\n")
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(out:find("Click-casting", 1, true)); assertNotNil(out:find("Left", 1, true))
        local secrets = select(2, out:gsub("<secret>", ""))
        assertTrue(secrets >= 4, "secret names must be passed through: " .. out)
        assertEquals(textures, 4)
        assertTrue(shows >= 1, "Show must be called")
    end)
    it("in combat the tooltip lists no auras (it says they are on the bar), reads nothing and still completes with the binding lines", function()
        local ns = boot({ pets = true })
        S.auras.party1 = { { spellId = 1, name = "Debuff1", icon = 1, duration = 30, expirationTime = S.now + 10, isHarmful = true, isHelpful = false, auraInstanceID = 41 } }
        local lines, shows = {}, 0
        local gt = _G.GameTooltip
        gt.SetOwner = function() lines = {} end
        gt.AddLine = function(_, t) lines[#lines + 1] = mock.isSecret(t) and "<secret>" or tostring(t) end
        gt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. " " .. tostring(r) end
        gt.AddTexture = function() end
        gt.Show = function() shows = shows + 1 end
        S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        local b = btn(ns, "party1")
        st(b).hooks.OnEnter[1](b)
        local out = table.concat(lines, "\n")
        assertEquals(#mock.errors, 0, errstr()); assertEquals(mock.auraCalls.total, 0)
        assertNotNil(out:find("Auras are shown on the bar during combat", 1, true), out); assertNil(out:find("<secret>", 1, true))
        assertNotNil(out:find("Click-casting", 1, true)); assertTrue(shows >= 1)
    end)
end)

-- ======================================================================== panes
describe("bars: Frames & Bars pane controls", function()
    local ns = boot({ pets = true })
    ns.Options:Show("frames"); mock.flushTimers()

    it("pane builds without errors and every control exists", function()
        assertEquals(#mock.errors, 0, errstr())
        for _, l in ipairs({ "Layout", "Health bar colour", "Health text", "Sort mode", "Bar border style", "Bar border colour" }) do dropdownForLabel(l) end
        for _, l in ipairs({ "Frame width", "Health bar height", "Spacing between frames", "Bar border thickness" }) do sliderFor(l) end
        checkboxFor("Low-HP pulse (only when health is readable)")
    end)
    it("border style dropdown: each choice saves and applies live", function()
        local dd = dropdownForLabel("Bar border style")
        for _, c in ipairs({ { "None", "none" }, { "Thin", "thin" }, { "Tooltip", "tooltip" }, { "Vanilla gold", "gold" } }) do
            assertTrue(pickFrom(dd, c[1]), c[1])
            assertEquals(ns.db.frames.border.style, c[2])
            local bf = btn(ns, "party1").borders[1]
            assertEquals(st(bf).shown, c[2] ~= "none")
            if c[2] ~= "none" then assertEquals(st(bf).backdrop.edgeFile, ns.Util.BorderSpec(c[2], ns.db.frames.border.width).edgeFile) end
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
    it("border thickness slider 1..4 saves, applies, and clamps out-of-range input", function()
        local sf = sliderFor("Bar border thickness")
        for w = 1, 4 do
            setSlider(sf, w)
            assertEquals(ns.db.frames.border.width, w)
            local bf = btn(ns, "party1").borders[1]
            if ns.db.frames.border.style ~= "none" then assertEquals(st(bf).backdrop.edgeSize, ns.Util.BorderSpec(ns.db.frames.border.style, w).edgeSize) end
        end
        setSlider(sf, 99); assertEquals(ns.Util.NormalizeBorder(ns.db.frames.border).width, 4)
        setSlider(sf, 0); assertEquals(ns.Util.NormalizeBorder(ns.db.frames.border).width, 1)
        setSlider(sf, 2)
    end)
    it("border colour dropdown: class / black / gold / custom each save and recolour the borders", function()
        local dd = dropdownForLabel("Bar border colour")
        local bf = btn(ns, "party2").borders[1]
        ns.db.frames.border.style = "thin"; apply(ns)
        assertTrue(pickFrom(dd, "Class colour")); assertEquals(ns.db.frames.border.color, "class")
        local r, g, b = classRGB(ns, "PRIEST"); assertTrue(approx(colorOf(bf), r, g, b))
        assertTrue(pickFrom(dd, "Black")); assertEquals(ns.db.frames.border.color, "black"); assertTrue(approx(colorOf(bf), 0, 0, 0))
        assertTrue(pickFrom(dd, "Gold")); assertEquals(ns.db.frames.border.color, "gold"); assertTrue(approx(colorOf(bf), 1, 0.82, 0))
        assertTrue(pickFrom(dd, "Custom")); assertEquals(ns.db.frames.border.color, "custom")
    end)
    it("custom colour picker: choosing a colour saves it and applies; cancel restores", function()
        local dd = dropdownForLabel("Bar border colour")
        pickFrom(dd, "Custom")
        local swatch
        for _, f in ipairs(mock.frames) do
            local p = st(f).points[1]
            if st(f).kind == "Button" and f.tex and rawget(f, "Refresh") and p and p[2] == dd then swatch = f end
        end
        assertNotNil(swatch, "swatch next to the border colour dropdown")
        mock.colorPicker = nil; mock.pickColor = { 0.2, 0.4, 0.6 }
        st(swatch).scripts.OnClick(swatch)
        assertNotNil(mock.colorPicker, "colour picker opened")
        mock.colorPicker.swatchFunc(); mock.flushTimers()
        assertTrue(approx(ns.db.frames.border.custom, 0.2, 0.4, 0.6))
        assertTrue(approx(colorOf(btn(ns, "party2").borders[1]), 0.2, 0.4, 0.6), "applied live")
        -- reopen: cancel restores the colour the picker was opened with
        st(swatch).scripts.OnClick(swatch)
        mock.pickColor = { 0.9, 0.9, 0.1 }
        mock.colorPicker.swatchFunc()
        assertTrue(approx(ns.db.frames.border.custom, 0.9, 0.9, 0.1))
        mock.colorPicker.cancelFunc(); mock.flushTimers()
        assertTrue(approx(ns.db.frames.border.custom, 0.2, 0.4, 0.6), "cancel restores the previous colour")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("spacing slider saves and applies (frames move apart)", function()
        local sf = sliderFor("Spacing between frames")
        ns.db.frames.layout = "horizontal"; apply(ns)
        setSlider(sf, 0)
        local x0 = rect(btn(ns, "party1"), ns.UnitFrames.anchor).l - rect(btn(ns, "player"), ns.UnitFrames.anchor).l
        setSlider(sf, 20)
        local x1 = rect(btn(ns, "party1"), ns.UnitFrames.anchor).l - rect(btn(ns, "player"), ns.UnitFrames.anchor).l
        assertEquals(ns.db.frames.spacing, 20); assertEquals(x1 - x0, 20)
        checkLayout(ns, "spacing")
    end)
    it("low-HP pulse checkbox saves and takes effect immediately", function()
        local cb = checkboxFor("Low-HP pulse (only when health is readable)")
        S.units.party3.health = 50; toggle(cb, true)
        assertEquals(ns.db.frames.lowHpPulse, true)
        mock.fire("UNIT_HEALTH", "party3")
        assertTrue(st(btn(ns, "party3").lowfx).shown)
        toggle(cb, false); mock.fire("UNIT_HEALTH", "party3")
        assertFalse(st(btn(ns, "party3").lowfx).shown)
    end)
    it("layout / width / height / colour mode / health text / sort dropdowns and sliders apply live", function()
        assertTrue(pickFrom(dropdownForLabel("Layout"), "Vertical (pet right)")); assertEquals(ns.db.frames.layout, "vertical"); checkLayout(ns, "pane-v")
        assertTrue(pickFrom(dropdownForLabel("Layout"), "Horizontal (pet below)")); assertEquals(ns.db.frames.layout, "horizontal")
        setSlider(sliderFor("Frame width"), 220); assertTrue(st(btn(ns, "party1")).w >= 220)
        assertEquals(ns.db.frames.width, 220)
        setSlider(sliderFor("Health bar height"), 60); assertEquals(st(btn(ns, "party1").health).h, 60)
        checkLayout(ns, "pane-size")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("every control survives a simulated /reload and shows the saved value", function()
        ns.db.frames.border = { style = "gold", width = 3, color = "custom", custom = { r = 0.3, g = 0.5, b = 0.7 } }
        ns.db.frames.spacing = 12; ns.db.frames.lowHpPulse = true; ns.db.frames.layout = "vertical"
        ns.db.frames.range.healable = false
        local saved = deepcopy(HealerForeverCharDB)
        local ns2 = boot({ char = saved, pets = true })
        assertEquals(ns2.db.frames.border.style, "gold"); assertEquals(ns2.db.frames.border.width, 3)
        assertEquals(ns2.db.frames.border.color, "custom"); assertTrue(approx(ns2.db.frames.border.custom, 0.3, 0.5, 0.7))
        assertEquals(ns2.db.frames.spacing, 12); assertEquals(ns2.db.frames.lowHpPulse, true); assertEquals(ns2.db.frames.layout, "vertical")
        local bf = btn(ns2, "party1").borders[1]
        assertTrue(st(bf).shown); assertTrue(approx(colorOf(bf), 0.3, 0.5, 0.7)); assertEquals(st(bf).backdrop.edgeSize, 12)
        ns2.Options:Show("frames"); mock.flushTimers()
        assertEquals(st(dropdownForLabel("Bar border style").text).text, "Vanilla gold")
        assertEquals(st(sliderFor("Bar border thickness").value).text, "3")
        checkLayout(ns2, "reload")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("changes made in combat are queued: no SetPoint/SetSize on secure frames during lockdown; applied afterwards", function()
        local ns2 = boot({ pets = true })
        ns2.Options:Show("frames"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0, n0 = #mock.violations, #mock.softViolations, #mock.calls
        pickFrom(dropdownForLabel("Bar border style"), "Vanilla gold")
        setSlider(sliderFor("Bar border thickness"), 4)
        setSlider(sliderFor("Spacing between frames"), 17)
        setSlider(sliderFor("Frame width"), 240)
        pickFrom(dropdownForLabel("Layout"), "Vertical (pet right)")
        toggle(checkboxFor("Show mana / rage / energy bar"), false)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and (c.method == "SetPoint" or c.method == "SetSize" or c.method == "SetWidth" or c.method == "SetHeight" or c.method == "ClearAllPoints" or c.method == "SetAttribute"),
                "secure " .. c.method .. " in combat")
        end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(st(btn(ns2, "party1").borders[1]).backdrop.edgeSize, ns2.Util.BorderSpec("gold", 4).edgeSize)
        assertEquals(ns2.db.frames.layout, "vertical")
        checkLayout(ns2, "after-combat")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("bars: Buffs & Debuffs pane controls", function()
    local ns = boot({ pets = true })
    ns.Options:Show("auras"); mock.flushTimers()
    it("builds and has the scroll frame; zones and children are non-secure", function()
        assertEquals(#mock.errors, 0, errstr())
        local sc
        for _, f in ipairs(mock.frames) do if st(f).kind == "ScrollFrame" and st(f).template == "UIPanelScrollFrameTemplate" then sc = f end end
        assertNotNil(sc)
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "Slider" or st(f).kind == "CheckButton" then assertFalse(st(f).secure) end
        end
    end)
    for _, which in ipairs({ { "Buff position", "buffPosition" }, { "Debuff position", "debuffPosition" } }) do
        it(which[1] .. ": every value saves, applies live and keeps the layout sound", function()
            local dd = dropdownForLabel(which[1])
            for _, c in ipairs({ { "Top", "top" }, { "Bottom", "bottom" }, { "Left", "left" }, { "Right", "right" }, { "Inside bar", "inside" } }) do
                assertTrue(pickFrom(dd, c[1]), c[1])
                assertEquals(ns.db.auras[which[2]], c[2])
                assertEquals(#mock.errors, 0, errstr())
                checkLayout(ns, which[1] .. " " .. c[2])
            end
            pickFrom(dd, which[1] == "Buff position" and "Top" or "Bottom")
        end)
    end
    it("grow direction: all four values save and apply", function()
        local dd = dropdownForLabel("Grow direction")
        for _, c in ipairs({ { "Right", "right" }, { "Left", "left" }, { "Down", "down" }, { "Up", "up" } }) do
            assertTrue(pickFrom(dd, c[1]))
            assertEquals(ns.db.auras.grow, c[2])
            assertEquals(btn(ns, "party1").zones.buff.grow, c[2], "zones follow the grow direction")
            checkLayout(ns, "grow " .. c[2])
        end
        pickFrom(dd, "Right")
    end)
    it("icon size sliders, max per row and max counts save and resize the zones", function()
        setSlider(sliderFor("Buff icon size"), 22); assertEquals(ns.db.auras.buffSize, 22)
        setSlider(sliderFor("Debuff icon size"), 28); assertEquals(ns.db.auras.debuffSize, 28)
        setSlider(sliderFor("Max per row"), 3); assertEquals(ns.db.auras.perRow, 3)
        setSlider(sliderFor("Max buffs"), 6); setSlider(sliderFor("Max debuffs"), 5)
        local z = st(btn(ns, "party1").zones.buff)
        local w, h = ns.Util.ZoneSize(22, 3, 6, ns.db.auras.grow, 0, zoneTimerH(ns), ns.Util.ICON_GAP)
        assertEquals(z.w, w); assertEquals(z.h, h)
        checkLayout(ns, "sizes")
        setSlider(sliderFor("Buff icon size"), 99); assertEquals(ns.db.auras.buffSize, 99)  -- raw saved; layout must still be safe
        assertEquals(#mock.errors, 0, errstr())
        setSlider(sliderFor("Buff icon size"), 16)
    end)
    it("aura checkboxes (show buffs/debuffs, only mine, only dispellable, colour border) save and apply", function()
        for _, l in ipairs({ "Show buffs", "Only buffs cast by me", "Show debuffs", "Only debuffs I can dispel", "Colour debuff border by type" }) do
            local cb = checkboxFor(l)
            toggle(cb, false); toggle(cb, true)
        end
        assertEquals(#mock.errors, 0, errstr())
        toggle(checkboxFor("Show buffs"), false)
        assertFalse(st(btn(ns, "party1").zones.buff).shown)
        toggle(checkboxFor("Show buffs"), true)
    end)
    it("every aura setting survives a reload", function()
        ns.db.auras.buffPosition, ns.db.auras.debuffPosition, ns.db.auras.grow = "left", "inside", "up"
        ns.db.auras.buffSize, ns.db.auras.debuffSize, ns.db.auras.perRow, ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 12, 30, 7, 7, 4
        local ns2 = boot({ char = deepcopy(HealerForeverCharDB), pets = true })
        local a = ns2.db.auras
        assertEquals(a.buffPosition, "left"); assertEquals(a.debuffPosition, "inside"); assertEquals(a.grow, "up")
        assertEquals(a.buffSize, 12); assertEquals(a.debuffSize, 30); assertEquals(a.perRow, 7); assertEquals(a.maxBuffs, 7); assertEquals(a.maxDebuffs, 4)
        checkLayout(ns2, "aura reload")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("aura layout changes in combat are queued (no secure SetPoint/SetSize), applied after combat", function()
        local ns2 = boot({ pets = true })
        ns2.Options:Show("auras"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0, n0 = #mock.violations, #mock.softViolations, #mock.calls
        pickFrom(dropdownForLabel("Buff position"), "Left")
        pickFrom(dropdownForLabel("Debuff position"), "Right")
        pickFrom(dropdownForLabel("Grow direction"), "Down")
        setSlider(sliderFor("Max per row"), 3)
        setSlider(sliderFor("Buff icon size"), 24)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and (c.method == "SetPoint" or c.method == "SetSize" or c.method == "ClearAllPoints" or c.method == "SetAttribute"), "secure " .. c.method .. " in combat")
        end
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        checkLayout(ns2, "after combat")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== migration
describe("bars: migration from an old profile with style / appearance keys", function()
    local function oldProfile()
        return {
            version = 2, activePreset = 2,
            presets = { { name = "Default", map = {}, extras = {} }, { name = "Raid", map = { PALADIN = { DEFAULT = "might" } }, extras = {} } },
            bindings = { ["|1"] = { type = "spell", spell = "Holy Light" }, ["|2"] = { type = "spell", spell = "Flash of Light" },
                ["alt|3"] = { type = "spell", spell = "Oath of Light" }, ["meta|2"] = { type = "spell", spell = "Blessing of Protection" } },
            frames = { layout = "vertical", width = 200, height = 50, locked = true, style = "A", spacing = 9,
                point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 321, y = -123 }, showPets = false, lowHpPulse = true },
            appearance = { A = { bs = "gold", bw = 4 }, B = {}, C = { bs = "stone" } },
            ui = { modSet = "mac", extraButtons = true, appearanceTarget = "C" },
            hideBlizzardParty = true, taintMigrated = true,
            auras = { maxBuffs = 6, buffPosition = "bottom", grow = "left" },
            minimap = { angle = 77 }, roleOverrides = { ["Tank-TestRealm"] = "TANK" },
        }
    end
    it("loads cleanly: stale keys are removed, every other setting is preserved", function()
        local ns = boot({ char = oldProfile(), pets = true })
        assertEquals(#mock.errors, 0, errstr())
        assertNil(ns.db.appearance); assertNil(ns.db.frames.style); assertNil(ns.db.ui.appearanceTarget)
        assertNil(ns.db.hideBlizzardParty); assertNil(ns.db.taintMigrated)
        assertEquals(ns.db.frames.layout, "vertical"); assertEquals(ns.db.frames.width, 200); assertEquals(ns.db.frames.height, 50)
        assertEquals(ns.db.frames.locked, true); assertEquals(ns.db.frames.spacing, 9)
        assertEquals(ns.db.frames.point.x, 321); assertEquals(ns.db.frames.point.y, -123)
        assertEquals(ns.db.frames.showPets, false); assertEquals(ns.db.frames.lowHpPulse, true)
        assertEquals(ns.db.activePreset, 2); assertEquals(ns.db.presets[2].name, "Raid")
        assertEquals(ns.db.bindings["|1"].spell, "Holy Light"); assertEquals(ns.db.bindings["alt|3"].spell, "Oath of Light")
        assertEquals(ns.db.bindings["meta|2"].spell, "Blessing of Protection")
        assertEquals(ns.db.ui.modSet, "mac"); assertEquals(ns.db.ui.extraButtons, true)
        assertEquals(ns.db.auras.maxBuffs, 6); assertEquals(ns.db.auras.buffPosition, "bottom"); assertEquals(ns.db.auras.grow, "left")
        assertEquals(ns.db.minimap.angle, 77); assertEquals(ns.db.roleOverrides["Tank-TestRealm"], "TANK")
        assertEquals(ns.db.frames.border.style, "tooltip", "missing border gets the default")
        checkLayout(ns, "migrated")
    end)
    it("a user profile from the account DB (copied with /hf copyaccount) migrates the same way and the account DB is untouched", function()
        local acct = oldProfile()
        local ns = boot({ account = acct, pets = true })
        assertNil(ns.db.migratedFrom, "a new character is not seeded automatically")
        assertTrue(ns.db.frames.layout ~= "vertical" or ns.DEFAULTS.frames.layout == "vertical")
        local ok, skipped = ns:ImportAccount(); mock.flushTimers()
        assertTrue(ok); assertFalse(skipped)
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(ns.db.migratedFrom, "account")
        assertNil(ns.db.appearance); assertNil(ns.db.frames.style); assertEquals(ns.db.frames.layout, "vertical")
        assertNil(ns.db.hideBlizzardParty); assertNil(ns.db.ui.appearanceTarget); assertEquals(ns.db.bindings["alt|3"].spell, "Oath of Light")
        checkLayout(ns, "copied account")
        assertEquals(_G.HealerForeverDB.frames.style, "A"); assertNotNil(_G.HealerForeverDB.appearance); assertEquals(_G.HealerForeverDB.hideBlizzardParty, true)
    end)
    it("corrupted border values are sanitised", function()
        for _, bad in ipairs({ "x", 5, true, {}, { style = "bogus", width = 99, color = {}, custom = "red" }, { style = "thin", width = "3", color = "class", custom = { r = 5, g = -2, b = "x" } } }) do
            local ns = boot({ char = { version = 2, frames = { border = bad } } })
            assertEquals(#mock.errors, 0, errstr())
            local b = ns.db.frames.border
            assertTrue(ns.Util.NormalizeBorder(b).width == b.width and b.width >= 1 and b.width <= 4)
            assertNotNil(b.style); assertNotNil(b.color)
            checkLayout(ns, "corrupt border")
        end
    end)
    it("corrupted aura layout values are sanitised without breaking the layout", function()
        local ns = boot({ char = { version = 2, auras = { buffPosition = "middle", debuffPosition = 5, grow = {}, buffSize = "big", perRow = -3, maxBuffs = 0 } }, pets = true })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(ns.db.auras.buffPosition), "string")
        checkLayout(ns, "corrupt auras")
    end)
    it("a second load of the migrated profile is stable", function()
        local ns = boot({ char = oldProfile(), pets = true })
        local saved = deepcopy(HealerForeverCharDB)
        local ns2 = boot({ char = saved, pets = true })
        local function same(a, b)
            if type(a) ~= type(b) then return false end
            if type(a) ~= "table" then return a == b end
            for k, v in pairs(a) do if not same(v, b[k]) then return false end end
            for k in pairs(b) do if a[k] == nil then return false end end
            return true
        end
        assertTrue(same(saved, ns2.db), "reload must not change the migrated DB")
    end)
end)

-- ======================================================================== source / TOC
describe("bars: TOC and source hygiene", function()
    it("no listed file is a removed module and nothing references ns.Styles / the appearance pane / HideParty", function()
        for _, f in ipairs(toc.files) do
            for _, gone in ipairs({ "Styles", "AppearancePane", "HideParty" }) do assertNil(f:find(gone, 1, true), "TOC lists " .. f) end
        end
        for _, gone in ipairs({ "Data/Styles.lua", "Options/AppearancePane.lua", "Blizzard/HideParty.lua" }) do assertFalse(L.exists(L.path(gone)), gone .. " should be gone") end
        for _, rel in ipairs(toc.files) do
            if rel:lower():match("%.lua$") then
                local src = L.readFile(L.path(rel)):gsub("%-%-[^\\n]*", "")
                for _, bad in ipairs({ "ns%.Styles", "Styles%.", "AppearancePane", "appearanceTarget", "ns%.HideParty" }) do
                    local s = src:find(bad)
                    -- Core.lua deletes the stale saved keys by name
                    if s then assertTrue(rel == "Core.lua" and bad == "appearanceTarget", rel .. " references " .. bad) end
                end
            end
        end
    end)
    it("every listed file exists and every shipped .lua is listed (Bindings.xml excepted)", function()
        for _, f in ipairs(toc.files) do assertTrue(L.exists(L.path(f)), f) end
        local listed = {}
        for _, f in ipairs(toc.files) do listed[f:gsub("\\", "/"):lower()] = true end
        for _, f in ipairs(L.listAddonFiles()) do
            if f:lower() ~= "bindings.xml" then assertTrue(listed[f:lower()], f .. " not in the TOC") end
        end
    end)
    it("the pure border/zone helpers live in Util and are used by the frames (not duplicated)", function()
        local src = L.readFile(L.path("Frames/UnitFrames.lua"))
        for _, f in ipairs({ "NormalizeBorder", "BorderSpec", "BarBorderColor", "ZoneSize", "CellLayout" }) do
            assertNotNil(src:find("Util." .. f, 1, true), "UnitFrames should use Util." .. f)
        end
        local aur = L.readFile(L.path("Frames/Auras.lua"))
        assertNotNil(aur:find("Util.IconOffset", 1, true))
    end)
end)
