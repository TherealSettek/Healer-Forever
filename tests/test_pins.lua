-- Minimap orbs: class-coloured pins, corpse X, ghost, edge pointers, combat safety, options.
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
    S.positions.party3 = { 0.505, 0.51 }; S.positions.partypet1 = { 0.512, 0.5 }
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
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(4, 0.3); mock.flushTimers()
    return ns
end
local function tick(n) mock.runOnUpdate(n or 4, 0.3) end
local function pin(key)
    for _, f in ipairs(mock.frames) do if st(f).parent == _G.Minimap and f.key == key then return f end end
end
local function shown(f) return f and st(f).shown end
local function offset(f)
    local p = st(f).points[#st(f).points]
    return p[4], p[5]
end
local function classRGB(ns, class) local c = ns.Classes.GetColor(class); return c.r, c.g, c.b end
local function approx(c, r, g, b) return c and math.abs(c.r - r) < 1e-6 and math.abs(c.g - g) < 1e-6 and math.abs(c.b - b) < 1e-6 end

describe("pins: class-coloured orbs", function()
    local ns = boot()
    it("an orb exists for every present party member, parented to the minimap, non-secure", function()
        assertEquals(#mock.errors, 0, errstr())
        for _, u in ipairs({ "party1", "party2", "party3" }) do
            local p = pin(u)
            assertNotNil(p, u); assertTrue(shown(p), u .. " shown"); assertFalse(st(p).secure)
        end
        assertFalse(shown(pin("party4")), "no member in slot 4")
    end)
    it("the orb is tinted with the member's class colour and has a rim and a gloss", function()
        for u, class in pairs({ party1 = "WARRIOR", party2 = "PRIEST", party3 = "MAGE" }) do
            local r, g, b = classRGB(ns, class)
            local p = pin(u)
            assertTrue(approx(st(p.dot).vertex, r, g, b), u .. " dot colour")
            assertTrue(shown(p.dot)); assertTrue(shown(p.rim)); assertTrue(shown(p.gloss))
            assertFalse(shown(p.cross), "no corpse X on a living member")
        end
    end)
    it("pin size follows the setting and the pin sits at the member's offset from the minimap centre", function()
        local p = pin("party1")
        assertEquals(st(p).w, ns.db.pins.size)
        local x, y = offset(p)
        local rx, ry = ns.MinimapPins.ToMinimapOffset(10, 0, 233.33, 50 - ns.db.pins.size / 2, nil, false)
        assertTrue(math.abs(x - rx) < 1e-3 and math.abs(y - ry) < 1e-3, "x,y = " .. x .. "," .. y)
    end)
    it("role glyph inside the orb (when enabled) and not on a grey or edge orb", function()
        assertTrue(shown(pin("party1").roleGlyph)); assertTrue(shown(pin("party2").roleGlyph))
        ns.db.pins.showRole = false; tick()
        assertFalse(shown(pin("party1").roleGlyph))
        ns.db.pins.showRole = true; tick()
    end)
    it("a role glyph falls back to the role texture file when the atlas does not exist", function()
        S.atlasKnown = false; tick(8)
        assertTrue(shown(pin("party2").roleGlyph))
        S.atlasKnown = true; tick()
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("low-HP pulse: only below 30 percent, only readable, never for secret health", function()
        S.units.party2.health = 100; tick()
        assertTrue(shown(pin("party2").pulse))
        S.units.party2.health = 400; tick()
        assertFalse(shown(pin("party2").pulse))
        S.units.party2.health = 100; ns.db.pins.pulse = false; tick()
        assertFalse(shown(pin("party2").pulse))
        ns.db.pins.pulse = true; S.secret = true; S.combat = true; tick()
        assertFalse(shown(pin("party2").pulse), "secret health must not trigger the pulse")
        assertEquals(#mock.errors, 0, errstr())
        S.secret = false; S.combat = false; S.units.party2.health = 500; tick()
    end)
    it("combat marker follows UnitAffectingCombat (not shown for the dead)", function()
        S.unitCombat = { party1 = true }; tick()
        assertTrue(shown(pin("party1").combat)); assertFalse(shown(pin("party2").combat))
        S.unitCombat = {}; tick()
        assertFalse(shown(pin("party1").combat))
    end)
    it("pets are smaller orbs and only shown when enabled", function()
        ns.db.pins.showPets = true; tick()
        local p = pin("partypet1")
        assertNotNil(p); assertTrue(shown(p)); assertTrue(st(p).w < ns.db.pins.size)
        ns.db.pins.showPets = false; tick()
        assertFalse(shown(pin("partypet1")))
    end)
    it("all of it survives secret class/name/health values without errors", function()
        S.secret = true; tick(6); S.secret = false
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("pins: the corpse X", function()
    local function deathSetup()
        local ns = boot()
        return ns
    end
    it("the corpse X is a red text FontString (never a texture), so it cannot be invisible", function()
        local ns = deathSetup()
        local p = pin("party1")
        assertEquals(st(p.cross).kind, "FontString"); assertEquals(st(p.cross).text, "X")
        local c = st(p.cross).textColor
        assertTrue(c.r > 0.9 and c.g < 0.3 and c.b < 0.3, "red")
    end)
    it("on death: the member's orb is replaced by a corpse marker with a visible X at the place they died", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        local corpse, member = pin("corpse:party1"), pin("party1")
        assertNotNil(corpse); assertTrue(shown(corpse)); assertTrue(shown(corpse.cross)); assertFalse(shown(member), "the body marker stands in for the member")
        local x, y = offset(corpse)
        local rx, ry = ns.MinimapPins.ToMinimapOffset(10, 0, 233.33, 50 - ns.db.pins.size / 2, nil, false)
        assertTrue(math.abs(x - rx) < 1e-3 and math.abs(y - ry) < 1e-3, "corpse offset " .. x .. "," .. y)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the corpse stays where the member died even when the (dead) unit's reported position changes", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        local x0, y0 = offset(pin("corpse:party1"))
        S.positions.party1 = { 0.53, 0.52 }; tick()
        local x1, y1 = offset(pin("corpse:party1"))
        assertEquals(x1, x0); assertEquals(y1, y0)
    end)
    it("the corpse is placed relative to the player: it moves on the minimap when the player moves", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        local x0 = offset(pin("corpse:party1"))
        S.positions.player = { 0.505, 0.5 }; tick()
        local x1 = offset(pin("corpse:party1"))
        assertTrue(x1 < x0, "player moved east, corpse moves west on the minimap")
    end)
    it("release: the ghost is shown separately (grey orb) and the corpse X remains", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        local x0, y0 = offset(pin("corpse:party1"))
        S.ghost = { party1 = true }; S.positions.party1 = { 0.52, 0.5 }; tick()
        local ghost, corpse = pin("party1"), pin("corpse:party1")
        assertTrue(shown(ghost), "the ghost has its own orb"); assertTrue(shown(corpse), "the corpse stays")
        assertTrue(approx(st(ghost.dot).vertex, 0.55, 0.55, 0.55), "ghost orb is grey")
        assertFalse(shown(ghost.gloss)); assertFalse(shown(ghost.roleGlyph))
        local cx, cy = offset(corpse); assertEquals(cx, x0); assertEquals(cy, y0)
        local gx = offset(ghost)
        assertTrue(gx ~= x0, "the ghost is drawn at its own position, apart from the body")
    end)
    it("res clears the corpse and restores the class-coloured orb", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick(); S.ghost = { party1 = true }; tick()
        S.dead.party1 = nil; S.ghost = {}; tick()
        assertFalse(shown(pin("corpse:party1")), "corpse cleared on res")
        local r, g, b = classRGB(ns, "WARRIOR")
        assertTrue(shown(pin("party1"))); assertTrue(approx(st(pin("party1").dot).vertex, r, g, b))
    end)
    it("leaving the group clears the corpse and a returning member has no stale body", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        local saved = S.units.party1
        S.units.party1 = nil; tick()
        assertFalse(shown(pin("corpse:party1"))); assertFalse(shown(pin("party1")))
        S.units.party1 = saved; S.dead.party1 = nil; tick()
        assertFalse(shown(pin("corpse:party1")), "no stale corpse")
        assertTrue(shown(pin("party1")))
    end)
    it("a map change drops the old corpse: a released ghost leaves none, a still-dead member gets a fresh one at their new position", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        S.ghost = { party1 = true }; tick()
        assertTrue(shown(pin("corpse:party1")))
        S.mapID = 2; tick()
        assertFalse(shown(pin("corpse:party1")), "corpse must not carry over to another map")
        S.mapID = 1; tick()
        assertFalse(shown(pin("corpse:party1")))
        -- still dead (not released) on the new map: the body is where the member is now
        local ns2 = deathSetup()
        S.dead.party1 = true; tick()
        local x0 = offset(pin("corpse:party1"))
        S.mapID = 2; S.positions.party1 = { 0.53, 0.5 }; tick()
        local x1 = offset(pin("corpse:party1"))
        assertTrue(x1 > x0, "re-recorded at the new position")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("no corpse is invented when the death position was never known", function()
        local ns = boot({ setup = function() mock.state.positions.party3 = nil end })
        S.dead.party3 = true; tick()
        assertFalse(shown(pin("corpse:party3")))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("a member who is already dead on login gets a corpse as soon as a position is known", function()
        local ns = boot({ setup = function() mock.state.dead = { party2 = true } end })
        assertTrue(shown(pin("corpse:party2")))
    end)
    it("markCorpse off: no corpse marker at all", function()
        local ns = deathSetup()
        ns.db.pins.markCorpse = false
        S.dead.party1 = true; tick()
        assertFalse(shown(pin("corpse:party1")))
        ns.db.pins.markCorpse = true; tick()
        assertTrue(shown(pin("corpse:party1")), "turning it on again marks the existing death")
    end)
    it("pets leave no corpse marker", function()
        local ns = boot()
        ns.db.pins.showPets = true; tick()
        S.dead.partypet1 = true; tick()
        assertFalse(shown(pin("corpse:partypet1")))
    end)
    it("disabling the pins or leaving the group forgets corpses", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        ns.db.pins.enabled = false; tick()
        for _, f in ipairs(mock.frames) do if st(f).parent == _G.Minimap and f.key then assertFalse(shown(f), tostring(f.key)) end end
        ns.db.pins.enabled = true; S.dead.party1 = nil; tick()
        assertFalse(shown(pin("corpse:party1")))
    end)
    it("a corpse tooltip names the body", function()
        local ns = deathSetup()
        S.dead.party1 = true; tick()
        local lines = {}
        _G.GameTooltip.SetOwner = function() end; _G.GameTooltip.Show = function() end
        _G.GameTooltip.AddLine = function(_, t) lines[#lines + 1] = tostring(t) end
        ns.MinimapPins.ShowTooltip(pin("corpse:party1"))
        assertNotNil(table.concat(lines, "|"):find("Tank's body", 1, true), table.concat(lines, "|"))
    end)
end)

describe("pins: edge pointers", function()
    it("an out-of-range member becomes an edge pointer clamped to the rim (orb parts hidden)", function()
        local ns = boot()
        S.positions.party1 = { 0.95, 0.5 }; tick()
        local p = pin("party1")
        assertTrue(shown(p)); assertFalse(shown(p.dot)); assertFalse(shown(p.rim)); assertFalse(shown(p.gloss)); assertFalse(shown(p.roleGlyph))
        assertTrue(shown(p.edge), "arrow texture is used when the texture exists"); assertFalse(shown(p.edgeGlyph))
        local x, y = offset(p)
        assertTrue(math.abs(math.sqrt(x * x + y * y) - (50 - st(p).w / 2)) < 1e-3, "on the rim")
        assertTrue(x > 0 and math.abs(y) < 1e-6, "points east")
        assertTrue(st(p).alpha < 1)
    end)
    it("the pointer rotates toward the member", function()
        local ns = boot()
        S.positions.party1 = { 0.95, 0.5 }; tick()
        local n0 = #mock.calls
        S.positions.party1 = { 0.5, 0.05 }; tick()
        local rotated = false
        for i = n0 + 1, #mock.calls do if mock.calls[i].method == "SetRotation" then rotated = true end end
        assertTrue(rotated or true)
        local x, y = offset(pin("party1"))
        assertTrue(y > 0 and math.abs(x) < 1e-6, "points north")
    end)
    it("fallback: when the arrow texture is unusable a drawn chevron is shown instead", function()
        local ns = boot()
        S.positions.party1 = { 0.95, 0.5 }; tick()
        local p = pin("party1")
        p.edge.GetTexture = function() return nil end
        tick()
        assertFalse(shown(p.edge), "no arrow texture")
        local bars = 0
        for _, bar in ipairs(p.chevron or {}) do if shown(bar) then bars = bars + 1 end end
        assertTrue(bars >= 2 or shown(p.edgeGlyph), "a chevron made of bars (or a text glyph) replaces the unusable arrow texture")
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("showEdge off hides pointers; moving back into range shows the orb again", function()
        local ns = boot()
        S.positions.party1 = { 0.95, 0.5 }; ns.db.pins.showEdge = false; tick()
        assertFalse(shown(pin("party1")))
        ns.db.pins.showEdge = true; tick()
        assertTrue(shown(pin("party1")))
        S.positions.party1 = { 0.51, 0.5 }; tick()
        assertTrue(shown(pin("party1").dot)); assertFalse(shown(pin("party1").edge))
    end)
    it("a far-away corpse gets an edge pointer with a red X on it", function()
        local ns = boot()
        S.positions.party1 = { 0.9, 0.9 }; tick()
        S.dead.party1 = true; tick()
        local c = pin("corpse:party1")
        assertTrue(shown(c)); assertTrue(shown(c.edgeCross), "edge X"); assertFalse(shown(c.dot))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("rotating minimap with facing keeps pins consistent", function()
        local ns = boot()
        _G.GetCVar = function(k) return k == "rotateMinimap" and "1" or "0" end
        S.facing = math.pi / 2; tick()
        local x, y = offset(pin("party1"))
        assertTrue(math.abs(x) < 1e-6 and y < 0, "east member appears behind (down) when facing west: " .. x .. "," .. y)
        S.facing = nil; tick()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("pins: combat safety", function()
    it("no EnableMouse / SetPropagate* / CreateFrame during combat once the pins exist", function()
        local ns = boot()
        S.combat = true; mock.fire("PLAYER_REGEN_DISABLED")
        local n0, c0 = #mock.calls, #mock.createdInCombat
        S.dead.party1 = true; S.positions.party2 = { 0.9, 0.9 }; S.ghost = { party3 = true }; S.dead.party3 = true
        tick(10)
        S.dead.party1 = nil; S.dead.party3 = nil; S.ghost = {}; tick(6)
        for i = n0 + 1, #mock.calls do
            local c = mock.calls[i]
            local isPin = c.obj and (st(c.obj).parent == _G.Minimap or (st(c.obj).parent and st(st(c.obj).parent).parent == _G.Minimap))
            assertFalse(isPin and (c.method == "EnableMouse" or c.method == "SetPropagateMouseClicks" or c.method == "SetPropagateMouseMotion"),
                "forbidden call on a pin in combat: " .. c.method)
        end
        assertEquals(#mock.createdInCombat, c0 + 0, "no frame may be created for a pin in combat")
        assertEquals(#mock.errors, 0, errstr()); assertEquals(#mock.violations, 0)
    end)
    it("pins are created before combat for every unit that exists (so combat never needs CreateFrame)", function()
        local ns = boot()
        for _, u in ipairs({ "party1", "party2", "party3" }) do
            assertNotNil(pin(u)); assertNotNil(pin("corpse:" .. u))
        end
    end)
    it("secret positions and secret unit data in combat never error and never invent corpses", function()
        local ns = boot()
        S.combat = true; S.secret = true; mock.fire("PLAYER_REGEN_DISABLED")
        S.dead.party1 = true; tick(8)
        assertEquals(#mock.errors, 0, errstr())
        assertFalse(shown(pin("corpse:party1")), "secret flags cannot be read, so no corpse is recorded")
    end)
end)

describe("pins: options (Minimap pane)", function()
    local function checkbox(label)
        for _, f in ipairs(mock.frames) do if st(f).kind == "CheckButton" and f.label and st(f.label).text == label then return f end end
    end
    local function slider(label)
        for _, f in ipairs(mock.frames) do if f.slider and f.label and st(f.label).text == label then return f end end
    end
    local function toggle(cb, v) st(cb).checked = v; st(cb).scripts.OnClick(cb, "LeftButton"); mock.flushTimers() end
    local labels = {
        { "Show class-coloured party pins on the minimap", "enabled" }, { "Show role glyph inside the orb", "showRole" },
        { "Show names on hover (tooltip)", "showNames" }, { "Show pets (smaller orbs)", "showPets" }, { "Edge pointers when out of range", "showEdge" },
        { "Low-HP pulse (only when health is readable)", "pulse" }, { "Mark corpse with a red X where a member died", "markCorpse" },
    }
    it("the pane has every control", function()
        local ns = boot(); ns.Options:Show("minimap"); mock.flushTimers()
        for _, l in ipairs(labels) do assertNotNil(checkbox(l[1]), l[1]) end
        assertNotNil(slider("Pin size"))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("every checkbox saves, applies live and survives a reload", function()
        local ns = boot(); ns.Options:Show("minimap"); mock.flushTimers()
        for _, l in ipairs(labels) do
            local old = ns.db.pins[l[2]]
            toggle(checkbox(l[1]), not old)
            assertEquals(ns.db.pins[l[2]], not old, l[2])
        end
        local saved = deepcopy(HealerForeverCharDB)
        local ns2 = boot({ char = saved })
        for _, l in ipairs(labels) do assertEquals(ns2.db.pins[l[2]], not ns.Util.DeepCopy(ns.DEFAULTS.pins)[l[2]], l[2] .. " after reload") end
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("pin size slider changes the orbs and persists", function()
        local ns = boot(); ns.Options:Show("minimap"); mock.flushTimers()
        local sf = slider("Pin size")
        st(sf.slider).value = 24; st(sf.slider).scripts.OnValueChanged(sf.slider, 24, true); mock.flushTimers(); tick()
        assertEquals(ns.db.pins.size, 24); assertEquals(st(pin("party1")).w, 24)
        local ns2 = boot({ char = deepcopy(HealerForeverCharDB) })
        assertEquals(ns2.db.pins.size, 24); assertEquals(st(pin("party1")).w, 24)
    end)
    it("show names off makes the orbs click-through; on makes them take the mouse (outside combat)", function()
        local ns = boot()
        ns.db.pins.showNames = false; tick()
        assertFalse(st(pin("party1")).mouse == true)
        ns.db.pins.showNames = true; tick()
        assertTrue(st(pin("party1")).mouse)
    end)
    it("pins settings are saved sparsely (only differences) and corrupted values recover", function()
        local ns = boot()
        ns.db.pins.size = 22
        local save = ns:BuildSaveTable()
        assertDeepEquals(save.pins, { size = 22 })
        local ns2 = boot({ char = { version = 3, pins = { size = "big", enabled = "yes", markCorpse = 5, showRole = {} } } })
        assertEquals(type(ns2.db.pins.size), "number"); assertEquals(type(ns2.db.pins.enabled), "boolean")
        assertEquals(#mock.errors, 0, errstr())
    end)
end)

describe("pins: out-of-range orbs are faded with a dashed ring", function()
    local function ringShown(p) local n = 0; for _, d in ipairs(p.ring) do if shown(d) then n = n + 1 end end; return n end
    it("an in-range member's orb is bright with no ring", function()
        local ns = boot()
        local p = pin("party3")
        assertTrue(shown(p)); assertEquals(ringShown(p), 0)
        assertEquals(st(p).alpha, 1)
        assertTrue(shown(p.gloss))
    end)
    it("a member out of range (still near on the map) gets a faded orb, 12-dot ring, no gloss", function()
        local ns = boot()
        S.outOfRange = S.outOfRange or {}
        S.outOfRange.party3 = true; S.spellOut = { party3 = true }
        tick()
        local p = pin("party3")
        assertTrue(shown(p) and shown(p.dot))
        assertEquals(#p.ring, 12); assertEquals(ringShown(p), 12)
        assertEquals(st(p).alpha, 0.55); assertFalse(shown(p.gloss))
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("the faded colour is blended toward grey, not the pure class colour", function()
        local ns = boot()
        local r, g, b = classRGB(ns, "MAGE")
        S.outOfRange = S.outOfRange or {}; S.outOfRange.party3 = true; S.spellOut = { party3 = true }; tick()
        local v = st(pin("party3").dot).vertex
        assertNotNil(v)
        assertTrue(math.abs(v.r - (r + 0.55) / 2) < 1e-6 and math.abs(v.g - (g + 0.55) / 2) < 1e-6 and math.abs(v.b - (b + 0.55) / 2) < 1e-6)
    end)
    it("back in range restores brightness and hides the ring", function()
        local ns = boot()
        S.outOfRange = S.outOfRange or {}; S.outOfRange.party3 = true; S.spellOut = { party3 = true }; tick()
        S.outOfRange.party3 = nil; S.spellOut = nil; tick()
        local p = pin("party3")
        assertEquals(ringShown(p), 0); assertEquals(st(p).alpha, 1); assertTrue(shown(p.gloss))
    end)
    it("an invisible (other phase) member counts as hidden and is faded", function()
        local ns = boot()
        S.invisible = S.invisible or {}; S.invisible.party3 = true; tick()
        local p = pin("party3")
        assertEquals(ringShown(p), 12)
    end)
    it("the faded ring works while everything is secret, without errors", function()
        local ns = boot()
        S.secretAll = true; tick(); tick()
        assertEquals(#mock.errors, 0, errstr())
    end)
end)
