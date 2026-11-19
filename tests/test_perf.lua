-- /hf perf (Options/Perf.lua): CPU / memory per addon from the client's addon profiler (C_AddOnProfiler), else from
-- GetAddOnCPUUsage only when the scriptProfile CVar is "1", else memory only with a note; our row marked " (us)" and
-- shown after "..." when it is outside the top 8; every API missing / raising / secret without a Lua error; no memory
-- refresh in combat; the hot-path sampler (/hf perf start [seconds] / stop): ns.perfOn only while sampling, uf / mp / bb
-- (+ rf / rfbuffs only with the raid layout), window clamp 5..600, refused while running or without debugprofilestop,
-- the ticker stopping the sample, the result shown later; the /hf report and /hf copy blocks, SLASH_COMMANDS and usage.
local mock = require("wow_mock")
local H = require("raid_helpers")
local L = require("loader")

if not L.parseToc() then it("TOC present", function() error("no TOC") end) return end
local errstr = H.errstr

local function clean(label)
    assertEquals(#mock.errors, 0, (label or "") .. " errors:\n" .. errstr())
    assertEquals(H.violations(), "", (label or "") .. " protected calls in combat")
end

local function boot(opts)
    opts = opts or {}
    local ns = H.boot({ group = opts.group or 4, raid = opts.raid })
    return ns, ns.Perf
end

-- Our addon plus others; the Blizzard_ one and the not-loaded one must never be listed.
local function addons(ours)
    return {
        { name = "Questie", cpu = 0.5, recent = 0.6, peak = 4, mem = 30000 },
        { name = "HealerForever", cpu = ours and ours.cpu or 0.05, recent = ours and ours.recent or 0.06, peak = 1.2, mem = ours and ours.mem or 900 },
        { name = "Details", cpu = 0.2, recent = 0.25, peak = 2, mem = 5000 },
        { name = "Blizzard_Foo", cpu = 9, mem = 99999 },
        { name = "SleepyAddon", loaded = false, cpu = 99, mem = 99999 },
    }
end

local function find(lines, text)
    for i, line in ipairs(lines) do if line:find(text, 1, true) then return i, line end end
    return nil
end
local function joined(lines) return table.concat(lines, "\n") end
local function rowNames(lines)
    local out = {}
    for _, line in ipairs(lines) do
        local name = line:match("^%s*%d+%. (%S+)")
        if name then out[#out + 1] = name end
    end
    return out
end
local function printed() return table.concat(mock.printed, "\n") end

describe("perf: CPU from the game addon profiler", function()
    it("header, rows sorted by CPU (highest first), our row marked, Blizzard and unloaded addons left out", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = true })
        assertEquals(Perf.CpuSource(), "profiler")
        local lines = Perf.Lines()
        assertTrue(lines[1]:find("Addons by CPU (game addon profiler", 1, true) == 1, lines[1])
        assertDeepEquals(rowNames(lines), { "Questie", "Details", "HealerForever" })
        local _, ours = find(lines, "HealerForever")
        assertEquals(ours, " 3. HealerForever (us)  cpu 0.050 ms/frame (recent 0.060, peak 1.2)  mem 900 KB")
        local _, q = find(lines, "Questie")
        assertEquals(q, " 1. Questie  cpu 0.500 ms/frame (recent 0.600, peak 4.0)  mem 29.3 MB")
        assertNil(find(lines, "Blizzard_Foo")); assertNil(find(lines, "SleepyAddon"))
        local us = 0
        for _, line in ipairs(lines) do if line:find("(us)", 1, true) then us = us + 1 end end
        assertEquals(us, 1, "only our row says (us)")
        assertNotNil(find(lines, "3 addons loaded (Blizzard's own not counted)."))
        assertNotNil(find(lines, "No timing sample yet"))
        assertNil(find(lines, "..."), "we are in the top 8: no separate row")
        clean()
    end)

    it("IsEnabled() true keeps the profiler; IsEnabled() false falls back (memory, or scriptProfile when it is on)", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = true, profilerEnabled = true })
        assertEquals(Perf.CpuSource(), "profiler")
        mock.setAddons(addons(), { profiler = true, profilerEnabled = false })
        local src, note = Perf.CpuSource()
        assertNil(src); assertTrue(note:find("CPU per addon: not available", 1, true) == 1, note)
        local lines = Perf.Lines()
        assertEquals(lines[1], "Addons by memory:")
        mock.setAddons(addons(), { profiler = true, profilerEnabled = false, scriptProfile = "1", cpuUsage = true })
        assertEquals(Perf.CpuSource(), "scriptProfile")
        clean()
    end)

    it("Healer Forever outside the top 8: '...' and then our own row with its real rank", function()
        local _, Perf = boot()
        local list = {}
        for i = 1, 10 do list[#list + 1] = { name = "Other" .. string.format("%02d", i), cpu = 1 + i, mem = 100 } end
        list[#list + 1] = { name = "HealerForever", cpu = 0.01, mem = 800 }
        mock.setAddons(list, { profiler = true })
        local lines = Perf.Lines()
        local names = rowNames(lines)
        assertEquals(#names, 9, "top 8 + our row:\n" .. joined(lines))
        assertEquals(names[1], "Other10", "highest CPU first")
        assertEquals(names[8], "Other03")
        local dots = find(lines, "...")
        assertNotNil(dots)
        assertEquals(lines[dots + 1]:match("^%s*(%d+)%. HealerForever %(us%)"), "11", lines[dots + 1])
        assertNotNil(find(lines, "11 addons loaded"))
        -- a smaller top N still keeps us
        local short = Perf.Lines(3)
        assertEquals(#rowNames(short), 4)
        assertTrue(rowNames(short)[4] == "HealerForever")
        clean()
    end)

    it("our addon not reported by the addon list at all is still added as a row", function()
        local _, Perf = boot()
        mock.setAddons({ { name = "Questie", cpu = 0.5, mem = 300 } }, { profiler = true })
        local lines = Perf.Lines()
        assertDeepEquals(rowNames(lines), { "Questie", "HealerForever" })
        assertNotNil(find(lines, "HealerForever (us)"))
        clean()
    end)
end)

describe("perf: without the profiler", function()
    it("scriptProfile '0': memory only, sorted by memory, says CPU is not available (no zeros)", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = false, scriptProfile = "0" })
        local lines = Perf.Lines()
        assertEquals(lines[1], "Addons by memory:")
        assertTrue(lines[2]:find("CPU per addon: not available", 1, true) == 1, lines[2])
        assertTrue(lines[2]:find("scriptProfile", 1, true) ~= nil)
        assertDeepEquals(rowNames(lines), { "Questie", "Details", "HealerForever" })
        assertNil(joined(lines):find("cpu ", 1, true), "no CPU column without a CPU source")
        local _, ours = find(lines, "HealerForever")
        assertEquals(ours, " 3. HealerForever (us)  mem 900 KB")
        assertEquals(mock.perfCalls.memUpdate, 1, "memory refreshed once per snapshot out of combat")
        assertEquals(mock.perfCalls.cpuUpdate, 0)
        clean()
    end)

    it("scriptProfile '0' but GetAddOnCPUUsage exists: still memory only (those numbers would be zeros)", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = false, scriptProfile = "0", cpuUsage = true })
        assertNil(Perf.CpuSource())
        local lines = Perf.Lines()
        assertEquals(lines[1], "Addons by memory:")
        assertNil(joined(lines):find("ms total", 1, true))
        assertEquals(mock.perfCalls.cpuUpdate, 0, "UpdateAddOnCPUUsage not called with scriptProfile off")
        clean()
    end)

    it("scriptProfile '1' + GetAddOnCPUUsage: CPU header, 'ms total', sorted by CPU, UpdateAddOnCPUUsage called", function()
        local _, Perf = boot()
        mock.setAddons({
            { name = "Bulky", cpu = 10, mem = 90000 },
            { name = "HealerForever", cpu = 1234.4, mem = 2048 },
            { name = "Busy", cpu = 5000, mem = 10 },
        }, { profiler = false, scriptProfile = "1", cpuUsage = true })
        assertEquals(Perf.CpuSource(), "scriptProfile")
        local lines = Perf.Lines()
        assertTrue(lines[1]:find("Addons by CPU (scriptProfile is ON", 1, true) == 1, lines[1])
        assertDeepEquals(rowNames(lines), { "Busy", "HealerForever", "Bulky" })
        local _, ours = find(lines, "HealerForever")
        assertEquals(ours, " 2. HealerForever (us)  cpu 1234 ms total  mem 2.0 MB")
        assertEquals(mock.perfCalls.cpuUpdate, 1)
        clean()
    end)

    it("scriptProfile '1' without GetAddOnCPUUsage: memory only", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = false, scriptProfile = "1", cpuUsage = false })
        assertNil(Perf.CpuSource())
        assertEquals(Perf.Lines()[1], "Addons by memory:")
        clean()
    end)

    it("no memory API either: a note instead of numbers, rows show 'mem ?'", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = false, memory = false })
        local lines = Perf.Lines()
        assertNotNil(find(lines, "memory per addon: not available in this client"))
        assertNotNil(find(lines, "HealerForever (us)  mem ?"))
        clean()
    end)
