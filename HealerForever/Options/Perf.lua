local ADDON_NAME, ns = ...

-- /hf perf: how much CPU and memory Healer Forever uses next to the other loaded addons, plus timings of our own
-- hot paths while a sample runs (/hf perf start [seconds] / stop).
--
-- Sources, best first (every call pcall'd; a missing API never errors):
--   CPU:    C_AddOnProfiler.GetAddOnMetric(name, Enum.AddOnProfilerMetric.*) (ms per frame, always on in modern clients);
--           else GetAddOnCPUUsage only when the scriptProfile CVar is "1" (otherwise we say so instead of printing zeros).
--   Memory: UpdateAddOnMemoryUsage + GetAddOnMemoryUsage (KB).
-- Hot paths: the hot code checks the plain field ns.perfOn (nil unless sampling) and only then calls
-- debugprofilestop() and Perf.Add, so the instrumentation costs one table lookup per tick when idle.
-- None of these values come from unit/aura APIs; they are still checked with issecret before any arithmetic.
local Perf = {}
ns.Perf = Perf

Perf.TOP_N = 8
Perf.DEFAULT_WINDOW = 60
Perf.MIN_WINDOW, Perf.MAX_WINDOW = 5, 600
Perf.SAMPLE_EVERY = 5

-- hot paths, in print order
Perf.PATHS = {
    { key = "uf", label = "Party bars update (every 0.25 s)" },
    { key = "rf", label = "Raid bars update (every 0.2 s)" },
    { key = "rfbuffs", label = "Raid buff markers (every 0.5 s)" },
    { key = "bb", label = "Buff buttons refresh (every 0.5 s)" },
    { key = "mp", label = "Minimap pins (every 0.15 s)" },
}

Perf.stats = {}     -- key -> { n, total, peak } (ms), filled only while sampling
Perf.last = nil     -- result of the last finished sample
Perf.sampling = nil -- state of the running sample

local function num(v)
    if ns.issecret(v) then return nil end
    if type(v) ~= "number" or v ~= v then return nil end
    return v
end

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

local function now()
    return num(call(GetTime)) or 0
end

-- Hot-path counters -----------------------------------------------------------------------------------------------

-- Called by hot code as: local t0 = ns.perfOn and debugprofilestop(); ...; if t0 then ns.Perf.Add("uf", t0) end
function Perf.Add(key, t0)
    local t1 = num(call(debugprofilestop))
    t0 = num(t0)
    if not t1 or not t0 then return end
    local ms = t1 - t0
    if ms < 0 then ms = 0 end
    local s = Perf.stats[key]
    if not s then
        s = { n = 0, total = 0, peak = 0 }
        Perf.stats[key] = s
    end
    s.n = s.n + 1
    s.total = s.total + ms
    if ms > s.peak then s.peak = ms end
end

-- Addon list ------------------------------------------------------------------------------------------------------

local function addonNames()
    local api = C_AddOns
    local count = num(call(api and api.GetNumAddOns or GetNumAddOns)) or 0
    local names, seenOurs = {}, false
    for i = 1, count do
        local ok, name = pcall(function()
            local first
            if api and api.GetAddOnInfo then first = api.GetAddOnInfo(i) elseif GetAddOnInfo then first = GetAddOnInfo(i) end
            if type(first) == "table" then first = first.name end
            return first
        end)
        if ok and type(name) == "string" and not name:find("^Blizzard_") then
            local loaded = call(function()
                if api and api.IsAddOnLoaded then return api.IsAddOnLoaded(name) end
                return IsAddOnLoaded and IsAddOnLoaded(name)
            end)
            if loaded or name == ADDON_NAME then
                names[#names + 1] = name
                if name == ADDON_NAME then seenOurs = true end
            end
        end
    end
    if not seenOurs then names[#names + 1] = ADDON_NAME end
    return names
end

-- CPU source ------------------------------------------------------------------------------------------------------

-- Returns "profiler", "scriptProfile" or nil plus a note for the user.
function Perf.CpuSource()
    local P = C_AddOnProfiler
    local metrics = Enum and Enum.AddOnProfilerMetric
    if type(P) == "table" and type(P.GetAddOnMetric) == "function" and type(metrics) == "table"
        and num(metrics.RecentAverageTime) and num(metrics.SessionAverageTime) then
        local enabled = true
        if type(P.IsEnabled) == "function" then
            local ok, v = pcall(P.IsEnabled)
            if ok and not ns.issecret(v) and v == false then enabled = false end
        end
        if enabled then return "profiler" end
    end
    local cvar = call(GetCVar, "scriptProfile")
    if not ns.issecret(cvar) and cvar == "1" and type(GetAddOnCPUUsage) == "function" then
        return "scriptProfile"
    end
    return nil, "CPU per addon: not available here (no addon profiler in this client and the scriptProfile CVar is off;"
        .. " '/console scriptProfile 1' then /reload turns it on, but it slows the game, so turn it off again after)"
end

local function profilerMetric(name, metricKey)
    local metrics = Enum and Enum.AddOnProfilerMetric
    local id = metrics and num(metrics[metricKey])
    if not id then return nil end
    return num(call(C_AddOnProfiler.GetAddOnMetric, name, id))
end

-- Snapshot --------------------------------------------------------------------------------------------------------

-- { cpuSource, cpuNote, memNote, rows = { { name, mem (KB|nil), cpu (ms|nil), cpuRecent, cpuPeak, ours } }, ours = row }
function Perf.Snapshot()
    local snap = { rows = {} }
    local source, note = Perf.CpuSource()
    snap.cpuSource, snap.cpuNote = source, note

    local haveMem = type(GetAddOnMemoryUsage) == "function"
    if haveMem and not ns.InCombat() then
        call(UpdateAddOnMemoryUsage)
    elseif haveMem then
        snap.memNote = "memory as of the last update (not refreshed in combat)"
    else
        snap.memNote = "memory per addon: not available in this client"
    end
    if source == "scriptProfile" then call(UpdateAddOnCPUUsage) end

    for _, name in ipairs(addonNames()) do
        local row = { name = name, ours = name == ADDON_NAME }
        if haveMem then row.mem = num(call(GetAddOnMemoryUsage, name)) end
        if source == "profiler" then
            row.cpu = profilerMetric(name, "SessionAverageTime")
            row.cpuRecent = profilerMetric(name, "RecentAverageTime")
            row.cpuPeak = profilerMetric(name, "PeakTime")
        elseif source == "scriptProfile" then
            row.cpu = num(call(GetAddOnCPUUsage, name)) -- total ms since reload / reset
        end
        snap.rows[#snap.rows + 1] = row
        if row.ours then snap.ours = row end
    end
    local byCpu = source ~= nil
    table.sort(snap.rows, function(a, b)
        local x, y
        if byCpu then x, y = a.cpu or -1, b.cpu or -1 else x, y = a.mem or -1, b.mem or -1 end
        if x ~= y then return x > y end
        return a.name < b.name
    end)
    for i, row in ipairs(snap.rows) do row.rank = i end
    return snap
end

-- Formatting ------------------------------------------------------------------------------------------------------

local function memText(kb)
    if not kb then return "?" end
    if kb >= 1024 then return string.format("%.1f MB", kb / 1024) end
    return string.format("%d KB", math.floor(kb + 0.5))
end

local function fmtMem(kb) return "mem " .. memText(kb) end

local function fmtCpu(row, source)
    if source == "profiler" then
        if not row.cpu then return "cpu ?" end
        return string.format("cpu %.3f ms/frame (recent %.3f, peak %.1f)", row.cpu, row.cpuRecent or 0, row.cpuPeak or 0)
    elseif source == "scriptProfile" then
        if not row.cpu then return "cpu ?" end
        return string.format("cpu %.0f ms total", row.cpu)
    end
    return nil
end

local function rowLine(row, source)
    local cpu = fmtCpu(row, source)
    return string.format("%2d. %s%s  %s%s", row.rank, row.name, row.ours and " (us)" or "",
        cpu and (cpu .. "  ") or "", fmtMem(row.mem))
end

function Perf.HotPathLines(stats, seconds)
    local out = {}
    for _, p in ipairs(Perf.PATHS) do
        local s = stats and stats[p.key]
        if s and s.n > 0 then
            out[#out + 1] = string.format("  %s: %d runs, avg %.3f ms, peak %.2f ms, total %.1f ms%s", p.label, s.n,
                s.total / s.n, s.peak, s.total, (seconds and seconds > 0) and string.format(" (%.2f ms/s)", s.total / seconds) or "")
        end
    end
    if #out == 0 then out[1] = "  (none of our timed code ran)" end
    return out
end

-- Lines for /hf perf, /hf report and /hf copy.
function Perf.Lines(topN)
    topN = topN or Perf.TOP_N
    local out = {}
    local snap = Perf.Snapshot()
    local source = snap.cpuSource
    if source == "profiler" then
        out[#out + 1] = "Addons by CPU (game addon profiler, average ms per frame since /reload):"
    elseif source == "scriptProfile" then
        out[#out + 1] = "Addons by CPU (scriptProfile is ON, total ms since /reload; turn it off when done, it slows the game):"
    else
        out[#out + 1] = "Addons by memory:"
        out[#out + 1] = snap.cpuNote
    end
    if snap.memNote then out[#out + 1] = snap.memNote end
    local shownOurs = false
    for i = 1, math.min(topN, #snap.rows) do
        local row = snap.rows[i]
        out[#out + 1] = rowLine(row, source)
        if row.ours then shownOurs = true end
    end
    if not shownOurs and snap.ours then
        out[#out + 1] = "..."
        out[#out + 1] = rowLine(snap.ours, source)
    end
    out[#out + 1] = string.format("%d addons loaded (Blizzard's own not counted).", #snap.rows)
    if Perf.sampling then
        out[#out + 1] = string.format("A sample is running (%d s so far). /hf perf stop ends it.",
            math.floor(now() - Perf.sampling.started))
    end
    local last = Perf.last
    if last then
        out[#out + 1] = string.format("Last sample: %d s%s", math.floor(last.seconds),
            last.combat and " (included combat)" or "")
        for _, line in ipairs(Perf.SampleLines(last)) do out[#out + 1] = line end
    else
        out[#out + 1] = "No timing sample yet (/hf perf start [seconds] measures our own code while you play)."
    end
    return out
end

-- Sampling --------------------------------------------------------------------------------------------------------

local function ourMemory()
    if type(GetAddOnMemoryUsage) ~= "function" then return nil end
    if not ns.InCombat() then call(UpdateAddOnMemoryUsage) end
    return num(call(GetAddOnMemoryUsage, ADDON_NAME))
end

local function sampleTick()
    local s = Perf.sampling
    if not s then return end
    if ns.InCombat() then s.combat = true end
    if Perf.CpuSource() == "profiler" then
        local v = profilerMetric(ADDON_NAME, "RecentAverageTime")
        if v then
            s.cpuN = s.cpuN + 1
            s.cpuTotal = s.cpuTotal + v
            if v > s.cpuPeak then s.cpuPeak = v end
        end
    end
    if now() - s.started >= s.window then Perf.Stop() end
end

function Perf.Start(seconds)
    if Perf.sampling then return false, "A sample is already running. /hf perf stop ends it." end
    if type(debugprofilestop) ~= "function" then
        return false, "This client has no debugprofilestop(); our own timings can't be measured."
    end
    local window = tonumber(seconds) or Perf.DEFAULT_WINDOW
    window = math.max(Perf.MIN_WINDOW, math.min(Perf.MAX_WINDOW, math.floor(window)))
    Perf.stats = {}
    Perf.sampling = { started = now(), window = window, cpuN = 0, cpuTotal = 0, cpuPeak = 0,
        combat = ns.InCombat(), memStart = ourMemory() }
    if C_Timer and C_Timer.NewTicker then
        Perf.sampling.ticker = call(C_Timer.NewTicker, Perf.SAMPLE_EVERY, sampleTick)
    end
    ns.perfOn = true
    return true, window
end

-- Ends the sample and stores the result in Perf.last; returns it (nil when nothing was running).
function Perf.Stop()
    local s = Perf.sampling
    if not s then return nil end
    ns.perfOn = nil
    Perf.sampling = nil
    if s.ticker and s.ticker.Cancel then pcall(s.ticker.Cancel, s.ticker) end
    local result = {
        seconds = math.max(0, now() - s.started), combat = s.combat or ns.InCombat(),
        stats = Perf.stats, memStart = s.memStart, memEnd = ourMemory(),
        cpuAvg = s.cpuN > 0 and (s.cpuTotal / s.cpuN) or nil, cpuPeak = s.cpuN > 0 and s.cpuPeak or nil,
    }
    Perf.stats = {}
    Perf.last = result
    ns:Print("Perf sample finished (" .. math.floor(result.seconds) .. " s):")
    for _, line in ipairs(Perf.SampleLines(result)) do ns:Print(line) end
    return result
end

function Perf.SampleLines(result)
    local out = {}
    if result.cpuAvg then
        out[#out + 1] = string.format("  Healer Forever cpu: avg %.3f ms/frame, peak %.3f (recent average read every %d s)",
            result.cpuAvg, result.cpuPeak or 0, Perf.SAMPLE_EVERY)
    end
    if result.memStart and result.memEnd then
        out[#out + 1] = string.format("  Healer Forever memory: %s -> %s", memText(result.memStart), memText(result.memEnd))
    end
    for _, line in ipairs(Perf.HotPathLines(result.stats, result.seconds)) do out[#out + 1] = line end
    return out
end

-- /hf perf [start [seconds]|stop]
function Perf.Slash(arg)
    local sub, rest = (arg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if sub == "start" then
        local ok, info = Perf.Start(rest ~= "" and rest or nil)
        if ok then
            ns:Print("Perf sample started for " .. info .. " s. Play normally; /hf perf stop ends it early.")
        else
            ns:Print(info)
        end
    elseif sub == "stop" then
        if not Perf.Stop() then ns:Print("No perf sample is running. /hf perf start [seconds] starts one.") end
    elseif sub == "" then
        for _, line in ipairs(Perf.Lines()) do ns:Print(line) end
    else
        ns:Print("/hf perf | /hf perf start [seconds] | /hf perf stop")
    end
end
