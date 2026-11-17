-- Full aura spacing matrix: buff position x debuff position x grow x timerPos x zoneGap (0/4/12) x icon size x layout.
-- Timer text must never overlap the bar, the other zone, neighbouring icons or the next tile.
-- Slow (about a minute), so it is not part of the mutation runs; test_aura_spacing has the reduced matrix.
local L = require("loader")
local mock = require("wow_mock")
local G = require("aura_geo")

local toc = L.parseToc()
if not toc then it("TOC present", function() error("no TOC") end) return end
local S
local function errstr() return table.concat(mock.errors, "\n---\n") end
local function unit(name, class, role) return { name = name, class = class, health = 500, maxHealth = 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" } end

mock.install(); S = mock.state
S.units.party1 = unit("Tank", "WARRIOR", "TANK"); S.units.party2 = unit("Heal", "PRIEST", "HEALER"); S.units.party3 = unit("Mage", "MAGE", "DAMAGER")
local ns = {}
for _, rel in ipairs(toc.files) do
    if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
end
mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
mock.fire("PLAYER_LOGIN"); mock.flushTimers()
mock.setGroup(4)
mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.runOnUpdate(2, 0.5); mock.flushTimers()
local UNITS = { "player", "party1", "party2", "party3" }
G.setAuras(S, UNITS, 8, 6)
ns.db.auras.maxBuffs, ns.db.auras.maxDebuffs = 8, 6
local function apply()
    ns:Changed("frames"); mock.flushTimers()
    for _, u in ipairs(UNITS) do mock.fire("UNIT_AURA", u) end
    mock.flushTimers(); mock.runOnUpdate(1, 0.2)
end

local POS = { "top", "bottom", "left", "right", "inside" }
local GROWS = { "right", "left", "down", "up" }
local checked, bad = 0, {}
for _, layout in ipairs({ "horizontal", "vertical" }) do
    ns.db.frames.layout = layout
    for _, bp in ipairs(POS) do for _, dp in ipairs(POS) do for _, grow in ipairs(GROWS) do
        for _, tp in ipairs({ "below", "inside" }) do for _, gap in ipairs({ 0, 4, 12 }) do for _, size in ipairs({ { 10, 12 }, { 28, 32 } }) do
            local a = ns.db.auras
            a.buffPosition, a.debuffPosition, a.grow, a.timerPos, a.zoneGap = bp, dp, grow, tp, gap
            a.buffSize, a.debuffSize, a.perRow = size[1], size[2], 4
            apply()
            checked = checked + 1
            for _, p in ipairs(G.check(ns, UNITS, string.format("%s %s/%s/%s/%s/gap%d/%d", layout, bp, dp, grow, tp, gap, size[1]))) do
                bad[#bad + 1] = p
            end
        end end end
    end end end
end

describe("zone matrix: timers never overlap anything", function()
    it("ran every combination without a Lua error", function()
        assertEquals(checked, 2 * 5 * 5 * 4 * 2 * 3 * 2)
        assertEquals(#mock.errors, 0, errstr())
    end)
    it("no overlaps between timers, icons, zones, bars and tiles", function()
        local show = {}
        for i = 1, math.min(#bad, 8) do show[#show + 1] = bad[i] end
        assertEquals(#bad, 0, #bad .. " problems (of " .. checked .. " layouts), first:\n" .. table.concat(show, "\n"))
    end)
end)
