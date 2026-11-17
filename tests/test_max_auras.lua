-- Max buffs 1-20 (default 4) and max debuffs 1-12 (default 3): sanitising, the two sliders, the container's maxFrameCount, and zero-overlap
-- geometry at the new maxima (20 / 12) in auto and fixed per-row layouts (several rows), for the container path and the hand-drawn fallback.
local L = require("loader")
local mock = require("wow_mock")
local G = require("aura_geo")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end
local function deepcopy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = deepcopy(v) end return o end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.containers then mock.enableContainers() end
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function apply(ns) ns:Changed("frames"); mock.flushTimers(); if mock.refreshContainers then mock.refreshContainers() end end
local function button(ns, u) return ns.UnitFrames.byUnit[u] end
local function container(ns, u, kind) return button(ns, u).auraContainers[kind] end
local function frames(c) return rawget(c.frame, "__container").groups[c.kind].frames end
local function sliderFor(text) for _, f in ipairs(mock.frames) do if f.slider and f.label and st(f.label).text == text then return f end end error("slider " .. text) end
local function setSlider(sf, v) st(sf.slider).value = v; st(sf.slider).scripts.OnValueChanged(sf.slider, v, true); mock.flushTimers() end
local function buff(i) return { spellId = 6000 + i, name = "B" .. i, icon = 100 + i, duration = 300, expirationTime = S.now + 200, isHelpful = true, isHarmful = false, auraInstanceID = 100 + i, sourceUnit = "player" } end
local function debuff(i) return { spellId = 7000 + i, name = "D" .. i, icon = 300 + i, duration = 60, expirationTime = S.now + 40, isHarmful = true, isHelpful = false, dispelName = (i % 2 == 1) and "Magic" or nil, auraInstanceID = 200 + i } end
local function fill(u, nb, nd) local l = {} for i = 1, nb do l[#l + 1] = buff(i) end for i = 1, nd do l[#l + 1] = debuff(i) end S.auras[u] = l end
local function shownCount(ns, u, kind)
    local n = 0
    if button(ns, u).auraContainers then for _, f in ipairs(frames(container(ns, u, kind))) do if st(f).shown then n = n + 1 end end
    else for _, icon in ipairs(kind == "buff" and button(ns, u).buffIcons or button(ns, u).debuffIcons) do if st(icon).shown then n = n + 1 end end end
    return n
end

-- ======================================================================== defaults + sanitising
describe("max auras: defaults and clamps", function()
    it("defaults are 4 buffs and 3 debuffs", function()
        local ns = boot()
        assertEquals(ns.db.auras.maxBuffs, 4); assertEquals(ns.db.auras.maxDebuffs, 3)
        assertEquals(ns.DEFAULTS.auras.maxBuffs, 4); assertEquals(ns.DEFAULTS.auras.maxDebuffs, 3)
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.auras == nil or (HealerForeverCharDB.auras.maxBuffs == nil and HealerForeverCharDB.auras.maxDebuffs == nil), "defaults are not saved")
    end)
    it("saved maxBuffs: 1-20 kept, 0 / negative -> 1, above 20 -> 20, junk -> the default 4", function()
        for _, c in ipairs({ { 1, 1 }, { 4, 4 }, { 8, 8 }, { 12, 12 }, { 20, 20 }, { 0, 1 }, { -7, 1 }, { 21, 20 }, { 99, 20 }, { 1e9, 20 }, { "x", 4 }, { true, 4 }, { {}, 4 } }) do
            local ns = boot({ char = { version = 4, auras = { maxBuffs = c[1] } } })
            assertEquals(ns.db.auras.maxBuffs, c[2], "saved " .. tostring(c[1]))
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
    it("saved maxDebuffs: 1-12 kept, 0 / negative -> 1, above 12 -> 12, junk -> the default 3", function()
        for _, c in ipairs({ { 1, 1 }, { 3, 3 }, { 6, 6 }, { 12, 12 }, { 0, 1 }, { -2, 1 }, { 13, 12 }, { 50, 12 }, { 1e9, 12 }, { "x", 3 }, { false, 3 }, { {}, 3 } }) do
            local ns = boot({ char = { version = 4, auras = { maxDebuffs = c[1] } } })
            assertEquals(ns.db.auras.maxDebuffs, c[2], "saved " .. tostring(c[1]))
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
    it("NaN is clamped into range too; the old maxima (8 / 6) are inside the new ranges and stay as saved", function()
        local ns = boot({ char = { version = 4, auras = { maxBuffs = 0 / 0, maxDebuffs = 0 / 0 } } })
        assertTrue(ns.db.auras.maxBuffs >= 1 and ns.db.auras.maxBuffs <= 20); assertTrue(ns.db.auras.maxDebuffs >= 1 and ns.db.auras.maxDebuffs <= 12)
        local ns2 = boot({ char = { version = 4, auras = { maxBuffs = 8, maxDebuffs = 6 } } })
        assertEquals(ns2.db.auras.maxBuffs, 8); assertEquals(ns2.db.auras.maxDebuffs, 6)
    end)
    it("changed values save sparsely and survive a reload; back to the default omits them", function()
        local ns = boot()
        ns.db.auras.maxBuffs = 20; ns.db.auras.maxDebuffs = 12
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(saved.auras.maxBuffs, 20); assertEquals(saved.auras.maxDebuffs, 12)
        local ns2 = boot({ char = saved })
        assertEquals(ns2.db.auras.maxBuffs, 20); assertEquals(ns2.db.auras.maxDebuffs, 12)
        ns2.db.auras.maxBuffs = 4; ns2.db.auras.maxDebuffs = 3
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.auras == nil or (HealerForeverCharDB.auras.maxBuffs == nil and HealerForeverCharDB.auras.maxDebuffs == nil))
    end)
end)

-- ======================================================================== sliders
describe("max auras: the sliders", function()
    it("'Max buffs' runs 1-20 and 'Max debuffs' 1-12, show the saved values, and set them live", function()
        local ns = boot()
        ns.Options:Show("auras"); mock.flushTimers()
        local sb, sd = sliderFor("Max buffs"), sliderFor("Max debuffs")
        assertEquals(st(sb.slider).min, 1); assertEquals(st(sb.slider).max, 20)
        assertEquals(st(sd.slider).min, 1); assertEquals(st(sd.slider).max, 12)
        assertEquals(st(sb.slider).value, 4); assertEquals(st(sd.slider).value, 3)
        setSlider(sb, 20); setSlider(sd, 12)
        assertEquals(ns.db.auras.maxBuffs, 20); assertEquals(ns.db.auras.maxDebuffs, 12)
        setSlider(sb, 1); setSlider(sd, 1)
        assertEquals(ns.db.auras.maxBuffs, 1); assertEquals(ns.db.auras.maxDebuffs, 1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("every slider position 1..20 / 1..12 saves exactly that value and lays out without error", function()
        local ns = boot()
        ns.Options:Show("auras"); mock.flushTimers()
        for v = 1, 20 do setSlider(sliderFor("Max buffs"), v); assertEquals(ns.db.auras.maxBuffs, v) end
        for v = 1, 12 do setSlider(sliderFor("Max debuffs"), v); assertEquals(ns.db.auras.maxDebuffs, v) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("sliders work in combat (queued layout), no protected calls", function()
        local ns = boot()
        ns.Options:Show("auras"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        setSlider(sliderFor("Max buffs"), 15); setSlider(sliderFor("Max debuffs"), 9)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.auras.maxBuffs, 15); assertEquals(ns.db.auras.maxDebuffs, 9); assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== icons shown
describe("max auras: the number of shown icons follows the maximum (container and fallback)", function()
    for _, containers in ipairs({ true, false }) do
        it((containers and "container" or "fallback") .. ": 20 buffs / 12 debuffs at the maxima, fewer at lower maxima, never more than the maximum", function()
            local ns = boot({ containers = containers })
            fill("party1", 25, 15)
            ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 20, 12; apply(ns)
            if not containers then mock.fire("UNIT_AURA", "party1"); mock.flushTimers() end
            assertEquals(shownCount(ns, "party1", "buff"), 20); assertEquals(shownCount(ns, "party1", "debuff"), 12)
            ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 7, 5; apply(ns)
            if not containers then mock.fire("UNIT_AURA", "party1"); mock.flushTimers() end
            assertEquals(shownCount(ns, "party1", "buff"), 7); assertEquals(shownCount(ns, "party1", "debuff"), 5)
            ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 1, 1; apply(ns)
            if not containers then mock.fire("UNIT_AURA", "party1"); mock.flushTimers() end
            assertEquals(shownCount(ns, "party1", "buff"), 1); assertEquals(shownCount(ns, "party1", "debuff"), 1)
            assertEquals(#mock.errors, 0, errstr())
        end)
    end
    it("container: maxFrameCount equals the slider value, frames exist up front and the group is re-configured when it changes", function()
        local ns = boot({ containers = true })
        for _, c in ipairs({ { 20, 12 }, { 1, 1 }, { 10, 6 }, { 4, 3 } }) do
            ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = c[1], c[2]; apply(ns)
            local gb = rawget(container(ns, "party1", "buff").frame, "__container").groups.buff
            local gd = rawget(container(ns, "party1", "debuff").frame, "__container").groups.debuff
            assertEquals(gb.maxFrameCount, c[1]); assertEquals(gd.maxFrameCount, c[2])
            assertTrue(#gb.frames >= c[1] and #gd.frames >= c[2], "frames exist for every allowed icon (created at layout time, never in combat)")
            assertEquals(ns.Auras.ContainerGeometry("buff", ns.db.auras).max, c[1]); assertEquals(ns.Auras.ContainerGeometry("debuff", ns.db.auras).max, c[2])
        end
        assertEquals(#mock.createdInCombat, 0)
    end)
    it("raising the maximum IN COMBAT creates no frames in combat; they are created after combat", function()
        local ns = boot({ containers = true })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        ns.db.auras.maxBuffs = 20; ns:Changed("frames"); mock.flushTimers()
        assertEquals(#mock.createdInCombat, 0)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertTrue(#frames(container(ns, "party1", "buff")) >= 20)
    end)
    it("the fallback pre-creates icons for the maximum at layout time (none created in combat)", function()
        local ns = boot()
        ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 20, 12; apply(ns)
        assertTrue(#button(ns, "party1").buffIcons >= 20 and #button(ns, "party1").debuffIcons >= 12)
        assertEquals(#mock.createdInCombat, 0)
    end)
end)

-- ======================================================================== geometry at 20 / 12
describe("max auras: zero-overlap geometry at the maxima (auto and fixed per row, several rows)", function()
    local function containerItems(ns, units)
        local root = ns.UnitFrames.anchor
        local tiles = {}
        for _, u in ipairs(units) do
            local b = button(ns, u)
            local items = { { kind = "bar", rect = G.rect(b, root), owner = u } }
            for _, kind in ipairs({ "buff", "debuff" }) do
                local g = ns.Auras.ContainerGeometry(kind, ns.db.auras)
                local zoneRect = G.rect(b.zones[kind], root)
                if not g.inside then items[#items + 1] = { kind = "zone", rect = zoneRect, owner = u, zoneKind = kind } end
                for i, f in ipairs(frames(container(ns, u, kind))) do
                    if st(f).shown then
                        local r = G.rect(f, root)
                        items[#items + 1] = { kind = "icon", rect = r, owner = u, zoneKind = kind, zone = (not g.inside) and zoneRect or nil, inside = g.inside, id = kind .. i }
                        if g.timerH > 0 then
                            items[#items + 1] = { kind = "timer", rect = { l = r.l, r = r.r, t = r.b + 1, b = r.b + g.timerH }, owner = u, zoneKind = kind, zone = (not g.inside) and zoneRect or nil, id = kind .. i }
                        end
                    end
                end
            end
            tiles[#tiles + 1] = items
        end
        return tiles
    end
    local function problems(tiles, label)
        local bad = {}
        local function name(it) return it.owner .. ":" .. it.kind .. (it.id and ("/" .. it.id) or it.zoneKind and ("/" .. it.zoneKind) or "") end
        for _, items in ipairs(tiles) do
            local bar
            for _, it in ipairs(items) do if it.kind == "bar" then bar = it end end
            for _, it in ipairs(items) do
                if (it.kind == "icon" or it.kind == "timer") and it.zone and not G.inside(it.rect, it.zone) then bad[#bad + 1] = label .. " " .. name(it) .. " leaves its zone" end
                if (it.kind == "icon" or it.kind == "timer") and not it.inside and bar and G.overlap(it.rect, bar.rect) then bad[#bad + 1] = label .. " " .. name(it) .. " overlaps its bar" end
            end
            for i = 1, #items do for j = i + 1, #items do
                local a, b = items[i], items[j]
                local skip = a.kind == "bar" or b.kind == "bar" or a.kind == "zone" or b.kind == "zone" or (a.id and a.id == b.id and a.zoneKind == b.zoneKind) or (a.inside and b.inside)
                if not skip and G.overlap(a.rect, b.rect) then bad[#bad + 1] = label .. " " .. name(a) .. " overlaps " .. name(b) end
            end end
        end
        for i = 1, #tiles do for j = i + 1, #tiles do
            for _, a in ipairs(tiles[i]) do for _, b in ipairs(tiles[j]) do
                if (not a.inside or a.kind == "bar") and (not b.inside or b.kind == "bar") and G.overlap(a.rect, b.rect) then
                    bad[#bad + 1] = label .. " " .. name(a) .. " overlaps " .. name(b)
                end
            end end
        end end
        return bad
    end
    local UNITS = { "player", "party1", "party2" }
    local function run(containers, perRow, pos, grow, layout)
        local ns = boot({ containers = containers })
        local a = ns.db.auras
        a.maxBuffs, a.maxDebuffs, a.perRow, a.grow, a.timerPos = 20, 12, perRow, grow, "below"
        a.buffPosition, a.debuffPosition = pos, pos == "top" and "bottom" or "top"
        ns.db.frames.layout = layout
        for _, u in ipairs(UNITS) do fill(u, 20, 12) end
        apply(ns)
        if not containers then for _, u in ipairs(UNITS) do mock.fire("UNIT_AURA", u) end; mock.flushTimers() end
        local label = string.format("%s perRow=%s %s %s %s", containers and "container" or "fallback", tostring(perRow), pos, grow, layout)
        local bad
        if containers then bad = problems(containerItems(ns, UNITS), label) else bad = G.check(ns, UNITS, label) end
        return ns, bad
    end
    it("container path: 20 buffs / 12 debuffs, auto and fixed per row (4, 7), top / left zones, grow right / down, both layouts", function()
        local allBad, runs = {}, 0
        for _, perRow in ipairs({ 0, 4, 7 }) do
            for _, pos in ipairs({ "top", "left" }) do
                for _, grow in ipairs({ "right", "down" }) do
                    for _, layout in ipairs({ "horizontal", "vertical" }) do
                        local ns, bad = run(true, perRow, pos, grow, layout)
                        runs = runs + 1
                        for _, b in ipairs(bad) do allBad[#allBad + 1] = b end
                        assertEquals(shownCount(ns, "party1", "buff"), 20); assertEquals(shownCount(ns, "party1", "debuff"), 12)
                    end
                end
            end
        end
        assertEquals(runs, 3 * 2 * 2 * 2)
        assertEquals(#allBad, 0, #allBad .. " problems, first: " .. tostring(allBad[1]) .. "\n" .. tostring(allBad[2]))
    end)
    it("fallback path: the same maxima, auto and fixed per row", function()
        local allBad = {}
        for _, perRow in ipairs({ 0, 4, 7 }) do
            for _, pos in ipairs({ "top", "left" }) do
                for _, grow in ipairs({ "right", "down" }) do
                    local ns, bad = run(false, perRow, pos, grow, "horizontal")
                    for _, b in ipairs(bad) do allBad[#allBad + 1] = b end
                    assertEquals(shownCount(ns, "party1", "buff"), 20)
                end
            end
        end
        assertEquals(#allBad, 0, #allBad .. " problems, first: " .. tostring(allBad[1]))
    end)
    it("fixed per row makes several rows: 20 icons at 4 per row = 5 rows (container zone height grows to fit)", function()
        local ns = run(true, 4, "top", "right", "horizontal")
        local g = ns.Auras.ContainerGeometry("buff", ns.db.auras)
        assertEquals(g.perRow, 4)
        local z = st(button(ns, "party1").zones.buff)
        local w, h = ns.Util.ZoneSize(g.size, 4, 20, g.grow, 0, g.timerH, g.gap)
        assertEquals(z.w, w); assertEquals(z.h, h)
        local rows = {}
        for _, f in ipairs(frames(container(ns, "party1", "buff"))) do if st(f).shown then rows[st(f).points[#st(f).points][5]] = true end end
        local n = 0
        for _ in pairs(rows) do n = n + 1 end
        assertEquals(n, 5)
    end)
    it("auto mode at 20 buffs: wraps by the bar width (180px / 16px icons = 9 per row = 3 rows), never one endless line", function()
        local ns = run(true, 0, "top", "right", "horizontal")
        local g = ns.Auras.ContainerGeometry("buff", ns.db.auras)
        assertEquals(g.perRow, math.min(20, math.floor((ns.db.frames.width - 4) / (ns.db.auras.buffSize + ns.Util.ICON_GAP))))
        assertTrue(g.perRow < 20)
        local rows = {}
        for _, f in ipairs(frames(container(ns, "party1", "buff"))) do if st(f).shown then rows[st(f).points[#st(f).points][5]] = true end end
        local n = 0
        for _ in pairs(rows) do n = n + 1 end
        assertEquals(n, math.ceil(20 / g.perRow))
    end)
    it("everything at once in combat and with everything secret: no errors, no protected calls", function()
        local ns = boot({ containers = true })
        ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 20, 12; apply(ns)
        for _, u in ipairs(UNITS) do fill(u, 20, 12) end
        S.combat = true; S.secretAll = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.refreshContainers(); mock.advance(3)
        S.combat = false; S.secretAll = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
end)
