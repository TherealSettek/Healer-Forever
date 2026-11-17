-- Non-Mac meta handling: "Win" labels, Bindings.HasMeta / DisplayLabel, the greyed "Win key (not recommended)" toggle with its
-- warning tooltip, chip suffix, bar tooltip label, unchanged Mac UI, and no key glyph bytes left in the addon source.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function st(f) return rawget(f, "__s") end
local function errstr() return table.concat(mock.errors, "\n---\n") end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.macClient = opts.mac and true or false
    S.units.party1 = { name = "T", class = "WARRIOR", health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = "TANK" }
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if ns.db then Fx.seed(ns, { presets = 2 }) end
    if opts.pre then opts.pre(ns) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(2)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.3); mock.flushTimers()
    return ns
end

-- ======================================================================== pure helpers
describe("meta labels: Bindings.HasMeta / DisplayLabel / ModifierLabel", function()
    local ns = boot()
    local B = ns.Bindings
    it("HasMeta is true exactly for combos containing meta", function()
        assertTrue(B.HasMeta("meta")); assertTrue(B.HasMeta("alt-meta")); assertTrue(B.HasMeta("alt-ctrl-meta-shift"))
        for _, k in ipairs({ "", "shift", "ctrl", "alt", "alt-ctrl-shift", "ctrl-shift" }) do assertFalse(B.HasMeta(k), k) end
    end)
    it("HasMeta never raises on nil or junk", function()
        for _, v in ipairs({ "bogus", "meta-meta", "|" }) do assertTrue(pcall(B.HasMeta, v)) end
        assertTrue(pcall(B.HasMeta, nil))
        assertFalse(B.HasMeta(nil) and true or false)
    end)
    it("non-Mac: ModifierLabel says Win, DisplayLabel adds ' (Win key)' for meta combos only", function()
        assertEquals(B.ModifierLabel("meta", false), "Win")
        assertEquals(B.DisplayLabel("meta", false), "Win (Win key)")
        assertEquals(B.DisplayLabel("shift-meta", false), "Shift + Win (Win key)")
        assertEquals(B.DisplayLabel("alt-ctrl-meta-shift", false), "Shift + Ctrl + Alt + Win (Win key)")
        assertEquals(B.DisplayLabel("shift", false), "Shift")
        assertEquals(B.DisplayLabel("alt-ctrl", false), "Ctrl + Alt")
        assertEquals(B.DisplayLabel("", false), "No modifier")
    end)
    it("Mac: DisplayLabel equals ModifierLabel (Cmd/Option, no suffix) for every combo", function()
        assertEquals(B.DisplayLabel("meta", true), "Cmd")
        assertEquals(B.DisplayLabel("alt-meta", true), "Option + Cmd")
        for _, k in ipairs({ "", "shift", "alt", "meta", "alt-ctrl-meta-shift", "ctrl-shift" }) do
            assertEquals(B.DisplayLabel(k, true), B.ModifierLabel(k, true), k)
            assertNil(B.DisplayLabel(k, true):find("Win", 1, true), k)
        end
    end)
    it("DisplayLabel and HasMeta cover all 16 combinations consistently", function()
        for mask = 0, 15 do
            local key = ns.Util.ModifierKey(mask % 2 == 1, math.floor(mask / 2) % 2 == 1, math.floor(mask / 4) % 2 == 1, math.floor(mask / 8) % 2 == 1)
            local has = math.floor(mask / 8) % 2 == 1
            assertEquals(B.HasMeta(key), has, key)
            assertEquals(B.DisplayLabel(key, false):find("(Win key)", 1, true) ~= nil, has, key)
            assertNil(B.ModifierLabel(key, false):find("Meta", 1, true), "no 'Meta' wording left: " .. key)
        end
    end)
end)

