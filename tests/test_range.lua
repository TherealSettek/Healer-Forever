-- Range style B: UF.RangeState / UF.Distance, badge texts, dashed/dotted outline, green edge, old dim style,
-- secret-value drive (SetAlphaFromBoolean), tooltip lines, combat, options.
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
local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    S.units.partypet1 = unit("Pet", "HUNTER")
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end
local function btn(ns, u) return ns.UnitFrames.byUnit[u] end
local function update(ns, u) ns.UnitFrames:UpdateRange(btn(ns, u or "party1")) end
local function nSegments(b) local n = 0 for _, t in ipairs(b.dashTex or {}) do if st(t).shown then n = n + 1 end end return n end
local function approx(c, r, g, bl) return c and math.abs(c.r - r) < 1e-6 and math.abs(c.g - g) < 1e-6 and math.abs(c.b - bl) < 1e-6 end

describe("range: UF.RangeState", function()
    local ns = boot()
    local R = ns.UnitFrames.RangeState
    it("the player is always in range, whatever the APIs say", function()
        S.invisible = { player = true }; S.outOfRange.player = true; S.rangeError = true
        assertEquals((R("player")), "in")
        S.invisible = nil; S.outOfRange.player = nil; S.rangeError = false
    end)
    it("in range: visible, UnitInRange true, spell in range", function()
        local s, secret = R("party1"); assertEquals(s, "in"); assertNil(secret)
    end)
    it("out: UnitInRange false", function() S.outOfRange.party1 = true; assertEquals((R("party1")), "out"); S.outOfRange.party1 = nil end)
    it("out: UnitInRange true but the heal spell is out of range", function()
        S.spellOut = { party1 = true }; assertEquals((R("party1")), "out"); S.spellOut = nil
    end)
    it("hidden: not visible (wins over everything)", function()
        S.invisible = { party1 = true }; S.outOfRange.party1 = true
        assertEquals((R("party1")), "hidden")
        S.invisible = nil; S.outOfRange.party1 = nil
    end)
    it("a readable IsSpellInRange is preferred over a secret UnitInRange (no secret returned)", function()
        S.secretRange = false
        local real = _G.UnitInRange
        _G.UnitInRange = function() return mock.newSecret(), true end
        local s, secret = R("party1")
        assertEquals(s, "in"); assertNil(secret, "a readable spell result means no secret is handed on")
        S.spellOut = { party1 = true }
        s, secret = R("party1"); assertEquals(s, "out"); assertNil(secret)
        S.spellOut = nil; _G.UnitInRange = real
    end)
    it("the secret is returned ONLY when nothing readable is left (secret UnitInRange and no readable spell result)", function()
        local real = _G.UnitInRange
        local sentinel = mock.newSecret()
        _G.UnitInRange = function() return sentinel, true end
        S.spellNil = true
        local s, secret = R("party1")
        assertEquals(s, "in"); assertTrue(secret == sentinel)
        S.spellNil = false
        local realSpell = C_Spell.IsSpellInRange
        C_Spell.IsSpellInRange = function() return mock.newSecret() end
        s, secret = R("party1"); assertEquals(s, "in"); assertTrue(secret == sentinel, "secret spell result is not readable either")
        C_Spell.IsSpellInRange = realSpell; _G.UnitInRange = real
    end)
    it("secret visibility is ignored; secret everything counts as in range (unknown = in)", function()
        S.secretRange = true
        local s = R("party1")
        assertEquals(s, "in")
        S.secretRange = false
    end)
    it("erroring APIs: unknown counts as in range, never raises", function()
        S.rangeError = true
        local ok, s = pcall(R, "party1")
        assertTrue(ok); assertEquals(s, "in")
        S.rangeError = false
        local real = _G.UnitInRange
        _G.UnitInRange = function() error("boom") end
        ok, s = pcall(R, "party1"); assertTrue(ok); assertEquals(s, "in")
        _G.UnitInRange = real
    end)
    it("works without the heal spell API (no known heal): falls back to UnitInRange", function()
        local real = C_Spell.IsSpellInRange
        C_Spell.IsSpellInRange = nil
        assertEquals((R("party1")), "in"); S.outOfRange.party1 = true; assertEquals((R("party1")), "out"); S.outOfRange.party1 = nil
        C_Spell.IsSpellInRange = real
    end)
end)

