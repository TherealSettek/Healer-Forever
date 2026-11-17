-- Early rebuff: buffs.rebuffPercent (default 5, clamped 0-50). A class buff counts as missing when it is gone or below that % of its duration;
-- permanent / unknown / secret durations never count. Role buffs keep the seconds threshold. Presets.BuffReport, the badge, smart button,
-- MissingCount, the /hf debug buffs lines, the warn checkbox and the two sliders.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end
local function deepcopy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = deepcopy(v) end return o end

-- ======================================================================== pure: Presets.BuffReport / GetMissingBuffs
mock.install()
local pns = {}
local _, _, perrs = L.loadContract(pns)
if next(perrs) then it("contract loads", function() error(tostring(select(2, next(perrs)))) end) return end
local P, C = pns.Presets, pns.Classes
local NOW = 1000
local preset = { name = "x", map = { WARRIOR = { DEFAULT = { "fortitude", "spirit" } }, PALADIN = { DEFAULT = { "kings" } } }, extras = {} }
P.MigratePreset(preset)
local function aura(key, remaining, duration, extra)
    local d = C.BUFFS[key]
    local a = { spellId = d.spellIds[1], name = d.name, expirationTime = remaining and (NOW + remaining) or 0, duration = duration }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local function missing(auras, pct, threshold, cls)
    return P.GetMissingBuffs(cls or "WARRIOR", auras, preset, NOW, C.BUFFS, threshold or 60, nil, false, pct)
end