end)

describe("perf: broken, missing and secret APIs", function()
    it("every addon API raising: no Lua error, no logged error, our row still listed", function()
        local ns, Perf = boot()
        mock.setAddons(addons(), { profiler = true, profilerEnabled = true, scriptProfile = "1", cpuUsage = true, raise = true })
        local ok, lines = pcall(Perf.Lines)
        assertTrue(ok, tostring(lines))
        assertDeepEquals(rowNames(lines), { "HealerForever" })
        assertNotNil(find(lines, "HealerForever (us)  cpu ?  mem ?"))
        local ok2, err = H.slash("perf")
        assertTrue(ok2, tostring(err))
        assertTrue(printed():find("Addons by CPU", 1, true) ~= nil, printed())
        assertTrue(ns.Report.Build():find("HealerForever (us)", 1, true) ~= nil)
        assertEquals(#(ns.db.errorLog or {}), 0, "nothing logged")
        clean()
    end)

    it("every API removed (C_AddOns, profiler, Enum metric, GetCVar, memory, CPU, GetTime): no error", function()
        local ns, Perf = boot()
        mock.setAddons(addons(), { profiler = false, memory = false })
        for _, g in ipairs({ "C_AddOns", "GetNumAddOns", "GetAddOnInfo", "IsAddOnLoaded", "GetCVar", "GetAddOnCPUUsage",
            "UpdateAddOnCPUUsage", "C_AddOnProfiler", "GetTime" }) do
            mock.setGlobal(g, nil)
        end
        local ok, lines = pcall(Perf.Lines)
        assertTrue(ok, tostring(lines))
        assertEquals(lines[1], "Addons by memory:")
        assertDeepEquals(rowNames(lines), { "HealerForever" })
        local okS, why = Perf.Start(10)
        assertTrue(okS, tostring(why))
        assertTrue(Perf.Stop() ~= nil)
        H.slash("perf")
        assertTrue(ns.CopyText():find("== /hf perf ==", 1, true) ~= nil)
        clean()
    end)

    it("secret metrics and memory: '?' everywhere, no arithmetic, comparison or concatenation on them", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = true, secret = true })
        local ok, lines = pcall(Perf.Lines)
        assertTrue(ok, tostring(lines))
        assertNotNil(find(lines, "HealerForever (us)  cpu ?  mem ?"))
        assertDeepEquals(rowNames(lines), { "Details", "HealerForever", "Questie" }, "no numbers: sorted by name")
        mock.setAddons(addons(), { profiler = false, scriptProfile = "1", cpuUsage = true, secret = true })
        ok, lines = pcall(Perf.Lines)
        assertTrue(ok, tostring(lines))
        assertNotNil(find(lines, "HealerForever (us)  cpu ?  mem ?"))
        -- a secret sample tick and a secret timer value
        Perf.Start(30)
        mock.state.now = mock.state.now + 30
        mock.tick(); mock.flushTimers()
        assertNil(Perf.sampling, "the window ended")
        Perf.Add("uf", mock.newSecret())
        assertNil(Perf.stats.uf, "a secret start time is ignored")
        clean()
    end)

    it("secret CVar, secret addon count, secret IsEnabled, secret metric ids: safe answers", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = false, scriptProfile = "1", cpuUsage = true })
        mock.setGlobal("GetCVar", function() return mock.newSecret() end)
        assertNil(Perf.CpuSource(), "a secret scriptProfile answer is not '1'")
        mock.setAddons(addons(), { profiler = true, profilerEnabled = true })
        _G.C_AddOnProfiler.IsEnabled = function() return mock.newSecret() end
        assertEquals(Perf.CpuSource(), "profiler", "a secret IsEnabled is not 'false'")
        _G.Enum.AddOnProfilerMetric = { SessionAverageTime = mock.newSecret(), RecentAverageTime = mock.newSecret(), PeakTime = 3 }
        assertNil(Perf.CpuSource(), "secret metric ids: no profiler")
        _G.C_AddOns.GetNumAddOns = function() return mock.newSecret() end
        local ok, lines = pcall(Perf.Lines)
        assertTrue(ok, tostring(lines))
        assertDeepEquals(rowNames(lines), { "HealerForever" })
        clean()
    end)
