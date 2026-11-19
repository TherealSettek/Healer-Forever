-- Party golden snapshot (raid layout Phase 0): the party frames must stay exactly as Healer Forever 0.10.1 drew them while the
-- raid layout is added. tests/party_snapshot.lua captures every party / pet button (attributes and macros, snippets, state
-- drivers, unit watch, size, points, shown, scale, texts, colours, aura containers, buff buttons) plus the smart / tank
-- buttons, for each scenario; the result must equal tests/fixtures/party-golden-0.10.1.lua.
--
-- Regenerate ONLY when a party change is intended:  HF_UPDATE_GOLDEN=1 ./run-tests.sh party_golden
-- (then review the fixture diff line by line: every changed line is a visible party change).
local mock = require("wow_mock")
local PS = require("party_snapshot")

local UPDATE = os.getenv("HF_UPDATE_GOLDEN") == "1"
local function errstr() return table.concat(mock.errors, "\n---\n") end

-- Boots a scenario, checks it ran clean, returns its snapshot.
local function capture(sc)
    local ns = PS.boot(sc)
    assertEquals(#mock.errors, 0, sc.name .. " errors:\n" .. errstr())
    assertEquals(#mock.violations, 0, sc.name .. ": protected calls in combat")
    return PS.snapshotParty(ns), ns
end

local golden = PS.loadGolden()
local fresh = {}

describe("party golden: snapshot helper", function()
    it("is deterministic: two boots of the same scenario give the same snapshot", function()
        local sc = PS.scenario("party4_v0.10.1_save")
        local a = capture(sc)
        local b = capture(sc)
        assertNil(PS.diff(a, b), "snapshot differs between two identical boots")
    end)
    it("sees the things it is meant to pin (macros, snippets, drivers, containers, buff buttons)", function()
        local snap = capture(PS.scenario("party3_paladin_example"))
        local text = table.concat(snap.lines, "\n")
        assertTrue(text:find("HealerForeverUnit1 attr macrotext1 = \"/cast [@player,dead] Redemption; [@player,help,nodead] Flash of Light\"", 1, true) ~= nil, "plain Left macro")
        assertTrue(text:find("HealerForeverUnit1 attr _onenter = str<", 1, true) ~= nil, "hover snippet interned")
        assertTrue(text:find("HealerForeverUnit1 attr meta[type2]", 1, true) ~= nil, "Cmd swap entry keyed by slot")
        assertTrue(text:find("HFB<META-BUTTON2>", 1, true) ~= nil, "override slot named after its binding key")
        assertTrue(text:find("HealerForeverUnit1 driver hfmeta = \"[mod:meta] meta; none\"", 1, true) ~= nil, "Cmd state driver")
        assertTrue(text:find("HealerForeverUnit1 kind=Button", 1, true) ~= nil and text:find("watch=true", 1, true) ~= nil, "unit watch")
        assertTrue(text:find("container group buff filter=\"HELPFUL\"", 1, true) ~= nil, "aura container filter")
        assertTrue(text:find("HealerForeverUnit1 auras.debuff unit=\"player\" key=", 1, true) ~= nil, "aura container geometry key")
        assertTrue(text:find("HealerForeverBuff2 state", 1, true) ~= nil, "buff button state")
        assertTrue(text:find("HealerForeverSmartBuff kind=Button", 1, true) ~= nil, "smart button")
        assertTrue(text:find("HealerForeverTankBuff kind=Button", 1, true) ~= nil, "tank button")
        assertTrue(text:find("HealerForeverUnit2.healthText kind=FontString", 1, true) ~= nil, "health text")
        assertTrue(text:find("HealerForeverUnit1.health kind=StatusBar", 1, true) ~= nil and text:find(" sb=(", 1, true) ~= nil, "bar colour")
        assertTrue(next(snap.strings) ~= nil, "long snippets are interned")
    end)
    it("pairs-order numbering is canonical (HFB slots and numbered Cmd / dead entries)", function()
        local a = PS.canonicalAttrs({ ["hf-nbinds"] = 2, ["hf-bkey1"] = "META-BUTTON1", ["hf-bkey2"] = "BUTTON6",
            ["*type-HFB1"] = "macro", ["*type-HFB2"] = "macro", ["hf-mn"] = 1, ["hf-mtype1"] = "type1", ["hf-mmac1"] = "macrotext1",
            ["hf-mtext1"] = "x", ["hf-motype1"] = "macro", ["hf-momac1"] = "y", ["hf-dn"] = 1, ["hf-dtype1"] = "*type-HFB2",
            ["hf-dmac1"] = "*macrotext-HFB2", ["hf-dorig1"] = "togglemenu", ["hf-dtext1"] = "z" })
        local b = PS.canonicalAttrs({ ["hf-nbinds"] = 2, ["hf-bkey1"] = "BUTTON6", ["hf-bkey2"] = "META-BUTTON1",
            ["*type-HFB2"] = "macro", ["*type-HFB1"] = "macro", ["hf-mn"] = 1, ["hf-mtype1"] = "type1", ["hf-mmac1"] = "macrotext1",
            ["hf-mtext1"] = "x", ["hf-motype1"] = "macro", ["hf-momac1"] = "y", ["hf-dn"] = 1, ["hf-dtype1"] = "*type-HFB1",
            ["hf-dmac1"] = "*macrotext-HFB1", ["hf-dorig1"] = "togglemenu", ["hf-dtext1"] = "z" })
        assertDeepEquals(a, b)
        -- but a real difference (another macro behind the same key) is still seen
        local c = PS.canonicalAttrs({ ["hf-nbinds"] = 1, ["hf-bkey1"] = "BUTTON6", ["*macrotext-HFB1"] = "/cast A" })
        local d = PS.canonicalAttrs({ ["hf-nbinds"] = 1, ["hf-bkey1"] = "BUTTON6", ["*macrotext-HFB1"] = "/cast B" })
        local function flat(x) local o = {}; for _, p in ipairs(x) do o[#o + 1] = p[1] .. "=" .. tostring(p[2]) end return table.concat(o, "\n") end
        assertTrue(flat(c) ~= flat(d), "different macros behind the same key must differ")
        assertTrue(flat(c):find("*macrotext-HFB<BUTTON6>=/cast A", 1, true) ~= nil, flat(c))
    end)
    it("the synthetic 0.10.1 fixture is a schema-4 sparse save and really loads non-default party settings", function()
        local sc = PS.scenario("party4_v0.10.1_save")
        local ns = PS.boot(sc)
        assertEquals(ns.db.version, 4)
        assertEquals(ns.db.frames.layout, "vertical")
        assertEquals(ns.db.frames.healthText, "deficit")
        assertEquals(ns.db.frames.sortMode, "role")
        assertEquals(ns.db.frames.border.style, "gold")
        assertEquals(ns.db.auras.debuffPosition, "inside")
        assertEquals(ns.db.activePreset, 2)
        assertEquals(ns.db.bindings["meta-shift|1"].spell, "Lay on Hands")
        assertEquals(ns.db.presets[2].map.PALADIN.HEALER[2], "light")
        assertEquals(ns.db.smartButton.show, true)
        assertEquals(ns.db.minimap.angle, 135)
        assertEquals(ns.db.pins.size, 20)
    end)
end)

describe("party golden: raid layout scenarios really are in a raid", function()
    it("raid25_layoutMode_party: in a 25-man raid, Always party, raid frames idle", function()
        local ns, S = PS.boot(PS.scenario("raid25_layoutMode_party"))
        assertEquals(#mock.errors, 0, errstr())
        assertTrue(S.inRaid and S.raidSize == 25, "the mock raid was joined")
        assertEquals(ns.db.raid.layoutMode, "party")
        local RF = ns.RaidFrames
        assertNotNil(RF.anchor, "raid frames created")
        assertEquals(RF.active, "party")
        assertFalse(rawget(RF.anchor, "__s").shown, "raid anchor hidden")
        for _, b in ipairs(RF.buttons) do
            assertFalse(rawget(b, "__s").shown); assertFalse(rawget(b, "__s").unitWatch == true, "no unit watch on idle raid buttons")
        end
    end)
    -- Round trip: the default (auto) layout switches to the raid layout for a 25-man raid, then back to party when the
    -- raid ends. The party frames must come back identical. Suspending hides the party buttons and un-suspending
    -- re-registers their unit watch; in the game the unit watch then shows them again. The golden file was captured
    -- WITHOUT simulating the unit watch (buttons keep the mock's default shown=true, even for missing pets), so the
    -- reference here is a fresh boot of the same scenario with mock.applyUnitWatch(), compared with the round trip after
    -- mock.applyUnitWatch(). Only events and timers run (the clock is not advanced), so aura timer texts stay comparable.
    -- The no-raid golden itself is still checked above (party4_v0.10.1_save).
    it("raid layout and back to party: the party snapshot equals a fresh party boot", function()
        local sc = PS.scenario("party4_v0.10.1_save")
        local ref = PS.boot(sc)
        mock.applyUnitWatch()
        local want = PS.snapshotParty(ref)

        local ns = PS.boot(sc)
        local RF = ns.RaidFrames
        mock.setRaid(25)
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.applyUnitWatch()
        assertEquals(RF.active, "raid", "25-man raid switches to the raid layout")
        assertFalse(rawget(ns.UnitFrames.anchor, "__s").shown, "party anchor hidden while the raid layout is active")
        -- Auto inside a raid: soft suspend. The party buttons keep their unit watch (they must come back at once if the raid
        -- ends mid-combat) under the party anchor, which a secure visibility driver hides while in a raid.
        local partyVisible = 0
        for _, b in ipairs(ns.UnitFrames.buttons) do
            if mock.isVisible(b) then partyVisible = partyVisible + 1 end
            assertTrue(rawget(b, "__s").unitWatch == true, "soft-suspended party buttons keep their unit watch")
        end
        assertEquals(partyVisible, 0, "no party bar visible while the raid layout is active")
        assertEquals((rawget(ns.UnitFrames.anchor, "__s").stateDrivers or {}).visibility, "[group:raid] hide; show")
        mock.setRaid(0)
        mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers(); mock.applyUnitWatch()
        assertEquals(RF.active, "party")
        assertEquals(#mock.errors, 0, errstr())
        assertEquals(#mock.violations, 0)
        local d = PS.diff(want, PS.snapshotParty(ns))
        assertNil(d, "party frames differ after a raid round trip:\n" .. tostring(d))
    end)
end)

describe("party golden: every scenario matches party-golden-0.10.1", function()
    for _, sc in ipairs(PS.SCENARIOS) do
        if sc.pending then
            -- hook for later scenarios (raid code): skipped cleanly until the code it needs exists
            local ready = false
            if sc.requires then
                local ok, ns = pcall(PS.boot, PS.scenario(sc.sameAs) or sc)
                ready = ok and sc.requires(ns) or false
            end
            if not ready then
                skip(sc.name, sc.pending)
            else
                it(sc.name .. " (should be enabled: the code it needs exists now)", function()
                    error("scenario " .. sc.name .. " is still marked pending; implement its boot and remove `pending`")
                end)
            end
        else
            it(sc.name, function()
                local snap = capture(sc)
                fresh[sc.name] = snap
                if UPDATE then return end
                assertNotNil(golden, "missing tests/fixtures/" .. PS.GOLDEN .. ": run HF_UPDATE_GOLDEN=1 ./run-tests.sh party_golden")
                local want = golden[sc.sameAs or sc.name]
                assertNotNil(want, "no golden for " .. sc.name .. ": run HF_UPDATE_GOLDEN=1 ./run-tests.sh party_golden")
                local d = PS.diff(want, snap)
                assertNil(d, sc.name .. ": the party frames changed:\n" .. tostring(d)
                    .. "\nIf this change is intended, regenerate: HF_UPDATE_GOLDEN=1 ./run-tests.sh party_golden")
            end)
        end
    end
    it("the golden file has no stale scenarios", function()
        if UPDATE or not golden then return end
        for name in pairs(golden) do
            local sc = PS.scenario(name)
            assertTrue(sc ~= nil and not sc.pending, "golden has an unknown scenario " .. name)
        end
    end)
end)

if UPDATE then
    describe("party golden: rewrite (HF_UPDATE_GOLDEN=1)", function()
        it("writes tests/fixtures/" .. PS.GOLDEN, function()
            local all = {}
            for _, sc in ipairs(PS.SCENARIOS) do if not sc.pending and not sc.sameAs then all[sc.name] = assert(fresh[sc.name], sc.name .. " not captured") end end
            local f = assert(io.open(PS.goldenPath(), "wb"))
            f:write(PS.serialize(all))
            f:close()
            local back = PS.loadGolden()
            for name, snap in pairs(all) do assertNil(PS.diff(snap, back[name]), "round trip " .. name) end
            warn("party golden REWRITTEN (" .. PS.GOLDEN .. "): review the diff before committing")
        end)
    end)
end
