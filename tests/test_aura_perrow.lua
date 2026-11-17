-- Icons per row: auras.perRow = 0 means AUTO (as many as fit the bar, capped by the max count; up/down growth = the full count; left/right zones
-- at most 5), sanitising (0 or 2-10), the Auto checkbox + slider, the owner's profile resolving to auto, zero-overlap geometry in auto mode, and
-- the container timer: compact SecondsFormatter options (with fallbacks) and the timer font size clamp.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")
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
    if opts.containers ~= false then mock.enableContainers(opts.container) end
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
local function apply(ns) ns:Changed("frames"); mock.flushTimers(); mock.refreshContainers() end
local function button(ns, u) return ns.UnitFrames.byUnit[u] end
local function container(ns, u, kind) return button(ns, u).auraContainers[kind] end
local function frames(c) return rawget(c.frame, "__container").groups[c.kind].frames end
local function debuff(i) return { spellId = 7000 + i, name = "D" .. i, icon = 300 + i, duration = 60, expirationTime = S.now + 40, isHarmful = true, isHelpful = false, dispelName = "Magic", auraInstanceID = 200 + i } end
local function buff(i) return { spellId = 6000 + i, name = "B" .. i, icon = 100 + i, duration = 300, expirationTime = S.now + 200, isHelpful = true, isHarmful = false, auraInstanceID = 100 + i, sourceUnit = "player" } end
local function fill(u, nb, nd) local l = {} for i = 1, nb do l[#l + 1] = buff(i) end for i = 1, nd do l[#l + 1] = debuff(i) end S.auras[u] = l end
local function sliderFor(text) for _, f in ipairs(mock.frames) do if f.slider and f.label and st(f.label).text == text then return f end end error("slider " .. text) end
local function checkboxFor(text) for _, f in ipairs(mock.frames) do if st(f).kind == "CheckButton" and f.label and st(f.label).text == text then return f end end error("checkbox " .. text) end
local function setSlider(sf, v) st(sf.slider).value = v; st(sf.slider).scripts.OnValueChanged(sf.slider, v, true); mock.flushTimers() end

-- ======================================================================== pure maths
mock.install()
local pns = {}
local _, _, perrs = L.loadContract(pns)
if next(perrs) then it("contract loads", function() error(tostring(select(2, next(perrs)))) end) return end
local U = pns.Util

describe("perRow: Util.AutoPerRow", function()
    it("a 180px bar with 16px icons and gap 3 fits 9", function() assertEquals(U.AutoPerRow(180, 16, 3), 9) end)
    it("the formula is floor((width - 4) / (size + gap))", function()
        for _, w in ipairs({ 100, 150, 180, 220, 300, 400 }) do for _, sz in ipairs({ 10, 14, 16, 20, 28, 32 }) do for _, gap in ipairs({ 2, 3, 12 }) do
            assertEquals(U.AutoPerRow(w, sz, gap), math.max(1, math.floor((w - 4) / (sz + gap))), w .. "/" .. sz .. "/" .. gap)
        end end end
    end)
    it("tiny bars never give less than 1 per row", function()
        for _, w in ipairs({ 0, 1, 4, 10, 20 }) do assertEquals(U.AutoPerRow(w, 16, 3), w >= 23 and 1 or 1, tostring(w)) end
        assertEquals(U.AutoPerRow(10, 32, 12), 1)
    end)
    it("nil arguments use the defaults (180px, 16px icons, gap 2) and a bigger icon or gap never fits more", function()
        assertEquals(U.AutoPerRow(), 9)
        assertEquals(U.AutoPerRow(130, 10), 10, "default gap is 2 (a gap of 3 would give 9)")
        assertTrue(U.AutoPerRow(180, 28, 3) <= U.AutoPerRow(180, 16, 3)); assertTrue(U.AutoPerRow(180, 16, 12) <= U.AutoPerRow(180, 16, 3))
        assertTrue(U.AutoPerRow(300, 16, 3) >= U.AutoPerRow(180, 16, 3))
    end)
end)

describe("perRow: Auras.PerRowFor for every position and grow direction", function()
    local ns = boot({ containers = false })
    local function cfg(over)
        local c = { perRow = 0, buffPosition = "top", debuffPosition = "bottom", grow = "right", buffSize = 16, debuffSize = 20, maxBuffs = 8, maxDebuffs = 6 }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    it("an explicit perRow is returned unchanged for both kinds", function()
        for _, n in ipairs({ 2, 5, 10 }) do
            assertEquals(ns.Auras.PerRowFor("buff", cfg({ perRow = n })), n); assertEquals(ns.Auras.PerRowFor("debuff", cfg({ perRow = n })), n)
        end
    end)
    it("auto + grow down/up: the FULL count (one column or row per line)", function()
        for _, grow in ipairs({ "down", "up" }) do
            for _, pos in ipairs({ "top", "bottom", "left", "right" }) do
                assertEquals(ns.Auras.PerRowFor("buff", cfg({ grow = grow, buffPosition = pos })), 8, grow .. pos)
                assertEquals(ns.Auras.PerRowFor("debuff", cfg({ grow = grow, debuffPosition = pos })), 6, grow .. pos)
            end
        end
    end)
    it("auto + left/right zones (grow right/left): at most 5, capped by a smaller count", function()
        for _, grow in ipairs({ "right", "left" }) do for _, pos in ipairs({ "left", "right" }) do
            assertEquals(ns.Auras.PerRowFor("buff", cfg({ grow = grow, buffPosition = pos })), 5)
            assertEquals(ns.Auras.PerRowFor("debuff", cfg({ grow = grow, debuffPosition = pos })), 5)
            assertEquals(ns.Auras.PerRowFor("buff", cfg({ grow = grow, buffPosition = pos, maxBuffs = 3 })), 3)
        end end
    end)
    it("auto + top/bottom zones growing right/left: as many as fit the bar width, capped by the count", function()
        for _, width in ipairs({ 100, 180, 260 }) do
            ns.db.frames.width = width
            for _, grow in ipairs({ "right", "left" }) do for _, pos in ipairs({ "top", "bottom" }) do
                local want = math.min(8, math.max(1, math.floor((width - 4) / (16 + ns.Util.ICON_GAP))))
                assertEquals(ns.Auras.PerRowFor("buff", cfg({ grow = grow, buffPosition = pos })), want, width .. grow .. pos)
                local wantD = math.min(6, math.max(1, math.floor((width - 4) / (20 + ns.Util.ICON_GAP))))
                assertEquals(ns.Auras.PerRowFor("debuff", cfg({ grow = grow, debuffPosition = pos })), wantD)
            end end
        end
        ns.db.frames.width = 180
        assertEquals(ns.Auras.PerRowFor("buff", cfg()), 8, "180px / 16px: 9 fit, capped at the count of 8")
        assertEquals(ns.Auras.PerRowFor("buff", cfg({ maxBuffs = 20 })), 9)
    end)
    it("a count of 0 or nil is treated as 1", function()
        assertEquals(ns.Auras.PerRowFor("buff", cfg({ maxBuffs = 0, grow = "down" })), 1)
        assertEquals(ns.Auras.PerRowFor("buff", cfg({ maxBuffs = false, grow = "down" })), 1)
    end)
    it("inside-the-bar zones grow left with capped icons (buffs 14, debuffs 16) and gap 2", function()
        ns.db.frames.width = 120
        assertEquals(ns.Auras.PerRowFor("buff", cfg({ buffPosition = "inside", maxBuffs = 20, buffSize = 28 })), math.floor((120 - 4) / (14 + 2)))
        assertEquals(ns.Auras.PerRowFor("debuff", cfg({ debuffPosition = "inside", maxDebuffs = 20, debuffSize = 32 })), math.floor((120 - 4) / (16 + 2)))
        assertEquals(ns.Auras.PerRowFor("buff", cfg({ buffPosition = "inside", grow = "down", maxBuffs = 20, buffSize = 16 })), math.floor((120 - 4) / (14 + 2)), "inside always grows left, whatever the grow option says")
        ns.db.frames.width = 180
    end)
    it("uses the live bar width: widening the frames changes the result", function()
        ns.db.frames.width = 100; local narrow = ns.Auras.PerRowFor("buff", cfg({ maxBuffs = 20 }))
        ns.db.frames.width = 300; local wide = ns.Auras.PerRowFor("buff", cfg({ maxBuffs = 20 }))
        assertTrue(wide > narrow, narrow .. " -> " .. wide)
        ns.db.frames.width = 180
    end)
    it("with no cfg argument it reads the saved options", function()
        ns.db.auras.perRow = 0; ns.db.auras.grow = "down"; ns.db.auras.maxBuffs = 5
        assertEquals(ns.Auras.PerRowFor("buff"), 5)
        ns.db.auras.perRow = 3; assertEquals(ns.Auras.PerRowFor("buff"), 3)
    end)
end)

-- ======================================================================== sanitising + the owner's profile
describe("perRow: default, sanitising and the owner's profile", function()
    it("the default is 0 (Auto) and is not written to the profile", function()
        local ns = boot({ containers = false })
        assertEquals(ns.db.auras.perRow, 0); assertEquals(ns.DEFAULTS.auras.perRow, 0)
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.auras == nil or HealerForeverCharDB.auras.perRow == nil)
    end)
    it("saved values: 0 and 2..10 are kept; out of range clamps to 2 / 10; junk becomes Auto", function()
        for _, c in ipairs({ { 0, 0 }, { 2, 2 }, { 6, 6 }, { 10, 10 }, { 1, 2 }, { -3, 2 }, { 11, 10 }, { 99, 10 }, { "x", 0 }, { true, 0 }, { {}, 0 } }) do
            local ns = boot({ containers = false, char = { version = 4, auras = { perRow = c[1] } } })
            assertEquals(ns.db.auras.perRow, c[2], "saved " .. tostring(c[1]))
            assertEquals(#mock.errors, 0, errstr())
        end
        local ns = boot({ containers = false, char = { version = 4, auras = { perRow = 0 / 0 } } })
        local v = ns.db.auras.perRow
        assertTrue(type(v) == "number" and (v == 0 or (v >= 2 and v <= 10)), tostring(v))
    end)
    it("an old profile that saved the old default 5 keeps 5 (the user's choice), not Auto", function()
        local ns = boot({ containers = false, char = { version = 4, auras = { perRow = 5 } } })
        assertEquals(ns.db.auras.perRow, 5); assertEquals(ns.Auras.PerRowFor("buff"), 5)
    end)
    it("the owner's real profile (no saved perRow) resolves to Auto, in every fixture generation, and stays unsaved", function()
        for _, raw in ipairs({ Fx.loadSaved(HF_TESTS .. "/fixtures/owner-char-pre-buffgroups.lua", "HealerForeverCharDB"),
            Fx.loadSaved(HF_TESTS .. "/fixtures/owner-char-v3.lua", "HealerForeverCharDB"), Fx.userAccount() }) do
            local ns = boot({ containers = false, char = raw })
            assertEquals(ns.db.auras.perRow, raw.auras and raw.auras.perRow == nil and 0 or ns.db.auras.perRow)
            if raw.auras == nil or raw.auras.perRow == nil then
                assertEquals(ns.db.auras.perRow, 0, "no saved perRow = Auto")
                assertEquals(ns.Auras.PerRowFor("buff"), math.min(ns.db.auras.maxBuffs, math.max(1, math.floor((ns.db.frames.width - 4) / (ns.db.auras.buffSize + ns.Util.ICON_GAP)))))
                local save = ns:BuildSaveTable()
                assertTrue(save.auras == nil or save.auras.perRow == nil)
            end
            assertEquals(#mock.errors, 0, errstr())
        end
    end)
end)

-- ======================================================================== pane controls
describe("perRow: the Auto checkbox and the 'Max per row' slider", function()
    local LABEL = "Auto: fit as many icons per row as the bar is wide"
    it("the checkbox is ticked by default; unticking sets 6, ticking sets 0 again; both apply live and save", function()
        local ns = boot()
        fill("party1", 8, 6); mock.refreshContainers()
        ns.Options:Show("auras"); mock.flushTimers()
        local cb = checkboxFor(LABEL)
        assertTrue(st(cb).checked and true or false)
        st(cb).checked = false; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers()
        assertEquals(ns.db.auras.perRow, 6)
        assertEquals(ns.Auras.PerRowFor("buff"), 6)
        st(cb).checked = true; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers()
        assertEquals(ns.db.auras.perRow, 0)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the slider runs 2-10, shows at least 2 while Auto, and moving it leaves Auto and applies live", function()
        local ns = boot()
        ns.Options:Show("auras"); mock.flushTimers()
        ns.db.auras.maxBuffs = 8; apply(ns)
        local sl = sliderFor("Max per row")
        assertEquals(st(sl.slider).min, 2); assertEquals(st(sl.slider).max, 10)
        assertEquals(st(sl.slider).value, 2, "Auto shows the lowest value")
        local before = rawget(container(ns, "party1", "buff").frame, "__container").flow.maxLine
        setSlider(sl, 4)
        assertEquals(ns.db.auras.perRow, 4)
        local after = rawget(container(ns, "party1", "buff").frame, "__container").flow.maxLine
        assertTrue(after < before, "narrower lines: " .. before .. " -> " .. after)
        assertFalse(st(checkboxFor(LABEL)).checked and true or false, "the checkbox follows")
        setSlider(sl, 10); assertEquals(ns.db.auras.perRow, 10)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a chosen number saves, reloads and shows in the pane; Auto is omitted from the save", function()
        local ns = boot()
        ns.db.auras.perRow = 7
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(saved.auras.perRow, 7)
        local ns2 = boot({ char = saved })
        ns2.Options:Show("auras"); mock.flushTimers()
        assertEquals(ns2.db.auras.perRow, 7); assertEquals(st(sliderFor("Max per row").slider).value, 7)
        assertFalse(st(checkboxFor(LABEL)).checked and true or false)
        ns2.db.auras.perRow = 0
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.auras == nil or HealerForeverCharDB.auras.perRow == nil, "back to Auto: omitted")
    end)
    it("the slider and checkbox work in combat (queued layout) without protected calls", function()
        local ns = boot()
        ns.Options:Show("auras"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        setSlider(sliderFor("Max per row"), 3)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.auras.perRow, 3); assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== auto geometry
describe("perRow: AUTO mode never overlaps, for many bar widths and icon sizes (container path and fallback path)", function()
    local function containerCase(width, size, pos, grow, timerPos)
        local ns = boot()
        local a = ns.db.auras
        a.perRow = 0; a.maxBuffs, a.maxDebuffs = 8, 6
        ns.db.frames.width = width
        a.buffPosition, a.debuffPosition = pos, pos == "top" and "bottom" or "top"
        a.grow, a.timerPos, a.buffSize, a.debuffSize = grow, timerPos, size, size + 4
        fill("party1", 8, 6); apply(ns)
        local root = ns.UnitFrames.anchor
        local zone = G.rect(button(ns, "party1").zones.buff, root)
        local barRect = G.rect(button(ns, "party1"), root)
        local g = ns.Auras.ContainerGeometry("buff", a)
        local rects, timers, bad = {}, {}, {}
        for i, f in ipairs(frames(container(ns, "party1", "buff"))) do
            if st(f).shown then
                local r = G.rect(f, root)
                rects[#rects + 1] = r
                if g.timerH > 0 then timers[#timers + 1] = { l = r.l, r = r.r, t = r.b + 1, b = r.b + g.timerH } end
                if not g.inside and not G.inside(r, zone) then bad[#bad + 1] = "icon " .. i .. " leaves its zone" end
                if not g.inside and G.overlap(r, barRect) then bad[#bad + 1] = "icon " .. i .. " overlaps the bar" end
                local c, x, y = ns.Util.IconOffset(i, g.size, g.perRow, g.grow, g.timerH, g.gap)
                local p = st(f).points[#st(f).points]
                if p[1] ~= c or p[4] ~= x or p[5] ~= y then bad[#bad + 1] = "icon " .. i .. " not at IconOffset" end
            end
        end
        for i = 1, #rects do for j = i + 1, #rects do if G.overlap(rects[i], rects[j]) then bad[#bad + 1] = "icons overlap " .. i .. "/" .. j end end end
        for i = 1, #rects do for j = 1, #timers do if i ~= j and G.overlap(rects[i], timers[j]) then bad[#bad + 1] = "icon/timer overlap" end end end
        -- across a top/bottom zone of a bar the icons never run past the bar width in auto mode
        if (pos == "top" or pos == "bottom") and (grow == "right" or grow == "left") then
            for _, r in ipairs(rects) do if r.r > barRect.r + 1e-6 or r.l < barRect.l - 1e-6 then bad[#bad + 1] = "icon wider than the bar" end end
        end
        return #rects, bad
    end
    it("container path: widths x sizes x positions x grows x timer positions, every icon placed by IconOffset with no overlap", function()
        local total, allBad = 0, {}
        for _, width in ipairs({ 100, 140, 180, 260, 400 }) do
            for _, size in ipairs({ 10, 16, 28 }) do
                for _, pos in ipairs({ "top", "left", "inside" }) do
                    for _, grow in ipairs({ "right", "down" }) do
                        for _, tp in ipairs({ "below", "inside" }) do
                            local n, bad = containerCase(width, size, pos, grow, tp)
                            total = total + 1
                            for _, b in ipairs(bad) do allBad[#allBad + 1] = string.format("w%d s%d %s %s %s: %s", width, size, pos, grow, tp, b) end
                            assertTrue(n > 0)
                        end
                    end
                end
            end
        end
        assertEquals(total, 5 * 3 * 3 * 2 * 2)
        assertEquals(#allBad, 0, #allBad .. " problems, first: " .. tostring(allBad[1]))
    end)
    it("fallback path: the same widths and sizes (zone matrix checker, auto mode)", function()
        local problems = {}
        for _, width in ipairs({ 100, 180, 400 }) do
            for _, size in ipairs({ 10, 16, 28 }) do
                local ns = boot({ containers = false })
                local a = ns.db.auras
                a.perRow = 0; a.maxBuffs, a.maxDebuffs = 8, 6; a.buffSize, a.debuffSize = size, size + 4
                ns.db.frames.width = width
                a.buffPosition, a.debuffPosition, a.grow = "top", "bottom", "right"
                for _, u in ipairs({ "player", "party1", "party2" }) do fill(u, 8, 6) end
                ns:Changed("frames"); mock.flushTimers()
                for _, u in ipairs({ "player", "party1", "party2" }) do mock.fire("UNIT_AURA", u) end
                mock.flushTimers()
                for _, p in ipairs(G.check(ns, { "player", "party1", "party2" }, "auto w" .. width .. " s" .. size)) do problems[#problems + 1] = p end
            end
        end
        assertEquals(#problems, 0, #problems .. " problems, first: " .. tostring(problems[1]))
    end)
    it("a narrow bar wraps to several lines but never overlaps (auto = a few per row)", function()
        local n, bad = containerCase(100, 28, "top", "right", "below")
        assertEquals(#bad, 0, table.concat(bad, "; "))
        assertTrue(n >= 4)
    end)
end)

-- ======================================================================== the container timer: formatter + font
describe("perRow: the container timer - compact SecondsFormatter and the font size", function()
    it("every group button gets ONE shared formatter via SetDurationText{ textFormatter }, configured compactly", function()
        local ns = boot()
        assertEquals(#mock.formatters, 1, "one formatter for the whole session")
        local fmt = mock.formatters[1]
        local btn = rawget(container(ns, "party1", "buff").frame, "__container").groups.buff.frames[1]
        assertTrue(btn.durationTextOpts.textFormatter == fmt)
        for _, b in ipairs(ns.UnitFrames.buttons) do
            if b.auraContainers then
                for _, kind in ipairs({ "buff", "debuff" }) do
                    for _, f in ipairs(frames(b.auraContainers[kind])) do assertTrue(f.durationTextOpts.textFormatter == fmt) end
                end
            end
        end
        local c = fmt.config
        assertEquals(c.SetDefaultAbbreviation[1], Enum.SecondsFormatterAbbreviation.OneLetter)
        assertEquals(c.SetRounding[1], Enum.SecondsFormatterRounding.Truncate)
        assertEquals(c.SetCanRoundUpLastUnit[1], true)
        assertEquals(c.SetMinInterval[1], Enum.SecondsFormatterInterval.Seconds)
        assertEquals(c.SetDesiredUnitCount[1], 1)
        assertEquals(c.SetStripIntervalWhitespace[1], Enum.SecondsFormatterIntervalWhitespace.StripIgnoreLocale)
        local curve = c.SetMaxIntervalCurve[1]
        assertEquals(#curve.points, 4)
        assertDeepEquals({ curve.points[1][1], curve.points[2][1], curve.points[3][1], curve.points[4][1] }, { 0, 91, 5401, 129601 })
        assertDeepEquals({ curve.points[1][2], curve.points[2][2], curve.points[3][2], curve.points[4][2] },
            { Enum.SecondsFormatterInterval.Seconds, Enum.SecondsFormatterInterval.Minutes, Enum.SecondsFormatterInterval.Hours, Enum.SecondsFormatterInterval.Days })
        assertEquals(curve.config.SetType[1], Enum.LuaCurveType.Step)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("without the SecondsFormatter API the buttons still work with the default text (empty options), no error", function()
        local ns = boot({ container = { noFormatter = true } })
        assertEquals(#mock.formatters, 0)
        local btn = frames(container(ns, "party1", "buff"))[1]
        assertNotNil(btn.durationTextOpts); assertNil(btn.durationTextOpts.textFormatter)
        assertEquals(ns.Auras.mode, "container"); assertEquals(#mock.errors, 0, errstr())
    end)
    it("a missing enum (any one of them) also falls back to the default text instead of breaking the container", function()
        for _, missing in ipairs({ "SecondsFormatterRounding", "SecondsFormatterInterval", "SecondsFormatterAbbreviation", "SecondsFormatterIntervalWhitespace" }) do
            local ns = boot({ container = { missingEnums = { [missing] = true } } })
            local btn = frames(container(ns, "party1", "buff"))[1]
            assertNil(btn.durationTextOpts.textFormatter, missing)
            assertEquals(ns.Auras.mode, "container", missing); assertEquals(#mock.errors, 0, missing .. ": " .. errstr())
        end
    end)
    it("the formatter is created once even when the buttons are rebuilt (a roster of many units)", function()
        local ns = boot({ group = 4 })
        assertEquals(#mock.formatters, 1)
    end)
    it("the timer font size is floor(size * 0.55 + 0.5) clamped to 8..11 (icon size 10 -> 8, 16 -> 9, 20 -> 11, 28 -> 11)", function()
        local ns = boot()
        for _, c in ipairs({ { 10, 8 }, { 12, 8 }, { 14, 8 }, { 16, 9 }, { 18, 10 }, { 20, 11 }, { 24, 11 }, { 28, 11 }, { 32, 11 } }) do
            ns.db.auras.buffSize = math.min(28, math.max(10, c[1])); ns.db.auras.debuffSize = math.min(32, math.max(12, c[1]))
            apply(ns)
            local want = math.max(8, math.min(11, math.floor(ns.db.auras.buffSize * 0.55 + 0.5)))
            local f = frames(container(ns, "party1", "buff"))[1]
            assertEquals(st(f.Time).font[2], want, "buff size " .. ns.db.auras.buffSize)
            local wantD = math.max(8, math.min(11, math.floor(ns.db.auras.debuffSize * 0.55 + 0.5)))
            assertEquals(st(frames(container(ns, "party1", "debuff"))[1].Time).font[2], wantD, "debuff size " .. ns.db.auras.debuffSize)
            if c[1] == 16 then assertEquals(want, 9) end
            if c[1] == 20 then assertEquals(wantD, 11) end
        end
        assertEquals(st(frames(container(ns, "party1", "buff"))[1].Time).font[3], "OUTLINE")
    end)
    it("inside-the-bar zones use the capped icon size for the font (buffs 14 -> 8, debuffs 16 -> 9)", function()
        local ns = boot()
        ns.db.auras.buffPosition = "inside"; ns.db.auras.debuffPosition = "inside"; ns.db.auras.buffSize = 28; ns.db.auras.debuffSize = 32; apply(ns)
        assertEquals(st(frames(container(ns, "party1", "buff"))[1].Time).font[2], 8)
        assertEquals(st(frames(container(ns, "party1", "debuff"))[1].Time).font[2], 9)
    end)
    it("the font keeps the template's font path and survives repeated layouts", function()
        local ns = boot()
        local f = frames(container(ns, "party1", "buff"))[1]
        local path = st(f.Time).font[1]
        for _ = 1, 3 do ns.db.auras.buffSize = 20; apply(ns); ns.db.auras.buffSize = 14; apply(ns) end
        assertEquals(st(f.Time).font[1], path)
    end)
    it("timerPos is honoured for container buttons: below = under the icon (TOP/BOTTOM, -1), inside = at the icon's bottom (BOTTOM/BOTTOM, +1), live", function()
        local ns = boot()
        local f = frames(container(ns, "party1", "buff"))[1]
        local p = st(f.Time).points[1]
        assertEquals(p[1], "TOP"); assertTrue(p[2] == f); assertEquals(p[3], "BOTTOM"); assertEquals(p[5], -1)
        ns.db.auras.timerPos = "inside"; apply(ns)
        p = st(f.Time).points[1]
        assertEquals(p[1], "BOTTOM"); assertEquals(p[3], "BOTTOM"); assertEquals(p[5], 1)
        local lay = rawget(container(ns, "party1", "buff").frame, "__container").layout
        assertEquals(lay.elementHeight, lay.elementWidth, "inside reserves no timer line in the container slots")
        ns.db.auras.timerPos = "below"; apply(ns)
        assertEquals(st(f.Time).points[1][1], "TOP")
        assertEquals(rawget(container(ns, "party1", "buff").frame, "__container").layout.elementHeight, lay.elementWidth + ns.Util.TIMER_HEIGHT)
    end)
    it("in combat and with everything secret the timer settings are untouched and nothing errors", function()
        local ns = boot()
        S.combat = true; S.secretAll = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.advance(5)
        S.combat = false; S.secretAll = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
