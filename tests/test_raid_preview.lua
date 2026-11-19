-- "Preview full raid" (Frames/RaidPreview.lua, Phase 4): runtime only (off by default and after reload), refused in combat
-- and in a real raid (exact messages), auto-off on combat / joining a raid with one chat line, only plain non-secure frames
-- (no attributes, unit tokens or protected calls), 10 / 20 / 25 / 40 players, live redraw on raid settings, debuffs only of
-- types the player's class can dispel, buffs from the player's catalog, made-up names only, the gold tag (locked /
-- unlocked), dragging saves raid.point and moves the real raid anchor (after combat), the fake tooltip, /hf raid preview.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local st, errstr = H.st, H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
end

local function boot(opts)
    opts = opts or {}
    local ns = H.boot({ group = opts.group or 4, raid = opts.raid, setup = opts.setup, afterLoad = opts.afterLoad })
    return ns, ns.RaidPreview
end
local function shownFrames(RP)
    local n = 0
    for _, f in ipairs(RP.frames) do if st(f).shown then n = n + 1 end end
    return n
end
local function printedLines(pattern)
    local out = {}
    for _, p in ipairs(mock.printed) do if p:find(pattern, 1, true) then out[#out + 1] = p end end
    return out
end

describe("raid preview: on / off", function()
    it("off by default, nothing built until first use", function()
        local _, RP = boot()
        assertFalse(RP:IsOn())
        assertNil(RP.anchor)
        clean()
    end)
    it("turns on with 40 fake players by default; 10 / 20 / 25 / 40 show that many frames", function()
        local _, RP = boot()
        local ok = RP:SetOn(true)
        assertTrue(ok)
        assertTrue(st(RP.anchor).shown)
        assertEquals(shownFrames(RP), 40)
        for _, n in ipairs({ 10, 20, 25, 40 }) do
            assertTrue(RP:SetSize(n))
            assertEquals(shownFrames(RP), n, "size " .. n)
        end
        assertFalse(RP:SetSize(15), "invalid size refused")
        assertEquals(RP.size, 40)
        RP:SetOn(false)
        assertFalse(st(RP.anchor).shown)
        assertTrue(RP:SetSize(20), "size can change while off")
        RP:SetOn(true)
        assertEquals(shownFrames(RP), 20)
        RP:SetOn(true, 10)
        assertEquals(shownFrames(RP), 10)
        clean()
    end)
    it("never saved: off after a reload, nothing about the preview in the save", function()
        local ns, RP = boot()
        RP:SetOn(true, 25)
        ns.db.raid.width = 70          -- a real raid setting changed at the same time is saved
        mock.fire("PLAYER_LOGOUT")
        local saved = H.deepcopy(_G.HealerForeverCharDB)
        assertDeepEquals(saved.raid, { width = 70 })
        local ns2 = H.boot({ group = 4, char = saved })
        assertFalse(ns2.RaidPreview:IsOn())
        assertNil(ns2.RaidPreview.anchor)
        assertEquals(ns2.db.raid.width, 70)
        clean()
    end)
    it("refused in combat and in a real raid, with the exact messages", function()
        local _, RP = boot()
        H.enterCombat()
        local ok, msg = RP:SetOn(true)
        assertFalse(ok); assertEquals(msg, "Can't preview in combat."); assertEquals(RP.message, msg)
        assertNil(RP.anchor, "nothing created in combat")
        H.leaveCombat()
        local _, RP2 = boot({ raid = 10 })
        ok, msg = RP2:SetOn(true)
        assertFalse(ok)
        assertEquals(msg, "Can't preview while you are in a real raid: your real raid frames are already showing.")
        assertFalse(RP2:IsOn())
        clean()
    end)
    it("auto-off when combat starts: one chat line, message kept for the options pane", function()
        local _, RP = boot()
        RP:SetOn(true)
        mock.printed = {}
        H.enterCombat()
        assertFalse(RP:IsOn())
        assertFalse(st(RP.anchor).shown)
        assertEquals(#printedLines("Preview turned off"), 1)
        assertEquals(RP.message, "Preview turned off: combat started.")
        mock.fire("PLAYER_REGEN_DISABLED")
        assertEquals(#printedLines("Preview turned off"), 1, "only once")
        H.leaveCombat()
        clean()
    end)
    it("auto-off when you join a raid (only then: a party roster change keeps it on)", function()
        local _, RP = boot()
        RP:SetOn(true)
        mock.printed = {}
        H.roster(nil)                 -- party roster update
        assertTrue(RP:IsOn(), "a party roster change does not turn it off")
        mock.setGroup(2); H.roster(nil)
        assertTrue(RP:IsOn())
        H.roster(12)
        assertFalse(RP:IsOn())
        assertEquals(RP.message, "Preview turned off: you joined a real raid. Your real raid frames show now.")
        assertEquals(#printedLines("Preview turned off"), 1)
        clean()
    end)
end)

describe("raid preview: plain frames only", function()
    it("no secure frames, no attributes, no unit tokens, no protected calls, no unit API reads", function()
        local _, RP = boot()
        local n0 = #mock.frames
        local unitCalls = 0
        for _, api in ipairs({ "UnitHealth", "UnitHealthMax", "UnitName", "UnitClass", "UnitIsConnected", "UnitInRange" }) do
            local real = _G[api]
            mock.setGlobal(api, function(u, ...) if u ~= "player" then unitCalls = unitCalls + 1 end; return real(u, ...) end)
        end
        RP:SetOn(true, 40)
        for i = n0 + 1, #mock.frames do
            local f = mock.frames[i]
            local s = st(f)
            assertFalse(s.secure and true or false, tostring(s.name or s.kind) .. " is secure")
            assertNil(next(s.attrs), tostring(s.name or s.kind) .. " has attributes")
            assertNil(rawget(f, "unit"))
        end
        assertEquals(#mock.callsTo("SetAttribute", function(c) for i = n0 + 1, #mock.frames do if mock.frames[i] == c.obj then return true end end end), 0)
        assertEquals(unitCalls, 0, "the preview read unit APIs of other units (only the player's own class is used)")
        for _, f in ipairs(RP.frames) do assertNil(st(f).scripts.OnClick, "clickable") end
        clean()
    end)
end)

describe("raid preview: content", function()
    it("names only from RP.NAMES (made up), member 1 is you", function()
        local _, RP = boot()
        RP:SetOn(true, 40)
        local allowed = {}
        for _, n in ipairs(RP.NAMES) do allowed[n] = true end
        for i = 1, 40 do assertTrue(allowed[st(RP.frames[i].name).text], "name " .. tostring(st(RP.frames[i].name).text)) end
        assertEquals(RP.data[1].name, "You"); assertTrue(RP.data[1].me)
        assertNil(st(RP.frames[2].name).text:find("Tankard", 1, true), "never a real party member's name")
    end)
    it("debuffs only of types the player's class can dispel; none for a Warrior", function()
        local ns, RP = boot()
        RP:SetOn(true, 40)
        local can = {}
        for _, t in ipairs(ns.Classes.DATA.PALADIN.dispels or {}) do can[t] = true end
        local any = 0
        for i = 1, 40 do
            for _, t in ipairs(RP.data[i].debuffs) do any = any + 1; assertTrue(can[t], "Paladin can't dispel " .. t) end
            assertTrue(#RP.data[i].debuffs <= ns.db.raid.debuffs.max)
        end
        assertTrue(any > 0)
        local _, RPw = boot({ setup = function(S) S.units.player.class = "WARRIOR" end })
        RPw:SetOn(true, 40)
        for i = 1, 40 do assertEquals(#RPw.data[i].debuffs, 0) end
        for i = 1, 40 do assertEquals(#RPw.data[i].buffs, 0, "a Warrior has no buff catalog") end
        clean()
    end)
    it("my buffs come from the player's catalog (Paladin blessings), missing / ending markers present", function()
        local ns, RP = boot()
        RP:SetOn(true, 10)
        local catalog = {}
        for _, k in ipairs(ns.Classes.CatalogBuffs("PALADIN")) do catalog[k] = true end
        local kinds = {}
        for i = 1, 10 do
            for _, m in ipairs(RP.data[i].buffs) do assertTrue(catalog[m.key], m.key); kinds[m.kind] = true end
        end
        assertTrue(kinds.miss and kinds["end"], "both marker kinds appear in a 10-player preview")
    end)
    it("live redraw on a raid setting change (size, healthText) and the real anchor is untouched", function()
        local ns, RP = boot()
        RP:SetOn(true, 10)
        ns.db.raid.width = 90; ns.db.raid.healthText = "percent"
        ns:Changed("raid"); mock.flushTimers()
        assertEquals(st(RP.frames[1]).w, 90)
        local hurt = RP.frames[2]
        assertTrue(tostring(st(hurt.centerText).text):find("%%") ~= nil, tostring(st(hurt.centerText).text))
        assertFalse(st(ns.RaidFrames.anchor).shown, "the real raid frames stay hidden outside a raid")
        clean()
    end)
    it("fake tooltip: name, class / role / group, state, ends with the preview note", function()
        local _, RP = boot()
        RP:SetOn(true, 10)
        local lines = {}
        local tip = _G.GameTooltip
        tip.AddLine = function(_, t) lines[#lines + 1] = t end
        local f = RP.frames[4]   -- dead rogue
        st(f).scripts.OnEnter(f)
        local text = table.concat(lines, "\n")
        assertTrue(text:find(RP.NAMES[4], 1, true) ~= nil, text)
        assertTrue(text:find("Group 1", 1, true) ~= nil, text)
        assertTrue(text:find("DEAD", 1, true) ~= nil, text)
        assertEquals(lines[#lines], "Preview: fake player, clicks do nothing")
        st(f).scripts.OnLeave(f)
        assertNil(RP.hovered)
        clean()
    end)
end)

describe("raid preview: tag and drag", function()
    it("tag text: locked = no drag hint, unlocked = 'drag to move'", function()
        local ns, RP = boot()
        ns.db.frames.locked = true
        RP:SetOn(true, 10)
        assertEquals(st(RP.tag.text).text, RP.TAG_TEXT)
        ns.db.frames.locked = false
        ns:Fire("LOCK_CHANGED")
        assertTrue(st(RP.tag.text).text:find("drag to move", 1, true) ~= nil)
        assertTrue(st(RP.tag).w >= st(RP.anchor).w, "the tag is at least as wide as the preview")
    end)
    it("dragging the tag (unlocked) saves raid.point and moves the real raid anchor; locked frames don't move", function()
        local ns, RP = boot()
        ns.db.frames.locked = false
        RP:SetOn(true, 10)
        local tag = RP.tag
        st(tag).scripts.OnDragStart(tag)
        assertTrue(RP.dragging)
        RP.anchor:ClearAllPoints(); RP.anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 222, -111)
        st(tag).scripts.OnDragStop(tag)
        assertDeepEquals(ns.db.raid.point, { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 222, y = -111 })
        local p = st(ns.RaidFrames.anchor).points[#st(ns.RaidFrames.anchor).points]
        assertEquals(p[4], 222); assertEquals(p[5], -111)
        ns.db.frames.locked = true
        st(tag).scripts.OnDragStart(tag)
        assertNil(RP.dragging, "locked: no drag")
        clean()
    end)
    it("a drag ending in combat saves the point but moves the real (protected) anchor only after combat", function()
        local ns, RP = boot()
        ns.db.frames.locked = false
        RP:SetOn(true, 10)
        local tag = RP.tag
        st(tag).scripts.OnDragStart(tag)
        mock.state.combat = true      -- combat starts mid-drag (before PLAYER_REGEN_DISABLED reaches us)
        RP.anchor:ClearAllPoints(); RP.anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 50, -60)
        st(tag).scripts.OnDragStop(tag)
        assertEquals(ns.db.raid.point.x, 50)
        local pts = st(ns.RaidFrames.anchor).points
        assertTrue(#pts == 0 or pts[#pts][4] ~= 50, "real anchor moved in combat")
        H.leaveCombat()
        pts = st(ns.RaidFrames.anchor).points
        assertEquals(pts[#pts][4], 50)
        clean()
    end)
end)

describe("raid preview: /hf raid preview", function()
    it("toggle, sizes, on / off, bad argument, refusal message in chat", function()
        local _, RP = boot()
        local ok, err, out = H.slash("raid preview")
        assertTrue(ok, err); assertTrue(RP:IsOn()); assertTrue(out:find("Raid preview ON (40 fake players)", 1, true) ~= nil, out)
        ok, err, out = H.slash("raid preview")
        assertFalse(RP:IsOn()); assertTrue(out:find("Raid preview off.", 1, true) ~= nil, out)
        H.slash("raid preview 20")
        assertTrue(RP:IsOn()); assertEquals(RP.size, 20); assertEquals(shownFrames(RP), 20)
        H.slash("raid preview 25")
        assertEquals(shownFrames(RP), 25, "a size while on switches size, stays on")
        H.slash("raid preview off")
        assertFalse(RP:IsOn())
        H.slash("raid preview on")
        assertTrue(RP:IsOn()); assertEquals(RP.size, 25)
        ok, err, out = H.slash("raid preview 33")
        assertTrue(ok, err); assertTrue(out:find("/hf raid preview [10|20|25|40|off]", 1, true) ~= nil, out)
        H.slash("raid preview off")
        H.enterCombat()
        ok, err, out = H.slash("raid preview")
        assertTrue(out:find("Can't preview in combat.", 1, true) ~= nil, out)
        H.leaveCombat()
        clean()
    end)
end)