describe("range: UF.Distance", function()
    local ns = boot()
    local D = ns.UnitFrames.Distance
    it("computed in the open world (yards between the two positions)", function()
        local d = D("party1")
        assertTrue(d and math.abs(d - 10) < 1e-6, tostring(d))
        S.positions.party2 = { 0.5, 0.53 }
        assertTrue(math.abs(D("party2") - 30) < 1e-6)
    end)
    it("nil in instances, when secret, when positions are missing, or in different instance ids", function()
        S.inInstance = true; assertNil(D("party1")); S.inInstance = false
        S.secretPos = true; assertNil(D("party1")); S.secretPos = false
        S.noPositions = true; assertNil(D("party1")); S.noPositions = false
        S.otherInstance = { party1 = true }; assertNil(D("party1")); S.otherInstance = nil
        S.secret = true; assertNil(D("party1")); S.secret = false
        assertNotNil(D("party1"))
    end)
    it("never raises when UnitPosition itself errors", function()
        local real = _G.UnitPosition
        _G.UnitPosition = function() error("restricted") end
        local ok, d = pcall(D, "party1")
        assertTrue(ok); assertNil(d)
        _G.UnitPosition = real
    end)
end)

describe("range: badge style visuals", function()
    local ns = boot()
    ns.db.frames.range.style = "badge"
    local b = btn(ns, "party1")
    local function badge() if b.badge and st(b.badge).shown then return st(b.badge.text).text end return nil end
    it("in range: no badge, no outline", function()
        update(ns)
        assertNil(badge()); assertFalse(st(b.dashFrame).shown); assertEquals(nSegments(b), 0)
        assertEquals(b.health:GetAlpha(), 1)
    end)
    it("out of range: OUT OF RANGE badge, dashed outline in the out colour, bars dimmed (not the whole button)", function()
        S.outOfRange.party1 = true; update(ns)
        assertEquals(badge(), "OUT OF RANGE")
        assertTrue(st(b.dashFrame).shown); assertTrue(nSegments(b) > 8)
        local oc = ns.db.frames.range.outColor
        assertTrue(approx(st(b.dashTex[1]).vertex, oc.r, oc.g, oc.b), "dashes use the out colour")
        local dim = ns.db.frames.range.dim / 100
        assertEquals(b.health:GetAlpha(), dim); assertEquals(b.power:GetAlpha(), dim)
        assertEquals(b:GetAlpha(), 1, "the whole button stays opaque in badge style")
        local bc = st(b.borders[1]).borderColor
        assertTrue(approx(bc, oc.r, oc.g, oc.b), "bar borders take the out colour")
    end)
    it("not visible: NOT VISIBLE badge, dotted outline (more, shorter segments) in the hidden colour, health text '?'", function()
        local outSeg = nSegments(b)
        S.outOfRange.party1 = nil; S.invisible = { party1 = true }; update(ns)
        assertEquals(badge(), "NOT VISIBLE")
        assertTrue(nSegments(b) > outSeg, "dotted has more segments than dashed")
        local hc = ns.db.frames.range.hiddenColor
        assertTrue(approx(st(b.dashTex[1]).vertex, hc.r, hc.g, hc.b))
        assertEquals(st(b.healthText).text, "?")
        assertEquals(b.health:GetAlpha(), 1, "hidden does not dim the bars")
        assertTrue(approx(st(b.borders[1]).borderColor, hc.r, hc.g, hc.b))
    end)
    it("back in range: badge, outline and '?' are gone, bars restored", function()
        S.invisible = nil; update(ns)
        assertNil(badge()); assertFalse(st(b.dashFrame).shown); assertEquals(b.health:GetAlpha(), 1)
        assertTrue(st(b.healthText).text ~= "?")
    end)
    it("a dead member out of range says CAN'T RESURRECT; not visible too; pets say OUT OF RANGE", function()
        S.dead.party1 = true; mock.fire("UNIT_FLAGS", "party1"); S.outOfRange.party1 = true; update(ns)
        assertEquals(badge(), "CAN'T RESURRECT")
        S.outOfRange.party1 = nil; S.invisible = { party1 = true }; update(ns)
        assertEquals(badge(), "CAN'T RESURRECT")
        S.dead.party1 = nil; S.invisible = nil; mock.fire("UNIT_FLAGS", "party1"); update(ns)
        local pet = btn(ns, "partypet1")
        S.dead.partypet1 = true; S.outOfRange.partypet1 = true; mock.fire("UNIT_FLAGS", "partypet1"); ns.UnitFrames:UpdateRange(pet)
        assertTrue(not pet.badge or not st(pet.badge).shown or st(pet.badge.text).text == "OUT OF RANGE")
        S.dead.partypet1 = nil; S.outOfRange.partypet1 = nil
    end)
    it("the badge option off hides the text but keeps the outline", function()
        ns.db.frames.range.badge = false
        S.outOfRange.party1 = true; ns.UnitFrames:ApplyRangeVisuals(b); update(ns)
        assertNil(badge()); assertTrue(st(b.dashFrame).shown)
        ns.db.frames.range.badge = true; S.outOfRange.party1 = nil; update(ns)
    end)
    it("healable green edge: in-range borders are tinted half way to the healable colour (and not for 'none' borders)", function()
        ns.db.frames.range.healable = true
        ns.db.frames.border = { style = "thin", width = 1, color = "class", custom = { r = 1, g = 1, b = 1 } }
        ns:Changed("frames"); mock.flushTimers(); update(ns)
        local cc = ns.Classes.GetColor("WARRIOR"); local h = ns.db.frames.range.healableColor
        local bc = st(b.borders[1]).borderColor
        assertTrue(approx(bc, (cc.r + h.r) / 2, (cc.g + h.g) / 2, (cc.b + h.b) / 2), "blended: got " .. bc.r .. "," .. bc.g .. "," .. bc.b .. " state=" .. tostring(b.rangeState))
        ns.db.frames.range.healable = false; ns:Changed("frames"); mock.flushTimers(); update(ns)
        assertTrue(approx(st(b.borders[1]).borderColor, cc.r, cc.g, cc.b), "healable off = plain class colour")
        ns.db.frames.range.healable = true; ns.db.frames.border.style = "none"; ns:Changed("frames"); mock.flushTimers()
        assertFalse(st(b.borders[1]).shown)
    end)
    it("aggro still wins over every range colour", function()
        ns.db.frames.border.style = "thin"; ns:Changed("frames"); mock.flushTimers()
        S.outOfRange.party1 = true; update(ns)
        S.threat = { party1 = 3 }; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1")
        assertTrue(approx(st(b.borders[1]).borderColor, 1, 0.13, 0.13))
        S.threat = {}; mock.fire("UNIT_THREAT_SITUATION_UPDATE", "party1"); S.outOfRange.party1 = nil; update(ns)
    end)
    it("the dashed outline is a plain non-secure overlay that never takes the mouse; segments are WHITE8X8 and recycled", function()
        S.outOfRange.party1 = true; update(ns)
        assertFalse(st(b.dashFrame).secure); assertFalse(st(b.dashFrame).mouse == true)
        local n = #b.dashTex
        S.outOfRange.party1 = nil; update(ns); S.outOfRange.party1 = true; update(ns)
        assertEquals(#b.dashTex, n, "segment textures are reused, not re-created")
        for _, t in ipairs(b.dashTex) do assertNotNil(tostring(st(t).texture):find("WHITE8X8", 1, true)) end
        S.outOfRange.party1 = nil; update(ns)
    end)
    it("segment geometry scales with the bar size and always covers all four sides", function()
        S.outOfRange.party1 = true
        for _, w in ipairs({ 100, 180, 260 }) do
            ns.db.frames.width = w; ns:Changed("frames"); mock.flushTimers(); update(ns)
            local points = {}
            for _, t in ipairs(b.dashTex) do if st(t).shown then points[st(t).points[1][1]] = true end end
            assertTrue(points.TOPLEFT and points.BOTTOMLEFT and points.TOPRIGHT, "all sides present at width " .. w)
        end
        ns.db.frames.width = 180; ns:Changed("frames"); mock.flushTimers(); S.outOfRange.party1 = nil; update(ns)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("offline units keep the old dim alpha and show no range visuals", function()
        S.offline.party1 = true; mock.fire("UNIT_CONNECTION", "party1"); update(ns)
        assertEquals(b:GetAlpha(), 0.45)
        S.offline.party1 = nil; mock.fire("UNIT_CONNECTION", "party1"); update(ns)
    end)
end)

describe("range: old dim style and secret values", function()
    local ns = boot()
    local b = btn(ns, "party1")
    it("dim style fades the whole button to the dim alpha, no badge, no outline", function()
        ns.db.frames.range.style = "dim"; ns.db.frames.range.dim = 40
        S.outOfRange.party1 = true; update(ns)
        assertEquals(b:GetAlpha(), 0.4)
        assertTrue(not st(b.badge).shown); assertFalse(st(b.dashFrame).shown)
        assertEquals(b.health:GetAlpha(), 1)
        S.outOfRange.party1 = nil; update(ns); assertEquals(b:GetAlpha(), 1)
    end)
    it("dim style with a secret range: SetAlphaFromBoolean(button, 1, dim) receives the secret value", function()
        local sentinel = mock.newSecret()
        local real = _G.UnitInRange
        _G.UnitInRange = function() return sentinel, true end
        S.spellNil = true
        local n0 = #mock.calls
        update(ns)
        local got
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            if c.method == "SetAlphaFromBoolean" and c.obj == b then got = c end
        end
        assertNotNil(got, "SetAlphaFromBoolean must be used for a secret range")
        assertTrue(got.args[1] == sentinel); assertEquals(got.args[2], 1); assertEquals(got.args[3], 0.4)
        assertEquals(#mock.errors, 0, errstr())
        S.spellNil = false; _G.UnitInRange = real; S.secretRange = false
    end)
    it("badge style with a secret range: health, power, badge, dashes and edge glow are all driven by the secret (no truth test)", function()
        ns.db.frames.range.style = "badge"; ns.db.frames.range.dim = 50
        local sentinel = mock.newSecret()
        local real = _G.UnitInRange
        _G.UnitInRange = function() return sentinel, true end
        S.spellNil = true
        local n0 = #mock.calls
        b.rangeState = nil; update(ns)
        local by = {}
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            if c.method == "SetAlphaFromBoolean" and c.args[1] == sentinel then by[c.obj] = c.args end
        end
        assertNotNil(by[b.health]); assertEquals(by[b.health][2], 1); assertEquals(by[b.health][3], 0.5)
        assertNotNil(by[b.power]); assertNotNil(by[b.badge]); assertNotNil(by[b.dashFrame]); assertNotNil(by[b.edgeGlow])
        assertEquals(by[b.badge][2], 0); assertEquals(by[b.badge][3], 1)
        assertEquals(by[b.edgeGlow][2], 1); assertEquals(by[b.edgeGlow][3], 0)
        assertEquals(b:GetAlpha(), 1)
        -- shown with the secret-driven alphas: dashes + green edge exist
        assertTrue(st(b.dashFrame).shown); assertTrue(st(b.edgeGlow).shown)
        local h = ns.db.frames.range.healableColor
        assertTrue(approx(st(b.edgeGlow).borderColor, h.r, h.g, h.b))
        assertEquals(#mock.errors, 0, errstr())
        S.spellNil = false; _G.UnitInRange = real
        b.rangeState = nil; update(ns)
    end)
    it("a secret range value never reaches a truth test in the frame code (nothing raises, repeated ticks stay stable)", function()
        S.secretRange = true; S.combat = true; S.secret = true
        for _ = 1, 20 do update(ns, "party1"); update(ns, "party2"); mock.runOnUpdate(1, 0.3) end
        assertEquals(#mock.errors, 0, errstr())
        S.secretRange = false; S.combat = false; S.secret = false
    end)
end)

describe("range: tooltip lines", function()
    local ns = boot()
    local b = btn(ns, "party1")
    local lines
    local function hover()
        lines = {}
        local gt = _G.GameTooltip
        gt.SetOwner = function() lines = {} end; gt.Show = function() end
        gt.AddLine = function(_, t) lines[#lines + 1] = mock.isSecret(t) and "<secret>" or tostring(t) end
        gt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. " " .. tostring(r) end
        gt.AddTexture = function() end
        ns.UnitFrames:ShowTooltip(b)
        return table.concat(lines, "\n")
    end
    it("in range", function() update(ns); assertNotNil(hover():find("In range", 1, true)) end)
    it("out of range with the distance (open world)", function()
        S.outOfRange.party1 = true; update(ns)
        local out = hover()
        assertNotNil(out:find("Out of range (can't heal)", 1, true)); assertNotNil(out:find("about 10 yd", 1, true), out)
        S.inInstance = true; out = hover(); assertNil(out:find("yd", 1, true), "no distance in instances"); S.inInstance = false
    end)
    it("not visible", function()
        S.outOfRange.party1 = nil; S.invisible = { party1 = true }; update(ns)
        assertNotNil(hover():find("Not visible", 1, true))
    end)
    it("dead and out of reach: can't resurrect from here", function()
        S.dead.party1 = true; mock.fire("UNIT_FLAGS", "party1"); update(ns)
        assertNotNil(hover():find("Can't resurrect from here", 1, true))
        S.dead.party1 = nil; S.invisible = nil; mock.fire("UNIT_FLAGS", "party1"); update(ns)
        assertNil(hover():find("Can't resurrect", 1, true))
    end)
    it("a secret range state adds no range line (and the tooltip still completes)", function()
        S.secretRange = true; b.rangeState = nil; update(ns)
        local out = hover()
        assertNil(out:find("In range", 1, true)); assertNil(out:find("Out of range", 1, true)); assertNotNil(out:find("Click-casting", 1, true))
        S.secretRange = false
    end)
    it("the player's own frame has no range line", function()
        local pb = btn(ns, "player")
        lines = {}
        ns.UnitFrames:ShowTooltip(pb)
        assertNil(table.concat(lines, "\n"):find("range", 1, true))
    end)
end)

describe("range: combat", function()
    it("range visuals keep updating in combat with no protected calls", function()
        local ns = boot()
        local b = btn(ns, "party1")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0, n0 = #mock.violations, #mock.softViolations, #mock.calls
        S.outOfRange.party1 = true; update(ns)
        assertEquals(st(b.badge.text).text, "OUT OF RANGE"); assertTrue(st(b.dashFrame).shown)
        S.outOfRange.party1 = nil; S.invisible = { party1 = true }; update(ns)
        assertEquals(st(b.badge.text).text, "NOT VISIBLE")
        S.invisible = nil; update(ns); assertFalse(st(b.badge).shown)
        mock.runOnUpdate(6, 0.3)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and (c.method == "SetPoint" or c.method == "SetSize" or c.method == "SetAttribute" or c.method == "ClearAllPoints" or c.method == "Show" or c.method == "Hide"),
                "protected call in combat: " .. c.method)
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("range: options (Frames & Bars pane)", function()
    local function label(text) for _, f in ipairs(mock.frames) do if st(f).kind == "FontString" and st(f).text == text then return f end end end
    local function dropdownFor(text)
        local l = label(text); local y = st(l).points[1][3]
        for _, f in ipairs(mock.frames) do
            local q = st(f).points[1]
            if rawget(f, "Refresh") and rawget(f, "text") and st(f).kind == "Button" and q and q[2] == 150 and q[3] == y + 4 then return f end
        end
    end
    local function checkbox(text) for _, f in ipairs(mock.frames) do if st(f).kind == "CheckButton" and f.label and st(f.label).text == text then return f end end end
    local function slider(text) for _, f in ipairs(mock.frames) do if f.slider and f.label and st(f.label).text == text then return f end end end
    local function pick(dd, text)
        mock.menu = nil
        st(dd).scripts.OnClick(dd, "LeftButton")
        for _, f in ipairs(mock.frames) do if st(f).shown and f.item and f.item.text == text and st(f).scripts.OnClick then st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers(); return true end end
        for _, e in ipairs(mock.menu and mock.menu.entries or {}) do if e.text == text then e.cb(); mock.flushTimers(); return true end end
    end
    local function swatchFor(text)
        local l = label(text); local y = st(l).points[1][3]
        for _, f in ipairs(mock.frames) do
            local q = st(f).points[1]
            if st(f).kind == "Button" and f.tex and rawget(f, "Refresh") and q and q[2] == 150 and q[3] == y + 4 then return f end
        end
    end
    it("every Range control exists, saves, applies live and survives a reload", function()
        local ns = boot()
        ns.Options:Show("frames"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        local b = btn(ns, "party1")
        -- style
        assertTrue(pick(dropdownFor("Out-of-range style"), "Old dim (fade the whole frame)")); assertEquals(ns.db.frames.range.style, "dim")
        S.outOfRange.party1 = true; update(ns)
        assertEquals(b:GetAlpha(), ns.db.frames.range.dim / 100)
        assertTrue(pick(dropdownFor("Out-of-range style"), "B. Range badge")); assertEquals(ns.db.frames.range.style, "badge")
        update(ns); assertEquals(b:GetAlpha(), 1); assertTrue(st(b.badge).shown)
        -- dim slider
        local sf = slider("Dim alpha (%)")
        st(sf.slider).value = 30; st(sf.slider).scripts.OnValueChanged(sf.slider, 30, true); mock.flushTimers(); update(ns)
        assertEquals(ns.db.frames.range.dim, 30); assertEquals(b.health:GetAlpha(), 0.3)
        -- checkboxes
        local cb = checkbox("Show OUT OF RANGE / NOT VISIBLE badge")
        st(cb).checked = false; st(cb).scripts.OnClick(cb); mock.flushTimers(); update(ns)
        assertEquals(ns.db.frames.range.badge, false); assertFalse(st(b.badge).shown)
        local ce = checkbox("Healable green edge on in-range bars")
        st(ce).checked = false; st(ce).scripts.OnClick(ce); mock.flushTimers()
        assertEquals(ns.db.frames.range.healable, false)
        -- colours via the picker
        for _, c in ipairs({ { "Healable colour", "healableColor" }, { "Out-of-range colour", "outColor" }, { "Not-visible colour", "hiddenColor" } }) do
            local sw = swatchFor(c[1])
            assertNotNil(sw, c[1])
            mock.colorPicker = nil; mock.pickColor = { 0.11, 0.22, 0.33 }
            st(sw).scripts.OnClick(sw); mock.colorPicker.swatchFunc(); mock.flushTimers()
            assertTrue(approx(ns.db.frames.range[c[2]], 0.11, 0.22, 0.33), c[2])
        end
        S.outOfRange.party1 = true; ns.db.frames.range.badge = true; ns:Changed("frames"); mock.flushTimers(); update(ns)
        assertTrue(approx(st(b.dashTex[1]).vertex, 0.11, 0.22, 0.33), "the new out colour is used live")
        -- reload
        local saved = deepcopy(HealerForeverCharDB)
        local ns2 = boot({ char = saved })
        local r = ns2.db.frames.range
        assertEquals(r.style, "badge"); assertEquals(r.dim, 30); assertEquals(r.badge, true); assertEquals(r.healable, false)
        assertTrue(approx(r.outColor, 0.11, 0.22, 0.33)); assertTrue(approx(r.hiddenColor, 0.11, 0.22, 0.33)); assertTrue(approx(r.healableColor, 0.11, 0.22, 0.33))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("range options are saved sparsely (defaults omitted) and corrupted values are sanitised", function()
        local ns = boot()
        assertNil(ns:BuildSaveTable().frames and ns:BuildSaveTable().frames.range)
        ns.db.frames.range.dim = 55
        assertDeepEquals(ns:BuildSaveTable().frames.range, { dim = 55 })
        local ns2 = boot({ char = { version = 3, frames = { range = { style = "weird", dim = "x", badge = 5, healable = {}, outColor = "red", healableColor = { r = 9 } } } } })
        local r = ns2.db.frames.range
        assertTrue(r.style == "badge" or r.style == "dim"); assertEquals(type(r.dim), "number"); assertEquals(type(r.outColor), "table")
        assertTrue(r.healableColor.r <= 1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Util.NormalizeRange: clamps and defaults for every field", function()
        mock.install(); local ns = {}; L.loadContract(ns)
        local N = ns.Util.NormalizeRange
        assertEquals(N(nil).style, "badge"); assertEquals(N({ style = "dim" }).style, "dim"); assertEquals(N({ style = "x" }).style, "badge")
        assertEquals(N({ dim = 0 }).dim, 10); assertEquals(N({ dim = 500 }).dim, 100); assertEquals(N({ dim = "a" }).dim, 72)
        assertEquals(N({ badge = false }).badge, false); assertEquals(N({}).badge, true); assertEquals(N({ healable = false }).healable, false)
        local c = N({ outColor = { r = 2, g = -1 } }).outColor
        assertEquals(c.r, 1); assertEquals(c.g, 0); assertEquals(type(c.b), "number")
        assertTrue(N("x") ~= nil)
    end)
end)

describe("range: secret-range mode and the return to readable states", function()
    local ns = boot()
    local b = btn(ns, "party1")
    local real = _G.UnitInRange
    local sentinel = mock.newSecret()
    local function goSecret() _G.UnitInRange = function() return sentinel, true end; S.spellNil = true; b.rangeState = nil; update(ns) end
    local function goReadable() _G.UnitInRange = real; S.spellNil = false; end
    local function alphas() return { h = b.health:GetAlpha(), p = b.power and b.power:GetAlpha(), badge = b.badge:GetAlpha(), dash = b.dashFrame:GetAlpha(), btn = b:GetAlpha() } end
    local function driven()
        local by = {}
        for i = #mock.calls, 1, -1 do
            local c = mock.calls[i]
            if c.method == "SetAlphaFromBoolean" and c.args[1] == sentinel and not by[c.obj] then by[c.obj] = c.args end
            if #mock.calls - i > 60 then break end
        end
        return by
    end
    it("secret mode shows the dashed outline, the badge frame and the green edge, and drives their alphas from the secret", function()
        ns.db.frames.range.style = "badge"; ns.db.frames.range.healable = true
        goSecret()
        assertEquals(b.rangeState, "secret")
        assertTrue(st(b.dashFrame).shown); assertTrue(st(b.edgeGlow).shown)
        local by = driven()
        assertNotNil(by[b.badge]); assertEquals(by[b.badge][2], 0); assertEquals(by[b.badge][3], 1, "badge only when out")
        assertNotNil(by[b.dashFrame]); assertEquals(by[b.dashFrame][2], 0); assertEquals(by[b.dashFrame][3], 1)
        assertNotNil(by[b.edgeGlow]); assertEquals(by[b.edgeGlow][2], 1); assertEquals(by[b.edgeGlow][3], 0)
        assertNotNil(by[b.health]); assertNotNil(by[b.power])
        assertEquals(b:GetAlpha(), 1, "the button itself is never faded in badge style")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the edge glow is not shown in secret mode when the healable option is off, nor in the dim style", function()
        ns.db.frames.range.healable = false; goSecret(); assertFalse(st(b.edgeGlow).shown)
        ns.db.frames.range.healable = true; ns.db.frames.range.style = "dim"; goSecret()
        assertFalse(st(b.edgeGlow).shown); assertFalse(st(b.dashFrame).shown)
        ns.db.frames.range.style = "badge"
    end)
    it("secret -> in range: every alpha is reset to 1 and the secret-only visuals disappear", function()
        goSecret()
        -- the secret drive left the mock's alpha at the "in" value for the regions it touched; dirty them like the game would
        b.badge:SetAlpha(0); b.dashFrame:SetAlpha(0); b.health:SetAlpha(0.5); b.power:SetAlpha(0.5)
        goReadable(); update(ns)
        local a = alphas()
        assertEquals(a.h, 1); assertEquals(a.p, 1); assertEquals(a.badge, 1); assertEquals(a.dash, 1); assertEquals(a.btn, 1)
        assertEquals(b.rangeState, "in")
        assertFalse(st(b.dashFrame).shown); assertFalse(st(b.edgeGlow).shown); assertFalse(st(b.badge).shown)
    end)
    it("secret -> out of range: dim bars, badge and dashes shown at alpha 1, no green edge", function()
        goSecret()
        b.badge:SetAlpha(0); b.dashFrame:SetAlpha(0)
        goReadable(); S.outOfRange.party1 = true; update(ns)
        local a = alphas()
        assertEquals(b.rangeState, "out")
        assertEquals(a.badge, 1); assertEquals(a.dash, 1); assertEquals(a.h, ns.db.frames.range.dim / 100); assertEquals(a.btn, 1)
        assertTrue(st(b.badge).shown); assertTrue(st(b.dashFrame).shown); assertFalse(st(b.edgeGlow).shown)
        S.outOfRange.party1 = nil; update(ns)
    end)
    it("secret -> not visible: dotted outline and NOT VISIBLE badge at alpha 1", function()
        goSecret(); b.badge:SetAlpha(0)
        goReadable(); S.invisible = { party1 = true }; update(ns)
        assertEquals(b.rangeState, "hidden"); assertEquals(b.badge:GetAlpha(), 1); assertEquals(b.dashFrame:GetAlpha(), 1)
        assertEquals(st(b.badge.text).text, "NOT VISIBLE")
        S.invisible = nil; update(ns)
    end)
    it("flipping between secret and readable many times never leaves a stale alpha", function()
        for i = 1, 12 do
            if i % 2 == 1 then goSecret() else goReadable(); update(ns) end
        end
        goReadable(); update(ns)
        local a = alphas()
        assertEquals(a.h, 1); assertEquals(a.p, 1); assertEquals(a.badge, 1); assertEquals(a.dash, 1)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("changing the style while secret re-applies the drive for the new style", function()
        ns.db.frames.range.style = "badge"; goSecret()
        ns.db.frames.range.style = "dim"
        local n0 = #mock.calls; update(ns)
        local got
        for i = n0 + 1, #mock.calls do local c = mock.calls[i]; if c.method == "SetAlphaFromBoolean" and c.obj == b then got = c end end
        assertNotNil(got); assertTrue(got.args[1] == sentinel)
        ns.db.frames.range.style = "badge"; goReadable(); update(ns)
    end)
end)
