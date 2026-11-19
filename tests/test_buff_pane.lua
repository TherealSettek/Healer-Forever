-- Buff Presets pane (class-aware, stacking groups): the cell popup (sections, checkbox / radio / None, greyed unknown spells), cell icons,
-- "You are playing", the empty-catalog hint, the Self row, the "Load example..." menu, and the "by trtg" credit (footer on every tab,
-- About block, /hf version, TOC Author).
local L = require("loader")
local mock = require("wow_mock")
local BU = require("buff_ui")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end
local function deepcopy(t) if type(t) ~= "table" then return t end local o = {} for k, v in pairs(t) do o[k] = deepcopy(v) end return o end

local function boot(class, opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.player.class = class
    S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER")
    if opts.setup then opts.setup() end
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
    ns.Options:Show("buffs"); mock.flushTimers()
    return ns
end
local function labelFrame(text)
    for _, f in ipairs(mock.frames) do if st(f).kind == "FontString" and st(f).text == text then return f end end
end
local function textOf(prefix)
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.kind == "FontString" and type(s.text) == "string" and s.text:find(prefix, 1, true) == 1 then return f, s.text end
    end
end
local function buttonByText(text) for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and st(f).text == text then return f end end end
local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
local function labels(rows) local out = {}; for _, r in ipairs(rows) do out[#out + 1] = r.label end return out end

local CASTERS = { "PALADIN", "PRIEST", "MAGE", "DRUID" }
local EMPTY = { "WARRIOR", "ROGUE", "HUNTER", "SHAMAN", "WARLOCK" }

-- ======================================================================== "You are playing" + empty catalog
describe("buff pane: 'You are playing' and the empty-catalog hint", function()
    for _, class in ipairs({ "PALADIN", "PRIEST", "MAGE", "DRUID", "WARRIOR", "ROGUE", "HUNTER", "SHAMAN", "WARLOCK" }) do
        it(class .. ": the header says 'You are playing: <Class>' in the class colour", function()
            local ns = boot(class)
            local f, text = textOf("You are playing:")
            assertEquals(text, "You are playing: " .. ns.Classes.NAMES[class])
            local c = ns.Classes.GetColor(class)
            local col = st(f).textColor
            assertNotNil(col); assertTrue(math.abs(col.r - c.r) < 1e-6 and math.abs(col.g - c.g) < 1e-6)
            assertEquals(#mock.errors, 0, errstr())
        end)
    end
    for _, class in ipairs(EMPTY) do
        it(class .. ": the grid and the Self row are hidden and the hint is shown, while Role buffs and Group roles remain", function()
            local ns = boot(class)
            local hint = labelFrame("Your class has no party buffs to assign. Use Role buffs below for anything special.")
            assertNotNil(hint); assertTrue(st(hint).shown)
            local cells = BU.cells(ns)
            assertFalse(st(cells.self).shown, "Self cell hidden")
            assertFalse(st(labelFrame("Self (you)")).shown)
            assertFalse(st(buttonByText("Use class/role rules")).shown)
            -- the grid is inside a hidden scroll frame
            local scroll
            for _, f in ipairs(mock.frames) do if st(f).kind == "ScrollFrame" and st(f).w == 530 and st(f).h == 200 then scroll = f end end
            assertNotNil(scroll); assertFalse(st(scroll).shown)
            -- role buffs + group roles still there
            assertTrue(st(labelFrame("Role buffs")).shown); assertTrue(st(labelFrame("Group roles")).shown)
            local add = buttonByText("+ Add role buff")
            assertNotNil(add); assertTrue(st(add).shown)
        end)
    end
    it("opening a cell popup for a class without a catalog shows nothing and never raises", function()
        local ns = boot("WARRIOR")
        local cells = BU.cells(ns)
        BU.close()
        for _, r in ipairs(cells.rows) do st(r.cell).scripts.OnClick(r.cell, "LeftButton") end
        st(cells.self).scripts.OnClick(cells.self, "LeftButton")
        assertFalse(BU.popupShown())
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Role buffs work for an empty-catalog class: add a role buff, toggle its roles, remove it", function()
        local ns = boot("WARRIOR")
        local preset = ns.db.presets[1]
        mock.menu = nil
        click(buttonByText("+ Add role buff"))
        local picked = mock.pickMenu("Battle Shout")
        if not picked then
            for _, f in ipairs(mock.frames) do local s = st(f); if s.shown and f.item and f.item.text == "Battle Shout" and s.scripts.OnClick then s.scripts.OnClick(f, "LeftButton"); picked = true end end
        end
        if not picked then ns.Presets.AddExtra(preset, "Battle Shout", { TANK = true }, false); ns:Changed("presets"); mock.flushTimers() end
        assertEquals(#preset.extras, 1); assertEquals(preset.extras[1].spell, "Battle Shout")
        assertEquals(#mock.errors, 0, errstr())
        ns.Presets.RemoveExtra(preset, 1); ns:Changed("presets"); mock.flushTimers()
        assertEquals(#preset.extras, 0)
    end)
    for _, class in ipairs(CASTERS) do
        it(class .. ": the grid and the Self row are shown and the hint is hidden", function()
            local ns = boot(class)
            local hint = labelFrame("Your class has no party buffs to assign. Use Role buffs below for anything special.")
            assertFalse(st(hint).shown)
            local cells = BU.cells(ns)
            assertTrue(st(cells.self).shown); assertTrue(st(labelFrame("Self (you)")).shown)
            for _, r in ipairs(cells.rows) do assertTrue(st(r.cell).shown, r.class .. " " .. r.role) end
        end)
    end
end)

-- ======================================================================== the cell popup
describe("buff pane: the cell popup", function()
    it("Paladin: one section 'Blessing (one at a time)' with None + six radio blessings", function()
        local ns = boot("PALADIN")
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["PALADIN:DEFAULT"])
        assertTrue(BU.popupShown())
        local rows, headers = BU.rows()
        assertDeepEquals(headers, { "Blessing (one at a time)" })
        assertDeepEquals(labels(rows), { "None", "Blessing of Might", "Blessing of Wisdom", "Blessing of Kings", "Blessing of Salvation", "Blessing of Light", "Blessing of Sanctuary" })
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("Priest: three checkbox sections, no None row; a role row gets one 'Use class row' row on top, the class row does not", function()
        local ns = boot("PRIEST")
        BU.openCell(BU.cells(ns).byKey["WARRIOR:TANK"])
        local rows, headers = BU.rows()
        assertDeepEquals(headers, { "Fortitude", "Divine Spirit", "Shadow Protection" })
        assertDeepEquals(labels(rows), { "Use class row", "Power Word: Fortitude", "Divine Spirit", "Shadow Protection" })
        BU.openCell(BU.cells(ns).byKey["WARRIOR:DEFAULT"])
        rows = BU.rows()
        assertDeepEquals(labels(rows), { "Power Word: Fortitude", "Divine Spirit", "Shadow Protection" })
    end)
    it("Mage: Intellect checkbox, then 'Magic (one at a time)' with Use class row / Dampen / Amplify on a role row (None on the class row)", function()
        local ns = boot("MAGE")
        BU.openCell(BU.cells(ns).byKey["PRIEST:HEALER"])
        local rows, headers = BU.rows()
        assertDeepEquals(headers, { "Intellect", "Magic (one at a time)" })
        assertDeepEquals(labels(rows), { "Arcane Intellect", "Use class row", "Dampen Magic", "Amplify Magic" })
        BU.openCell(BU.cells(ns).byKey["PRIEST:DEFAULT"])
        rows, headers = BU.rows()
        assertDeepEquals(headers, { "Intellect", "Magic (one at a time)" })
        assertDeepEquals(labels(rows), { "Arcane Intellect", "None", "Dampen Magic", "Amplify Magic" })
    end)
    it("Druid: two checkbox sections", function()
        local ns = boot("DRUID")
        BU.openCell(BU.cells(ns).byKey["MAGE:DEFAULT"])
        local rows, headers = BU.rows()
        assertDeepEquals(headers, { "Mark of the Wild", "Thorns" }); assertDeepEquals(labels(rows), { "Mark of the Wild", "Thorns" })
    end)
    it("a radio group on a role row: 'Use class row' is ticked while inheriting; picking replaces; 'Use class row' resets to nil; the popup stays open", function()
        local ns = boot("PALADIN")
        local cell = BU.cells(ns).byKey["PALADIN:HEALER"]
        local preset = ns.db.presets[1]
        BU.openCell(cell)
        assertDeepEquals(BU.checked(), { "Use class row" })
        assertTrue(BU.pick("Blessing of Wisdom"))
        assertTrue(BU.popupShown(), "stays open for more clicks")
        assertDeepEquals(BU.checked(), { "Blessing of Wisdom" })
        assertDeepEquals(preset.map.PALADIN.HEALER, { "wisdom" })
        BU.pick("Blessing of Kings"); assertDeepEquals(BU.checked(), { "Blessing of Kings" }); assertDeepEquals(preset.map.PALADIN.HEALER, { "kings" })
        BU.pick("Use class row"); assertDeepEquals(BU.checked(), { "Use class row" }); assertNil(preset.map.PALADIN.HEALER)
        assertTrue(BU.popupShown(), "stays open after Use class row")
        BU.pick("Blessing of Kings"); BU.pick("Blessing of Kings")
        assertDeepEquals(preset.map.PALADIN.HEALER, { "kings" }, "clicking the chosen radio row keeps it")
    end)
    it("a radio group on the class row: None is ticked when nothing is chosen and None stores an empty set", function()
        local ns = boot("PALADIN")
        local preset = ns.db.presets[1]
        BU.openCell(BU.cells(ns).byKey["PALADIN:DEFAULT"])
        assertDeepEquals(BU.checked(), { "None" })
        BU.pick("Blessing of Might"); assertDeepEquals(preset.map.PALADIN.DEFAULT, { "might" }); assertDeepEquals(BU.checked(), { "Blessing of Might" })
        BU.pick("None"); assertDeepEquals(BU.checked(), { "None" }); assertDeepEquals(preset.map.PALADIN.DEFAULT, {})
        assertNil(ns.Presets.ResolveBuff(preset, "PALADIN", "DEFAULT"))
    end)
    it("checkbox groups toggle independently; ticking one never changes another", function()
        local ns = boot("PRIEST")
        local preset = ns.db.presets[1]
        BU.openCell(BU.cells(ns).byKey["MAGE:DEFAULT"])
        BU.pick("Power Word: Fortitude"); BU.pick("Shadow Protection")
        assertDeepEquals(BU.checked(), { "Power Word: Fortitude", "Shadow Protection" })
        assertDeepEquals(preset.map.MAGE.DEFAULT, { "fortitude", "shadowprot" })
        BU.pick("Power Word: Fortitude")
        assertDeepEquals(preset.map.MAGE.DEFAULT, { "shadowprot" }); assertDeepEquals(BU.checked(), { "Shadow Protection" })
        BU.pick("Divine Spirit"); assertDeepEquals(preset.map.MAGE.DEFAULT, { "spirit", "shadowprot" })
    end)
    it("Mage: Arcane Intellect plus one of Dampen/Amplify at the same time", function()
        local ns = boot("MAGE")
        local preset = ns.db.presets[1]
        BU.openCell(BU.cells(ns).byKey["WARRIOR:TANK"])
        BU.pick("Arcane Intellect"); BU.pick("Dampen Magic")
        assertDeepEquals(BU.checked(), { "Arcane Intellect", "Dampen Magic" })
        BU.pick("Amplify Magic")
        assertDeepEquals(BU.checked(), { "Arcane Intellect", "Amplify Magic" }); assertDeepEquals(preset.map.WARRIOR.TANK, { "arcaneint", "amplify" })
        assertFalse(BU.pick("None"), "a role row has no None row")
        BU.pick("Use class row")
        assertNil(preset.map.WARRIOR.TANK, "Use class row resets the whole role cell")
        assertDeepEquals(BU.checked(), { "Use class row" }, "class row is empty, so nothing else is ticked")
        assertDeepEquals(ns.Presets.CellBuffs(preset, "WARRIOR", "TANK"), {})
        BU.openCell(BU.cells(ns).byKey["WARRIOR:DEFAULT"])
        BU.pick("Arcane Intellect"); BU.pick("Dampen Magic"); BU.pick("None")
        assertDeepEquals(BU.checked(), { "Arcane Intellect", "None" }, "class row: None is ticked while the radio group is empty")
        assertDeepEquals(preset.map.WARRIOR.DEFAULT, { "arcaneint" })
    end)
    it("each row shows the buff icon (spellbook texture, or the catalog icon)", function()
        local ns = boot("PRIEST")
        BU.openCell(BU.cells(ns).byKey["MAGE:DEFAULT"])
        for _, r in ipairs((BU.rows())) do assertTrue(r.iconShown, r.label) end
    end)
    it("unknown spells are greyed with 'Not in your spellbook' but can still be assigned (a preset may be built for other characters)", function()
        local ns = boot("PRIEST")
        local ids = {}
        local info = C_Spell.GetSpellInfo("Power Word: Fortitude"); ids[info.spellID] = true
        _G.IsPlayerSpell = function(id) return ids[id] == true end; _G.IsSpellKnownOrOverridesKnown = function(id) return ids[id] == true end
        _G.IsSpellKnown = function() return false end; _G.C_SpellBook = { IsSpellKnown = function(id) return ids[id] == true end }
        BU.openCell(BU.cells(ns).byKey["MAGE:DEFAULT"])
        local rows = BU.rows()
        for _, r in ipairs(rows) do
            if r.label == "Power Word: Fortitude" then assertFalse(r.unknown); assertFalse(r.desat and true or false)
            else assertTrue(r.unknown, r.label .. " is not known"); assertTrue(r.desat, r.label .. " icon greyed") end
        end
        assertTrue(BU.pick("Divine Spirit"))
        assertDeepEquals(ns.db.presets[1].map.MAGE.DEFAULT, { "spirit" })
    end)
    it("a spell counts as known when only the group spell is known", function()
        local ns = boot("PRIEST")
        local ids = {}
        ids[C_Spell.GetSpellInfo("Prayer of Fortitude").spellID] = true
        _G.IsPlayerSpell = function(id) return ids[id] == true end; _G.IsSpellKnownOrOverridesKnown = function(id) return ids[id] == true end
        _G.IsSpellKnown = function() return false end; _G.C_SpellBook = { IsSpellKnown = function(id) return ids[id] == true end }
        BU.openCell(BU.cells(ns).byKey["MAGE:DEFAULT"])
        for _, r in ipairs((BU.rows())) do if r.label == "Power Word: Fortitude" then assertFalse(r.unknown) end end
    end)
    it("one popup serves every cell: opening another cell re-renders the ticks for THAT cell", function()
        local ns = boot("PRIEST")
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["MAGE:DEFAULT"]); BU.pick("Divine Spirit")
        BU.openCell(cells.byKey["ROGUE:DEFAULT"])
        assertDeepEquals(BU.checked(), {}, "another cell: nothing ticked")
        BU.openCell(cells.byKey["MAGE:DEFAULT"])
        assertDeepEquals(BU.checked(), { "Divine Spirit" })
    end)
    it("the popup is closed by the click-catcher and by ESC (UISpecialFrames), is non-secure and sits above the options window", function()
        local ns = boot("PALADIN")
        BU.openCell(BU.cells(ns).byKey["PALADIN:TANK"])
        local p = BU.popup()
        assertTrue(st(p).shown); assertFalse(st(p).secure and true or false); assertEquals(st(p).strata, "FULLSCREEN_DIALOG")
        local n = 0
        for _, name in ipairs(_G.UISpecialFrames) do if name == "HealerForeverBuffPopup" then n = n + 1 end end
        assertEquals(n, 1)
        mock.runFrameScript(p, "OnShow")
        local catcher
        for _, f in ipairs(mock.frames) do if st(f).kind == "Button" and st(f).strata == "FULLSCREEN" and st(f).allPoints then catcher = f end end
        assertNotNil(catcher); assertTrue(st(catcher).shown)
        st(catcher).scripts.OnClick(catcher, "LeftButton")
        assertFalse(st(p).shown)
        BU.openCell(BU.cells(ns).byKey["PALADIN:TANK"])
        for _, name in ipairs(_G.UISpecialFrames) do local fr = _G[name]; if fr and st(fr).shown then fr:Hide() end end
        assertFalse(st(p).shown, "ESC closes it")
    end)
    it("works in combat (non-secure pane): no protected calls, no errors", function()
        local ns = boot("PRIEST")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local cells = BU.cells(ns)
        BU.openCell(cells.byKey["WARRIOR:TANK"]); BU.pick("Divine Spirit"); BU.openCell(cells.self); BU.pick("Shadow Protection")
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, 0); assertEquals(#mock.softViolations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("works with every value secret", function()
        local ns = boot("MAGE")
        S.secretAll = true
        local cells = BU.cells(ns)
        for _, r in ipairs(cells.rows) do BU.openCell(r.cell); for _, row in ipairs((BU.rows())) do BU.click(row.frame) end end
        ns.Options:Show("buffs"); ns.Options:Refresh(); mock.flushTimers()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== cell icons + Self row
describe("buff pane: cell icons and the Self row", function()
    it("a cell shows an icon per buff of its set (catalog order), the dash when empty; role rows show '= default' until overridden", function()
        local ns = boot("PRIEST")
        local preset = ns.db.presets[1]
        ns.Presets.SetCellBuff(preset, "MAGE", "DEFAULT", "spirit", true); ns.Presets.SetCellBuff(preset, "MAGE", "DEFAULT", "fortitude", true)
        ns:Changed("presets"); mock.flushTimers()
        local cells = BU.cells(ns)
        local icons = BU.cellIcons(cells.byKey["MAGE:DEFAULT"])
        assertEquals(#icons, 2)
        assertEquals(icons[1], ns.BuffButtons.IconFor("Power Word: Fortitude", ns.Classes.BUFFS.fortitude))
        assertEquals(icons[2], ns.BuffButtons.IconFor("Divine Spirit", ns.Classes.BUFFS.spirit))
        assertEquals(BU.cellDash(cells.byKey["MAGE:DEFAULT"]), "")
        ns.Presets.ClearGroup(preset, "MAGE", "DEFAULT", "fortitude"); ns.Presets.ClearGroup(preset, "MAGE", "DEFAULT", "spirit"); ns:Changed("presets"); mock.flushTimers()
        cells = BU.cells(ns)
        assertEquals(#BU.cellIcons(cells.byKey["MAGE:DEFAULT"]), 0)
        assertEquals(BU.cellDash(cells.byKey["MAGE:DEFAULT"]), "\226\128\148", "an em dash for 'no buff'")
    end)
    it("a role row inherits DEFAULT's icons until overridden, and the '= default' note follows", function()
        local ns = boot("PRIEST")
        local preset = ns.db.presets[1]
        ns.Presets.SetCellBuff(preset, "PALADIN", "DEFAULT", "fortitude", true); ns:Changed("presets"); mock.flushTimers()
        local cells = BU.cells(ns)
        assertEquals(#BU.cellIcons(cells.byKey["PALADIN:TANK"]), 1, "inherits DEFAULT")
        local note
        for _, f in ipairs(mock.frames) do if st(f).kind == "FontString" and st(f).text == "= default" then note = f; break end end
        assertNotNil(note)
        ns.Presets.SetCellBuff(preset, "PALADIN", "TANK", "spirit", true); ns:Changed("presets"); mock.flushTimers()
        cells = BU.cells(ns)
        assertEquals(#BU.cellIcons(cells.byKey["PALADIN:TANK"]), 2)
    end)
    it("a cell never shows more than six icons", function()
        local ns = boot("PALADIN")
        local preset = ns.db.presets[1]
        preset.map.MAGE = { DEFAULT = { "might", "wisdom", "kings", "salvation", "light", "sanctuary", "fortitude", "spirit" } }
        ns:Changed("presets"); mock.flushTimers()
        assertTrue(#BU.cellIcons(BU.cells(ns).byKey["MAGE:DEFAULT"]) <= 6)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the Self cell: 'class/role rules' when self is nil, the dash text 'none' when empty, icons when set; 'Use class/role rules' resets", function()
        local ns = boot("PALADIN")
        local preset = ns.db.presets[1]
        local cells = BU.cells(ns)
        assertEquals(BU.cellDash(cells.self), "class/role rules"); assertEquals(#BU.cellIcons(cells.self), 0)
        BU.openCell(cells.self); BU.pick("Blessing of Kings")
        cells = BU.cells(ns)
        assertEquals(#BU.cellIcons(cells.self), 1); assertEquals(BU.cellDash(cells.self), "")
        assertTrue(BU.pick("None (no buffs for you)"), "the Self popup labels its None row clearly")
        cells = BU.cells(ns)
        assertEquals(BU.cellDash(cells.self), "none"); assertDeepEquals(preset.self, {})
        BU.close()
        click(buttonByText("Use class/role rules"))
        assertNil(preset.self); assertEquals(BU.cellDash(BU.cells(ns).self), "class/role rules")
    end)
    it("a Self set changes what the PLAYER'S buff button shows, nobody else's", function()
        local ns = boot("PRIEST")
        local preset = ns.db.presets[1]
        for _, c in ipairs({ "WARRIOR", "PRIEST", "MAGE", "PALADIN" }) do ns.Presets.SetCellBuff(preset, c, "DEFAULT", "fortitude", true) end
        local cells = BU.cells(ns)
        BU.openCell(cells.self); BU.pick("Shadow Protection"); BU.close()
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        local function buffBtn(u) for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == u then return f end end end
        assertEquals(buffBtn("player").buffKey, "shadowprot"); assertEquals(buffBtn("party1").buffKey, "fortitude")
    end)
    it("selecting another preset in the dropdown shows that preset's cells, and edits go to it only", function()
        local ns = boot("PRIEST")
        ns.Presets.Add(ns.db.presets, "Second", nil)
        ns:Changed("presets"); mock.flushTimers()
        local dd
        for _, f in ipairs(mock.frames) do local p = st(f).points[1]; if rawget(f, "Refresh") and p and p[2] == 60 and p[3] == -52 then dd = f end end
        assertNotNil(dd)
        st(dd).scripts.OnClick(dd, "LeftButton")
        local picked
        for _, f in ipairs(mock.frames) do local s = st(f); if s.shown and f.item and type(f.item.text) == "string" and f.item.text:find("2. Second", 1, true) then s.scripts.OnClick(f, "LeftButton"); picked = true end end
        if not picked then mock.pickMenu("2. Second") end
        mock.flushTimers()
        BU.openCell(BU.cells(ns).byKey["MAGE:DEFAULT"]); BU.pick("Divine Spirit"); BU.close()
        assertDeepEquals(ns.db.presets[2].map.MAGE.DEFAULT, { "spirit" })
        assertDeepEquals(ns.db.presets[1].map.MAGE and ns.db.presets[1].map.MAGE.DEFAULT or {}, {})
    end)
end)

-- ======================================================================== Load example menu
describe("buff pane: the 'Load example...' menu", function()
    local function openMenu(ns)
        mock.menu = nil
        click(buttonByText("Load example..."))
    end
    local function menuTexts()
        local out = {}
        for _, e in ipairs(mock.menu and mock.menu.entries or {}) do out[#out + 1] = e.text end
        if #out == 0 then
            for _, f in ipairs(mock.frames) do local s = st(f); if s.shown and f.item and type(f.item.text) == "string" and f.item.text:find("^Load example:") then out[#out + 1] = f.item.text end end
        end
        table.sort(out)
        return out
    end
    local function choose(text)
        if mock.pickMenu(text) then mock.flushTimers(); return true end
        for _, f in ipairs(mock.frames) do local s = st(f); if s.shown and f.item and f.item.text == text and s.scripts.OnClick then s.scripts.OnClick(f, "LeftButton"); mock.flushTimers(); return true end end
        return false
    end
    it("lists exactly Paladin, Priest, Mage and Druid", function()
        local ns = boot("PALADIN")
        openMenu(ns)
        assertDeepEquals(menuTexts(), { "Load example: Druid", "Load example: Mage", "Load example: Paladin", "Load example: Priest" })
    end)
    for _, class in ipairs(CASTERS) do
        it(class .. ": adds the example as a NEW preset, never overwrites or reorders, keeps the active preset", function()
            local ns = boot("PALADIN")
            ns.db.presets[1].name = "Mine"; ns.db.presets[1].map.MAGE = { DEFAULT = { "kings" } }
            ns.Presets.Add(ns.db.presets, "Second", 1)
            local before = deepcopy(ns.db.presets); local active = ns.db.activePreset
            local names = { PALADIN = "Paladin", PRIEST = "Priest", MAGE = "Mage", DRUID = "Druid" }
            openMenu(ns)
            assertTrue(choose("Load example: " .. names[class]))
            assertEquals(#ns.db.presets, #before + 1)
            for i = 1, #before do assertTrue(require("framework").deepEq(before[i], ns.db.presets[i]), "preset " .. i .. " changed") end
            local added = ns.db.presets[#before + 1]
            assertTrue(require("framework").deepEq(ns.Presets.ExampleFor(class), added))
            assertEquals(ns.db.activePreset, active, "the active preset does not change")
            assertEquals(#mock.errors, 0, errstr())
        end)
    end
    it("loading an example selects it for editing: the cells show its content", function()
        local ns = boot("PRIEST")
        openMenu(ns); assertTrue(choose("Load example: Priest"))
        local cells = BU.cells(ns)
        assertEquals(#BU.cellIcons(cells.byKey["MAGE:DEFAULT"]), 2, "Fortitude + Spirit")
        assertEquals(#BU.cellIcons(cells.byKey["WARRIOR:TANK"]), 2, "Fortitude + Shadow Protection")
    end)
    it("loading the same example twice adds two independent copies", function()
        local ns = boot("MAGE")
        openMenu(ns); choose("Load example: Mage"); openMenu(ns); choose("Load example: Mage")
        assertEquals(#ns.db.presets, 3)
        ns.Presets.SetCellBuff(ns.db.presets[2], "ROGUE", "DEFAULT", "dampen", true)
        assertDeepEquals(ns.db.presets[3].map.ROGUE.DEFAULT, { "arcaneint" })
    end)
    it("an example can be made active and the buff buttons then use it (Druid example: Mark of the Wild + Thorns on the tank)", function()
        local ns = boot("DRUID")
        openMenu(ns); choose("Load example: Druid")
        ns:SetActivePreset(#ns.db.presets); mock.flushTimers(); mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.tick(); mock.flushTimers()
        local b
        for _, f in ipairs(mock.frames) do local n = st(f).name; if n and n:match("^HealerForeverBuff%d$") and f.unit == "party1" then b = f end end
        assertEquals(b.buffKey, "motw"); assertEquals(rawget(b.count, "__s").text, "2")
    end)
    it("an example from another class is still loadable (a Paladin may load the Priest example for a friend); the menu works in combat", function()
        local ns = boot("PALADIN")
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        openMenu(ns); assertTrue(choose("Load example: Priest"))
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#ns.db.presets, 2); assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("the loaded examples survive save and reload", function()
        local ns = boot("PRIEST")
        openMenu(ns); choose("Load example: Priest")
        mock.fire("PLAYER_LOGOUT")
        local saved = deepcopy(HealerForeverCharDB)
        local ns2 = boot("PRIEST", { char = saved })
        assertEquals(#ns2.db.presets, 2)
        assertDeepEquals(ns2.db.presets[2].map.MAGE.DEFAULT, { "fortitude", "spirit" })
    end)
end)

-- ======================================================================== credit
describe("buff pane: the credit 'by trtg'", function()
    local ns = boot("PALADIN")
    it("the TOC Author is trtg", function() assertEquals(toc.meta.Author, "trtg") end)
    it("the footer reads '... settings vN . by trtg' on EVERY options tab", function()
        local keys = {}
        for _, pane in ipairs(ns.Options.panes) do keys[#keys + 1] = pane.key end
        assertTrue(#keys >= 6, "panes: " .. #keys)
        for _, key in ipairs(keys) do
            ns.Options:Show(key); mock.flushTimers()
            local found
            for _, f in ipairs(mock.frames) do
                local s = st(f)
                if s.kind == "FontString" and type(s.text) == "string" and s.text:find("by trtg", 1, true) and s.text:find("settings v" .. ns.SchemaVersion(), 1, true) then found = f end
            end
            assertNotNil(found, "footer missing on tab " .. key)
            assertTrue(st(ns.Options.frame).shown and st(found).shown, "the footer is part of the window frame, visible on " .. key)
            assertTrue(st(found).parent == ns.Options.frame, "the footer belongs to the window, not to a pane (" .. key .. ")")
        end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the footer text is exactly 'Healer Forever vX . settings vN . by trtg' (dev builds say dev)", function()
        S.addonVersion = "3.2.1"
        local text
        mock.install(); mock.state.addonVersion = "3.2.1"
        local n2 = {}
        for _, rel in ipairs(toc.files) do if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, n2)) end end
        mock.fire("ADDON_LOADED", "HealerForever"); mock.fire("PLAYER_LOGIN"); mock.setGroup(1); mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
        n2.Options:Show("general"); mock.flushTimers()
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("by trtg", 1, true) and s.text:find("settings v", 1, true) then text = s.text end end
        assertEquals(text, "Healer Forever v3.2.1 \194\183 settings v4 \194\183 by trtg")
    end)
    it("the About block on the General tab says 'created by trtg' with the version and schema", function()
        ns.Options:Show("general"); mock.flushTimers()
        local _, text = textOf("Healer Forever, created by trtg")
        assertNotNil(text)
        assertTrue(text:find("Version " .. ns.AddonVersion(), 1, true), text); assertTrue(text:find("settings schema v" .. ns.SchemaVersion(), 1, true), text)
    end)
    it("/hf version prints the version, the schema and the credit", function()
        mock.printed = {}
        _G.SlashCmdList.HEALERFOREVER("version")
        local out = table.concat(mock.printed, "\n")
        assertTrue(out:find("HealerForever " .. ns.AddonVersion() .. " (settings schema " .. ns.SchemaVersion() .. ") by trtg", 1, true), out)
    end)
    it("the credit appears nowhere it should not: no 'by trtg' text inside secure frames", function()
        for _, f in ipairs(mock.frames) do
            local s = st(f)
            if s.secure then assertFalse(type(s.text) == "string" and s.text:find("trtg", 1, true) ~= nil) end
        end
    end)
end)
