local ADDON_NAME, ns = ...

-- Support report and /hf mark snapshots. Everything is pcall'd, reads no protected state and no aura data in combat,
-- and never includes other players' names.
local Report = {}
ns.Report = Report

Report.EMAIL = "healer.forever.trtg@gmail.com"
local MAX_MARKS = 5
local MAX_ERRORS = 20
local MAX_LINES_PER_RUN = 80

local function stamp(t)
    if date and t then return date("%Y-%m-%d %H:%M:%S", t) end
    return "?"
end

local function safe(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
    return nil
end

local function text(v)
    if ns.issecret(v) then return "<secret>" end
    if v == nil then return "?" end
    return tostring(v)
end

-- Runs fn while collecting everything it prints; nothing reaches the chat frame.
local function capture(fn)
    local lines = {}
    local realPrint = ns.Print
    ns.Print = function(_, msg) lines[#lines + 1] = tostring(msg) end
    local ok, err = pcall(fn)
    ns.Print = realPrint
    if not ok then lines[#lines + 1] = "failed: " .. tostring(err) end
    return lines
end

local function auraDebugLines()
    return capture(function()
        local units = ns.UnitFrames and ns.UnitFrames.MEMBER_UNITS or {}
        for _, unit in ipairs(units) do
            if ns.Exists(unit) then
                local ok, lines = pcall(ns.Auras.Debug, unit)
                if ok then
                    for _, line in ipairs(lines) do ns:Print(line) end
                else
                    ns:Print(unit .. ": debug failed: " .. tostring(lines))
                end
            end
        end
    end)
end

local function buffDebugLines()
    return capture(function() ns.BuffButtons:Debug() end)
end

local function groupSize()
    if ns.InGroup() then return GetNumGroupMembers and GetNumGroupMembers() or 0 end
    return 1
end

-- Marks ----------------------------------------------------------------------------------------------------------

function Report.Mark(note)
    if not ns.db then return end
    if type(ns.db.marks) ~= "table" then ns.db.marks = {} end
    local mark = {
        time = time and time() or 0,
        note = (note and note ~= "") and note or nil,
        combat = ns.InCombat(),
        zone = safe(GetRealZoneText) or "?",
        group = groupSize(),
        auras = auraDebugLines(),
        buffs = buffDebugLines(),
    }
    local list = ns.db.marks
    list[#list + 1] = mark
    while #list > MAX_MARKS do table.remove(list, 1) end
    return mark
end

function Report.ClearMarks()
    if ns.db then ns.db.marks = {} end
end

-- Report text -----------------------------------------------------------------------------------------------------

local function settingsSummary(out)
    local db = ns.db
    if not db then return end
    local f, a, r, b = db.frames or {}, db.auras or {}, (db.frames or {}).range or {}, db.buffs or {}
    out[#out + 1] = string.format("Frames: layout=%s width=%s height=%s spacing=%s iconSize=%s colorMode=%s border=%s",
        text(f.layout), text(f.width), text(f.height), text(f.spacing), text(f.iconSize), text(f.colorMode),
        text(f.border and f.border.style))
    out[#out + 1] = string.format("Range: style=%s dim=%s badge=%s", text(r.style), text(r.dim), text(r.badge))
    out[#out + 1] = string.format("Auras: buffs=%s/%s size=%s pos=%s | debuffs=%s/%s size=%s pos=%s | perRow=%s grow=%s timer=%s onlyMine=%s onlyDispellable=%s colorBorder=%s tooltipIcons=%s",
        text(a.showBuffs), text(a.maxBuffs), text(a.buffSize), text(a.buffPosition), text(a.showDebuffs),
        text(a.maxDebuffs), text(a.debuffSize), text(a.debuffPosition), text(a.perRow), text(a.grow),
        text(a.timerPos), text(a.onlyMine), text(a.onlyDispellable), text(a.colorDebuffBorder), text(a.tooltipIcons))
    out[#out + 1] = string.format("Buffs: warn=%s threshold=%s rebuffPercent=%s showSolo=%s", text(b.warn),
        text(b.threshold), text(b.rebuffPercent), text(b.showSolo))
    local rd = db.raid or {}
    out[#out + 1] = string.format("Raid: mode=%s onlyAbove5=%s scale=%s size=%sx%s spacing=%s groups=%s/%s labels=%s sort=%s hideEmpty=%s names=%s healthText=%s rangeAlpha=%s",
        text(rd.layoutMode), text(rd.onlyAbove5), text(rd.scale), text(rd.width), text(rd.height), text(rd.spacing),
        text(rd.groupArrange), text(rd.groupsPerLine), text(rd.groupLabels), text(rd.sortWithin), text(rd.hideEmptyGroups),
        text(rd.showNames), text(rd.healthText), text(rd.rangeAlpha))
    out[#out + 1] = string.format("Presets: %d (active %s) | click bindings: %d | pins=%s minimapButton=%s",
        type(db.presets) == "table" and #db.presets or 0, text(db.activePreset),
        (function() local n = 0; if type(db.bindings) == "table" then for _ in pairs(db.bindings) do n = n + 1 end end; return n end)(), text(db.pins and db.pins.enabled),
        text(db.minimap and not db.minimap.hide))
end

local function addonList(out)
    local api = C_AddOns
    local count = (api and api.GetNumAddOns and api.GetNumAddOns()) or (GetNumAddOns and GetNumAddOns()) or 0
    local listed = 0
    for i = 1, count do
        local name = safe(function()
            local first
            if api and api.GetAddOnInfo then first = api.GetAddOnInfo(i) elseif GetAddOnInfo then first = GetAddOnInfo(i) end
            if type(first) == "table" then first = first.name end
            return first
        end)
        if type(name) == "string" and name ~= ADDON_NAME and not name:find("^Blizzard_") then
            local loaded = safe(function()
                if api and api.IsAddOnLoaded then return api.IsAddOnLoaded(name) end
                return IsAddOnLoaded and IsAddOnLoaded(name)
            end)
            if loaded then
                local version = safe(function()
                    if api and api.GetAddOnMetadata then return api.GetAddOnMetadata(name, "Version") end
                    return GetAddOnMetadata and GetAddOnMetadata(name, "Version")
                end)
                listed = listed + 1
                if listed <= 100 then
                    out[#out + 1] = "  " .. name .. ((type(version) == "string" and version ~= "") and (" " .. version) or "")
                end
            end
        end
    end
    if listed > 100 then out[#out + 1] = "  ... and " .. (listed - 100) .. " more" end
    if listed == 0 then out[#out + 1] = "  (none)" end
end

local function section(out, title, fn)
    out[#out + 1] = ""
    out[#out + 1] = "== " .. title .. " =="
    local ok, err = pcall(fn)
    if not ok then out[#out + 1] = "failed: " .. tostring(err) end
end

function Report.Build()
    local out = {}
    out[#out + 1] = "Paste this into your email to " .. Report.EMAIL
    out[#out + 1] = ""
    section(out, "Addon", function()
        out[#out + 1] = "Healer Forever " .. ns.AddonVersion() .. " (settings schema " .. ns.SchemaVersion() .. ")"
        out[#out + 1] = "Aura path: " .. ((ns.Auras and ns.Auras.mode == "container") and "container (native)" or "fallback (hand-drawn)")
    end)
    section(out, "Game", function()
        local version, build, _, toc = GetBuildInfo()
        out[#out + 1] = string.format("Client: %s (build %s, interface %s), locale %s, %s", text(version), text(build),
            text(toc), text(GetLocale and GetLocale()), ns.IsMac() and "Mac" or "Windows")
        local class = ns.PlayerClass()
        local level = safe(UnitLevel, "player")
        local spec
        local index = GetSpecialization and safe(GetSpecialization)
        if index and GetSpecializationInfo then spec = select(2, GetSpecializationInfo(index)) end
        out[#out + 1] = string.format("Player: %s%s, level %s", text(class), spec and (" (" .. text(spec) .. ")") or "", text(level))
        local raid = ns.InRaid() -- secret-safe: IsInRaid() can be a secret value (no truth test on it)
        out[#out + 1] = string.format("Group: %s, size %d, combat: %s", raid and "raid" or (ns.InGroup() and "party" or "solo"),
            groupSize(), tostring(ns.InCombat()))
        local RF = ns.RaidFrames
        out[#out + 1] = RF and RF:StatusLine() or "Layout: party (raid frames not loaded)"
    end)
    section(out, "Settings summary", function() settingsSummary(out) end)
    section(out, "Performance (/hf perf)", function()
        for _, line in ipairs(ns.Perf.Lines()) do out[#out + 1] = line end
    end)
    section(out, "Other loaded addons", function() addonList(out) end)
    section(out, "Last errors", function()
        local errors = ns.FormatErrors(MAX_ERRORS)
        if #errors == 0 then out[#out + 1] = "none" end
        for _, line in ipairs(errors) do out[#out + 1] = line end
    end)
    section(out, "Debug runs", function()
        local log = ns.db and ns.db.debugLog or {}
        if #log == 0 then out[#out + 1] = "none (run /hf debug buffs | auras first)" end
        for _, run in ipairs(log) do
            out[#out + 1] = "-- /hf debug " .. tostring(run.cmd) .. " (" .. stamp(run.time) .. ")"
            for i, line in ipairs(run.lines or {}) do
                if i > MAX_LINES_PER_RUN then out[#out + 1] = "   ..."; break end
                out[#out + 1] = tostring(line)
            end
        end
    end)
    section(out, "Marks (/hf mark)", function()
        local marks = ns.db and ns.db.marks or {}
        if #marks == 0 then out[#out + 1] = "none" end
        for i, m in ipairs(marks) do
            out[#out + 1] = string.format("-- mark %d: %s%s | combat=%s zone=%s group=%s", i, stamp(m.time),
                m.note and (" | " .. tostring(m.note)) or "", tostring(m.combat), tostring(m.zone), tostring(m.group))
            out[#out + 1] = "   auras:"
            for _, line in ipairs(m.auras or {}) do out[#out + 1] = "   " .. tostring(line) end
            out[#out + 1] = "   buffs:"
            for _, line in ipairs(m.buffs or {}) do out[#out + 1] = "   " .. tostring(line) end
        end
    end)
    return table.concat(out, "\n")
end

function Report.Show()
    ns.CopyWindow:ShowText(Report.Build(), "Healer Forever report - select all (Cmd/Ctrl+A), copy (Cmd/Ctrl+C), paste into your email")
end