end)

describe("perf: combat", function()
    it("in combat the memory is not refreshed (UpdateAddOnMemoryUsage) and a note says so", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = true })
        H.enterCombat()
        local lines = Perf.Lines()
        assertEquals(mock.perfCalls.memUpdateCombat, 0)
        assertEquals(mock.perfCalls.memUpdate, 0)
        assertNotNil(find(lines, "memory as of the last update (not refreshed in combat)"))
        assertNotNil(find(lines, "HealerForever (us)"))
        -- start / stop in combat do not refresh memory either
        assertTrue((Perf.Start(10)))
        mock.runOnUpdate(4, 0.3); mock.tick(); mock.flushTimers()
        local r = Perf.Stop()
        assertTrue(r.combat, "the sample says it included combat")
        assertEquals(mock.perfCalls.memUpdate, 0)
        assertNotNil(find(Perf.Lines(), "(included combat)"))
        H.leaveCombat()
        Perf.Lines()
        assertEquals(mock.perfCalls.memUpdate, 1, "out of combat it refreshes again")
        clean("combat")
    end)

    it("the full /hf perf flow in combat with everything secret: no errors, no protected calls", function()
        local ns = boot({ raid = 10 })
        mock.setAddons(addons(), { profiler = true, secret = true })
        H.enterCombat()
        mock.state.secretAll = true
        for _, msg in ipairs({ "perf", "perf start 5", "perf", "perf start", "perf stop", "perf stop", "perf junk", "report" }) do
            local ok, err = H.slash(msg)
            assertTrue(ok, msg .. ": " .. tostring(err))
            mock.runOnUpdate(3, 0.3); mock.tick(); mock.flushTimers()
        end
        assertTrue(ns.CopyText():find("== /hf perf ==", 1, true) ~= nil)
        mock.state.secretAll = false
        H.leaveCombat()
        clean("perf in combat")
    end)
