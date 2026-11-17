-- Layer 2: unit tests of the pure modules against the agreed contract.
local L = require("loader")
local mock = require("wow_mock")

local function fresh()
    mock.install()
    local ns, missing, errs = L.loadContract({})
    return ns, missing, errs
end

local ns, missing, loadErrs = fresh()

describe("contract files load", function()
    it("all contract files exist", function()
        assertEquals(#missing, 0, "missing: " .. table.concat(missing, ", "))
    end)
    it("all contract files load without error (mock env)", function()
        local msgs = {}
        for f, e in pairs(loadErrs) do msgs[#msgs + 1] = f .. ": " .. e end
        assertEquals(#msgs, 0, table.concat(msgs, "\n"))
    end)
end)

-- ---------------------------------------------------------------- Util
describe("Util.FormatAuraTime", function()
    local U = ns.Util
    if not U then it("ns.Util exists", function() error("ns.Util missing") end) return end
    local cases = {
        { 0, "" }, { -1, "" }, { nil, "" }, { -0.0001, "" },
        { 0.05, string.format("%.1f", 0.05) }, { 0.1, "0.1" }, { 5, "5.0" },
        { 9.94, "9.9" }, { 9.95, string.format("%.1f", 9.95) },
        { 10, "10" }, { 10.9, "10" }, { 59.9, "59" }, { 59, "59" },
        { 60, "1m" }, { 60.1, "2m" }, { 61, "2m" }, { 119, "2m" }, { 299, "5m" },
        { 3599, "60m" }, { 3599.9, "60m" }, { 3600, "1h" }, { 7199, "1h" }, { 7300, "2h" }, { 86400, "24h" },
    }
    for _, c in ipairs(cases) do
        it("FormatAuraTime(" .. tostring(c[1]) .. ") == " .. string.format("%q", c[2]), function()
            assertEquals(U.FormatAuraTime(c[1]), c[2])
        end)
    end
    it("matches the reference formula across a sweep", function()
        local function ref(s)
            if not s or s <= 0 then return "" end
            if s >= 3600 then return math.floor(s / 3600) .. "h" end
            if s >= 60 then return math.ceil(s / 60) .. "m" end
            if s >= 10 then return tostring(math.floor(s)) end
            return string.format("%.1f", s)
        end
        for s = -5, 8000, 0.37 do assertEquals(U.FormatAuraTime(s), ref(s), "s=" .. s) end
    end)
    it("always returns a string", function()
        for _, v in ipairs({ 0, 1, 1e9, 1e-9, -1e9 }) do assertEquals(type(U.FormatAuraTime(v)), "string") end
        assertEquals(type(U.FormatAuraTime(nil)), "string")
    end)
end)

describe("Util.DeepCopy", function()
    local U = ns.Util
    it("copies nested tables independently", function()
        local src = { a = 1, b = { c = { d = 2 } }, l = { 1, 2, 3 } }
        local cp = U.DeepCopy(src)
        assertDeepEquals(cp, src)
        cp.b.c.d = 99; cp.l[1] = 99
        assertEquals(src.b.c.d, 2); assertEquals(src.l[1], 1)
        assertTrue(cp.b ~= src.b)
    end)
    it("preserves false and 0", function()
        local cp = U.DeepCopy({ a = false, b = 0 })
        assertEquals(cp.a, false); assertEquals(cp.b, 0)
    end)
    it("handles empty tables and non-tables", function()
        assertDeepEquals(U.DeepCopy({}), {})
        assertEquals(U.DeepCopy(5), 5)
        assertEquals(U.DeepCopy("x"), "x")
        assertNil(U.DeepCopy(nil))
    end)
    it("copes with string keys that look numeric and mixed keys", function()
        local cp = U.DeepCopy({ [1] = "a", ["1"] = "b", x = { [2] = true } })
        assertEquals(cp[1], "a"); assertEquals(cp["1"], "b"); assertEquals(cp.x[2], true)
    end)
end)

describe("Util.MergeDefaults", function()
    local U = ns.Util
    it("fills missing keys recursively", function()
        local saved = { a = 1, n = { x = 1 } }
        local r = U.MergeDefaults(saved, { a = 5, b = 6, n = { x = 9, y = 8 }, m = { z = 1 } })
        assertDeepEquals(r, { a = 1, b = 6, n = { x = 1, y = 8 }, m = { z = 1 } })
        assertTrue(r == saved, "returns saved (same table)")
    end)
    it("never overwrites false or 0", function()
        local r = U.MergeDefaults({ f = false, z = 0, s = "" }, { f = true, z = 7, s = "d" })
        assertEquals(r.f, false); assertEquals(r.z, 0); assertEquals(r.s, "")
    end)
    it("nil saved -> deep copy of defaults; mutating it does not touch defaults", function()
        local d = { a = { b = 1 }, l = { 1, 2 } }
        local r = U.MergeDefaults(nil, d)
        assertDeepEquals(r, d)
        r.a.b = 99; r.l[1] = 99
        assertEquals(d.a.b, 1); assertEquals(d.l[1], 1)
    end)
    it("defaults subtables copied (not aliased) into saved", function()
        local d = { a = { b = 1 } }
        local r = U.MergeDefaults({}, d)
        r.a.b = 5
        assertEquals(d.a.b, 1)
    end)
    it("preserves extra keys in saved tables, at every depth", function()
        local r = U.MergeDefaults({ extra = 1, n = { extra2 = 2 } }, { n = { y = 1 } })
        assertEquals(r.extra, 1); assertEquals(r.n.extra2, 2); assertEquals(r.n.y, 1)
    end)
    -- Design note: MergeDefaults itself never replaces existing values (even of the wrong type);
    -- recovery from corrupted SavedVariables is checked at the ns:Init() level below.
    it("type mismatch: saved string where default is table does not error", function()
        local ok, r = pcall(U.MergeDefaults, { frames = "oops" }, { frames = { layout = "horizontal" } })
        assertTrue(ok, tostring(r))
        assertNotNil(r.frames)
    end)
    it("type mismatch: saved number where default is table does not error", function()
        local ok, r = pcall(U.MergeDefaults, { bindings = 5 }, { bindings = { ["|1"] = { type = "target" } } })
        assertTrue(ok, tostring(r))
    end)
    it("saved is a non-table -> no error", function()
        local ok, r = pcall(U.MergeDefaults, "garbage", { a = 1 })
        assertTrue(ok, tostring(r))
    end)
    it("type mismatch: saved table where default is a scalar is kept", function()
        local r = U.MergeDefaults({ a = { 1 } }, { a = 5 })
        assertEquals(type(r.a), "table")
    end)
    it("empty defaults leave saved alone", function()
        assertDeepEquals(U.MergeDefaults({ a = 1 }, {}), { a = 1 })
    end)
    it("idempotent", function()
        local d = { a = { b = 1 }, c = false }
        local once = U.MergeDefaults({}, d)
        local twice = U.MergeDefaults(U.DeepCopy(once), d)
        assertDeepEquals(once, twice)
    end)
end)

describe("Util.ModifierKey", function()
    local U = ns.Util
    local n = 0
    for mask = 0, 15 do
        local shift, ctrl, alt, meta = mask % 2 == 1, math.floor(mask / 2) % 2 == 1, math.floor(mask / 4) % 2 == 1, math.floor(mask / 8) % 2 == 1
        local parts = {}
        if alt then parts[#parts + 1] = "alt" end
        if ctrl then parts[#parts + 1] = "ctrl" end
        if meta then parts[#parts + 1] = "meta" end
        if shift then parts[#parts + 1] = "shift" end
        local want = table.concat(parts, "-")
        it(string.format("ModifierKey(shift=%s ctrl=%s alt=%s meta=%s) == %q", tostring(shift), tostring(ctrl), tostring(alt), tostring(meta), want), function()
            assertEquals(U.ModifierKey(shift, ctrl, alt, meta), want)
        end)
    end
    it("treats nil as not pressed", function() assertEquals(U.ModifierKey(nil, nil, nil, nil), "") end)
    it("treats truthy non-booleans (1) as pressed", function() assertEquals(U.ModifierKey(1, nil, nil, nil), "shift") end)
    it("no args", function() assertEquals(U.ModifierKey(), "") end)
end)

-- ---------------------------------------------------------------- Bindings
describe("Bindings keys", function()
    local B = ns.Bindings
    if not B then it("ns.Bindings exists", function() error("ns.Bindings missing") end) return end
    it("MakeKey formats", function()
        assertEquals(B.MakeKey("", 1), "|1")
        assertEquals(B.MakeKey("shift", 2), "shift|2")
        assertEquals(B.MakeKey("alt-meta", 1), "alt-meta|1")
    end)
    it("ParseKey returns modKey string and numeric button", function()
        local m, b = B.ParseKey("alt-meta|3")
        assertEquals(m, "alt-meta"); assertEquals(b, 3); assertEquals(type(b), "number")
        m, b = B.ParseKey("|1")
        assertEquals(m, ""); assertEquals(b, 1)
    end)
    it("MakeKey/ParseKey round-trip for all modifiers and buttons 1-5", function()
        for _, mod in ipairs({ "", "alt", "ctrl", "meta", "shift", "alt-ctrl", "alt-meta", "ctrl-shift", "alt-ctrl-meta-shift" }) do
            for btn = 1, 5 do
                local m, b = B.ParseKey(B.MakeKey(mod, btn))
                assertEquals(m, mod); assertEquals(b, btn)
            end
        end
    end)
    for _, bad in ipairs({ "", "|", "shift|", "foo|1", "|0", "|32", "|-1", "|abc", "||1", "1", "shift", "|1|2", " |1" }) do
        it(string.format("ParseKey(%q) does not raise", bad), function()
            local ok, m, b = pcall(B.ParseKey, bad)
            assertTrue(ok, tostring(m))
            assertTrue(b == nil or type(b) == "number", "button must be nil or number")
            assertTrue(m == nil or type(m) == "string", "modKey must be nil or string")
        end)
        it(string.format("ToAttributes(%q, spell) does not raise and returns nil or table", bad), function()
            local ok, r = pcall(B.ToAttributes, bad, { type = "spell", spell = "X" })
            assertTrue(ok, tostring(r))
            assertTrue(r == nil or type(r) == "table")
        end)
    end
    it("ParseKey(nil) does not raise", function() assertTrue(pcall(B.ParseKey, nil)) end)
    it("MakeKey(nil,nil) does not raise", function() assertTrue(pcall(B.MakeKey, nil, nil)) end)
    it("MakeKey with nil modKey behaves like no modifier", function()
        local ok, k = pcall(B.MakeKey, nil, 1)
        assertTrue(ok)
        assertEquals(k, "|1")
    end)
end)

-- Blizzard's SecureButton_GetModifierPrefix (retail 11.x/12.x): alt-ctrl-meta-shift-
local function prefixOf(modKey) if modKey == "" then return "" end return modKey .. "-" end

describe("Bindings.ToAttributes", function()
    local B = ns.Bindings
    it("|1 spell -> type1/spell1", function()
        local a = B.ToAttributes("|1", { type = "spell", spell = "Flash of Light" })
        assertEquals(a["type1"], "spell"); assertEquals(a["spell1"], "Flash of Light")
    end)
    it("shift|2 spell -> shift-type2/shift-spell2", function()
        local a = B.ToAttributes("shift|2", { type = "spell", spell = "Holy Light" })
        assertEquals(a["shift-type2"], "spell"); assertEquals(a["shift-spell2"], "Holy Light")
        assertNil(a["type2"])
    end)
    it("target action", function()
        assertEquals(B.ToAttributes("|1", { type = "target" })["type1"], "target")
    end)
    it("menu action maps to togglemenu", function()
        assertEquals(B.ToAttributes("|2", { type = "menu" })["type2"], "togglemenu")
    end)
    it("macro action carries macrotext", function()
        local a = B.ToAttributes("ctrl|3", { type = "macro", macrotext = "/say hi" })
        assertEquals(a["ctrl-type3"], "macro"); assertEquals(a["ctrl-macrotext3"], "/say hi")
    end)
    -- Blizzard's SecureButton_GetModifierPrefix has NO meta: documented in Bindings.lua. Combos with meta
    -- (and buttons > 5) go through override bindings (NeedsOverride / ToOverrideAttributes) instead.
    it("all 16 modifier combos: secure prefix order alt-ctrl-shift; meta combos return nil (override route)", function()
        for mask = 0, 15 do
            local p, hasMeta = {}, mask % 4 >= 2
            if mask >= 8 then p[#p + 1] = "alt" end
            if mask % 8 >= 4 then p[#p + 1] = "ctrl" end
            if hasMeta then p[#p + 1] = "meta" end
            if mask % 2 == 1 then p[#p + 1] = "shift" end
            local mod = table.concat(p, "-")
            local prefix = ""
            if mask >= 8 then prefix = prefix .. "alt-" end
            if mask % 8 >= 4 then prefix = prefix .. "ctrl-" end
            if mask % 2 == 1 then prefix = prefix .. "shift-" end
            for btn = 1, 5 do
                local a = B.ToAttributes(B.MakeKey(mod, btn), { type = "spell", spell = "S" })
                if hasMeta then
                    assertNil(a, "meta combo " .. mod .. "|" .. btn .. " must not produce secure attributes")
                    assertTrue(B.NeedsOverride(mod, btn), mod .. "|" .. btn .. " must need override route")
                else
                    assertNotNil(a, mod .. "|" .. btn)
                    assertEquals(a[prefix .. "type" .. btn], "spell", "attr for " .. mod .. "|" .. btn)
                    assertEquals(a[prefix .. "spell" .. btn], "S")
                    assertFalse(B.NeedsOverride(mod, btn))
                end
            end
        end
    end)
    it("NeedsOverride: buttons > 5 always, buttons 1-5 only with meta", function()
        for _, m in ipairs({ "", "shift", "alt-ctrl", "alt-ctrl-shift" }) do
            assertFalse(B.NeedsOverride(m, 5), m .. "|5")
            assertTrue(B.NeedsOverride(m, 6), m .. "|6")
            assertTrue(B.NeedsOverride(m, 31), m .. "|31")
        end
        assertTrue(B.NeedsOverride("meta", 1)); assertTrue(B.NeedsOverride("alt-meta", 6))
    end)
    it("ToOverrideAttributes uses wildcard slot attributes", function()
        local a = B.ToOverrideAttributes("HFB1", { type = "spell", spell = "S" })
        assertEquals(a["*type-HFB1"], "spell"); assertEquals(a["*spell-HFB1"], "S")
        a = B.ToOverrideAttributes("HFB2", { type = "macro", macrotext = "/x" })
        assertEquals(a["*macrotext-HFB2"], "/x")
        a = B.ToOverrideAttributes("HFB3", { type = "menu" })
        assertEquals(a["*type-HFB3"], "togglemenu")
    end)
    it("OverrideBindingKey builds ALT-CTRL-SHIFT-META-BUTTONn strings (Blizzard canonical chord order)", function()
        assertEquals(B.OverrideBindingKey("", 6), "BUTTON6")
        assertEquals(B.OverrideBindingKey("meta", 1), "META-BUTTON1")
        assertEquals(B.OverrideBindingKey("alt-ctrl-meta-shift", 2), "ALT-CTRL-SHIFT-META-BUTTON2")
        assertEquals(B.OverrideBindingKey("ctrl-shift", 7), "CTRL-SHIFT-BUTTON7")
        assertEquals(B.OverrideBindingKey("shift-meta", 1), "SHIFT-META-BUTTON1")
    end)
    it("unknown modifier name ('foo|1') must NOT silently become a plain left click", function()
        assertNil(B.ToAttributes("foo|1", { type = "target" }))
    end)
    it("button 0 ('|0') must not produce a bogus type0 attribute", function()
        assertNil(B.ToAttributes("|0", { type = "target" }))
    end)
    it("alt+ctrl+shift uses alt-ctrl-shift- prefix", function()
        local a = B.ToAttributes("alt-ctrl-shift|1", { type = "spell", spell = "S" })
        assertEquals(a["alt-ctrl-shift-type1"], "spell")
    end)
    it("button > 5 returns nil", function()
        assertNil(B.ToAttributes("|6", { type = "target" }))
        assertNil(B.ToAttributes("shift|32", { type = "target" }))
    end)
    it("nil/empty action does not raise", function()
        assertTrue(pcall(B.ToAttributes, "|1", nil))
        assertTrue(pcall(B.ToAttributes, "|1", {}))
        assertTrue(pcall(B.ToAttributes, nil, { type = "target" }))
    end)
    it("unknown action type does not raise", function()
        assertTrue(pcall(B.ToAttributes, "|1", { type = "bogus" }))
    end)
    it("spell action without spell name does not raise", function()
        assertTrue(pcall(B.ToAttributes, "|1", { type = "spell" }))
    end)
    it("does not mutate the action table", function()
        local act = { type = "spell", spell = "X" }
        B.ToAttributes("|1", act)
        assertDeepEquals(act, { type = "spell", spell = "X" })
    end)
end)

describe("Bindings.ToPhysicalAttributes", function()
    local B = ns.Bindings
    local mods = { "", "alt", "ctrl", "shift", "alt-ctrl", "alt-shift", "ctrl-shift", "alt-ctrl-shift" }
    local function prefix(m) return m == "" and "" or (m .. "-") end
    it("buttons 1-31 with alt/ctrl/shift prefixes (Blizzard order) produce type/spell attributes", function()
        for _, m in ipairs(mods) do
            for btn = 1, 31 do
                local a, tname, mname = B.ToPhysicalAttributes(B.MakeKey(m, btn), { type = "spell", spell = "S" })
                assertNotNil(a, m .. "|" .. btn)
                assertEquals(a[prefix(m) .. "type" .. btn], "spell", m .. "|" .. btn)
                assertEquals(a[prefix(m) .. "spell" .. btn], "S")
                assertEquals(tname, prefix(m) .. "type" .. btn)
                assertEquals(mname, prefix(m) .. "macrotext" .. btn)
            end
        end
    end)
    it("macro action carries macrotext for button 9", function()
        local a = B.ToPhysicalAttributes("shift|9", { type = "macro", macrotext = "/x" })
        assertEquals(a["shift-type9"], "macro"); assertEquals(a["shift-macrotext9"], "/x")
    end)
    it("meta combos must NOT produce physical attributes", function()
        for _, m in ipairs({ "meta", "alt-meta", "ctrl-meta", "shift-meta", "alt-ctrl-meta-shift" }) do
            for _, btn in ipairs({ 1, 2, 5, 6, 31 }) do
                assertNil((B.ToPhysicalAttributes(B.MakeKey(m, btn), { type = "spell", spell = "S" })), m .. "|" .. btn)
            end
        end
    end)
    it("malformed keys / nil do not raise and return nil", function()
        for _, k in ipairs({ "", "|", "garbage", "shift|" }) do
            local ok, r = pcall(B.ToPhysicalAttributes, k, { type = "target" })
            assertTrue(ok, tostring(r)); assertNil(r)
        end
        assertTrue(pcall(B.ToPhysicalAttributes, nil, nil))
    end)
    it("unknown action type returns nil", function()
        assertNil((B.ToPhysicalAttributes("|6", { type = "bogus" })))
    end)
end)

describe("Bindings.BuildTargetMacro / BuildResOnlyMacro", function()
    local B = ns.Bindings
    it("without res: plain target macro", function()
        assertEquals(B.BuildTargetMacro("party1", nil), "/target [@party1]")
    end)
    it("with res: res-only cast then target if alive", function()
        assertEquals(B.BuildTargetMacro("party2", "Redemption"), "/cast [@party2,dead] Redemption\n/target [@party2,nodead]")
    end)
    it("with res and out-of-combat res", function()
        assertEquals(B.BuildTargetMacro("party3", "Rebirth", "Revive"),
            "/cast [@party3,dead,nocombat] Revive; [@party3,dead] Rebirth\n/target [@party3,nodead]")
    end)
    for _, u in ipairs({ "player", "party1", "party4", "raid12", "partypet1" }) do
        it("unit token " .. u, function()
            assertEquals(B.BuildTargetMacro(u, nil), "/target [@" .. u .. "]")
            assertNotNil(B.BuildTargetMacro(u, "Resurrection"):find("[@" .. u .. ",nodead]", 1, true))
        end)
    end
    it("nil unit -> nil, no raise", function() assertNil(B.BuildTargetMacro(nil, "X")); assertNil(B.BuildTargetMacro(nil, nil)) end)
    it("BuildResOnlyMacro", function()
        assertEquals(B.BuildResOnlyMacro("party1", "Redemption"), "/cast [@party1,dead] Redemption")
        assertEquals(B.BuildResOnlyMacro("party1", "Rebirth", "Revive"), "/cast [@party1,dead,nocombat] Revive; [@party1,dead] Rebirth")
        assertNil(B.BuildResOnlyMacro("party1", nil)); assertNil(B.BuildResOnlyMacro(nil, "X"))
    end)
    it("BuildMacroText nil unit/spell return nil (guarded)", function()
        assertNil(B.BuildMacroText(nil, "X", nil)); assertNil(B.BuildMacroText("party1", nil, "Redemption"))
    end)
    it("macros stay under 255 chars with the longest names", function()
        assertTrue(#B.BuildTargetMacro("party4", "Ancestral Spirit", "Ancestral Spirit") <= 255)
    end)
end)

describe("Bindings.FilterForModifier", function()
    local B = ns.Bindings
    local bindings = {
        ["|1"] = { type = "target" }, ["|2"] = { type = "menu" }, ["shift|2"] = { type = "spell", spell = "A" },
        ["shift|1"] = { type = "spell", spell = "B" }, ["meta|1"] = { type = "spell", spell = "C" },
        ["alt-meta|1"] = { type = "spell", spell = "D" }, ["|5"] = { type = "target" }, ["|3"] = { type = "target" },
    }
    it("returns only exact modifier matches sorted by button", function()
        local r = B.FilterForModifier(bindings, "")
        assertEquals(#r, 4)
        assertEquals(r[1].button, 1); assertEquals(r[2].button, 2); assertEquals(r[3].button, 3); assertEquals(r[4].button, 5)
        assertEquals(r[2].action.type, "menu")
    end)
    it("'' does not match shift", function()
        for _, e in ipairs(B.FilterForModifier(bindings, "")) do assertTrue(e.action.spell == nil) end
    end)
    it("shift sorted", function()
        local r = B.FilterForModifier(bindings, "shift")
        assertEquals(#r, 2); assertEquals(r[1].button, 1); assertEquals(r[2].button, 2)
        assertEquals(r[1].action.spell, "B")
    end)
    it("'alt-meta' does not match 'meta' and vice versa", function()
        local r = B.FilterForModifier(bindings, "meta")
        assertEquals(#r, 1); assertEquals(r[1].action.spell, "C")
        r = B.FilterForModifier(bindings, "alt-meta")
        assertEquals(#r, 1); assertEquals(r[1].action.spell, "D")
    end)
    it("no match -> empty array", function() assertEquals(#B.FilterForModifier(bindings, "ctrl"), 0) end)
    it("nil/empty bindings -> empty array, no error", function()
        assertEquals(#B.FilterForModifier({}, ""), 0)
        local ok, r = pcall(B.FilterForModifier, nil, "")
        assertTrue(ok, tostring(r))
    end)
    it("ignores malformed keys in bindings without raising", function()
        local ok, r = pcall(B.FilterForModifier, { ["garbage"] = {}, [""] = {}, ["|"] = {}, ["|1"] = { type = "target" } }, "")
        assertTrue(ok, tostring(r))
        local found = false
        for _, e in ipairs(r) do if e.button == 1 then found = true end end
        assertTrue(found, "valid |1 binding must survive")
    end)
end)

describe("Bindings.SummarizeCombos", function()
    local B = ns.Bindings
    it("nil / empty -> empty array", function()
        assertEquals(#B.SummarizeCombos(nil), 0)
        assertEquals(#B.SummarizeCombos({}), 0)
    end)
    it("ignores invalid keys", function()
        local r = B.SummarizeCombos({ ["garbage"] = {}, [""] = {}, ["|"] = {}, ["shift|"] = {}, [5] = {}, ["|1"] = {} })
        assertEquals(#r, 1); assertEquals(r[1].modKey, ""); assertEquals(r[1].count, 1)
    end)
    it("counts per combo", function()
        local r = B.SummarizeCombos({ ["|1"] = {}, ["|2"] = {}, ["|3"] = {}, ["shift|1"] = {}, ["shift|2"] = {} })
        assertEquals(#r, 2)
        assertEquals(r[1].modKey, ""); assertEquals(r[1].count, 3)
        assertEquals(r[2].modKey, "shift"); assertEquals(r[2].count, 2)
    end)
    it("sorts '' first, then by number of modifiers, then alphabetically", function()
        local keys = { "alt-ctrl-shift|1", "shift|1", "meta|1", "alt-shift|1", "|1", "ctrl|3", "alt|1", "alt-ctrl|2", "ctrl-shift|1", "alt-meta|1" }
        local b = {}
        for _, k in ipairs(keys) do b[k] = {} end
        local r = B.SummarizeCombos(b)
        local got = {}
        for _, e in ipairs(r) do got[#got + 1] = e.modKey end
        assertDeepEquals(got, { "", "alt", "ctrl", "meta", "shift", "alt-ctrl", "alt-meta", "alt-shift", "ctrl-shift", "alt-ctrl-shift" })
    end)
    it("does not mutate its input and each entry has numeric count", function()
        local b = { ["|1"] = { type = "target" } }
        local r = B.SummarizeCombos(b)
        assertDeepEquals(b, { ["|1"] = { type = "target" } })
        assertEquals(type(r[1].count), "number")
    end)
    it("a full 31-button combo counts every button", function()
        local b = {}
        for i = 1, 31 do b["alt|" .. i] = {} end
        assertEquals(B.SummarizeCombos(b)[1].count, 31)
    end)
end)

describe("Bindings.ButtonLabel / ModifierLabel", function()
    local B = ns.Bindings
    local want = { "Left", "Right", "Middle", "Mouse 4", "Mouse 5", "Mouse 6" }
    for i, w in ipairs(want) do
        it("ButtonLabel(" .. i .. ") == " .. w, function() assertEquals(B.ButtonLabel(i), w) end)
    end
    it("ButtonLabel of weird values does not raise", function()
        assertTrue(pcall(B.ButtonLabel, 0)); assertTrue(pcall(B.ButtonLabel, nil)); assertTrue(pcall(B.ButtonLabel, 99))
    end)
    it("ModifierLabel basics", function()
        assertEquals(B.ModifierLabel("", false), "No modifier")
        assertEquals(B.ModifierLabel("", true), "No modifier")
        assertEquals(B.ModifierLabel("alt-meta", true), "Option + Cmd")
        assertEquals(B.ModifierLabel("shift", true), "Shift")
        assertEquals(B.ModifierLabel("ctrl-shift", true), "Shift + Ctrl")
        assertEquals(B.ModifierLabel("alt", false), "Alt")
        assertEquals(B.ModifierLabel("meta", false), "Win")
        assertEquals(B.ModifierLabel("meta", true), "Cmd")
        assertEquals(B.ModifierLabel("alt", true), "Option")
    end)
    it("ModifierLabel display order Shift, Ctrl, Alt, Meta (Win) for all four", function()
        assertEquals(B.ModifierLabel("alt-ctrl-meta-shift", false), "Shift + Ctrl + Alt + Win")
        assertEquals(B.ModifierLabel("alt-ctrl-meta-shift", true), "Shift + Ctrl + Option + Cmd")
    end)
    it("ModifierLabel with nil / unknown does not raise", function()
        assertTrue(pcall(B.ModifierLabel, nil, false)); assertTrue(pcall(B.ModifierLabel, "bogus", true))
    end)
end)

-- ---------------------------------------------------------------- Res macro (dead -> resurrect)
describe("Bindings.BuildMacroText", function()
    local B = ns.Bindings
    it("with res spell", function()
        assertEquals(B.BuildMacroText("party1", "Flash of Light", "Redemption"),
            "/cast [@party1,dead] Redemption; [@party1,help,nodead] Flash of Light")
    end)
    it("without res spell", function()
        assertEquals(B.BuildMacroText("party1", "Flash of Light", nil), "/cast [@party1,help,nodead] Flash of Light")
    end)
    for _, unit in ipairs({ "player", "party1", "party2", "party3", "party4", "raid1", "raid40", "party1pet" }) do
        it("every unit token embeds correctly: " .. unit, function()
            local t = B.BuildMacroText(unit, "Holy Light", "Redemption")
            assertEquals(t, "/cast [@" .. unit .. ",dead] Redemption; [@" .. unit .. ",help,nodead] Holy Light")
        end)
    end
    it("macro stays under the 255 char limit for long spell names", function()
        local t = B.BuildMacroText("party4", "Word of Glory Greater Long Name", "Ancestral Spirit")
        assertTrue(#t <= 255)
    end)
    it("nil unit / nil spell do not raise", function()
        local ok1 = pcall(B.BuildMacroText, nil, "X", nil)
        local ok2 = pcall(B.BuildMacroText, "party1", nil, "Redemption")
        if not (ok1 and ok2) then warn("Bindings.BuildMacroText raises on nil unit/spell (callers must guard)") end
    end)
end)

describe("Classes.GetResSpell", function()
    local C = ns.Classes
    if not C or not C.GetResSpell then it("ns.Classes.GetResSpell exists", function() error("missing") end) return end
    local function name(v) if type(v) == "table" then return v.name or v[1] or v.spell end return v end
    local want = { PALADIN = "Redemption", PRIEST = "Resurrection", SHAMAN = "Ancestral Spirit", DRUID = "Rebirth" }
    for cls, spell in pairs(want) do
        it(cls .. " -> " .. spell, function() assertEquals(name(C.GetResSpell(cls)), spell) end)
    end
    for _, cls in ipairs({ "WARRIOR", "MAGE", "ROGUE", "HUNTER", "WARLOCK" }) do
        it(cls .. " -> nil", function() assertNil(C.GetResSpell(cls)) end)
    end
    it("unknown / nil class -> nil, no raise", function()
        assertNil(C.GetResSpell("BOGUS")); assertNil(C.GetResSpell(nil)); assertNil(C.GetResSpell(""))
        assertNil(C.GetResSpell(5))
    end)
end)

-- ---------------------------------------------------------------- Presets
-- Locate the table of buff definitions (key -> {spellIds, names}).
local function findBuffDefs(ns)
    local function looks(t)
        if type(t) ~= "table" then return false end
        local n = 0
        for _, v in pairs(t) do
            if type(v) ~= "table" or type(v.spellIds) ~= "table" then return false end
            n = n + 1
        end
        return n >= 2
    end
    for _, holder in ipairs({ ns, ns.Classes or {}, ns.Presets or {}, ns.Buffs or {} }) do
        for k, v in pairs(holder) do if looks(v) then return v, k end end
    end
end

describe("Presets.DEFAULTS", function()
    local P = ns.Presets
    if not P then it("ns.Presets exists", function() error("missing") end) return end
    local buffDefs, defsName = findBuffDefs(ns)
    local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    it("exactly one shipped preset: a blank, named \"Default\" (no buff rules)", function()
        assertEquals(#P.DEFAULTS, 1); assertEquals(P.DEFAULTS[1].name, "Default"); assertEquals(next(P.DEFAULTS[1].map), nil)
    end)
    it("buff definitions table found (ns.* with spellIds)", function() assertNotNil(buffDefs, "could not locate buff defs") end)
    for i, preset in ipairs(P.DEFAULTS) do
        it("preset " .. i .. " has name + map", function()
            assertEquals(type(preset.name), "string"); assertTrue(preset.name ~= "")
            assertEquals(type(preset.map), "table")
        end)
        it("preset " .. i .. " (" .. tostring(preset.name) .. ") maps only valid class tokens to existing buff keys", function()
            local valid = {}
            for _, c in ipairs(CLASSES) do valid[c] = true end
            for cls, entry in pairs(preset.map) do
                assertTrue(valid[cls], "unknown class token " .. tostring(cls))
                assertEquals(type(entry), "table", "v2 preset: map[" .. cls .. "] must be a table")
                for role, key in pairs(entry) do
                    assertTrue(role == "DEFAULT" or role == "TANK" or role == "HEALER" or role == "DAMAGER", "bad role " .. tostring(role))
                    if buffDefs then assertTrue(key == "none" or buffDefs[key] ~= nil, "unknown buff key " .. tostring(key) .. " for " .. cls) end
                end
            end
        end)
        it("preset " .. i .. " ships blank (no class rules)", function() assertEquals(next(preset.map), nil) end)
    end
    it("preset names are unique", function()
        local seen = {}
        for _, p in ipairs(P.DEFAULTS) do assertNil(seen[p.name], "dup " .. p.name); seen[p.name] = true end
    end)
    it("buff defs have names; Paladin blessings have spellIds (the other classes' buffs match by name on purpose)", function()
        if not buffDefs then return end
        for k, d in pairs(buffDefs) do
            assertEquals(type(d.spellIds), "table", k)
            assertTrue(d.names and #d.names > 0, k .. " has empty names")
            if d.group == "blessing" then assertTrue(#d.spellIds > 0, k .. " (Paladin blessing) has no spellIds") end
            for _, id in ipairs(d.spellIds) do assertEquals(type(id), "number") end
        end
    end)
end)

describe("Presets.GetMissingBuff", function()
    local P = ns.Presets
    local defs = { kings = { spellIds = { 20217, 25898 }, names = { "Blessing of Kings", "Greater Blessing of Kings" } },
                   might = { spellIds = { 19740 }, names = { "Blessing of Might" } } }
    local preset = { name = "T", map = { PALADIN = "kings", WARRIOR = "might" } }
    local now = 1000
    local function aura(id, name, exp) return { spellId = id, name = name, expirationTime = exp } end
    local function miss(cls, auras, thr) return P.GetMissingBuff(cls, auras, preset, now, defs, thr) end

    it("no aura -> key", function() assertEquals(miss("PALADIN", {}), "kings") end)
    it("nil auras -> key", function() assertEquals(miss("PALADIN", nil), "kings") end)
    it("matches by spellId", function() assertNil(miss("PALADIN", { aura(20217, "x", now + 500) })) end)
    it("matches by name", function() assertNil(miss("PALADIN", { aura(999, "Blessing of Kings", now + 500) })) end)
    it("greater variant id counts", function() assertNil(miss("PALADIN", { aura(25898, "?", now + 500) })) end)
    it("greater variant name counts", function() assertNil(miss("PALADIN", { aura(1, "Greater Blessing of Kings", now + 500) })) end)
    it("expiring in 30s -> key", function() assertEquals(miss("PALADIN", { aura(20217, "x", now + 30) }), "kings") end)
    it("expiring in 120s -> nil", function() assertNil(miss("PALADIN", { aura(20217, "x", now + 120) })) end)
    it("expirationTime 0 = permanent -> nil", function() assertNil(miss("PALADIN", { aura(20217, "x", 0) })) end)
    it("custom threshold: 100s left, threshold 120 -> key; threshold 30 -> nil", function()
        assertEquals(miss("PALADIN", { aura(20217, "x", now + 100) }, 120), "kings")
        assertNil(miss("PALADIN", { aura(20217, "x", now + 100) }, 30))
    end)
    it("default threshold is 60: 59s -> key, 61s -> nil", function()
        assertEquals(miss("PALADIN", { aura(20217, "x", now + 59) }), "kings")
        assertNil(miss("PALADIN", { aura(20217, "x", now + 61) }))
    end)
    it("aura with 0 < expirationTime <= now (already expired) counts as missing", function()
        assertEquals(miss("PALADIN", { aura(20217, "x", now - 5) }), "kings")
        assertEquals(miss("PALADIN", { aura(20217, "x", now) }), "kings")
        assertEquals(miss("PALADIN", { aura(20217, "x", 1) }), "kings")
    end)
    it("class not in map -> nil", function() assertNil(miss("PRIEST", {})) end)
    it("unknown / nil class -> nil, no raise", function()
        assertNil(miss("BOGUS", {})); assertNil(miss(nil, {}))
    end)
    it("other buff present does not satisfy", function() assertEquals(miss("PALADIN", { aura(19740, "Blessing of Might", 0) }), "kings") end)
    it("one of several auras matches", function()
        assertNil(miss("PALADIN", { aura(1, "a", 0), aura(2, "b", 0), aura(20217, "x", 0) }))
    end)
    it("an expiring and a fresh duplicate: fresh wins -> nil", function()
        assertNil(miss("PALADIN", { aura(20217, "x", now + 10), aura(25898, "y", now + 900) }))
    end)
    it("preset maps to an unknown buff key -> nil, no raise", function()
        local ok, r = pcall(P.GetMissingBuff, "PALADIN", {}, { name = "x", map = { PALADIN = "nope" } }, now, defs)
        assertTrue(ok, tostring(r))
    end)
    it("nil preset / nil defs do not raise", function()
        assertTrue(pcall(P.GetMissingBuff, "PALADIN", {}, nil, now, defs))
        assertTrue(pcall(P.GetMissingBuff, "PALADIN", {}, preset, now, nil))
    end)
    it("auras with nil spellId/name entries do not raise", function()
        assertTrue(pcall(P.GetMissingBuff, "PALADIN", { {}, { expirationTime = 0 } }, preset, now, defs))
    end)
    it("does not mutate inputs", function()
        local a = { aura(20217, "x", now + 10) }
        local copyA = ns.Util.DeepCopy(a); local copyP = ns.Util.DeepCopy(preset)
        miss("PALADIN", a)
        assertDeepEquals(a, copyA); assertDeepEquals(preset, copyP)
    end)
end)

describe("Presets list operations", function()
    local P = ns.Presets
    local function mk() return { { name = "A", map = { PALADIN = { DEFAULT = "x", TANK = "t" } } }, { name = "B", map = { PALADIN = { DEFAULT = "y", TANK = "u" } } } } end

    it("Add with copyFromIndex deep-copies the map", function()
        local l = mk()
        P.Add(l, "C", 2)
        assertEquals(#l, 3); assertEquals(l[3].name, "C"); assertDeepEquals(l[3].map.PALADIN.DEFAULT, { "y" })
        l[3].map.PALADIN.DEFAULT = { "z" }; l[3].map.PALADIN.TANK = { "zz" }
        assertEquals(l[2].map.PALADIN.DEFAULT, "y"); assertEquals(l[2].map.PALADIN.TANK, "u")   -- the source preset is untouched (still its raw legacy form)
        assertTrue(l[3].map ~= l[2].map)
        assertTrue(l[3].map.PALADIN ~= l[2].map.PALADIN, "per-class entry tables must be copied too (deep copy)")
    end)
    it("Add without copyFromIndex gives a table map", function()
        local l = mk(); P.Add(l, "C"); assertEquals(type(l[3].map), "table")
    end)
    it("Add with out-of-range copyFromIndex does not raise", function()
        local l = mk(); assertTrue(pcall(P.Add, l, "C", 99)); assertTrue(pcall(P.Add, l, "D", 0))
    end)
    it("Add with empty/nil name does not raise", function()
        local l = mk(); assertTrue(pcall(P.Add, l, "", 1)); assertTrue(pcall(P.Add, l, nil, 1))
    end)
    it("Remove removes and returns truthy", function()
        local l = mk(); assertTrue(P.Remove(l, 1)); assertEquals(#l, 1); assertEquals(l[1].name, "B")
    end)
    it("Remove refuses to remove the last one", function()
        local l = { { name = "A", map = {} } }
        assertEquals(P.Remove(l, 1), false); assertEquals(#l, 1)
    end)
    for _, idx in ipairs({ 0, -1, 3, 99 }) do
        it("Remove index " .. idx .. " (out of range) leaves list intact", function()
            local l = mk()
            local ok, r = pcall(P.Remove, l, idx)
            assertTrue(ok, tostring(r))
            assertTrue(not r, "should return falsy")
            assertEquals(#l, 2)
        end)
    end
    it("Remove nil index does not raise", function() assertTrue(pcall(P.Remove, mk(), nil)) end)
    it("Rename trims", function()
        local l = mk(); assertTrue(P.Rename(l, 1, "  x  ")); assertEquals(l[1].name, "x")
    end)
    it("Rename to empty / whitespace -> false and unchanged", function()
        local l = mk()
        assertEquals(P.Rename(l, 1, ""), false); assertEquals(P.Rename(l, 1, "   "), false)
        assertEquals(l[1].name, "A")
    end)
    it("Rename nil name -> not raising, unchanged", function()
        local l = mk(); local ok = pcall(P.Rename, l, 1, nil); assertTrue(ok); assertEquals(l[1].name, "A")
    end)
    it("Rename invalid index -> not raising, falsy", function()
        local l = mk()
        for _, i in ipairs({ 0, 3, -1 }) do
            local ok, r = pcall(P.Rename, l, i, "ok"); assertTrue(ok, tostring(r)); assertTrue(not r)
        end
    end)
    it("Rename to a very long name does not raise (length may be capped)", function()
        local l = mk(); local long = string.rep("x", 5000)
        local ok, r = pcall(P.Rename, l, 1, long); assertTrue(ok, tostring(r))
        assertTrue(#l[1].name > 0)
    end)
    it("Add with a very long name does not raise", function()
        local l = mk(); assertTrue(pcall(P.Add, l, string.rep("y", 5000), 1))
    end)
    it("Add keeps source preset unchanged and independent of later source edits", function()
        local l = mk(); P.Add(l, "C", 1); l[1].map.PALADIN.DEFAULT = { "changed" }; assertDeepEquals(l[3].map.PALADIN.DEFAULT, { "x" })
    end)
end)

-- ---------------------------------------------------------------- Defaults + Init + migration
describe("ns.DEFAULTS shape", function()
    local D = ns.DEFAULTS
    it("exists", function() assertNotNil(D, "ns.DEFAULTS missing") end)
    if not D then return end
    it("version", function() assertNotNil(D.version) end)
    it("activePreset == 1", function() assertEquals(D.activePreset, 1) end)
    it("presets non-empty array", function() assertEquals(type(D.presets), "table"); assertTrue(#D.presets >= 1) end)
    it("frames.layout horizontal, colorMode class", function()
        assertEquals(D.frames.layout, "horizontal"); assertEquals(D.frames.colorMode, "class")
    end)
    it("auras table", function() assertEquals(type(D.auras), "table") end)
    it("the removed Blizzard-party option and A/B/C style keys are not part of the defaults", function()
        assertNil(D.hideBlizzardParty); assertNil(D.taintMigrated); assertNil(D.appearance); assertNil(D.frames.style)
        assertEquals(type(D.frames.border), "table")
    end)
    it("minimap table", function() assertEquals(type(D.minimap), "table") end)
    it("clean-install bindings are only plain Left = target and plain Right = unit menu", function()
        assertEquals(type(D.bindings), "table")
        local n = 0
        for _ in pairs(D.bindings) do n = n + 1 end
        assertEquals(n, 2)
        assertEquals(D.bindings["|1"].type, "target"); assertEquals(D.bindings["|2"].type, "menu")
    end)
    it("all default bindings parse and produce attributes", function()
        for key, act in pairs(D.bindings) do
            local m, b = ns.Bindings.ParseKey(key)
            assertNotNil(m, key); assertNotNil(b, key)
            if ns.Bindings.NeedsOverride(m, b) then
                assertNotNil(ns.Bindings.ToOverrideAttributes("HFB1", act), "no override attrs for " .. key)
            else
                assertNotNil(ns.Bindings.ToAttributes(key, act), "no attrs for default binding " .. key)
            end
        end
    end)
    it("activePreset points at an existing preset", function() assertNotNil(D.presets[D.activePreset]) end)
end)

local function doInit(db)
    mock.install()
    local n, _, errs = L.loadContract({})
    if next(errs) then error("load errors: " .. tostring(select(2, next(errs)))) end
    _G.HealerForeverCharDB = db
    -- Core may register ADDON_LOADED on a frame; fire it, then also call ns:Init() directly.
    mock.fire("ADDON_LOADED", "HealerForever")
    assertEquals(#mock.errors, 0, table.concat(mock.errors, "\n"))
    if n.Init then
        local ok, err = pcall(n.Init, n)
        assertTrue(ok, "ns:Init() raised: " .. tostring(err))
    end
    return n
end

describe("ns:Init() and SavedVariables migration", function()
    it("HealerForeverCharDB = nil -> created with defaults", function()
        doInit(nil)
        assertEquals(type(_G.HealerForeverCharDB), "table")
        assertEquals(_G.HealerForeverCharDB.activePreset, 1)
        assertEquals(_G.HealerForeverCharDB.frames.layout, "horizontal")
    end)
    it("HealerForeverCharDB = {} -> filled", function()
        doInit({})
        local db = _G.HealerForeverCharDB
        assertNotNil(db.version); assertNotNil(db.bindings["|1"]); assertTrue(#db.presets >= 1)
    end)
    it("user values preserved (including false and 0)", function()
        doInit({ activePreset = 3, frames = { layout = "vertical", showPets = false, lowHpPulse = true }, minimap = { hide = true },
            presets = { { name = "Mine", map = { PALADIN = "x" } }, { name = "Mine2", map = {} }, { name = "Mine3", map = {} } } })
        local db = _G.HealerForeverCharDB
        assertEquals(db.activePreset, 3); assertEquals(db.frames.showPets, false); assertEquals(db.frames.lowHpPulse, true)
        assertEquals(db.frames.layout, "vertical"); assertEquals(db.frames.colorMode, "class")
        assertEquals(db.minimap.hide, true); assertEquals(db.presets[1].name, "Mine")
    end)
    it("old table without version -> no error, gets version and defaults", function()
        doInit({ frames = { layout = "vertical" } })
        assertNotNil(_G.HealerForeverCharDB.version)
        assertEquals(_G.HealerForeverCharDB.frames.layout, "vertical")
        assertNotNil(_G.HealerForeverCharDB.bindings)
    end)
    it("custom bindings preserved, not merged with defaults destructively", function()
        doInit({ bindings = { ["shift|1"] = { type = "target" } } })
        assertEquals(_G.HealerForeverCharDB.bindings["shift|1"].type, "target")
    end)
    it("corrupted: presets = 'x'", function()
        doInit({ presets = "x" })
        assertEquals(type(_G.HealerForeverCharDB.presets), "table"); assertTrue(#_G.HealerForeverCharDB.presets >= 1)
    end)
    it("corrupted: bindings = 5", function()
        doInit({ bindings = 5 })
        assertEquals(type(_G.HealerForeverCharDB.bindings), "table")
    end)
    it("corrupted: everything wrong type", function()
        doInit({ presets = "x", bindings = 5, frames = "no", auras = 1, minimap = true, activePreset = "two", version = {} })
        local db = _G.HealerForeverCharDB
        assertEquals(type(db.frames), "table"); assertEquals(type(db.auras), "table"); assertEquals(type(db.minimap), "table")
        assertEquals(type(db.activePreset), "number")
    end)
    it("corrupted: presets = {} (empty) -> at least one preset", function()
        doInit({ presets = {} })
        assertTrue(#_G.HealerForeverCharDB.presets >= 1)
    end)
    it("activePreset out of range is clamped to an existing preset", function()
        doInit({ activePreset = 99 })
        local db = _G.HealerForeverCharDB
        assertNotNil(db.presets[db.activePreset], "activePreset=" .. tostring(db.activePreset))
    end)
    it("corrupted: HealerForeverCharDB itself is a string", function()
        doInit("garbage")
        assertEquals(type(_G.HealerForeverCharDB), "table")
    end)
    it("Init is idempotent (second call does not change the DB)", function()
        local n = doInit({ activePreset = 2 })
        local snap = n.Util.DeepCopy(_G.HealerForeverCharDB)
        n:Init()
        assertDeepEquals(_G.HealerForeverCharDB, snap)
    end)
    it("saved DB never aliases ns.DEFAULTS", function()
        local n = doInit(nil)
        _G.HealerForeverCharDB.frames.layout = "mutated"
        _G.HealerForeverCharDB.presets[1].name = "mutated"
        _G.HealerForeverCharDB.bindings["|1"].spell = "mutated"
        assertEquals(n.DEFAULTS.frames.layout, "horizontal")
        assertTrue(n.DEFAULTS.presets[1].name ~= "mutated")
        assertTrue(n.DEFAULTS.bindings["|1"].spell ~= "mutated")
    end)
end)

-- ---------------------------------------------------------------- MinimapPins (pure)
describe("MinimapPins.ToMinimapOffset", function()
    mock.install()
    local n = {}
    local pinsPath = L.path("Minimap/MinimapPins.lua")
    if not L.exists(pinsPath) then
        it("Minimap/MinimapPins.lua exists", function() error("not present yet") end)
        return
    end
    for _, f in ipairs({ "Util/Util.lua", "Data/Classes.lua", "Minimap/MinimapPins.lua" }) do
        if L.exists(L.path(f)) then pcall(L.loadFile, f, n) end
    end
    local P = n.MinimapPins
    if not P then it("ns.MinimapPins defined", function() error("missing") end) return end
    local T = P.ToMinimapOffset
    local function near(a, b) return math.abs(a - b) < 1e-6 end
    it("origin -> 0,0 not on edge", function()
        local x, y, e = T(0, 0, 100, 50, 0, false)
        assertTrue(near(x, 0) and near(y, 0)); assertFalse(e)
    end)
    it("half radius -> half pixel radius (magnitude), not on edge", function()
        local x, y, e = T(50, 0, 100, 50, 0, false)
        assertTrue(near(math.sqrt(x * x + y * y), 25), "len=" .. math.sqrt(x * x + y * y)); assertFalse(e)
        x, y, e = T(0, 50, 100, 50, 0, false)
        assertTrue(near(math.sqrt(x * x + y * y), 25))
    end)
    it("beyond radius is clamped to the edge, onEdge true", function()
        local x, y, e = T(500, 0, 100, 50, 0, false)
        assertTrue(e); assertTrue(near(math.sqrt(x * x + y * y), 50), "len=" .. math.sqrt(x * x + y * y))
        x, y, e = T(300, 400, 100, 50, 0, false)
        assertTrue(e); assertTrue(near(math.sqrt(x * x + y * y), 50))
    end)
    it("exactly at radius is not clamped beyond edge", function()
        local x, y = T(100, 0, 100, 50, 0, false)
        assertTrue(near(math.sqrt(x * x + y * y), 50))
    end)
    it("preserves direction when clamping", function()
        local x1, y1 = T(10, 20, 1000, 50, 0, false)
        local x2, y2, e = T(1000, 2000, 100, 50, 0, false)
        assertTrue(e)
        assertTrue(near(x1 / y1, x2 / y2), "direction changed")
    end)
    it("rotate=true with facing=pi/2 rotates by 90 degrees (magnitude kept)", function()
        local x0, y0 = T(50, 0, 100, 50, 0, false)
        local x1, y1 = T(50, 0, 100, 50, math.pi / 2, true)
        assertTrue(near(math.sqrt(x1 * x1 + y1 * y1), math.sqrt(x0 * x0 + y0 * y0)))
        local dot = x0 * x1 + y0 * y1
        assertTrue(math.abs(dot) < 1e-6, "expected perpendicular, dot=" .. dot)
    end)
    it("rotate=false ignores facing", function()
        local a, b = T(30, 10, 100, 50, 0, false)
        local c, d = T(30, 10, 100, 50, 1.234, false)
        assertTrue(near(a, c) and near(b, d))
    end)
    it("rotate=true with facing=0 equals no rotation", function()
        local a, b = T(30, 10, 100, 50, 0, false)
        local c, d = T(30, 10, 100, 50, 0, true)
        assertTrue(near(a, c) and near(b, d))
    end)
    it("axis/sign convention: +x east, +y north; facing west (pi/2) with rotate puts east behind (down) and north to the right", function()
        local x, y = T(50, 0, 100, 50, 0, false); assertTrue(x > 0 and near(y, 0), "east -> right")
        x, y = T(0, 50, 100, 50, 0, false); assertTrue(near(x, 0) and y > 0, "north -> up")
        x, y = T(50, 0, 100, 50, math.pi / 2, true); assertTrue(near(x, 0) and y < 0, "east when facing west -> down: " .. x .. "," .. y)
        x, y = T(0, 50, 100, 50, math.pi / 2, true); assertTrue(x > 0 and near(y, 0), "north when facing west -> right")
        x, y = T(0, 50, 100, 50, math.pi, true); assertTrue(near(x, 0) and y < 0, "north when facing south -> down")
    end)
    it("zero radius does not raise", function() assertTrue(pcall(T, 10, 10, 0, 50, 0, false)) end)
    it("nil args do not raise", function() assertTrue(pcall(T, nil, nil, nil, nil, nil, nil)) end)
end)
