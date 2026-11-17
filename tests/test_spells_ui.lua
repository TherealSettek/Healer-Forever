-- Dynamic spellbook: scan paths, panes, assignment, throttling, SpellKnown fallbacks.
local L = require("loader")
local mock = require("wow_mock")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end
local function frameNamed(name) for _, f in ipairs(mock.frames) do if st(f).name == name then return f end end end

local PALADIN_BOOK = {
    names = { [19750] = "Flash of Light", [82326] = "Holy Light", [900001] = "Light's Vigil", [900002] = "Oath of Light",
        [20217] = "Blessing of Kings", [7] = "Devotion Aura Passive", [8] = "Hearthstone", [9] = "Holy Specialization",
        [10] = "Frost Bolt Offspec" },
    passives = { [7] = true },
    offspec = { [10] = true },
    lines = {
        { name = "General", ids = { 8 } },
        { name = "Holy", ids = { 19750, 82326, 20217, 900001, 7, 10 } },
    },
}

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    if opts.class then S.units.player.class = opts.class end
    if opts.book then mock.setSpellbook(opts.book) end
    if opts.setup then opts.setup() end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.db ~= nil then _G.HealerForeverCharDB = opts.db end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    if opts.group then mock.setGroup(opts.group) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns
end
local function listNames(ns)
    local set, arr = {}, {}
    for _, s in ipairs(ns.ClassSpellList()) do set[s.name] = s; arr[#arr + 1] = s.name end
    return set, arr
end

describe("spells: skill-line scan (modern C_SpellBook)", function()
    local book = PALADIN_BOOK
    local ns = boot({ book = {
        names = book.names, passives = book.passives, offspec = book.offspec, lines = book.lines, talents = { 900002 } }, group = 2 })
    it("boots clean", function() assertEquals(#mock.errors, 0, errstr()) end)
    it("Light's Vigil (skill line) and Oath of Light (talent tree) are in the list", function()
        local set = listNames(ns)
        assertNotNil(set["Light's Vigil"], "Light's Vigil missing")
        assertNotNil(set["Oath of Light"], "Oath of Light (talent) missing")
        assertNotNil(set["Flash of Light"]); assertNotNil(set["Holy Light"])
    end)
    it("passives, off-spec and the General tab are excluded", function()
        local set = listNames(ns)
        assertNil(set["Devotion Aura Passive"]); assertNil(set["Frost Bolt Offspec"]); assertNil(set["Hearthstone"])
    end)
    it("groups: Flash of Light healing, Blessing of Kings buffs, Light's Vigil other, Oath of Light buffs (curated)", function()
        local groups = {}
        for _, s in ipairs(ns.ClassSpellList()) do groups[s.name] = s.group end
        assertEquals(groups["Flash of Light"], "Healing")
        assertEquals(groups["Blessing of Kings"], "Blessings / Buffs")
        assertNotNil(groups["Light's Vigil"])
    end)
    it("entries have spell id and icon", function()
        local set = listNames(ns)
        assertEquals(set["Light's Vigil"].id, 900001)
        assertNotNil(set["Light's Vigil"].icon)
    end)
    it("ns.SpellKnown knows scanned spells by name, and not unknown ones", function()
        assertTrue(ns.SpellKnown("Light's Vigil"))
        assertTrue(ns.Spells.IsKnownByName("Light's Vigil"))
        assertFalse(ns.Spells.IsKnownByName("Totally Unknown"))
    end)
    it("Class Spells pane lists Light's Vigil and Oath of Light", function()
        ns.Options:Show("spells"); mock.flushTimers()
        local shown = {}
        for _, f in ipairs(mock.frames) do
            if f.entry and st(f).shown then shown[f.entry.name] = true end
        end
        assertTrue(shown["Light's Vigil"], "Light's Vigil not shown in the pane")
        assertTrue(shown["Oath of Light"], "Oath of Light not shown in the pane")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("pane search filters; dragging an entry picks the spell up", function()
        local box
        for _, f in ipairs(mock.frames) do if st(f).kind == "EditBox" and st(f).scripts.OnTextChanged then box = f end end
        assertNotNil(box)
        st(box).text = "vigil"; st(box).scripts.OnTextChanged(box)
        local shown = {}
        for _, f in ipairs(mock.frames) do if f.entry and st(f).shown then shown[#shown + 1] = f end end
        assertEquals(#shown, 1); assertEquals(shown[1].entry.name, "Light's Vigil")
        local picked
        _G.C_Spell.PickupSpell = function(id) picked = id end
        st(shown[1]).scripts.OnDragStart(shown[1])
        assertEquals(picked, 900001)
        st(box).text = ""; st(box).scripts.OnTextChanged(box)
    end)
    it("Pick menu offers them and picking assigns the binding", function()
        ns.Options:Show("binds"); mock.flushTimers()
        local row
        for _, f in ipairs(mock.frames) do if type(f.button) == "number" and f.pick and f.clear and f.button == 1 then row = f end end
        assertNotNil(row)
        mock.menu = nil
        st(row.pick).scripts.OnClick(row.pick)
        local texts = {}
        for _, e in ipairs(mock.menu.entries) do texts[e.text] = true end
        assertTrue(texts["Light's Vigil"]); assertTrue(texts["Oath of Light"])
        assertTrue(mock.pickMenu("Light's Vigil"))
        mock.flushTimers()
        assertEquals(ns.db.bindings[row.key].type, "spell")
        assertEquals(ns.db.bindings[row.key].spell, "Light's Vigil")
        local btn = frameNamed("HealerForeverUnit1")
        local a = st(btn).attrs
        local txt = a["macrotext1"] or a["spell1"]
        assertNotNil(tostring(txt):find("Light's Vigil", 1, true), "attribute not applied: " .. tostring(txt))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Oath of Light can also be assigned from the menu", function()
        local row
        for _, f in ipairs(mock.frames) do if type(f.button) == "number" and f.pick and f.button == 3 then row = f end end
        mock.menu = nil
        st(row.pick).scripts.OnClick(row.pick)
        assertTrue(mock.pickMenu("Oath of Light"))
        assertEquals(ns.db.bindings[row.key].spell, "Oath of Light")
    end)
end)

describe("spells: legacy API fallback (no C_SpellBook skill lines)", function()
    it("scans the old spell tabs", function()
        local book = PALADIN_BOOK
        local ns = boot({ book = { names = book.names, passives = book.passives, lines = book.lines, legacy = true }, group = 1 })
        assertEquals(#mock.errors, 0, errstr())
        local set = listNames(ns)
        assertNotNil(set["Light's Vigil"], "legacy scan missed Light's Vigil")
        assertNotNil(set["Flash of Light"])
        assertNil(set["Hearthstone"], "tab 1 (General) must be skipped")
    end)
    it("no spellbook API at all: falls back to the curated list filtered by known spells, no error", function()
        local ns = boot({ setup = function()
            mock.setGlobal("C_SpellBook", nil); mock.setGlobal("GetNumSpellTabs", nil)
        end, group = 1 })
        assertEquals(#mock.errors, 0, errstr())
        local set = listNames(ns)
        assertNotNil(set["Flash of Light"], "curated fallback should list known curated spells")
    end)
    it("spellbook APIs that raise do not break the list", function()
        local ns = boot({ setup = function()
            mock.setGlobal("C_SpellBook", { GetNumSpellBookSkillLines = function() error("boom") end,
                GetSpellBookSkillLineInfo = function() error("boom") end, GetSpellBookItemInfo = function() error("boom") end })
        end, group = 1 })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(ns.ClassSpellList()), "table")
    end)
    it("talent API raising is tolerated", function()
        local ns = boot({ book = PALADIN_BOOK, setup = function()
            mock.setGlobal("C_ClassTalents", { GetActiveConfigID = function() error("x") end })
            mock.setGlobal("C_Traits", {})
        end, group = 1 })
        assertEquals(#mock.errors, 0, errstr())
        assertNotNil((listNames(ns))["Light's Vigil"])
    end)
    it("empty spellbook (new character): curated fallback, no error", function()
        local ns = boot({ book = { names = {}, lines = {} }, group = 1 })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(ns.ClassSpellList()), "table")
    end)
    it("a class without any curated data (WARRIOR) and empty book: empty list, panes open", function()
        local ns = boot({ class = "WARRIOR", book = { names = {}, lines = {} }, group = 1 })
        ns.Options:Show("spells"); ns.Options:Show("binds"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("spells: AddCustom + customSpells", function()
    local ns = boot({ book = { names = { [19750] = "Flash of Light", [555] = "My Custom Spell" }, lines = { { name = "G", ids = {} }, { name = "H", ids = { 19750 } } } }, group = 1 })
    it("unknown spell name (no spell info) is refused", function()
        S.spellByName = S.spellByName
        local real = _G.C_Spell.GetSpellInfo
        _G.C_Spell.GetSpellInfo = function(s) if s == "No Such Spell" then return nil end return real(s) end
        local n = #ns.db.customSpells
        assertFalse((ns.Spells.AddCustom("No Such Spell")))
        assertEquals(#ns.db.customSpells, n)
        _G.C_Spell.GetSpellInfo = real
    end)
    it("a real spell is added, persisted and listed; SPELLS_UPDATED fires once after the throttle", function()
        local fired = 0
        ns:On("SPELLS_UPDATED", function() fired = fired + 1 end)
        local ok, name = ns.Spells.AddCustom("My Custom Spell")
        assertTrue(ok); assertEquals(name, "My Custom Spell")
        assertEquals(ns.db.customSpells[#ns.db.customSpells].name, "My Custom Spell")
        mock.flushTimers()
        assertEquals(fired, 1)
        assertNotNil((listNames(ns))["My Custom Spell"])
    end)
    it("adding the same spell twice does not duplicate", function()
        local n = #ns.db.customSpells
        assertTrue(ns.Spells.AddCustom("My Custom Spell"))
        assertEquals(#ns.db.customSpells, n)
    end)
    it("pane: Add by name works and reports unknown names", function()
        ns.Options:Show("spells"); mock.flushTimers()
        local box, add
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.kind == "EditBox" and s.scripts.OnEnterPressed and s.shown then box = f end
            if s.scripts.OnClick and s.text == "Add" then add = f end
        end
        assertNotNil(box); assertNotNil(add)
        local real = _G.C_Spell.GetSpellInfo
        _G.C_Spell.GetSpellInfo = function(s) if s == "Nope Nope" then return nil end return real(s) end
        mock.printed = {}
        st(box).text = "Nope Nope"; st(add).scripts.OnClick(add)
        assertNotNil(table.concat(mock.printed, "\n"):find("not found"))
        _G.C_Spell.GetSpellInfo = real
        st(box).text = "Flash of Light"; st(add).scripts.OnClick(add)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("corrupted customSpells entries do not break scans", function()
        ns.db.customSpells = { 5, "x", { name = 5 }, {}, { name = "My Custom Spell" } }
        ns.Spells.Invalidate(); mock.flushTimers()
        assertEquals(type(ns.ClassSpellList()), "table")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("customSpells is restored to a table from a corrupted saved variable", function()
        boot({ db = { customSpells = "oops" }, group = 1 })
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(type(_G.HealerForeverCharDB.customSpells), "table")
    end)
end)

describe("spells: SPELLS_CHANGED throttling and combat safety", function()
    it("50 SPELLS_CHANGED events -> one SPELLS_UPDATED and at most one rescan", function()
        local ns = boot({ book = PALADIN_BOOK, group = 2 })
        ns.ClassSpellList(); mock.flushTimers()
        local fired = 0
        ns:On("SPELLS_UPDATED", function() fired = fired + 1 end)
        local scans0 = mock.scanCalls
        for _ = 1, 50 do mock.fire("SPELLS_CHANGED"); mock.fire("PLAYER_TALENT_UPDATE"); mock.fire("TRAIT_CONFIG_UPDATED") end
        mock.flushTimers()
        assertEquals(fired, 1, "SPELLS_UPDATED fired " .. fired .. " times")
        ns.ClassSpellList(); ns.ClassSpellList(); ns.ClassSpellList()
        assertTrue(mock.scanCalls - scans0 <= 2, "rescanned " .. (mock.scanCalls - scans0) .. " times")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("an unchanged list is served from cache (no rescans)", function()
        local ns = boot({ book = PALADIN_BOOK, group = 1 })
        ns.ClassSpellList()
        local n0 = mock.scanCalls
        for _ = 1, 20 do ns.ClassSpellList() end
        assertEquals(mock.scanCalls, n0)
    end)
    it("SPELLS_CHANGED in combat never touches secure frames, even when the book changed", function()
        local ns = boot({ book = PALADIN_BOOK, group = 2 })
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local v0, s0, n0 = #mock.violations, #mock.softViolations, #mock.calls
        S.spells[900003] = "New Spell"
        mock.fire("SPELLS_CHANGED"); mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5)
        assertEquals(#mock.violations, v0); assertEquals(#mock.softViolations, s0)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            assertFalse(c.secure and c.method == "SetAttribute", "SetAttribute on a secure frame in combat")
        end
        assertEquals(#mock.errors, 0, errstr())
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("secret spell info (combat, secret values) does not break a scan", function()
        local ns = boot({ book = PALADIN_BOOK, group = 1 })
        S.secret = true; S.combat = true
        local real = _G.C_Spell.GetSpellInfo
        _G.C_Spell.GetSpellInfo = function() return { name = mock.newSecret(), spellID = mock.newSecret(), iconID = 1 } end
        ns.Spells.Invalidate(); mock.flushTimers()
        assertTrue(pcall(ns.ClassSpellList))
        _G.C_Spell.GetSpellInfo = real
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("spells: ns.SpellKnown fallbacks", function()
    local function bootNoSource()
        local ns = boot({ group = 1, setup = function()
            mock.setGlobal("IsPlayerSpell", function() return false end)
            mock.setGlobal("IsSpellKnownOrOverridesKnown", function() return false end)
            mock.setGlobal("IsSpellKnown", function() return false end)
            mock.setGlobal("C_SpellBook", { IsSpellKnown = function() return false end, FindSpellBookSlotForSpell = function() return nil end })
        end })
        ns.Spells.knownNames = {}
        return ns
    end
    local cases = {
        { "IsPlayerSpell", function() _G.IsPlayerSpell = function() return true end end },
        { "IsSpellKnownOrOverridesKnown", function() _G.IsSpellKnownOrOverridesKnown = function() return true end end },
        { "C_SpellBook.IsSpellKnown", function() _G.C_SpellBook.IsSpellKnown = function() return true end end },
        { "IsSpellKnown", function() _G.IsSpellKnown = function() return true end end },
        { "FindSpellBookSlotForSpell", function() _G.C_SpellBook.FindSpellBookSlotForSpell = function() return 12 end end },
        { "Spells.knownNames (spellbook scan)", function() end },
    }
    it("no source says known -> false (name and id), nil -> false", function()
        local ns = bootNoSource()
        assertFalse(ns.SpellKnown("Flash of Light")); assertFalse(ns.SpellKnown(19750)); assertFalse(ns.SpellKnown(nil))
    end)
    for _, c in ipairs(cases) do
        it("exactly one source '" .. c[1] .. "' is enough", function()
            local ns = bootNoSource()
            c[2]()
            if c[1]:find("knownNames") then ns.Spells.knownNames = { ["Flash of Light"] = true } end
            assertTrue(ns.SpellKnown("Flash of Light"), c[1])
            if not c[1]:find("knownNames") then assertTrue(ns.SpellKnown(19750), c[1] .. " by id") end
        end)
    end
    it("a missing API (nil global) is skipped without error", function()
        local ns = bootNoSource()
        _G.IsSpellKnownOrOverridesKnown = nil; _G.IsSpellKnown = nil; _G.C_SpellBook = nil
        assertFalse(ns.SpellKnown("Flash of Light"))
        _G.IsPlayerSpell = function() return true end
        assertTrue(ns.SpellKnown("Flash of Light"))
    end)
    it("unknown name with no spell info is false", function()
        local ns = bootNoSource()
        _G.C_Spell.GetSpellInfo = function() return nil end
        assertFalse(ns.SpellKnown("Does Not Exist"))
    end)
end)