describe("rebuff: boundaries of the percent rule (a 300s buff, default 5%)", function()
    it("4.9% left (14.7s) is missing; exactly 5% (15s) is NOT (strictly below); 5.1% (15.3s) is not", function()
        assertDeepEquals(missing({ aura("fortitude", 14.7, 300), aura("spirit", 600, 600) }, 5), { "fortitude" })
        assertDeepEquals(missing({ aura("fortitude", 15, 300), aura("spirit", 600, 600) }, 5), {})
        assertDeepEquals(missing({ aura("fortitude", 15.3, 300), aura("spirit", 600, 600) }, 5), {})
    end)
    it("the boundary scales with the percent: 10% of 300s is 30s", function()
        assertDeepEquals(missing({ aura("fortitude", 29.9, 300), aura("spirit", 600, 600) }, 10), { "fortitude" })
        assertDeepEquals(missing({ aura("fortitude", 30, 300), aura("spirit", 600, 600) }, 10), {})
        assertDeepEquals(missing({ aura("fortitude", 149, 300), aura("spirit", 600, 600) }, 50), { "fortitude" })
        assertDeepEquals(missing({ aura("fortitude", 151, 300), aura("spirit", 600, 600) }, 50), {})
    end)
    it("the boundary scales with the DURATION: 5% of a 3600s buff is 180s, of a 60s buff 3s", function()
        assertDeepEquals(missing({ aura("fortitude", 179, 3600), aura("spirit", 600, 600) }, 5), { "fortitude" })
        assertDeepEquals(missing({ aura("fortitude", 181, 3600), aura("spirit", 600, 600) }, 5), {})
        assertDeepEquals(missing({ aura("fortitude", 2.9, 60), aura("spirit", 600, 600) }, 5), { "fortitude" })
        assertDeepEquals(missing({ aura("fortitude", 3.1, 60), aura("spirit", 600, 600) }, 5), {})
    end)
    it("0% means only when gone: even 1 second left is fine, an expired aura (remaining <= 0) still counts as missing", function()
        assertDeepEquals(missing({ aura("fortitude", 1, 300), aura("spirit", 1, 300) }, 0), {})
        assertDeepEquals(missing({ aura("fortitude", 0, 300, { expirationTime = NOW }), aura("spirit", 100, 300) }, 0), { "fortitude" })
        assertDeepEquals(missing({}, 0), { "fortitude", "spirit" })
    end)
    it("an expired aura counts as missing under every percent", function()
        for _, pct in ipairs({ 0, 5, 50 }) do
            assertDeepEquals(missing({ aura("fortitude", -3, 300), aura("spirit", 600, 600) }, pct), { "fortitude" }, tostring(pct))
        end
    end)
    it("permanent (no expiration) and unknown-duration auras never count as running out", function()
        assertDeepEquals(missing({ aura("fortitude", nil, 0), aura("spirit", nil, nil) }, 50), {}, "expirationTime 0 = permanent")
        assertDeepEquals(missing({ aura("fortitude", 2, 0), aura("spirit", 2, nil) }, 50), {}, "duration 0 / unknown: cannot take a percent")
        assertDeepEquals(missing({ aura("fortitude", 2, -5), aura("spirit", 2, "x") }, 50), {}, "garbage durations are ignored")
    end)
    it("a SECRET duration is ignored (Snapshot hands nil on); BuffReport tolerates a missing duration field", function()
        assertDeepEquals(missing({ { spellId = C.BUFFS.fortitude.spellIds[1], name = "Power Word: Fortitude", expirationTime = NOW + 2 }, aura("spirit", 600, 600) }, 50), {})
        mock.install()
        local sns = {}
        L.loadContract(sns)
    end)
    it("the best matching aura wins: a fresh aura next to an expiring one counts as present", function()
        assertDeepEquals(missing({ aura("fortitude", 5, 300), aura("fortitude", 250, 300), aura("spirit", 600, 600) }, 5), {})
    end)
    it("percent = nil falls back to the seconds rule (the older callers): 59s missing, 60s present", function()
        assertDeepEquals(missing({ aura("fortitude", 59, 300), aura("spirit", 600, 600) }, nil, 60), { "fortitude" })
        assertDeepEquals(missing({ aura("fortitude", 60, 300), aura("spirit", 600, 600) }, nil, 60), {})
    end)
    it("BuffReport items: key, missing, auraName, remaining, pct and the rule text", function()
        local rep = P.BuffReport("WARRIOR", { aura("fortitude", 150, 300), aura("spirit", 6, 300) }, preset, NOW, C.BUFFS, 60, nil, false, 5)
        assertEquals(#rep, 2)
        assertEquals(rep[1].key, "fortitude"); assertFalse(rep[1].missing); assertEquals(rep[1].auraName, "Power Word: Fortitude")
        assertEquals(rep[1].remaining, 150); assertTrue(math.abs(rep[1].pct - 50) < 1e-9); assertEquals(rep[1].rule, "5% of its duration")
        assertEquals(rep[2].key, "spirit"); assertTrue(rep[2].missing); assertEquals(rep[2].auraName, "Divine Spirit"); assertTrue(math.abs(rep[2].pct - 2) < 1e-9)
        local old = P.BuffReport("WARRIOR", {}, preset, NOW, C.BUFFS, 60, nil, false, nil)
        assertEquals(old[1].rule, "60s"); assertTrue(old[1].missing); assertNil(old[1].auraName); assertNil(old[1].pct)
    end)
    it("a buff def that is unknown never raises and counts as missing", function()
        local pp = { name = "g", map = { WARRIOR = { DEFAULT = { "ghostbuff" } } } }
        assertTrue(pcall(P.BuffReport, "WARRIOR", {}, pp, NOW, C.BUFFS, 60, nil, false, 5))
        assertTrue(P.BuffReport("WARRIOR", {}, pp, NOW, C.BUFFS, 60, nil, false, 5)[1].missing)
    end)
end)

-- ======================================================================== whole addon
local function boot(class, opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = class or "PRIEST"
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 3)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function refresh() mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers() end
local function buffBtn(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == u then return f end end end
local function extraBtn(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverExtra%d$") and f.unit == u then return f end end end
local function smart() for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverSmartBuff" then return f end end end
local function active(b) return b:GetAlpha() > 0 and st(b).mouse == true end
local function assign(ns, class, keys) ns.db.presets[ns.db.activePreset].map[class] = { DEFAULT = keys }; ns:Changed("presets"); refresh() end
local function auraOf(ns, key, remaining, duration)
    local d = ns.Classes.BUFFS[key]
    return { spellId = d.spellIds[1] or 0, name = d.name, icon = 1, duration = duration, expirationTime = remaining and (S.now + remaining) or 0, isHelpful = true,
        sourceUnit = "player", auraInstanceID = 6000 + ns.Classes.BuffOrder(key) }
end
local function setBuffs(u, list) S.auras[u] = list; mock.fire("UNIT_AURA", u); refresh() end
local function debugText()
    mock.printed = {}
    assert(pcall(_G.SlashCmdList.HEALERFOREVER, "debug buffs"))
    return table.concat(mock.printed, "\n")
end
local function sliderFor(text) for _, f in ipairs(mock.frames) do if f.slider and f.label and st(f.label).text == text then return f end end error("slider " .. text) end
local function checkboxFor(text) for _, f in ipairs(mock.frames) do if st(f).kind == "CheckButton" and f.label and st(f.label).text == text then return f end end error("checkbox " .. text) end
local function setSlider(sf, v) st(sf.slider).value = v; st(sf.slider).scripts.OnValueChanged(sf.slider, v, true); mock.flushTimers() end

describe("rebuff: the option, defaults and clamping on load", function()
    it("buffs.rebuffPercent defaults to 5 and is NOT written to the profile while default", function()
        local ns = boot()
        assertEquals(ns.db.buffs.rebuffPercent, 5); assertEquals(ns.DEFAULTS.buffs.rebuffPercent, 5)
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.buffs == nil or HealerForeverCharDB.buffs.rebuffPercent == nil)
    end)
    it("clamped on load: -5 -> 0, 99 -> 50, 0 and 50 kept, a string/table/boolean -> the default 5, NaN/huge handled", function()
        for _, c in ipairs({ { -5, 0 }, { 99, 50 }, { 0, 0 }, { 50, 50 }, { 12, 12 }, { "x", 5 }, { {}, 5 }, { true, 5 }, { 1e9, 50 }, { -1e9, 0 } }) do
            local ns = boot("PRIEST", { char = { version = 4, buffs = { rebuffPercent = c[1] } } })
            assertEquals(ns.db.buffs.rebuffPercent, c[2], "saved " .. tostring(c[1]))
            assertEquals(#mock.errors, 0, errstr())
        end
        local ns = boot("PRIEST", { char = { version = 4, buffs = { rebuffPercent = 0 / 0 } } })
        local v = ns.db.buffs.rebuffPercent
        assertTrue(type(v) == "number" and v >= 0 and v <= 50, tostring(v))
    end)
    it("a profile saved before the option existed (no key) gets 5", function()
        local ns = boot("PRIEST", { char = { version = 4, buffs = { warn = true, threshold = 90 } } })
        assertEquals(ns.db.buffs.rebuffPercent, 5); assertEquals(ns.db.buffs.threshold, 90)
    end)
    it("a changed value is saved sparsely and survives a reload", function()
        local ns = boot()
        ns.db.buffs.rebuffPercent = 17
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(saved.buffs.rebuffPercent, 17); assertNil(saved.buffs.warn, "other defaults stay unsaved")
        local ns2 = boot("PRIEST", { char = saved })
        assertEquals(ns2.db.buffs.rebuffPercent, 17)
        ns2.db.buffs.rebuffPercent = 5
        mock.fire("PLAYER_LOGOUT")
        assertTrue(HealerForeverCharDB.buffs == nil or HealerForeverCharDB.buffs.rebuffPercent == nil, "back to the default: omitted again")
    end)
end)

describe("rebuff: class buffs on the buttons use the percent", function()
    local function fresh(pct)
        local ns = boot("PRIEST")
        if pct then ns.db.buffs.rebuffPercent = pct end
        assign(ns, "WARRIOR", { "fortitude", "spirit" })
        return ns
    end
    it("badge, button and next buff follow the percent: with 20%, 100s of 600s (16.7%) rebuffs and 130s (21.7%) does not", function()
        local ns = fresh(20)
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600), auraOf(ns, "spirit", 600, 600) })
        local b = buffBtn("party1")
        assertEquals(b.buffKey, "fortitude"); assertTrue(active(b)); assertEquals(st(b.count).text, "")
        setBuffs("party1", { auraOf(ns, "fortitude", 130, 600), auraOf(ns, "spirit", 100, 600) })
        assertEquals(buffBtn("party1").buffKey, "spirit")
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600), auraOf(ns, "spirit", 100, 600) })
        assertEquals(st(buffBtn("party1").count).text, "2", "both running out: the badge says 2")
        setBuffs("party1", { auraOf(ns, "fortitude", 130, 600), auraOf(ns, "spirit", 130, 600) })
        assertFalse(active(buffBtn("party1")))
    end)
    it("changing the option applies live (ns:Changed refreshes the buttons)", function()
        local ns = fresh(5)
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600), auraOf(ns, "spirit", 100, 600) })
        assertFalse(active(buffBtn("party1")), "16.7% left, threshold 5%: fine")
        ns.db.buffs.rebuffPercent = 20; ns:Changed("presets"); refresh()
        assertTrue(active(buffBtn("party1")))
        ns.db.buffs.rebuffPercent = 0; ns:Changed("presets"); refresh()
        assertFalse(active(buffBtn("party1")))
    end)
    it("MissingCount counts early-rebuff buffs; the minimap dot turns red for them", function()
        local ns = fresh(20)
        for _, u in ipairs({ "player", "party1", "party2", "party3", "party4" }) do S.auras[u] = {} end
        for _, c in ipairs({ "PRIEST", "MAGE", "PALADIN", "ROGUE" }) do ns.db.presets[ns.db.activePreset].map[c] = { DEFAULT = {} } end
        ns.db.presets[ns.db.activePreset].self = {}
        ns:Changed("presets"); refresh()
        setBuffs("party1", { auraOf(ns, "fortitude", 500, 600), auraOf(ns, "spirit", 500, 600) })
        assertEquals(ns.BuffButtons:MissingCount(), 0)
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600), auraOf(ns, "spirit", 100, 600) })
        assertEquals(ns.BuffButtons:MissingCount(), 2)
        local mb
        for _, f in ipairs(mock.frames) do if st(f).name == "HealerForeverMinimapButton" then mb = f end end
        ns.MinimapButton:UpdateBadges()
        local v = st(mb.dot).vertex
        assertTrue(v.r > 0.9 and v.g < 0.3, "red")
        setBuffs("party1", { auraOf(ns, "fortitude", 500, 600), auraOf(ns, "spirit", 500, 600) })
        ns.MinimapButton:UpdateBadges()
        assertEquals(ns.BuffButtons:MissingCount(), 0); assertTrue(st(mb.dot).vertex.g > 0.8)
    end)
    it("the smart button offers the early rebuff and moves on after it", function()
        local ns = fresh(20)
        for _, c in ipairs({ "PRIEST", "MAGE", "ROGUE", "PALADIN" }) do ns.db.presets[ns.db.activePreset].map[c] = { DEFAULT = {} } end
        ns.db.presets[ns.db.activePreset].self = {}; ns:Changed("presets")
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600), auraOf(ns, "spirit", 600, 600) })
        assertEquals(smart().castUnit, "party1"); assertEquals(smart().castSpell, "Power Word: Fortitude")
        setBuffs("party1", { auraOf(ns, "fortitude", 590, 600), auraOf(ns, "spirit", 600, 600) })
        assertNil(smart().castUnit)
    end)
    it("permanent buffs and buffs without a readable duration never trigger an early rebuff, whatever the percent", function()
        local ns = fresh(50)
        setBuffs("party1", { auraOf(ns, "fortitude", nil, 0), auraOf(ns, "spirit", 3, nil) })
        assertFalse(active(buffBtn("party1")))
    end)
    it("a buff that is simply gone is always missing, even at 0%", function()
        local ns = fresh(0)
        setBuffs("party1", { auraOf(ns, "fortitude", 1, 600) })
        assertEquals(buffBtn("party1").buffKey, "spirit")
    end)
    it("the first scan with secret durations (everything secret) neither errors nor invents a rebuff", function()
        local ns = fresh(50)
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600), auraOf(ns, "spirit", 100, 600) })
        S.secretAll = true
        refresh(); mock.runOnUpdate(3, 0.5)
        S.secretAll = false
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("in combat the buttons stay frozen and nothing protected is touched; after combat the percent rule applies", function()
        local ns = fresh(20)
        setBuffs("party1", { auraOf(ns, "fortitude", 590, 600), auraOf(ns, "spirit", 590, 600) })
        assertFalse(active(buffBtn("party1")))
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.auras.party1 = { auraOf(ns, "fortitude", 60, 600), auraOf(ns, "spirit", 60, 600) }
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers(); mock.tick()
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); refresh()
        assertTrue(active(buffBtn("party1")))
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("rebuff: role buffs keep the seconds threshold; the warn checkbox disables both rules", function()
    local function withExtra()
        local ns = boot("PALADIN")
        ns.Presets.AddExtra(ns.db.presets[ns.db.activePreset], "Oath of Light", { TANK = true }, false)
        ns.db.presets[ns.db.activePreset].map.WARRIOR = { DEFAULT = {} }
        ns.db.buffs.rebuffPercent = 50          -- must not influence role buffs
        ns:Changed("presets"); refresh()
        return ns
    end
    local function extraAura(remaining, duration) return { spellId = 900003, name = "Oath of Light", icon = 1, duration = duration, expirationTime = S.now + remaining, isHelpful = true, sourceUnit = "player", auraInstanceID = 77 } end
    it("an extra buff is missing below the SECONDS threshold (default 60) regardless of the percent: 59s yes, 61s no", function()
        local ns = withExtra()
        setBuffs("party1", { extraAura(59, 600) })
        assertTrue(active(extraBtn("party1")))
        setBuffs("party1", { extraAura(61, 600) })
        assertFalse(active(extraBtn("party1")))
        ns.db.buffs.threshold = 120; ns:Changed("presets"); refresh()
        assertTrue(active(extraBtn("party1")), "61s < 120s")
    end)
    it("warn OFF: class buffs only when gone AND role buffs only when absent", function()
        local ns = withExtra()
        ns.db.buffs.warn = false
        setBuffs("party1", { extraAura(5, 600) })
        assertFalse(active(extraBtn("party1")), "role buff: 5s left but warn is off")
        S.auras.party1 = {}; mock.fire("UNIT_AURA", "party1"); refresh()
        assertTrue(active(extraBtn("party1")), "role buff absent: shown")
        local ns2 = boot("PRIEST")
        ns2.db.buffs.warn = false
        assign(ns2, "WARRIOR", { "fortitude" })
        setBuffs("party1", { auraOf(ns2, "fortitude", 1, 600) })
        assertFalse(active(buffBtn("party1")), "class buff: 1s left but warn is off")
    end)
    it("the warn checkbox ('Rebuff early (uncheck: only when a buff is gone)') toggles it and applies live", function()
        local ns = boot("PRIEST")
        assign(ns, "WARRIOR", { "fortitude" })
        ns.Options:Show("auras"); mock.flushTimers()
        local cb = checkboxFor("Rebuff early (uncheck: only when a buff is gone)")
        assertTrue(st(cb).checked and true or false)
        setBuffs("party1", { auraOf(ns, "fortitude", 20, 600) })
        assertTrue(active(buffBtn("party1")), "3.3% left: early rebuff")
        st(cb).checked = false; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers(); refresh()
        assertFalse(ns.db.buffs.warn); assertFalse(active(buffBtn("party1")))
        st(cb).checked = true; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers(); refresh()
        assertTrue(active(buffBtn("party1")))
    end)
end)