-- ======================================================================== pane (non-Mac)
local function paneParts()
    local toggles, rows, labels = {}, {}, {}
    local byLabel = { Shift = "shift", Ctrl = "ctrl", Alt = "alt", Option = "alt", Cmd = "meta", ["Win key (not recommended)"] = "meta" }
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.kind == "Button" and type(rawget(f, "text")) == "table" and s.scripts.OnClick and s.template == "BackdropTemplate" then
            local k = byLabel[st(f.text).text]
            if k then toggles[k] = f end
        end
        if type(f.button) == "number" and f.pick and f.clear then rows[f.button] = f end
        if s.kind == "FontString" and type(s.text) == "string" and s.text ~= "" then labels[#labels + 1] = f end
    end
    return toggles, rows, labels
end
local function click(f) st(f).scripts.OnClick(f, "LeftButton"); mock.flushTimers() end
local function chipTexts()
    local out = {}
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.shown and type(s.text) == "string" and s.text:match("%(%d+%)$") and s.scripts.OnClick then out[#out + 1] = s.text end
    end
    return out
end
local function cmdNoteShown()
    for _, f in ipairs(mock.frames) do
        local s = st(f)
        if s.kind == "FontString" and s.text == "On Mac, Cmd+Left-click may act as a right click." then return s.shown end
    end
end
local function recorder()
    local lines = {}
    local gt = _G.GameTooltip
    gt.SetOwner = function() lines = {} end
    gt.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
    gt.AddDoubleLine = function(_, l, r) lines[#lines + 1] = tostring(l) .. " " .. tostring(r) end
    gt.Show = function() end; gt.Hide = function() end; gt.ClearLines = function() lines = {} end
    return function() return table.concat(lines, "\n") end
end

describe("meta labels: non-Mac Click-Casting pane", function()
    local ns = boot({ pre = function(ns)
        ns.db.bindings[ns.Bindings.MakeKey("meta", 1)] = { type = "spell", spell = "Flash Heal" }
        ns.db.bindings[ns.Bindings.MakeKey(ns.Util.ModifierKey(true, false, false, true), 2)] = { type = "target" }
    end })
    ns.Options:Show("binds"); mock.flushTimers()
    local toggles, rows = paneParts()
    it("builds with four toggles; the meta toggle is labelled 'Win key (not recommended)'", function()
        assertEquals(#mock.errors, 0, errstr())
        for _, m in ipairs({ "shift", "ctrl", "alt", "meta" }) do assertNotNil(toggles[m], m) end
        assertEquals(st(toggles.meta.text).text, "Win key (not recommended)")
        assertEquals(st(toggles.alt.text).text, "Alt")
    end)
    it("the meta toggle is 170px wide and the others 100px", function()
        assertEquals(st(toggles.meta).w, 170)
        for _, m in ipairs({ "shift", "ctrl", "alt" }) do assertEquals(st(toggles[m]).w, 100, m) end
    end)
    it("the meta toggle is greyed (text colour and dimmed flag); the others are not", function()
        local c = st(toggles.meta.text).textColor
        assertNotNil(c); assertTrue(c.r < 0.7 and math.abs(c.r - c.g) < 1e-6 and math.abs(c.g - c.b) < 1e-6, "grey")
        assertTrue(toggles.meta.dimmed)
        for _, m in ipairs({ "shift", "ctrl", "alt" }) do assertFalse(toggles[m].dimmed and true or false, m); assertNil(st(toggles[m].text).textColor, m) end
    end)
    it("toggles do not overlap each other (the wide button shifts nothing after it into a neighbour)", function()
        local order = { "shift", "ctrl", "alt", "meta" }
        for i = 1, #order - 1 do
            local a, b = st(toggles[order[i]]), st(toggles[order[i + 1]])
            assertTrue(a.points[1][2] + a.w <= b.points[1][2], order[i] .. " overlaps " .. order[i + 1])
        end
    end)
    it("hovering the meta toggle shows the warning tooltip; leaving hides it", function()
        local get = recorder()
        local hid = false
        _G.GameTooltip.Hide = function() hid = true end
        st(toggles.meta).scripts.OnEnter(toggles.meta)
        local t = get()
        assertTrue(t:find("Windows key", 1, true), t); assertTrue(t:find("Start menu", 1, true), t)
        assertTrue(t:find("Shift, Ctrl or Alt", 1, true), t)
        st(toggles.meta).scripts.OnLeave(toggles.meta)
        assertTrue(hid)
    end)
    it("the other toggles have no tooltip handlers", function()
        for _, m in ipairs({ "shift", "ctrl", "alt" }) do assertNil(st(toggles[m]).scripts.OnEnter, m) end
    end)
    it("the greyed toggle still works (all four modifiers toggle the visible rows' combo)", function()
        _, rows = paneParts()
        click(toggles.meta)
        for i = 1, 5 do assertEquals(rows[i].key, ns.Bindings.MakeKey("meta", i)) end
        click(toggles.shift)
        for i = 1, 5 do assertEquals(rows[i].key, ns.Bindings.MakeKey(ns.Util.ModifierKey(true, false, false, true), i)) end
        click(toggles.shift); click(toggles.meta)
        for i = 1, 5 do assertEquals(rows[i].key, ns.Bindings.MakeKey("", i)) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("existing meta bindings are untouched by showing, toggling and reopening the pane", function()
        local k1, k2 = ns.Bindings.MakeKey("meta", 1), ns.Bindings.MakeKey(ns.Util.ModifierKey(true, false, false, true), 2)
        click(toggles.meta)
        _, rows = paneParts()
        assertEquals(st(rows[1].text).text, "Flash Heal")
        click(toggles.meta)
        ns.Options:Show("general"); ns.Options:Show("binds"); mock.flushTimers()
        assertEquals(ns.db.bindings[k1].spell, "Flash Heal"); assertEquals(ns.db.bindings[k2].type, "target")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the 'editing' line and the chips use the Win wording; chips carry the ' (Win key)' suffix only for meta combos", function()
        local chips = chipTexts()
        local joined = table.concat(chips, "|")
        assertTrue(joined:find("Win (Win key) (1)", 1, true), joined)
        assertTrue(joined:find("Shift + Win (Win key) (1)", 1, true), joined)
        assertNil(joined:find("Meta", 1, true), joined)
        for _, c in ipairs(chips) do
            if not c:find("Win", 1, true) then assertNil(c:find("(Win key)", 1, true), c) end
        end
        local editing
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("^Editing: ") then editing = s.text end end
        assertNotNil(editing)
    end)
    it("the Cmd+Left-click note is NOT shown on non-Mac, even with meta toggled", function()
        click(toggles.meta)
        assertFalse(cmdNoteShown() and true or false)
        click(toggles.meta)
    end)
    it("the editing line says 'Win' for meta on non-Mac", function()
        click(toggles.meta)
        local editing
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("^Editing: ") then editing = s.text end end
        assertEquals(editing, "Editing: Win")
        click(toggles.meta)
    end)
end)

describe("meta labels: the bar tooltip", function()
    local ns = boot({ pre = function(ns) ns.db.bindings[ns.Bindings.MakeKey("meta", 1)] = { type = "spell", spell = "Flash Heal" } end })
    local function hover(mod)
        local get = recorder()
        S.shift, S.ctrl, S.alt, S.meta = mod.shift, mod.ctrl, mod.alt, mod.meta
        local b = ns.UnitFrames.byUnit.party1
        ns.UnitFrames:ShowTooltip(b)
        S.shift, S.ctrl, S.alt, S.meta = nil, nil, nil, nil
        return get()
    end
    it("holding the Win key lists 'Click-casting: Win (Win key)' on non-Mac", function()
        local t = hover({ meta = true })
        assertTrue(t:find("Click-casting: Win (Win key)", 1, true), t)
        assertNil(t:find("Meta", 1, true), t)
    end)
    it("other modifiers have no suffix", function()
        local t = hover({ shift = true }); assertTrue(t:find("Click-casting: Shift\n", 1, true) or t:find("Click-casting: Shift$"), t)
        assertNil(t:find("(Win key)", 1, true))
        t = hover({}); assertTrue(t:find("Click-casting: No modifier", 1, true), t)
    end)
    it("combined: Shift + Win (Win key)", function()
        assertTrue(hover({ shift = true, meta = true }):find("Click-casting: Shift + Win (Win key)", 1, true))
    end)
end)

-- ======================================================================== Mac UI unchanged
describe("meta labels: the Mac UI is unchanged", function()
    local ns = boot({ mac = true, pre = function(ns) ns.db.bindings[ns.Bindings.MakeKey("meta", 1)] = { type = "spell", spell = "Flash Heal" } end })
    ns.Options:Show("binds"); mock.flushTimers()
    local toggles, rows = paneParts()
    it("toggles read plain Shift / Ctrl / Option / Cmd, all 100px wide, none greyed", function()
        assertEquals(st(toggles.shift.text).text, "Shift"); assertEquals(st(toggles.ctrl.text).text, "Ctrl")
        assertEquals(st(toggles.alt.text).text, "Option"); assertEquals(st(toggles.meta.text).text, "Cmd")
        for _, m in ipairs({ "shift", "ctrl", "alt", "meta" }) do
            assertEquals(st(toggles[m]).w, 100, m)
            assertFalse(toggles[m].dimmed and true or false, m)
            assertNil(st(toggles[m].text).textColor, m)
            assertNil(st(toggles[m]).scripts.OnEnter, m)
        end
    end)
    it("the Cmd+Left-click note shows only while Cmd is toggled", function()
        assertFalse(cmdNoteShown() and true or false)
        click(toggles.meta); assertTrue(cmdNoteShown())
        click(toggles.meta); assertFalse(cmdNoteShown() and true or false)
    end)
    it("chips and the editing line say Cmd with no Win suffix", function()
        local joined = table.concat(chipTexts(), "|")
        assertTrue(joined:find("Cmd (", 1, true), joined)
        assertNil(joined:find("Win", 1, true), joined)
        click(toggles.meta)
        local editing
        for _, f in ipairs(mock.frames) do local s = st(f); if s.kind == "FontString" and type(s.text) == "string" and s.text:find("^Editing: ") then editing = s.text end end
        assertEquals(editing, "Editing: Cmd")
        click(toggles.meta)
    end)
    it("the bar tooltip says Cmd on Mac", function()
        local get = recorder()
        S.meta = true
        ns.UnitFrames:ShowTooltip(ns.UnitFrames.byUnit.party1)
        S.meta = nil
        local t = get()
        assertTrue(t:find("Click-casting: Cmd", 1, true), t); assertNil(t:find("Win", 1, true), t)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

-- ======================================================================== source: no key glyphs
describe("meta labels: no key glyph bytes remain in the addon", function()
    it("neither U+2325 (option) nor U+2318 (command) appears in any shipped file", function()
        local p = io.popen('find "' .. L.addonDir .. '" -type f \\( -name "*.lua" -o -name "*.xml" -o -name "*.toc" \\)')
        local bad, n = {}, 0
        for path in p:lines() do
            n = n + 1
            local src = L.readFile(path)
            if src:find("\226\140\165", 1, true) then bad[#bad + 1] = path .. ": U+2325" end
            if src:find("\226\140\152", 1, true) then bad[#bad + 1] = path .. ": U+2318" end
        end
        p:close()
        assertTrue(n > 20, "scanned " .. n .. " files")
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
    it("the scan can see the bytes (self-test)", function()
        assertTrue(("x\226\140\165y"):find("\226\140\165", 1, true) ~= nil)
    end)
end)
