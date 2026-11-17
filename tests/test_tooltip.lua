-- Hover tooltip aura list: pure BuildTooltipLines + whole-addon tooltip behaviour.
local L = require("loader")
local mock = require("wow_mock")

mock.install()
local pns, _, perrs = L.loadContract({})
local pok, perr = pcall(L.loadFile, "Frames/Auras.lua", pns)

describe("tooltip: BuildTooltipLines exists", function()
    it("Frames/Auras.lua loads and exposes ns.Auras.BuildTooltipLines", function()
        assertTrue(pok, tostring(perr))
        assertEquals(type(pns.Auras and pns.Auras.BuildTooltipLines), "function")
    end)
end)

if pns.Auras and pns.Auras.BuildTooltipLines then
    local B = pns.Auras.BuildTooltipLines
    local FA = pns.Util.FormatAuraTime
    local now = 1000
    local function a(name, extra)
        local t = { name = name, icon = 111, dispelName = nil, applications = 0, expirationTime = 0, duration = 0 }
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end
    local function texts(lines) local o = {} for _, l in ipairs(lines) do o[#o + 1] = l.text end return o end
    local function names(lines)
        local o = {}
        for _, l in ipairs(lines) do o[#o + 1] = (l.text:gsub("^|T.-|t ", ""):match("^(.-) %- ") or l.text:gsub("^|T.-|t ", "")) end
        return o
    end

    describe("tooltip: BuildTooltipLines (pure)", function()
        it("empty / nil list -> empty array", function()
            assertEquals(#B({}, now, {}), 0); assertEquals(#B(nil, now, nil), 0)
            assertEquals(type(B(nil, nil, nil)), "table")
        end)
        it("lines carry text, r, g, b, dispellable", function()
            local l = B({ a("Poison Sting", { dispelName = "Poison" }) }, now, {})[1]
            assertEquals(type(l.text), "string")
            for _, k in ipairs({ "r", "g", "b" }) do assertEquals(type(l[k]), "number") end
            assertEquals(l.dispellable, false)
        end)
        it("includes the name, the type, and the icon texture markup", function()
            local l = B({ a("Curse of Doom", { dispelName = "Curse", icon = 4242 }) }, now, {})[1]
            assertNotNil(l.text:find("Curse of Doom", 1, true)); assertNotNil(l.text:find("Curse", 1, true))
            assertNotNil(l.text:find("|T4242:", 1, true))
        end)
        it("no dispel type is labelled Physical", function()
            assertNotNil(B({ a("Bleed") }, now, {})[1].text:find("Physical", 1, true))
        end)
        it("marks only debuffs the player can dispel; dispellable come first", function()
            local lines = B({ a("Bleed"), a("Fire Debuff", { dispelName = "Magic" }), a("Rot", { dispelName = "Disease" }) }, now, { "Magic" })
            assertTrue(lines[1].dispellable); assertNotNil(lines[1].text:find("Fire Debuff", 1, true))
            assertNotNil(lines[1].text:find("[dispel]", 1, true))
            assertFalse(lines[2].dispellable); assertFalse(lines[3].dispellable)
            assertNil(lines[2].text:find("[dispel]", 1, true))
        end)
        it("canDispelTypes may be an array or a set", function()
            assertTrue(B({ a("X", { dispelName = "Magic" }) }, now, { "Magic" })[1].dispellable)
            assertTrue(B({ a("X", { dispelName = "Magic" }) }, now, { Magic = true })[1].dispellable)
            assertFalse(B({ a("X", { dispelName = "Magic" }) }, now, { Magic = false })[1].dispellable)
            assertFalse(B({ a("X", { dispelName = "Magic" }) }, now, nil)[1].dispellable)
            assertFalse(B({ a("X", { dispelName = "Magic" }) }, now, { "Curse", "Poison" })[1].dispellable)
        end)
        it("non-dispellable sort by time left ascending; no timer sorts last", function()
            local lines = B({ a("Long", { expirationTime = now + 300 }), a("NoTimer"), a("Short", { expirationTime = now + 5 }), a("Mid", { expirationTime = now + 60 }) }, now, {})
            local order = {}
            for _, l in ipairs(lines) do order[#order + 1] = l.text:gsub("^|T.-|t ", ""):match("^(%a+)") end
            assertDeepEquals(order, { "Short", "Mid", "Long", "NoTimer" })
        end)
        it("dispellable ones are also sorted among themselves by time left", function()
            local lines = B({ a("MagicLong", { dispelName = "Magic", expirationTime = now + 100 }), a("MagicShort", { dispelName = "Magic", expirationTime = now + 10 }) }, now, { "Magic" })
            assertNotNil(lines[1].text:find("MagicShort", 1, true))
        end)
        it("ties keep input order (stable)", function()
            local lines = B({ a("First"), a("Second"), a("Third") }, now, {})
            assertNotNil(lines[1].text:find("First", 1, true)); assertNotNil(lines[3].text:find("Third", 1, true))
        end)
        it("time uses FormatAuraTime", function()
            for _, secs in ipairs({ 5.4, 45, 120, 3700 }) do
                local l = B({ a("T", { expirationTime = now + secs }) }, now, {})[1]
                assertNotNil(l.text:find(" - " .. FA(secs), 1, true), l.text .. " should contain " .. FA(secs))
            end
        end)
        it("nil or 0 expiration means no timer", function()
            for _, exp in ipairs({ 0, false }) do
                local l = B({ a("Perm", { expirationTime = exp or nil }) }, now, {})[1]
                assertNil(l.text:find(" %- %d"), l.text)
                assertNil(l.text:find("0%.0"))
            end
        end)
        it("an already-expired aura shows no timer", function()
            local l = B({ a("Old", { expirationTime = now - 5 }) }, now, {})[1]
            assertNil(l.text:find("%-5"), l.text)
        end)
        it("stacks shown only when > 1", function()
            assertNil(B({ a("S", { applications = 0 }) }, now, {})[1].text:find(" x%d"))
            assertNil(B({ a("S", { applications = 1 }) }, now, {})[1].text:find(" x%d"))
            assertNotNil(B({ a("S", { applications = 2 }) }, now, {})[1].text:find(" x2", 1, true))
            assertNotNil(B({ a("S", { applications = 12 }) }, now, {})[1].text:find(" x12", 1, true))
            assertNil(B({ a("S", { applications = nil }) }, now, {})[1].text:find(" x%d"))
        end)
        it("an aura without a name is skipped; garbage entries are skipped", function()
            local lines = B({ { icon = 1 }, 5, "x", a("Real"), { name = nil } }, now, {})
            assertEquals(#lines, 1)
        end)
        it("empty-string dispelName is treated as no type", function()
            local l = B({ a("E", { dispelName = "" }) }, now, { "Magic" })[1]
            assertNotNil(l.text:find("Physical", 1, true)); assertFalse(l.dispellable)
        end)
        it("colours: type colour for typed debuffs, a red-ish default for physical", function()
            local magic = B({ a("M", { dispelName = "Magic" }) }, now, {})[1]
            local c = pns.Classes.DISPEL_COLORS.Magic
            assertEquals(magic.r, c.r); assertEquals(magic.b, c.b)
            local phys = B({ a("P") }, now, {})[1]
            assertTrue(phys.r > phys.g)
        end)
        it("opts.buff: no type label, never dispellable, neutral colour", function()
            local l = B({ a("Kings", { dispelName = "Magic" }) }, now, { "Magic" }, { buff = true })[1]
            assertNil(l.text:find("Physical", 1, true)); assertNil(l.text:find("Magic", 1, true)); assertNil(l.text:find("[dispel]", 1, true))
            assertFalse(l.dispellable)
        end)
        it("does not mutate its input and handles 200 auras", function()
            local list = { a("A", { expirationTime = now + 5 }), a("B") }
            local snap = pns.Util.DeepCopy(list)
            B(list, now, {})
            assertDeepEquals(list, snap)
            local big = {}
            for i = 1, 200 do big[i] = a("Aura" .. i, { expirationTime = now + i }) end
            assertEquals(#B(big, now, {}), 200)
        end)
        it("nil now does not raise and shows no timers", function()
            local ok, r = pcall(B, { a("N", { expirationTime = 5000 }) }, nil, {})
            assertTrue(ok, tostring(r)); assertEquals(#r, 1)
        end)
    end)
end

-- ======================================================================== whole addon
local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end
local function unit(name, class, role)
    return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end
local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN", nil); mock.flushTimers()
    mock.setGroup(2)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local lines, textures
local function recorder()
    local gt = _G.GameTooltip
    lines = {}
    gt.SetOwner = function() lines = {} end
    gt.ClearLines = function() lines = {} end
    textures = {}
    gt.AddTexture = function(_, tex) textures[#textures + 1] = mock.isSecret(tex) and "<secret>" or tostring(tex) end
    gt.AddLine = function(_, text) lines[#lines + 1] = mock.isSecret(text) and "<secret>" or tostring(text) end
    gt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. " " .. tostring(r) end
    gt.Show = function() end
end
local function buttonFor(u)
    for _, f in ipairs(mock.frames) do
        if tostring(st(f).name):match("^HealerForeverUnit") and st(f).attrs.unit == u then return f end
    end
end
local function hover(u) local b = buttonFor(u); st(b).hooks.OnEnter[1](b); return b end
local function joined() return table.concat(lines, "\n") end
local SIX = { "Poison Sting", "Fire Debuff", "Bleed A", "Curse of Doom", "Rotting Touch", "Slow" }
local function sixDebuffs()
    local list = {}
    for i, n in ipairs(SIX) do
        list[#list + 1] = { spellId = 5000 + i, name = n, icon = 100 + i, duration = 30, expirationTime = S.now + 10 * i,
            applications = (i == 3) and 3 or 0, dispelName = ({ "Poison", "Magic", nil, "Curse", "Disease", nil })[i], isHarmful = true, isHelpful = false, auraInstanceID = 200 + i }
    end
    return list
end

describe("tooltip: hovering a unit lists ALL debuffs", function()
    local ns = boot()
    recorder()
    S.auras.party1 = sixDebuffs()
    ns.db.auras.onlyDispellable = true
    ns.db.auras.maxDebuffs = 3
    it("all 6 names appear even with onlyDispellable on and a 3-icon bar limit", function()
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        for _, n in ipairs(SIX) do assertNotNil(joined():find(n, 1, true), n .. " missing from tooltip:\n" .. joined()) end
        assertNotNil(joined():find("Debuffs (6)", 1, true), joined())
    end)
    it("type, stacks and time left are listed", function()
        local out = joined()
        assertNotNil(out:find("Poison", 1, true)); assertNotNil(out:find(" x3", 1, true)); assertNotNil(out:find(ns.Util.FormatAuraTime(10), 1, true))
    end)
    it("dispellable ones (for this class) come first and are marked", function()
        local first, firstDispel
        for i, l in ipairs(lines) do
            if l:find("%[dispel%]") then firstDispel = firstDispel or i end
            if l:find("Slow", 1, true) or l:find("Bleed A", 1, true) then first = first or i end
        end
        if ns.Classes.DATA.PALADIN.dispels and #ns.Classes.DATA.PALADIN.dispels > 0 then
            assertNotNil(firstDispel, "paladin can dispel something: expected a [dispel] marker\n" .. joined())
            assertTrue(firstDispel < first, "dispellable must come before physical ones")
        end
    end)
    it("a UNIT_AURA while hovering refreshes the lines (new debuff appears, removed one disappears)", function()
        local b = hover("party1")
        S.auras.party1[#S.auras.party1 + 1] = { spellId = 6000, name = "Brand New Debuff", icon = 1, duration = 20, expirationTime = S.now + 20,
            applications = 0, isHarmful = true, isHelpful = false, auraInstanceID = 300 }
        table.remove(S.auras.party1, 1)
        mock.fire("UNIT_AURA", "party1"); mock.runOnUpdate(3, 0.3); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(joined():find("Brand New Debuff", 1, true), "tooltip not refreshed after UNIT_AURA:\n" .. joined())
        assertNil(joined():find("Poison Sting", 1, true))
        assertNotNil(joined():find("Debuffs (6)", 1, true))
    end)
    it("leaving the unit hides the tooltip and stops refreshing", function()
        local b = buttonFor("party1")
        local hid = false
        _G.GameTooltip.Hide = function() hid = true end
        st(b).hooks.OnLeave[1](b)
        assertTrue(hid)
        assertNil(ns.UnitFrames.hovered)
    end)
    it("no debuffs: no debuff section out of combat", function()
        S.auras.party1 = {}
        hover("party1")
        assertNil(joined():find("Debuffs (", 1, true)); assertNil(joined():find("hidden by the game", 1, true))
    end)
end)

describe("tooltip: options", function()
    local ns = boot()
    recorder()
    S.auras.party1 = sixDebuffs()
    S.auras.party1[#S.auras.party1 + 1] = { spellId = 9000, name = "Blessing of Kings", icon = 7, duration = 600, expirationTime = 0, applications = 0, isHelpful = true, auraInstanceID = 400 }
    it("'Show debuff list' off hides the section", function()
        ns.db.auras.tooltipDebuffs = false
        hover("party1")
        assertNil(joined():find("Debuffs (", 1, true)); assertNil(joined():find("Poison Sting", 1, true))
        assertNotNil(joined():find("Click-casting", 1, true), "the rest of the tooltip stays")
    end)
    it("'Also list buffs' adds buff lines (and off removes them)", function()
        ns.db.auras.tooltipDebuffs = true; ns.db.auras.tooltipBuffs = false
        hover("party1")
        assertNil(joined():find("Blessing of Kings", 1, true))
        ns.db.auras.tooltipBuffs = true
        hover("party1")
        assertNotNil(joined():find("Blessing of Kings", 1, true), joined())
        assertNotNil(joined():find("Buffs (1)", 1, true))
        assertNotNil(joined():find("Poison Sting", 1, true), "debuffs still listed")
        assertNil(joined():find("Blessing of Kings %- ", 1), "buff lines have no type label")
    end)
    it("debuffs are listed before buffs", function()
        local d, b
        for i, l in ipairs(lines) do
            if l:find("Poison Sting", 1, true) then d = d or i end
            if l:find("Blessing of Kings", 1, true) then b = b or i end
        end
        assertTrue(d < b)
    end)
    it("the options checkboxes toggle the settings", function()
        ns.Options:Show("auras"); mock.flushTimers()
        local function cb(label)
            for _, f in ipairs(mock.frames) do if st(f).kind == "CheckButton" and f.label and st(f.label).text == label then return f end end
        end
        local d, b = cb("Show debuff list in hover tooltip"), cb("Also list buffs in hover tooltip")
        assertNotNil(d); assertNotNil(b)
        st(d).checked = false; st(d).scripts.OnClick(d); assertFalse(ns.db.auras.tooltipDebuffs)
        st(d).checked = true; st(d).scripts.OnClick(d); assertTrue(ns.db.auras.tooltipDebuffs)
        st(b).checked = false; st(b).scripts.OnClick(b); assertFalse(ns.db.auras.tooltipBuffs)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a saved variable without the tooltip settings gets defaults", function()
        mock.install()
        local n, _, e = L.loadContract({})
        _G.HealerForeverCharDB = { auras = { maxBuffs = 3 } }
        mock.fire("ADDON_LOADED", "HealerForever")
        assertEquals(type(_G.HealerForeverCharDB.auras.tooltipDebuffs), "boolean")
        assertEquals(type(_G.HealerForeverCharDB.auras.tooltipBuffs), "boolean")
    end)
end)

describe("tooltip: secret values (readable but secret) and combat", function()
    local function setup()
        local ns = boot()
        recorder()
        S.auras.party1 = sixDebuffs()
        return ns
    end
    local function count(s, pat) local n = 0 for _ in s:gmatch(pat) do n = n + 1 end return n end
    it("in combat with secret aura fields: names are passed straight to AddLine (with AddTexture icons), no error, no 'hidden' line", function()
        local ns = setup()
        S.secret = true      -- secret data while the game still lets us read (e.g. the real login case); in combat nothing is read at all, see below
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        local out = joined()
        assertNil(out:find("hidden by the game", 1, true), "the hidden line is only for a total enumeration failure:\n" .. out)
        assertEquals(count(out, "<secret>"), 6, "all 6 secret names must be passed through:\n" .. out)
        assertEquals(#textures, 6, "one AddTexture icon per secret entry")
        assertNotNil(out:find("Debuffs (6)", 1, true))
        assertNotNil(out:find("Click-casting", 1, true), "tooltip still completes")
    end)
    it("a secret aura TABLE (length/index raise): enumeration falls back to instance IDs and still lists every aura", function()
        local ns = setup()
        S.secret = true; S.secretTable = true
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        assertNil(joined():find("hidden by the game", 1, true), joined())
        assertEquals(count(joined(), "<secret>"), 6, joined())
    end)
    it("the secret table AND instance IDs unavailable: falls back to GetAuraDataByIndex", function()
        local ns = setup()
        S.secret = true; S.secretTable = true; S.noInstanceIDs = true
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(count(joined(), "<secret>"), 6, joined())
    end)
    it("ONLY when every enumeration method fails does the 'hidden by the game' line appear", function()
        local ns = setup()
        S.secret = true; S.failAll = true
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(joined():find("Debuffs hidden by the game during combat", 1, true), joined())
        assertEquals(count(joined(), "<secret>"), 0)
        assertNotNil(joined():find("Click-casting", 1, true))
    end)
    it("table readable but individual fields secret: same passthrough behaviour", function()
        local ns = setup()
        S.secret = true
        _G.issecrettable = function() return false end
        _G.canaccesstable = function() return true end
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(count(joined(), "<secret>"), 6, joined())
        assertNil(joined():find("hidden by the game", 1, true))
    end)
    it("secret names that cannot even be handed to AddLine are counted as hidden entries", function()
        local ns = setup()
        S.secret = true
        _G.GameTooltip.AddLine = function(_, text, r)
            if mock.isSecret(text) then error("tooltip refused a secret") end
            lines[#lines + 1] = tostring(text)
        end
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(joined():find("6 entries hidden by the game", 1, true), joined())
    end)
    it("IN COMBAT the unit tooltip lists no auras at all: one explanatory line per section, ZERO aura API calls, the rest of the tooltip completes", function()
        local ns = setup()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        mock.resetAuraCalls()
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        local out = joined()
        assertTrue(count(out, "Auras are shown on the bar during combat") >= 1, out)
        assertNil(out:find("Debuffs (", 1, true)); assertNil(out:find("<secret>", 1, true)); assertEquals(#textures, 0)
        assertEquals(mock.auraCalls.total, 0, "no aura API call while building a combat tooltip: " .. tostring(next(mock.auraCalls.byName)))
        assertNotNil(out:find("Click-casting", 1, true), "tooltip still completes")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    end)
    it("leaving combat restores the aura list in the tooltip", function()
        local ns = setup()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED"); hover("party1")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        hover("party1")
        assertNotNil(joined():find("Debuffs (6)", 1, true), joined())
    end)
    it("a single secret field (name only) among readable auras: readable ones listed, no error", function()
        local ns = setup()
        S.combat = false
        local real = C_UnitAuras.GetUnitAuras
        C_UnitAuras.GetUnitAuras = function(u, f)
            local list = real(u, f)
            list[1].name = mock.newSecret()
            return list
        end
        S.secret = false
        local realIs = _G.issecretvalue
        _G.issecretvalue = function(v) return mock.isSecret(v) end
        hover("party1")
        _G.issecretvalue = realIs
        C_UnitAuras.GetUnitAuras = real
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(joined():find("Fire Debuff", 1, true), "readable debuffs must still be listed:\n" .. joined())
    end)
    it("hovering during combat transitions (enter, leave, UNIT_AURA, OnUpdate refresh) never errors", function()
        local ns = setup()
        for _ = 1, 4 do
            S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED")
            hover("party1"); mock.fire("UNIT_AURA", "party1"); mock.runOnUpdate(3, 0.3)
            S.combat = false; S.secret = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
            hover("party1"); mock.runOnUpdate(2, 0.3)
        end
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, 0)
    end)
    it("GetUnitAuras raising (API change) does not break the tooltip", function()
        local ns = setup()
        C_UnitAuras.GetUnitAuras = function() error("boom") end
        C_UnitAuras.GetAuraDataByIndex = function() error("boom") end
        hover("party1")
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil(joined():find("Click-casting", 1, true))
    end)
    it("a unit that does not exist: hover does not error", function()
        local ns = setup()
        local b = buttonFor("party4")
        if b then st(b).hooks.OnEnter[1](b) end
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
