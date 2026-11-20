local ADDON_NAME, ns = ...

local Util = ns.Util

ns.issecret = issecretvalue or function() return false end

ns.DEFAULTS = {
    version = 4,
    activePreset = 1,
    presets = Util.DeepCopy(ns.Presets.DEFAULTS),
    frames = {
        layout = "horizontal",
        width = 180,
        height = 44,
        iconSize = 20,
        colorMode = "class",
        customColor = { r = 0.2, g = 0.8, b = 0.33 },
        healthText = "percent",
        showPower = true,
        showPrediction = true,
        showOverheal = true,
        showPets = true,
        showPlayer = true,
        showRoleIcon = true,
        locked = false,
        lowHpPulse = false,
        -- threat strip above the health bar (party members only); off by default so older party frames look the same
        showThreatBar = false,
        threatBarHeight = 3,
        threatBarOnlyCombat = true,
        threatBarShowSafe = false,   -- green strip for level 0 (in the fight, less threat than the tank)
        range = {
            style = "badge", dim = 72, badge = true, healable = true,
            healableColor = { r = 0.3, g = 0.9, b = 0.4 }, outColor = { r = 0.6, g = 0.6, b = 0.6 },
            hiddenColor = { r = 0.5, g = 0.6, b = 0.75 },
        },
        spacing = 6,
        border = { style = "tooltip", width = 2, color = "black", custom = { r = 1, g = 0.82, b = 0 } },
        sortMode = "manual",
        order = { "player", "party1", "party2", "party3", "party4" },
        point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 60, y = -250 },
    },
    auras = {
        showBuffs = true,
        onlyMine = false,
        showDebuffs = true,
        onlyDispellable = false,
        colorDebuffBorder = true,
        maxBuffs = 4,
        maxDebuffs = 3,
        buffPosition = "top",
        debuffPosition = "bottom",
        buffSize = 16,
        debuffSize = 20,
        perRow = 0,   -- 0 = auto: as many icons per row as fit the bar width
        grow = "right",
        tooltipDebuffs = true,
        tooltipBuffs = false,
        tooltipIcons = true,
        zoneGap = 4,
        timerPos = "below",
    },
    buffs = { warn = true, threshold = 60, showSolo = true, rebuffPercent = 5 },
    resurrectOnClick = true,
    roleOverrides = {},
    smartButton = { show = false, point = { point = "CENTER", relativePoint = "CENTER", x = 0, y = -150 } },
    customSpells = {},
    ui = { modSet = "mac", extraButtons = false },
    -- raid layout (its own settings; the party layout is never changed by them). Validated by
    -- ns.RaidLayout.Normalize in buildDB. No schema bump: older saves simply have no `raid` key.
    raid = {
        layoutMode = "auto", onlyAbove5 = true,
        point = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 60, y = -330 },
        scale = 100, width = 64, height = 24, spacing = 2,
        groupArrange = "columns", groupsPerLine = 8, groupLabels = true,
        sortWithin = "none", hideEmptyGroups = true,
        showNames = true, nameSize = 7, nameLength = 7,
        healthText = "deficit", muteFull = true, showIncoming = true, rangeAlpha = 50,
        buffs = { show = true, size = 10, rebuffPercent = 5, showEnding = true,
            endingLook = "pulse", multi = "state", inCombat = "hide" },
        debuffs = { show = true, display = "glowIcons", max = 3, size = 10 },
    },
    errorLog = {},
    marks = {},
    debugLog = {},
    minimap = { hide = false, angle = 220, badges = true, lockPos = false },
    pins = { enabled = true, showEdge = true, showPets = false, size = 16, showRole = true, showNames = true,
        pulse = true, markCorpse = true },
    -- clean install: only the two interaction defaults (plain Left = target, plain Right = unit menu)
    bindings = {
        ["|1"] = { type = "target" },
        ["|2"] = { type = "menu" },
    },
}