end)

describe("perf: sampling our hot paths", function()
    it("ns.perfOn is nil by default, true while sampling, nil again after stop", function()
        local ns, Perf = boot()
        assertNil(ns.perfOn)
        assertNil(Perf.sampling)
        assertTrue((Perf.Start()))
        assertEquals(ns.perfOn, true)
        Perf.Stop()
        assertNil(ns.perfOn)
        assertNil(Perf.sampling)
        clean()
    end)

    it("no hot-path stats are collected while idle", function()
        local _, Perf = boot()
        mock.runOnUpdate(6, 0.3); mock.tick(); mock.flushTimers()
        assertNil(next(Perf.stats), "idle: nothing recorded")
        clean()
    end)

    it("party mode: party bars (uf), minimap pins (mp) and buff buttons (bb) are timed; raid paths are not", function()
        local _, Perf = boot()
        assertTrue((Perf.Start(60)))
        mock.runOnUpdate(6, 0.3); mock.tick(); mock.tick(); mock.flushTimers()
        for _, k in ipairs({ "uf", "mp", "bb" }) do
            assertTrue(Perf.stats[k] and Perf.stats[k].n > 0, k .. " timed")
        end
        assertEquals(Perf.stats.bb.n, 2, "one per buff ticker run")
        assertNil(Perf.stats.rf, "raid bars idle in party mode")
        assertNil(Perf.stats.rfbuffs)
        local r = Perf.Stop()
        assertTrue(r.stats.uf.n > 0)
        assertDeepEquals(Perf.stats, {}, "stats are reset after stop")
        clean()
    end)

    it("raid layout active: raid bars (rf) and raid buff markers (rfbuffs) are timed", function()
        local ns, Perf = boot({ raid = 10 })
        assertEquals(ns.RaidFrames.active, "raid")
        assertTrue((Perf.Start(60)))
        mock.runOnUpdate(6, 0.3); mock.flushTimers()
        assertTrue(Perf.stats.rf and Perf.stats.rf.n > 0, "rf timed")
        assertTrue(Perf.stats.rfbuffs and Perf.stats.rfbuffs.n > 0, "rfbuffs timed")
        Perf.Stop()
        clean()
    end)

    it("Perf.Add: runs, total, peak and average; a negative interval counts as 0", function()
        local _, Perf = boot()
        local t = 100
        mock.setGlobal("debugprofilestop", function() return t end)
        Perf.Add("uf", 97)          -- 3 ms
        t = 110; Perf.Add("uf", 109) -- 1 ms
        t = 5; Perf.Add("uf", 10)    -- clock went back: 0 ms
        local s = Perf.stats.uf
        assertEquals(s.n, 3); assertEquals(s.total, 4); assertEquals(s.peak, 3)
        local lines = Perf.HotPathLines(Perf.stats, 2)
        assertEquals(lines[1], "  Party bars update (every 0.25 s): 3 runs, avg 1.333 ms, peak 3.00 ms, total 4.0 ms (2.00 ms/s)")
        assertDeepEquals(Perf.HotPathLines({}, 2), { "  (none of our timed code ran)" })
        clean()
    end)

    it("a second start while sampling is refused with a message; the first sample keeps running", function()
        local ns, Perf = boot()
        assertTrue((Perf.Start(30)))
        local first = Perf.sampling
        local ok, msg = Perf.Start(90)
        assertFalse(ok)
        assertEquals(msg, "A sample is already running. /hf perf stop ends it.")
        assertTrue(Perf.sampling == first)
        assertEquals(Perf.sampling.window, 30)
        assertEquals(ns.perfOn, true)
        H.slash("perf start 20")
        assertTrue(printed():find("A sample is already running", 1, true) ~= nil, printed())
        Perf.Stop()
        clean()
    end)

    it("the window is clamped to 5..600 s; junk gives the default 60; fractions are floored", function()
        local _, Perf = boot()
        local function window(arg)
            local ok, w = Perf.Start(arg)
            assertTrue(ok, tostring(w))
            Perf.Stop()
            return w
        end
        assertEquals(window(1), 5)
        assertEquals(window(0), 5)
        assertEquals(window(-30), 5)
        assertEquals(window(9999), 600)
        assertEquals(window(600), 600)
        assertEquals(window("abc"), 60)
        assertEquals(window(nil), 60)
        assertEquals(window(12.7), 12)
        assertEquals(window("45"), 45)
        clean()
    end)

    it("the ticker ends the sample once the window has passed and cancels itself; profiler CPU is averaged", function()
        local ns, Perf = boot()
        mock.setAddons(addons({ cpu = 0.05, recent = 0.07 }), { profiler = true })
        mock.printed = {}
        assertTrue((Perf.Start(10)))
        local ticker = Perf.sampling.ticker
        assertNotNil(ticker, "a C_Timer ticker drives the sample")
        mock.state.now = mock.state.now + 5
        mock.tick()
        assertNotNil(Perf.sampling, "still inside the window")
        mock.state.now = mock.state.now + 5
        mock.tick()
        assertNil(Perf.sampling, "window over: stopped")
        assertNil(ns.perfOn)
        assertTrue(ticker.cancelled, "the ticker is cancelled")
        local r = Perf.last
        assertEquals(math.floor(r.seconds + 0.5), 10)
        assertTrue(math.abs(r.cpuAvg - 0.07) < 1e-9)
        assertTrue(printed():find("Perf sample finished (10 s):", 1, true) ~= nil, printed())
        assertTrue(printed():find("Healer Forever cpu: avg 0.070 ms/frame", 1, true) ~= nil, printed())
        assertTrue(printed():find("Healer Forever memory: 900 KB -> 900 KB", 1, true) ~= nil, printed())
        -- a manual stop cancels the ticker too
        assertTrue((Perf.Start(60)))
        local t2 = Perf.sampling.ticker
        Perf.Stop()
        assertTrue(t2.cancelled)
        clean()
    end)

    it("no debugprofilestop(): start is refused, nothing is switched on", function()
        local ns, Perf = boot()
        mock.setGlobal("debugprofilestop", nil)
        local ok, msg = Perf.Start(30)
        assertFalse(ok)
        assertEquals(msg, "This client has no debugprofilestop(); our own timings can't be measured.")
        assertNil(ns.perfOn); assertNil(Perf.sampling)
        H.slash("perf start")
        assertTrue(printed():find("no debugprofilestop", 1, true) ~= nil, printed())
        clean()
    end)

    it("the result is shown later by /hf perf: running note while sampling, then 'Last sample' with the hot paths", function()
        local _, Perf = boot()
        mock.setAddons(addons(), { profiler = true })
        assertTrue((Perf.Start(60)))
        mock.runOnUpdate(4, 0.5); mock.tick(); mock.flushTimers()
        local lines = Perf.Lines()
        assertNotNil(find(lines, "A sample is running (2 s so far). /hf perf stop ends it."), joined(lines))
        Perf.Stop()
        lines = Perf.Lines()
        assertNil(find(lines, "A sample is running"))
        assertNil(find(lines, "No timing sample yet"))
        assertNotNil(find(lines, "Last sample: 2 s"), joined(lines))
        assertNotNil(find(lines, "  Party bars update (every 0.25 s): "), joined(lines))
        assertNotNil(find(lines, "  Buff buttons refresh (every 0.5 s): 1 runs"), joined(lines))
        assertNil(find(lines, "Raid bars update"), "raid paths did not run")
        clean()
    end)
end)

