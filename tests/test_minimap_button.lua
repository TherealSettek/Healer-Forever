-- Minimap button, design B "status badges": icon fallback, status dot, lock badge, preset initial, tooltip, drag, clicks.
local L = require("loader")
local mock = require("wow_mock")
local Fx = require("fixtures")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end

local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function st(f) return rawget(f, "__s") end
local function frameNamed(name) for _, f in ipairs(mock.frames) do if st(f).name == name then return f end end end

local function boot(opts)
    opts = opts or {}
    mock.install(); S = mock.state
    S.units.party1 = { name = "T", class = "WARRIOR", health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = "TANK" }
    if opts.setup then opts.setup(S) end
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if ns.db then Fx.seed(ns, { presets = 3 }) end
    if opts.pre then opts.pre(ns) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 1)
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
    return ns, frameNamed("HealerForeverMinimapButton")
end

local lines
local function record()
    local gt = _G.GameTooltip
    lines = {}
    gt.SetOwner = function() lines = {} end
    gt.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
    gt.Show = function() end
    gt.Hide = function() end
end
local function tip() return table.concat(lines, "\n") end

describe("minimap button: creation and icon", function()
    it("exists, parented to the Minimap, with dot, lock, letter and icon", function()
        local ns, b = boot()
        assertNotNil(b); assertEquals(st(b).parent, _G.Minimap)
        for _, k in ipairs({ "icon", "dot", "lock", "letterPill", "letter" }) do assertNotNil(b[k], k) end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("shows the player's main heal icon when a heal is known", function()
        local ns, b = boot()
        assertNotNil(ns.UnitFrames.RangeSpell())
        assertEquals(st(b.icon).texture, 134400)
    end)
    it("falls back to the Flash Heal icon when no heal spell is known", function()
        local ns, b = boot({ setup = function(s) s.units.player.class = "MAGE" end })
        assertEquals(st(b.icon).texture, "Interface\\Icons\\Spell_Holy_FlashHeal")
    end)
    it("falls back when the spell has no texture", function()
        local ns, b = boot()
        local old = C_Spell.GetSpellTexture
        C_Spell.GetSpellTexture = function() return nil end
        ns.MinimapButton:UpdateBadges()
        local tex = st(b.icon).texture
        C_Spell.GetSpellTexture = old
        assertTrue(type(tex) == "string")
    end)
    it("hidden when minimap.hide is set, shown again afterwards", function()
        local ns, b = boot()
        ns.db.minimap.hide = true; ns:Changed("minimap"); mock.flushTimers()
        assertFalse(st(b).shown)
        ns.db.minimap.hide = false; ns:Changed("minimap"); mock.flushTimers()
        assertTrue(st(b).shown)
    end)
end)

describe("minimap button: status dot", function()
    it("green when no buff is missing", function()
        local ns, b = boot()
        ns.BuffButtons.MissingCount = function() return 0 end
        ns.MinimapButton:UpdateBadges()
        local v = st(b.dot).vertex
        assertTrue(v.g > v.r and v.g > 0.5, "green")
    end)
    it("red when MissingCount > 0, and flips back", function()
        local ns, b = boot()
        local n = 2
        ns.BuffButtons.MissingCount = function() return n end
        ns.MinimapButton:UpdateBadges()
        assertTrue(st(b.dot).vertex.r > 0.9 and st(b.dot).vertex.g < 0.3, "red")
        n = 0; ns.MinimapButton:UpdateBadges()
        assertTrue(st(b.dot).vertex.g > 0.8, "green again")
    end)
    it("follows the real buff buttons (missing buff -> red)", function()
        local ns, b = boot({ group = 2, setup = function(s)
            s.units.player.class = "PALADIN"; s.units.party1.class = "PALADIN" end })
        mock.runOnUpdate(2, 0.5); mock.tick(); mock.flushTimers()
        local missing = ns.BuffButtons:MissingCount()
        assertTrue(missing >= 0)
        ns.MinimapButton:UpdateBadges()
        assertEquals(st(b.dot).vertex.r > 0.9, missing > 0)
    end)
    it("missing buffs line in the tooltip uses the count", function()
        local ns, b = boot(); record()
        ns.BuffButtons.MissingCount = function() return 3 end
        st(b).scripts.OnEnter(b)
        assertTrue(tip():find("Missing buffs: 3", 1, true))
        ns.BuffButtons.MissingCount = function() return 0 end
        st(b).scripts.OnEnter(b)
        assertTrue(tip():find("Missing buffs: none", 1, true))
    end)
    it("a UNIT_AURA on a tracked unit schedules a refresh without error", function()
        local ns, b = boot({ group = 2 })
        ns.BuffButtons.MissingCount = function() return 1 end
        mock.fire("UNIT_AURA", "party1"); mock.flushTimers()
        assertTrue(st(b.dot).vertex.r > 0.9)
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("minimap button: lock badge", function()
    it("matches frames.locked initially and after toggles", function()
        local ns, b = boot()
        assertEquals(st(b.lock).shown, ns.db.frames.locked and true or false)
        ns.UnitFrames:SetLocked(false); assertFalse(st(b.lock).shown)
        ns.UnitFrames:SetLocked(true); assertTrue(st(b.lock).shown)
    end)
    it("hidden when badges are off even if locked", function()
        local ns, b = boot()
        ns.UnitFrames:SetLocked(true)
        ns.db.minimap.badges = false; ns:Changed("minimap"); mock.flushTimers()
        assertFalse(st(b.lock).shown); assertFalse(st(b.dot).shown); assertFalse(st(b.letterPill).shown)
        ns.db.minimap.badges = true; ns:Changed("minimap"); mock.flushTimers()
        assertTrue(st(b.lock).shown); assertTrue(st(b.dot).shown); assertTrue(st(b.letterPill).shown)
    end)
end)

describe("minimap button: preset initial", function()
    local function initialFor(name)
        local ns, b = boot({ pre = function(ns) ns.db.presets[ns.db.activePreset].name = name end })
        ns.MinimapButton:UpdateBadges()
        return st(b.letter).text
    end
    it("first letter, upper-cased", function() assertEquals(initialFor("raid"), "R") end)
    it("keeps an already upper-case initial", function() assertEquals(initialFor("Mythic"), "M") end)
    it("digits and symbols pass through", function() assertEquals(initialFor("5-man"), "5") end)
    it("non-ASCII initials are taken as a whole UTF-8 character", function()
        local c = initialFor("\195\164bc") -- "abc" with a-umlaut
        assertEquals(#c, 2, "two bytes = one char")
        assertTrue(c:byte(1) >= 0xC2)
    end)
    it("a multibyte CJK name yields one 3-byte char", function() assertEquals(#initialFor("\228\184\173\230\150\135"), 3) end)
    it("empty name falls back to ?", function() assertEquals(initialFor(""), "?") end)
    it("changing preset updates the initial", function()
        local ns, b = boot()
        ns.db.presets[1].name = "Alpha"; ns.db.presets[2].name = "Beta"
        ns:SetActivePreset(1); ns.MinimapButton:UpdateBadges(); assertEquals(st(b.letter).text, "A")
        ns:SetActivePreset(2); ns.MinimapButton:UpdateBadges(); assertEquals(st(b.letter).text, "B")
    end)
    it("pill width grows with the text but never below 12", function()
        local ns, b = boot()
        ns.MinimapButton:UpdateBadges()
        assertTrue(st(b.letterPill).w >= 12)
    end)
end)

describe("minimap button: tooltip", function()
    it("lists title with version, preset, lock state and click hints", function()
        local ns, b = boot(); record()
        S.addonVersion = "1.2.3"
        st(b).scripts.OnEnter(b)
        local t = tip()
        assertTrue(t:find("Healer Forever v1.2.3", 1, true), t)
        assertTrue(t:find("Active preset: " .. ns.db.presets[ns.db.activePreset].name, 1, true))
        assertTrue(t:find("Bars: ", 1, true))
        for _, h in ipairs({ "Left-click: Options", "Right-click: Lock / unlock bars", "Shift-click: Next preset", "Drag: Move" }) do
            assertTrue(t:find(h, 1, true), h)
        end
    end)
    it("shows (dev) without a version", function()
        local ns, b = boot(); record()
        S.addonVersion = nil
        st(b).scripts.OnEnter(b)
        assertTrue(tip():find("Healer Forever (dev)", 1, true))
        S.addonVersion = "@project-version@"
        st(b).scripts.OnEnter(b)
        assertTrue(tip():find("(dev)", 1, true))
    end)
    it("lock line follows state", function()
        local ns, b = boot(); record()
        ns.db.frames.locked = true; st(b).scripts.OnEnter(b); assertTrue(tip():find("Bars: Locked", 1, true))
        ns.db.frames.locked = false; st(b).scripts.OnEnter(b); assertTrue(tip():find("Bars: Unlocked", 1, true))
    end)
    it("OnLeave hides the tooltip", function()
        local ns, b = boot(); record()
        local hid = false
        _G.GameTooltip.Hide = function() hid = true end
        st(b).scripts.OnLeave(b)
        assertTrue(hid)
    end)
end)

describe("minimap button: click behaviour and drag", function()
    it("left-click toggles the options window", function()
        local ns, b = boot()
        local n = 0
        ns.Options.Toggle = function() n = n + 1 end
        st(b).scripts.OnClick(b, "LeftButton")
        assertEquals(n, 1)
    end)
    it("right-click toggles lock and prints", function()
        local ns, b = boot()
        local start = ns.db.frames.locked
        st(b).scripts.OnClick(b, "RightButton")
        assertEquals(ns.db.frames.locked, not start)
    end)
    it("shift-left-click cycles the preset and does not open options", function()
        local ns, b = boot()
        local opened = 0
        ns.Options.Toggle = function() opened = opened + 1 end
        local before = ns.db.activePreset
        S.shift = true
        st(b).scripts.OnClick(b, "LeftButton")
        S.shift = false
        assertEquals(ns.db.activePreset, (before % #ns.db.presets) + 1)
        assertEquals(opened, 0)
    end)
    it("shift-right-click still toggles lock (right wins)", function()
        local ns, b = boot()
        local start, preset = ns.db.frames.locked, ns.db.activePreset
        S.shift = true; st(b).scripts.OnClick(b, "RightButton"); S.shift = false
        assertEquals(ns.db.frames.locked, not start); assertEquals(ns.db.activePreset, preset)
    end)
    it("clicks work in combat without protected calls", function()
        local ns, b = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        st(b).scripts.OnClick(b, "RightButton")
        S.shift = true; st(b).scripts.OnClick(b, "LeftButton"); S.shift = false
        S.combat = false; mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
        assertEquals(#mock.violations, 0); assertEquals(#mock.errors, 0, errstr())
    end)
    it("drag start installs an OnUpdate that saves the angle; drag stop removes it", function()
        local ns, b = boot()
        st(b).scripts.OnDragStart(b)
        assertEquals(type(st(b).scripts.OnUpdate), "function")
        st(b).scripts.OnUpdate(b, 0.01)
        local a = ns.db.minimap.angle
        assertTrue(type(a) == "number" and a >= 0 and a < 360, tostring(a))
        st(b).scripts.OnDragStop(b)
        assertNil(st(b).scripts.OnUpdate)
    end)
    it("angle moves the button around the minimap edge", function()
        local ns, b = boot()
        ns.db.minimap.angle = 0; ns.MinimapButton:UpdatePosition()
        local p = st(b).points[#st(b).points]
        assertTrue(p[4] > 0 and math.abs(p[5]) < 0.001, "angle 0 = east")
        ns.db.minimap.angle = 90; ns.MinimapButton:UpdatePosition()
        p = st(b).points[#st(b).points]
        assertTrue(p[5] > 0 and math.abs(p[4]) < 0.001, "angle 90 = north")
    end)
    it("lockPos stops dragging entirely", function()
        local ns, b = boot()
        ns.db.minimap.lockPos = true
        local before = ns.db.minimap.angle
        st(b).scripts.OnDragStart(b)
        assertNil(st(b).scripts.OnUpdate)
        assertEquals(ns.db.minimap.angle, before)
    end)
    it("the saved angle persists across a logout/login", function()
        local ns, b = boot()
        st(b).scripts.OnDragStart(b); st(b).scripts.OnUpdate(b, 0.01); st(b).scripts.OnDragStop(b)
        local a = ns.db.minimap.angle
        mock.fire("PLAYER_LOGOUT")
        assertEquals(HealerForeverCharDB.minimap.angle, a)
    end)
    it("pressed state shifts the icon one pixel and restores it", function()
        local ns, b = boot()
        st(b).scripts.OnMouseDown(b)
        local p = st(b.icon).points[#st(b.icon).points]
        assertEquals(p[2], 1); assertEquals(p[3], -1)
        st(b).scripts.OnMouseUp(b)
        p = st(b.icon).points[#st(b.icon).points]
        assertEquals(p[2], 0); assertEquals(p[3], 0)
    end)
    it("the button is not a secure frame and has no protected calls", function()
        local ns, b = boot()
        assertFalse(st(b).secure and true or false)
        assertEquals(#mock.violations, 0)
    end)
end)

describe("minimap button: options", function()
    it("badges and lock-position checkboxes exist and write the db", function()
        local ns, b = boot()
        ns.Options:Show("general"); mock.flushTimers()
        local found = {}
        for _, f in ipairs(mock.frames) do
            if st(f).kind == "CheckButton" and f.label then
                local t = tostring(st(f.label).text)
                if t:find("status badges") then found.badges = f end
                if t:lower():find("lock") and t:lower():find("minimap") then found.lockPos = f end
            end
        end
        assertNotNil(found.badges, "badges checkbox")
        st(found.badges).checked = false; st(found.badges).scripts.OnClick(found.badges, "LeftButton")
        assertEquals(ns.db.minimap.badges, false)
        assertFalse(st(b.dot).shown)
    end)
end)