-- Error capture ---------------------------------------------------------------------
-- Every event handler, callback and widget script runs through ns.Safe/ns.Wrap so one error is logged
-- (HealerForeverCharDB.errorLog, capped) and never breaks the rest of the addon.

local MAX_ERRORS = 50
local notedError = false
ns.errorMemory = {}

local function nowSeconds()
    return time and time() or 0
end

function ns.LogError(label, message, stack, kind)
    local log = (ns.db and type(ns.db.errorLog) == "table") and ns.db.errorLog or ns.errorMemory
    local text = tostring(message)
    local last = log[#log]
    if last and last.msg == text and last.label == label then
        last.count = (last.count or 1) + 1
        last.time = nowSeconds()
        return
    end
    log[#log + 1] = {
        time = nowSeconds(), label = tostring(label), msg = text, stack = stack and tostring(stack) or nil,
        combat = InCombatLockdown and InCombatLockdown() or false, kind = kind or "error", count = 1,
    }
    while #log > MAX_ERRORS do table.remove(log, 1) end
    -- forward each new distinct error once so BugSack-style displays still see it
    if kind ~= "blocked" and geterrorhandler then
        local handler = geterrorhandler()
        if type(handler) == "function" then pcall(handler, text) end
    end
    if not notedError and kind ~= "blocked" then
        notedError = true
        if ns.Print then ns:Print("an error was logged (not shown): /hf errors") end
    end
end

-- Debug output capture -----------------------------------------------------------------------------------------
-- The last 10 /hf debug runs are kept in HealerForeverCharDB.debugLog ({ time, cmd, lines }) so the output can be
-- read from the saved file or copied from the copy window (WoW chat text cannot be copied).
local MAX_DEBUG_RUNS = 10

function ns.StoreDebug(cmd, lines)
    if not ns.db then return end
    if type(ns.db.debugLog) ~= "table" then ns.db.debugLog = {} end
    local log = ns.db.debugLog
    log[#log + 1] = { time = nowSeconds(), cmd = tostring(cmd), lines = lines }
    while #log > MAX_DEBUG_RUNS do table.remove(log, 1) end
end

-- Runs fn while collecting everything it prints through ns:Print; the lines are still printed and then stored.
function ns.RunDebug(cmd, fn)
    local lines = {}
    local realPrint = ns.Print
    ns.Print = function(self, msg)
        lines[#lines + 1] = tostring(msg)
        return realPrint(self, msg)
    end
    local ok, err = pcall(fn)
    ns.Print = realPrint
    if not ok then lines[#lines + 1] = "failed: " .. tostring(err) end
    ns.StoreDebug(cmd, lines)
    return lines
end

function ns.ClearDebug()
    if ns.db then ns.db.debugLog = {} end
end

-- Error log as plain text lines (shared by /hf errors and the copy window).
function ns.FormatErrors(limit)
    local log = ns.db and ns.db.errorLog or {}
    local out = {}
    for i = math.max(1, #log - (limit or 10) + 1), #log do
        local e = log[i]
        if type(e) == "table" then
            out[#out + 1] = string.format("[%s] %s%s (%s)%s: %s", date and date("%H:%M:%S", e.time or 0) or "?",
                e.kind == "blocked" and "BLOCKED " or "", tostring(e.label), e.combat and "combat" or "no combat",
                (e.count or 1) > 1 and (" x" .. e.count) or "", tostring(e.msg))
            if e.stack then out[#out + 1] = "    " .. tostring(e.stack):gsub("\n", "\n    ") end
        end
    end
    return out
end

-- Text for the copy window: the last debug run (with its command and time) followed by the error log.
function ns.CopyText()
    local parts = {}
    local log = ns.db and ns.db.debugLog or {}
    local last = log[#log]
    if last then
        parts[#parts + 1] = "== /hf debug " .. tostring(last.cmd) .. " ("
            .. (date and date("%H:%M:%S", last.time or 0) or "?") .. ") =="
        for _, line in ipairs(last.lines or {}) do parts[#parts + 1] = tostring(line) end
    else
        parts[#parts + 1] = "== no debug output yet (run /hf debug buffs | auras | click) =="
    end
    parts[#parts + 1] = ""
    local errors = ns.FormatErrors(20)
    parts[#parts + 1] = "== /hf errors (" .. #errors .. " lines) =="
    for _, line in ipairs(errors) do parts[#parts + 1] = line end
    if ns.Perf then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "== /hf perf =="
        local ok, lines = pcall(ns.Perf.Lines)
        if ok then
            for _, line in ipairs(lines) do parts[#parts + 1] = tostring(line) end
        else
            parts[#parts + 1] = "failed: " .. tostring(lines)
        end
    end
    return table.concat(parts, "\n")
end

local function errorHandler(label)
    return function(message)
        ns.LogError(label, message, debugstack and debugstack(3, 8, 0) or nil)
        return message
    end
end

local handlerCache = {}
local function handlerFor(label)
    local h = handlerCache[label]
    if not h then
        h = errorHandler(label)
        handlerCache[label] = h
    end
    return h
end

-- Calls fn with up to 5 arguments without letting an error escape; returns ok, result.
local curFn, a1, a2, a3, a4, a5
local function invoke()
    return curFn(a1, a2, a3, a4, a5)
end

function ns.Safe(label, fn, ...)
    local f, b1, b2, b3, b4, b5 = fn, ...
    curFn, a1, a2, a3, a4, a5 = f, b1, b2, b3, b4, b5
    return xpcall(invoke, handlerFor(label))
end

-- Wraps a function so errors are logged instead of propagating.
function ns.Wrap(label, fn)
    return function(x1, x2, x3, x4, x5)
        curFn, a1, a2, a3, a4, a5 = fn, x1, x2, x3, x4, x5
        local ok, result = xpcall(invoke, handlerFor(label))
        if ok then return result end
    end
end

-- Wrapped script helpers for SECURE frames: our own Lua handlers are wrapped explicitly at the call site, while
-- the frame's SetScript/HookScript are never overridden (Blizzard's SecureHandler code installs restricted
-- closures through them, and those must never pass through ns.Wrap / xpcall).
function ns.SecureHook(frame, name, fn)
    return frame:HookScript(name, ns.Wrap(name, fn))
end

function ns.SecureSetScript(frame, name, fn)
    return frame:SetScript(name, ns.Wrap(name, fn))
end

-- CreateFrame whose SetScript/HookScript handlers are wrapped with ns.Wrap. Frames made from a secure template
-- (or any protected frame) are left untouched; use ns.SecureHook / ns.SecureSetScript for those.
function ns.NewFrame(...)
    local template = select(4, ...)
    local frame = CreateFrame(...)
    local secure = type(template) == "string" and template:find("Secure", 1, true) ~= nil
    if frame and not secure and frame.IsProtected then
        local ok, protected = pcall(frame.IsProtected, frame)
        secure = ok and protected and true or false
    end
    if frame and not secure and not frame.hfWrapped then
        local rawSet, rawHook = frame.SetScript, frame.HookScript
        if rawSet and rawHook then
            local ok = pcall(function()
                frame.SetScript = function(self, name, fn)
                    if type(fn) == "function" then fn = ns.Wrap(name, fn) end
                    return rawSet(self, name, fn)
                end
                frame.HookScript = function(self, name, fn)
                    if type(fn) == "function" then fn = ns.Wrap(name, fn) end
                    return rawHook(self, name, fn)
                end
                frame.hfWrapped = true
            end)
            if not ok then frame.hfWrapped = nil end
        end
    end
    return frame
end

-- Callbacks -----------------------------------------------------------------

local callbacks = {}

function ns:On(msg, fn)
    callbacks[msg] = callbacks[msg] or {}
    table.insert(callbacks[msg], fn)
end

function ns:Fire(msg, ...)
    local list = callbacks[msg]
    if not list then return end
    for i = 1, #list do
        ns.Safe("callback:" .. msg, list[i], ...)
    end
end

-- Events --------------------------------------------------------------------

local handlers = {}
local eventFrame

local function dispatch(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        ns.Safe(event, list[i], event, ...)
    end
end

local function ensureFrame()
    if eventFrame or not CreateFrame then return end
    local ok, frame = pcall(CreateFrame, "Frame", "HealerForeverEventFrame")
    if ok and frame then
        eventFrame = frame
        ns.eventFrame = frame
        frame:SetScript("OnEvent", dispatch)
        for event in pairs(handlers) do
            pcall(frame.RegisterEvent, frame, event)
        end
    end
end

function ns:RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if eventFrame then pcall(eventFrame.RegisterEvent, eventFrame, event) end
    end
    table.insert(handlers[event], fn)
end

-- Helpers -------------------------------------------------------------------

function ns:Print(msg)
    local text = "|cffffd100Healer Forever|r: " .. tostring(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    else
        print(text)
    end
end

-- Existence / group checks that survive secret booleans (a secret answer counts as "yes").
function ns.Exists(unit)
    local ok, value = pcall(UnitExists, unit)
    if not ok then return false end
    if ns.issecret(value) then return true end
    return value and true or false
end

function ns.InGroup()
    if not IsInGroup then return false end
    local ok, value = pcall(IsInGroup)
    if not ok then return false end
    if ns.issecret(value) then return true end
    return value and true or false
end

-- In a raid? A secret answer counts as "yes" (the raid layout then decides from the other checks).
function ns.InRaid()
    if not IsInRaid then return false end
    local ok, value = pcall(IsInRaid)
    if not ok then return false end
    if ns.issecret(value) then return true end
    return value and true or false
end

-- Number of group members (0 when solo). A secret count is treated as a full raid (40).
function ns.GroupSize()
    if not GetNumGroupMembers then return 0 end
    local ok, value = pcall(GetNumGroupMembers)
    if not ok then return 0 end
    if ns.issecret(value) then return 40 end
    if type(value) ~= "number" then return 0 end
    return value
end

-- Instance type from IsInInstance ("none", "party", "raid", "pvp", "arena", "scenario"); secret or unknown -> "none".
function ns.InstanceType()
    if not IsInInstance then return "none" end
    local ok, _, kind = pcall(IsInInstance)
    if not ok or ns.issecret(kind) or type(kind) ~= "string" then return "none" end
    return kind
end

function ns.InCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

function ns.IsMac()
    return IsMacClient and IsMacClient() or false
end

function ns.PlayerClass()
    if UnitClass then
        local _, token = UnitClass("player")
        return token
    end
end

function ns.GetHeldModifierKey()
    return Util.ModifierKey(
        IsShiftKeyDown and IsShiftKeyDown(),
        IsControlKeyDown and IsControlKeyDown(),
        IsAltKeyDown and IsAltKeyDown(),
        IsMetaKeyDown and IsMetaKeyDown())
end

-- Is the spell (name or id) usable by the player?
function ns.SpellKnown(spell)
    if not spell then return false end
    local id = spell
    if type(spell) == "string" then
        -- the spellbook scan is the source of truth for names (ranks / Forever names may differ)
        if ns.Spells and ns.Spells.IsKnownByName and ns.Spells.IsKnownByName(spell) then return true end
        id = nil
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spell)
            id = info and info.spellID
        end
        if not id then return false end
    end
    if IsPlayerSpell and IsPlayerSpell(id) then return true end
    if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(id) then return true end
    if C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(id) then return true end
    if IsSpellKnown and IsSpellKnown(id) then return true end
    if C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell and C_SpellBook.FindSpellBookSlotForSpell(id) then
        return true
    end
    return false
end

function ns.SpellTexture(spell)
    if C_Spell and C_Spell.GetSpellTexture and spell then
        local tex = C_Spell.GetSpellTexture(spell)
        if tex then return tex end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Runs fn now, or after combat ends. A repeated key replaces the queued function.
local queue, queueOrder = {}, {}
function ns:AfterCombat(key, fn, silent)
    if not ns.InCombat() then
        fn()
        return true
    end
    if not queue[key] then queueOrder[#queueOrder + 1] = key end
    queue[key] = fn
    if not silent and not ns.notedQueue then
        ns.notedQueue = true
        ns:Print("Change queued until combat ends.")
    end
    return false
end

for _, blockedEvent in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    ns:RegisterEvent(blockedEvent, function(event, addon, func)
        if addon == ADDON_NAME then
            ns.LogError("taint", event .. ": " .. tostring(func), debugstack and debugstack(2, 6, 0) or nil, "blocked")
        end
    end)
end

ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    ns.notedQueue = nil
    local keys = queueOrder
    local fns = queue
    queue, queueOrder = {}, {}
    for _, key in ipairs(keys) do
        ns.Safe("aftercombat:" .. key, fns[key])
    end
    ns:Fire("COMBAT_ENDED")
end)

function ns:Changed(group)
    ns:Fire("CONFIG_CHANGED", group or "all")
end

function ns:SetActivePreset(index)
    local list = ns.db.presets
    if list[index] then
        ns.db.activePreset = index
        ns:Changed("presets")
    end
end

function ns:CyclePreset()
    local n = #ns.db.presets
    local nextIndex = (ns.db.activePreset % n) + 1
    ns:SetActivePreset(nextIndex)
    ns:Print("Active buff preset: " .. ns.db.presets[nextIndex].name)
end

-- Saved variables -------------------------------------------------------------

local VALID_ACTION_TYPES = { spell = true, target = true, menu = true, macro = true }

-- Drops wrong-typed values compared to the defaults (recursively); user-edited collections are skipped.
local function sanitize(saved, defaults)
    for k, default in pairs(defaults) do
        local value = saved[k]
        if value ~= nil and type(value) ~= type(default) then
            saved[k] = nil
        elseif type(default) == "table" and type(value) == "table"
            and k ~= "presets" and k ~= "bindings" then
            sanitize(value, default)
        end
    end
end

local function validBuff(key)
    return type(key) == "string" and (key == "none" or ns.Classes.BUFFS[key] ~= nil)
end

-- A stored cell: a legacy key string, or a set (array) of buff keys. Unknown keys are dropped.
local function cleanCell(value)
    if type(value) == "string" then
        if validBuff(value) then return value end
        return nil
    elseif type(value) == "table" then
        local out = {}
        for _, key in ipairs(value) do
            if type(key) == "string" and key ~= "none" and ns.Classes.BUFFS[key] ~= nil then out[#out + 1] = key end
        end
        return out
    end
    return nil
end

local function sanitizePresets(presets)
    if type(presets) ~= "table" then return nil end
    local out = {}
    for _, p in ipairs(presets) do
        if type(p) == "table" and type(p.name) == "string" and type(p.map) == "table" then
            local map = {}
            for class, entry in pairs(p.map) do
                if ns.Classes.ROLES[class] then
                    if type(entry) == "string" then entry = { DEFAULT = entry } end
                    if type(entry) == "table" then
                        local clean = {}
                        for role, key in pairs(entry) do
                            local cell = cleanCell(key)
                            if ns.Classes.IsValidRole(class, role) and cell ~= nil then clean[role] = cell end
                        end
                        map[class] = clean
                    end
                end
            end
            local preset = { name = p.name, map = map, extras = {} }
            local selfCell = cleanCell(p.self)
            if selfCell ~= nil then preset.self = selfCell end
            for _, e in ipairs(type(p.extras) == "table" and p.extras or {}) do
                if type(e) == "table" and type(e.spell) == "string" and e.spell ~= "" and type(e.roles) == "table" then
                    local roles = {}
                    for role, on in pairs(e.roles) do
                        if on and (role == "TANK" or role == "HEALER" or role == "DAMAGER" or role == "SELF") then
                            roles[role] = true
                        end
                    end
                    preset.extras[#preset.extras + 1] = { spell = e.spell, roles = roles, single = e.single and true or false }
                end
            end
            out[#out + 1] = ns.Presets.MigratePreset(preset)
        end
    end
    if #out == 0 then return nil end
    return out
end

local function sanitizeBindings(bindings)
    if type(bindings) ~= "table" then return nil end
    local out = {}
    for key, action in pairs(bindings) do
        if type(key) == "string" and ns.Bindings.ParseKey(key) and type(action) == "table"
            and VALID_ACTION_TYPES[action.type] then
            out[key] = action
        end
    end
    return out
end

-- Settings schema migrations: migrations[n] upgrades a profile saved with schema n to n + 1. They run in
-- order, once per step, after the data has been merged with defaults and sanitised.
--   1 -> 2: preset maps became { CLASS = { DEFAULT = ..., TANK = ... } } and extras were added
--           (done by sanitizePresets / Presets.MigratePreset, which are idempotent).
--   2 -> 3: profiles are saved sparsely (only values that differ from the defaults); nothing to convert.
local migrations = {
    [1] = function() end,
    [2] = function() end,
    -- 3 -> 4: a preset cell (and "self") became a SET of buff keys (one per catalog group) instead of one key:
    -- "might" -> { "might" }, "none" / nil -> {}. Presets.MigratePreset converts (idempotent).
    [3] = function(db)
        for _, preset in ipairs(db.presets or {}) do ns.Presets.MigratePreset(preset) end
    end,
}
ns.migrations = migrations

-- Fills missing keys, drops wrong-typed values and invalid user data; mutates and returns the table.
local function buildDB(saved)
    local presets, bindings
    local savedVersion = saved and type(saved.version) == "number" and saved.version or (saved and 1 or nil)
    if saved then
        presets = sanitizePresets(saved.presets)
        bindings = sanitizeBindings(saved.bindings)
        saved.presets, saved.bindings = nil, nil
        sanitize(saved, ns.DEFAULTS)
    end
    local db = Util.MergeDefaults(saved, ns.DEFAULTS)
    -- user-edited collections are never re-filled from defaults
    if presets then
        db.presets = presets
    else
        db.presets = Util.DeepCopy(ns.Presets.DEFAULTS)
        for _, p in ipairs(db.presets) do ns.Presets.MigratePreset(p) end
    end
    if bindings then db.bindings = bindings else db.bindings = Util.DeepCopy(ns.DEFAULTS.bindings) end
    local active = db.activePreset
    if type(active) ~= "number" or active ~= active or active < 1 or active > #db.presets then
        db.activePreset = 1
    else
        db.activePreset = math.floor(active)
    end
    local overrides = {}
    for name, role in pairs(db.roleOverrides) do
        if type(name) == "string" and (role == "TANK" or role == "HEALER" or role == "DAMAGER") then
            overrides[name] = role
        end
    end
    db.roleOverrides = overrides
    -- the removed A/B/C frame style system: drop saved leftovers, validate the rest
    db.appearance = nil
    db.frames.style = nil
    db.ui.appearanceTarget = nil
    db.frames.border = Util.NormalizeBorder(db.frames.border)
    db.frames.spacing = Util.ClampNumber(db.frames.spacing, 0, 24, 6)
    db.frames.range = Util.NormalizeRange(db.frames.range)
    db.frames.threatBarHeight = math.floor(Util.ClampNumber(db.frames.threatBarHeight, 2, 6, 3) + 0.5)
    local a = db.auras
    local function pick(list, value, fallback)
        for _, v in ipairs(list) do
            if v == value then return v end
        end
        return fallback
    end
    a.buffPosition = pick(Util.POSITIONS, a.buffPosition, "top")
    a.debuffPosition = pick(Util.POSITIONS, a.debuffPosition, "bottom")
    a.grow = pick(Util.GROWS, a.grow, "right")
    a.buffSize = Util.ClampNumber(a.buffSize, 10, 28, 16)
    a.debuffSize = Util.ClampNumber(a.debuffSize, 12, 32, 20)
    a.perRow = a.perRow == 0 and 0 or Util.ClampNumber(a.perRow, 2, 10, 0)
    a.zoneGap = Util.ClampNumber(a.zoneGap, 0, 12, 4)
    a.maxBuffs = Util.ClampNumber(a.maxBuffs, 1, 20, 4)
    a.maxDebuffs = Util.ClampNumber(a.maxDebuffs, 1, 12, 3)
    if a.timerPos ~= "inside" then a.timerPos = "below" end
    db.buffs.rebuffPercent = Util.ClampNumber(db.buffs.rebuffPercent, 0, 50, 5)
    if ns.RaidLayout then db.raid = ns.RaidLayout.Normalize(db.raid, ns.DEFAULTS.raid) end
    if type(db.errorLog) ~= "table" then db.errorLog = {} end
    if type(db.marks) ~= "table" then db.marks = {} end
    -- the "hide Blizzard party frames" option was removed (taint risk): drop the saved keys
    db.hideBlizzardParty = nil
    db.taintMigrated = nil

    local current = ns.DEFAULTS.version
    if savedVersion and savedVersion > current then
        -- saved by a newer version of the addon: never migrate backwards, keep the newer version number
        ns.downgradeFrom = savedVersion
        db.version = savedVersion
    else
        for step = savedVersion or current, current - 1 do
            if migrations[step] then migrations[step](db) end
        end
        db.version = current
    end
    return db
end

-- Version -------------------------------------------------------------------------------------------------

function ns.AddonVersion()
    local version
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    elseif GetAddOnMetadata then
        version = GetAddOnMetadata(ADDON_NAME, "Version")
    end
    if type(version) ~= "string" or version == "" or version == "@project-version@" then return "dev" end
    return version
end

function ns.SchemaVersion()
    return ns.DEFAULTS.version
end

-- Sparse saving ---------------------------------------------------------------------------------------------
-- ns.db stays a full table at runtime. On logout only the differences from the defaults are written.

local ATOMIC_KEYS = { bindings = true, presets = true, order = true, point = true, roleOverrides = true,
    customSpells = true, custom = true }

local function normalizedPresets(list)
    local copy = Util.DeepCopy(list or {})
    for _, p in ipairs(copy) do ns.Presets.MigratePreset(p) end
    return copy
end

function ns:BuildSaveTable()
    local out = Util.DiffFromDefaults(ns.db, ns.DEFAULTS, ATOMIC_KEYS)
    if Util.DeepEqual(normalizedPresets(ns.db.presets), normalizedPresets(ns.DEFAULTS.presets)) then
        out.presets = nil
    end
    out.version = ns.db.version
    return out
end

ns:RegisterEvent("PLAYER_LOGOUT", function()
    if ns.db then HealerForeverCharDB = ns:BuildSaveTable() end
end)

local function hasContent(t)
    return type(t) == "table" and next(t) ~= nil
end

-- The player's class token, read safely at load: nil when the API is missing, errors, returns a secret or an
-- unknown class. Callers treat nil as "can't tell" and change nothing.
local function playerClassToken()
    if not UnitClass then return nil end
    local ok, _, token = pcall(UnitClass, "player")
    if not ok or ns.issecret(token) or type(token) ~= "string" then return nil end
    if not ns.Classes.ROLES[token] then return nil end
    return token
end
ns.PlayerClassToken = playerClassToken

local function cellHasForeign(cell, allowed)
    if type(cell) == "string" then
        return cell ~= "none" and not allowed[cell]
    elseif type(cell) == "table" then
        for _, key in ipairs(cell) do
            if type(key) == "string" and key ~= "none" and not allowed[key] then return true end
        end
    end
    return false
end

-- True when any preset cell (class/role rules or "Self") holds a buff key the given caster class can't cast.
-- Pure; used to spot another class's presets copied in from the old account-wide settings.
function ns.PresetsHaveForeignBuffs(presets, classToken)
    if type(presets) ~= "table" or type(classToken) ~= "string" then return false end
    local allowed = {}
    for _, key in ipairs(ns.Classes.CatalogBuffs(classToken)) do allowed[key] = true end
    for _, p in ipairs(presets) do
        if type(p) == "table" then
            if cellHasForeign(p.self, allowed) then return true end
            for _, entry in pairs(type(p.map) == "table" and p.map or {}) do
                if type(entry) == "table" then
                    for _, cell in pairs(entry) do
                        if cellHasForeign(cell, allowed) then return true end
                    end
                end
            end
        end
    end
    return false
end

-- Buff presets and click-casting back to the clean-install defaults; everything else is kept.
local function resetPresetsAndBindings(db)
    db.presets = Util.DeepCopy(ns.Presets.DEFAULTS)
    for _, p in ipairs(db.presets) do ns.Presets.MigratePreset(p) end
    db.activePreset = 1
    db.bindings = Util.DeepCopy(ns.DEFAULTS.bindings)
end

ns.FOREIGN_SEED_CLEARED_MSG = "this character had another class's buff presets and click-casting copied from an old "
    .. "account-wide setup; they were cleared."

-- One-time cleanup (0.12.1) for characters that older versions seeded from the account-wide settings of a
-- different class (e.g. a new Druid that got the Paladin's blessings and Holy Light bindings). Only runs when the
-- profile is marked migratedFrom = "account" AND its presets hold buffs this class can't cast; then presets and
-- bindings go back to the defaults and the marker becomes "account-cleared" so it never runs again. A matching
-- class (the owner's Paladin) or an unreadable class changes nothing at all.
local function cleanForeignSeed(db)
    if db.migratedFrom ~= "account" then return false end
    local class = playerClassToken()
    if not class or not ns.PresetsHaveForeignBuffs(db.presets, class) then return false end
    resetPresetsAndBindings(db)
    db.migratedFrom = "account-cleared"
    ns:Print(ns.FOREIGN_SEED_CLEARED_MSG)
    return true
end

-- Settings are per character (HealerForeverCharDB). A character without saved settings starts from the clean
-- defaults (0.12.1, owner decision 2026-11-20); the legacy account-wide HealerForeverDB is no longer copied in
-- automatically, only on request with /hf copyaccount. HealerForeverDB is never modified.
function ns:Init()
    local char = HealerForeverCharDB
    if type(char) ~= "table" then char = nil end
    ns.db = buildDB(char)
    HealerForeverCharDB = ns.db
    if ns.downgradeFrom then
        ns:Print("your saved settings come from a newer version (schema " .. ns.downgradeFrom
            .. " > " .. ns.DEFAULTS.version .. "); they are kept untouched but some options may be ignored.")
    end
    cleanForeignSeed(ns.db)
    ns:Fire("INIT")
end

function ns:ProfileName()
    local name = UnitName and UnitName("player") or "?"
    local realm = GetRealmName and GetRealmName() or "?"
    return name .. "-" .. realm
end

-- Replaces this character's settings with a copy of the account-wide ones (/hf copyaccount confirm).
-- Returns false if none exist. If the copied buff presets hold buffs this class can't cast, the presets and
-- click-casting are NOT taken (they stay at the defaults) and the second return value is true.
function ns:ImportAccount()
    if not hasContent(HealerForeverDB) then return false end
    local copy = Util.DeepCopy(HealerForeverDB)
    copy.migratedFrom = "account"
    local db = buildDB(copy)
    local skipped = false
    local class = playerClassToken()
    if class and ns.PresetsHaveForeignBuffs(db.presets, class) then
        resetPresetsAndBindings(db)
        skipped = true
    end
    ns.db = db
    HealerForeverCharDB = ns.db
    ns:Changed("all")
    return true, skipped
end

function ns:ResetDB()
    ns.db = buildDB(nil)
    HealerForeverCharDB = ns.db
    ns:Changed("all")
end

ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == ADDON_NAME then
        ns:Init()
    end
end)

ensureFrame()