describe("rebuff: the two sliders", function()
    it("'Class buffs: rebuff below (% left)' 0-50 and 'Role buffs: rebuff below (s left)' 10-300 exist, save, apply live and survive a reload", function()
        local ns = boot("PRIEST")
        assign(ns, "WARRIOR", { "fortitude" })
        ns.Options:Show("auras"); mock.flushTimers()
        local pct, thr = sliderFor("Class buffs: rebuff below (% left)"), sliderFor("Role buffs: rebuff below (s left)")
        assertEquals(st(pct.slider).min, 0); assertEquals(st(pct.slider).max, 50)
        assertEquals(st(thr.slider).min, 10); assertEquals(st(thr.slider).max, 300)
        assertEquals(st(pct.slider).value, 5)
        setBuffs("party1", { auraOf(ns, "fortitude", 100, 600) })
        assertFalse(active(buffBtn("party1")))
        setSlider(pct, 20)
        assertEquals(ns.db.buffs.rebuffPercent, 20); refresh()
        assertTrue(active(buffBtn("party1")), "applies live")
        setSlider(thr, 90)
        assertEquals(ns.db.buffs.threshold, 90)
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        assertEquals(saved.buffs.rebuffPercent, 20); assertEquals(saved.buffs.threshold, 90)
        local ns2 = boot("PRIEST", { char = saved })
        ns2.Options:Show("auras"); mock.flushTimers()
        assertEquals(ns2.db.buffs.rebuffPercent, 20); assertEquals(st(sliderFor("Class buffs: rebuff below (% left)").slider).value, 20)
        assertEquals(st(sliderFor("Role buffs: rebuff below (s left)").slider).value, 90)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("dragging the percent slider across its whole range never errors and always stores a clamped value", function()
        local ns = boot("PRIEST")
        ns.Options:Show("auras"); mock.flushTimers()
        local pct = sliderFor("Class buffs: rebuff below (% left)")
        for v = 0, 50, 5 do setSlider(pct, v); assertEquals(ns.db.buffs.rebuffPercent, v) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the sliders work in combat (queued like every config change) without protected calls", function()
        local ns = boot("PRIEST")
        ns.Options:Show("auras"); mock.flushTimers()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        setSlider(sliderFor("Class buffs: rebuff below (% left)"), 30)
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(ns.db.buffs.rebuffPercent, 30); assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("rebuff: /hf debug buffs prints a line per assigned buff with the rule that applied", function()
    it("present / RUNNING OUT / MISSING, the aura, time left, % left and 'rebuff below N% of its duration'", function()
        local ns = boot("PRIEST")
        assign(ns, "WARRIOR", { "fortitude", "spirit", "shadowprot" })
        setBuffs("party1", { auraOf(ns, "fortitude", 300, 600), auraOf(ns, "spirit", 12, 600) })
        local out = debugText()
        assertTrue(out:find("Power Word: Fortitude: present | aura=Power Word: Fortitude | left=300s | 50.0% | rebuff below 5% of its duration", 1, true), out)
        assertTrue(out:find("Divine Spirit: RUNNING OUT | aura=Divine Spirit | left=12s | 2.0% | rebuff below 5% of its duration", 1, true), out)
        assertTrue(out:find("Shadow Protection: MISSING | aura=- | left=- | -% | rebuff below 5% of its duration", 1, true), out)
    end)
    it("the rule text follows the option, and a permanent aura prints 'no expiry'", function()
        local ns = boot("PRIEST")
        ns.db.buffs.rebuffPercent = 12
        assign(ns, "WARRIOR", { "fortitude" })
        setBuffs("party1", { auraOf(ns, "fortitude", nil, 0) })
        local out = debugText()
        assertTrue(out:find("rebuff below 12% of its duration", 1, true), out); assertTrue(out:find("left=no expiry", 1, true), out)
        ns.db.buffs.warn = false; refresh()
        assertTrue(debugText():find("rebuff below 0% of its duration", 1, true), "warn off = gone only")
    end)
    it("works solo, in combat and with everything secret", function()
        local ns = boot("PRIEST", { group = 1 })
        assertTrue(pcall(_G.SlashCmdList.HEALERFOREVER, "debug buffs"))
        S.combat = true; debugText(); S.secretAll = true; debugText(); S.secretAll = false; S.combat = false
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