describe("perf: /hf report, /hf copy, slash commands", function()
    it("/hf report has '== Performance (/hf perf) ==' with the per-addon lines", function()
        local ns = boot()
        mock.setAddons(addons(), { profiler = true })
        local text = ns.Report.Build()
        local a = text:find("== Performance (/hf perf) ==", 1, true)
        assertNotNil(a, text)
        local b = text:find("\n== ", a + 5, true)
        local sec = text:sub(a, b and b - 1 or #text)
        assertTrue(sec:find("Addons by CPU (game addon profiler", 1, true) ~= nil, sec)
        assertTrue(sec:find("HealerForever (us)", 1, true) ~= nil, sec)
        assertTrue(text:find("== Other loaded addons ==", 1, true) > a, "before the addon list")
        clean()
    end)

    it("/hf copy text ends with '== /hf perf ==' and the same lines; a failing Perf.Lines is reported, not raised", function()
        local ns = boot()
        mock.setAddons(addons(), { profiler = true })
        local text = ns.CopyText()
        local a = text:find("== /hf perf ==", 1, true)
        assertNotNil(a, text)
        assertTrue(text:find("HealerForever (us)", a, true) ~= nil)
        ns.Perf.Lines = function() error("boom") end
        local ok, t2 = pcall(ns.CopyText)
        assertTrue(ok, tostring(t2))
        assertTrue(t2:find("== /hf perf ==\nfailed: ", 1, true) ~= nil, t2)
        local ok3, rep = pcall(ns.Report.Build)
        assertTrue(ok3, tostring(rep))
        assertTrue(rep:find("== Performance (/hf perf) ==\nfailed: ", 1, true) ~= nil)
        clean()
    end)

    it("SLASH_COMMANDS lists /hf perf (shown in help); /hf perf prints the lines", function()
        local ns = boot()
        mock.setAddons(addons(), { profiler = true })
        local entry
        for _, c in ipairs(ns.SLASH_COMMANDS) do if c.cmd:find("^/hf perf") then entry = c end end
        assertNotNil(entry)
        assertEquals(entry.cmd, "/hf perf [start [seconds]|stop]")
        assertFalse(entry.hidden == true)
        H.slash("help")
        assertTrue(printed():find("/hf perf", 1, true) ~= nil, "help mentions /hf perf")
        H.slash("perf")
        assertTrue(printed():find("Addons by CPU (game addon profiler", 1, true) ~= nil, printed())
        assertTrue(printed():find("HealerForever (us)", 1, true) ~= nil)
        clean()
    end)

    it("start / stop / bad arguments: messages and usage", function()
        local ns = boot()
        H.slash("perf stop")
        assertTrue(printed():find("No perf sample is running. /hf perf start [seconds] starts one.", 1, true) ~= nil, printed())
        H.slash("perf START 30")
        assertTrue(printed():find("Perf sample started for 30 s.", 1, true) ~= nil, printed())
        assertEquals(ns.perfOn, true)
        H.slash("perf stop")
        assertTrue(printed():find("Perf sample finished", 1, true) ~= nil, printed())
        assertNil(ns.perfOn)
        H.slash("perf start 2")
        assertTrue(printed():find("started for 5 s", 1, true) ~= nil, "clamped in the message: " .. printed())
        H.slash("perf stop")
        for _, junk in ipairs({ "perf bogus", "perf 30", "perf stopp" }) do
            H.slash(junk)
            assertEquals(printed():match("[^\n]*/hf perf | /hf perf start %[seconds%] | /hf perf stop$") ~= nil, true, junk .. " -> " .. printed())
        end
        assertNil(ns.perfOn)
        clean()
    end)
end)
