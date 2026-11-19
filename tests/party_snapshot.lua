-- Party golden snapshot: a deterministic, serialisable picture of everything the PARTY frames put on screen and into the
-- secure environment (attributes, macros, snippets, state drivers, unit watch, geometry, colours, texts, aura containers,
-- missing-buff buttons, smart/tank buttons). Used by test_party_golden.lua (and later test_raid_upgrade.lua) to prove the
-- party layout stays byte-for-byte identical while other features (the raid layout) are added.
--
-- PS.snapshotParty(ns) -> { lines = { "..." }, strings = { [id] = longText } }
--   lines: one line per fact, in a fixed order (party frames subtree in creation order, then smart / tank buttons).
--   strings: long texts (secure snippets) are interned under a content hash id so the lines stay short.
-- Pairs-order noise is removed: the click-cast override slots (HFB1, HFB2, ...) and the numbered Cmd / dead-swap entries
-- (hf-mtypeN, hf-dtypeN, ...) are numbered by `pairs` over the bindings, which differs between LuaJIT processes; they are
-- rewritten to keys named after their binding key (HFB<META-BUTTON2>) and sorted. Everything else is kept verbatim.
local mock = require("wow_mock")
local L = require("loader")
local Fx = require("fixtures")
local bit = require("bit")

local PS = {}

local function st(f) return rawget(f, "__s") end
local function isFrame(v) return type(v) == "table" and rawget(v, "__s") ~= nil end

-- ------------------------------------------------------------------ value formatting
local function hash(s)
    local h = 5381
    for i = 1, #s do h = bit.band(bit.bxor(h * 33, s:byte(i)), 0x7fffffff) end
    return string.format("%08x", h)
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
        return type(a) < type(b)
    end)
    return keys
end

local function newCtx()
    return { names = {}, strings = {}, lines = {} }
end

local fmt
local function fmtNumber(v)
    if v ~= v then return "nan" end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    local txt = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
    return txt
end

fmt = function(ctx, v, depth)
    depth = depth or 0
    if mock.isSecret(v) then return "<secret>" end
    local t = type(v)
    if v == nil then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then return fmtNumber(v) end
    if t == "string" then
        if #v > 100 and v:find("\n", 1, true) then   -- secure snippets: interned by content hash
            local id = hash(v) .. ":" .. #v
            ctx.strings[id] = v
            return "str<" .. id .. ">"
        end
        return '"' .. v:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub('"', '\\"') .. '"'
    end
    if t == "function" then return "fn" end
    if isFrame(v) then
        local n = ctx.names[v]
        if n then return "@" .. n end
        local s = st(v)
        return "@" .. tostring(s.name or ("<" .. s.kind .. ">"))
    end
    if t == "table" then
        if depth > 3 then return "{...}" end
        local parts = {}
        for _, k in ipairs(sortedKeys(v)) do
            parts[#parts + 1] = (type(k) == "string" and k or ("[" .. fmt(ctx, k) .. "]")) .. "=" .. fmt(ctx, v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "<" .. t .. ">"
end

local function color(ctx, c)
    if c == nil then return nil end
    return "(" .. fmt(ctx, c.r) .. "," .. fmt(ctx, c.g) .. "," .. fmt(ctx, c.b) .. "," .. fmt(ctx, c.a) .. ")"
end

-- ------------------------------------------------------------------ attribute canonicalisation
local META_FIELDS = { "mtype", "mmac", "mtext", "motype", "momac" }
local DEAD_FIELDS = { "dtype", "dmac", "dorig", "dtext" }

-- Returns a sorted list of { name, value } with pairs-order numbering replaced by stable keys.
function PS.canonicalAttrs(attrs)
    local slotKey = {}
    local nb = tonumber(attrs["hf-nbinds"]) or 0
    for i = 1, nb do slotKey[i] = attrs["hf-bkey" .. i] end
    local function ren(s)
        if type(s) ~= "string" then return s end
        return (s:gsub("HFB(%d+)", function(d)
            local k = slotKey[tonumber(d)]
            return k and ("HFB<" .. k .. ">") or ("HFB" .. d)
        end))
    end
    local skip = {}
    local out = {}
    for i = 1, nb do skip["hf-bkey" .. i] = true end
    local function family(prefix, fields, countName)
        local n = tonumber(attrs[countName]) or 0
        local recs = {}
        for i = 1, n do
            local rec = {}
            for _, f in ipairs(fields) do
                skip["hf-" .. f .. i] = true
                rec[#rec + 1] = f .. "=" .. tostring(ren(attrs["hf-" .. f .. i]))
            end
            recs[#recs + 1] = { key = tostring(ren(attrs["hf-" .. fields[1] .. i])), text = table.concat(rec, " | ") }
        end
        table.sort(recs, function(a, b) return a.key < b.key end)
        for _, r in ipairs(recs) do out[#out + 1] = { prefix .. "[" .. r.key .. "]", r.text } end
    end
    family("meta", META_FIELDS, "hf-mn")
    family("dead", DEAD_FIELDS, "hf-dn")
    local keys = {}
    for i = 1, nb do keys[#keys + 1] = slotKey[i] end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    if nb > 0 then out[#out + 1] = { "hf-bkeys", table.concat(keys, ",") } end
    for name, value in pairs(attrs) do
        if not skip[name] then out[#out + 1] = { ren(name), ren(value) } end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    return out
end

local function canonNameList(ctxAttrs, set)
    local slotKey = {}
    for i = 1, tonumber(ctxAttrs["hf-nbinds"]) or 0 do slotKey[i] = ctxAttrs["hf-bkey" .. i] end
    local list = {}
    for name in pairs(set or {}) do
        local n = name:gsub("HFB(%d+)", function(d) local k = slotKey[tonumber(d)]; return k and ("HFB<" .. k .. ">") or ("HFB" .. d) end)
        n = n:gsub("^hf%-(%a+)%d+$", "hf-%1#")   -- numbered families collapse to one name (the count is in the attrs)
        list[n] = true
    end
    local out = {}
    for n in pairs(list) do out[#out + 1] = n end
    table.sort(out)
    return table.concat(out, ",")
end

-- ------------------------------------------------------------------ frame naming
local function inSubtree(f, roots)
    local seen = 0
    while f and seen < 64 do
        if roots[f] then return true end
        local s = rawget(f, "__s")
        if not s then return false end
        f = s.parent
        seen = seen + 1
    end
    return false
end

local function buildNames(ctx, members)
    local names = ctx.names
    local queue = {}
    for _, f in ipairs(members) do
        local n = st(f).name
        if n then names[f] = n; queue[#queue + 1] = f end
    end
    local inSet = {}
    for _, f in ipairs(members) do inSet[f] = true end
    local visited = {}
    local function walk(tbl, prefix, depth)
        for _, k in ipairs(sortedKeys(tbl)) do
            if k ~= "__s" and k ~= "__container" then
                local v = rawget(tbl, k)
                if isFrame(v) then
                    if inSet[v] and not names[v] then names[v] = prefix .. "." .. tostring(k); queue[#queue + 1] = v end
                elseif type(v) == "table" and depth < 2 and not visited[v] and not mock.isSecret(v) then
                    visited[v] = true
                    walk(v, prefix .. "." .. tostring(k), depth + 1)
                end
            end
        end
    end
    local i = 1
    while i <= #queue do
        local f = queue[i]; i = i + 1
        walk(f, names[f], 0)
    end
    -- anything left: parent path + kind + running number among the parent's unnamed children of that kind
    local changed = true
    while changed do
        changed = false
        local counters = {}
        for _, f in ipairs(members) do
            if not names[f] then
                local p = st(f).parent
                if p and names[p] then
                    local key = names[p] .. "/" .. st(f).kind
                    counters[key] = (counters[key] or 0) + 1
                    names[f] = key .. counters[key]
                    changed = true
                end
            end
        end
    end
    return names
end

-- ------------------------------------------------------------------ per-frame lines
local SCALAR_FIELDS_SKIP = { __s = true }

local function frameLines(ctx, f)
    local s = st(f)
    local name = ctx.names[f] or ("?" .. s.kind)
    local out = ctx.lines
    local parts = { name, "kind=" .. s.kind }
    local function add(k, v) if v ~= nil then parts[#parts + 1] = k .. "=" .. v end end
    add("tmpl", s.template and fmt(ctx, s.template))
    add("shown", tostring(s.shown))
    add("size", (s.w or s.h) and (fmt(ctx, s.w) .. "x" .. fmt(ctx, s.h)) or nil)
    add("scale", s.scale ~= nil and fmt(ctx, s.scale) or nil)
    add("alpha", s.alpha ~= nil and fmt(ctx, s.alpha) or nil)
    add("level", s.level ~= nil and fmt(ctx, s.level) or nil)
    add("strata", s.strata)
    if s.points and #s.points > 0 then
        local pts = {}
        for _, p in ipairs(s.points) do
            local a = {}
            for j = 1, table.maxn(p) do a[#a + 1] = fmt(ctx, p[j]) end
            pts[#pts + 1] = table.concat(a, " ")
        end
        add("pts", "[" .. table.concat(pts, "; ") .. "]")
    end
    add("all", s.allPoints ~= nil and fmt(ctx, s.allPoints) or nil)
    add("tex", s.texture ~= nil and fmt(ctx, s.texture) or nil)
    add("vtx", color(ctx, s.vertex))
    add("sb", color(ctx, s.sbColor))
    add("bd", s.backdrop ~= nil and fmt(ctx, s.backdrop) or nil)
    add("bdc", color(ctx, s.borderColor))
    add("bgc", color(ctx, s.bgColor))
    if s.kind == "FontString" or (s.text ~= nil and s.text ~= "") then add("text", fmt(ctx, s.text)) end
    add("tc", color(ctx, s.textColor))
    add("font", s.font and fmt(ctx, s.font) or nil)
    add("wrap", s.wordWrap ~= nil and tostring(s.wordWrap) or nil)
    if s.kind == "StatusBar" then add("mm", fmt(ctx, s.min) .. ".." .. fmt(ctx, s.max)); add("val", fmt(ctx, s.value)) end
    add("mouse", s.mouse ~= nil and tostring(s.mouse) or nil)
    add("desat", s.desat ~= nil and tostring(s.desat) or nil)
    add("playing", s.playing ~= nil and tostring(s.playing) or nil)
    add("watch", s.unitWatch ~= nil and tostring(s.unitWatch) or nil)
    for _, field in ipairs({ "mouseClick", "mouseMotion", "propagateMotion", "propagateClicks", "propClicks", "propMotion" }) do
        add(field, s[field] ~= nil and tostring(s[field]) or nil)
    end
    local scripts = sortedKeys(s.scripts)
    if #scripts > 0 then add("scripts", "[" .. table.concat(scripts, ",") .. "]") end
    local hooks = {}
    for _, ev in ipairs(sortedKeys(s.hooks)) do if #s.hooks[ev] > 0 then hooks[#hooks + 1] = ev .. ":" .. #s.hooks[ev] end end
    if #hooks > 0 then add("hooks", "[" .. table.concat(hooks, ",") .. "]") end
    local events = sortedKeys(s.events)
    if #events > 0 then add("events", "[" .. table.concat(events, ",") .. "]") end
    out[#out + 1] = table.concat(parts, " ")

    for _, d in ipairs(sortedKeys(s.stateDrivers or {})) do
        out[#out + 1] = name .. " driver " .. d .. " = " .. fmt(ctx, s.stateDrivers[d])
    end
    for _, w in ipairs(sortedKeys(s.wraps or {})) do
        out[#out + 1] = name .. " wrap " .. w .. " = " .. fmt(ctx, s.wraps[w].pre) .. " / " .. fmt(ctx, s.wraps[w].post)
    end
    for _, a in ipairs(PS.canonicalAttrs(s.attrs)) do
        out[#out + 1] = name .. " attr " .. a[1] .. " = " .. fmt(ctx, a[2])
    end
    -- the native aura container's own state (mock: filter, max, flow layout, unit)
    local c = rawget(f, "__container")
    if c then
        out[#out + 1] = name .. " container unit=" .. fmt(ctx, c.unit) .. " flow=" .. fmt(ctx, c.flow) .. " layout=" .. fmt(ctx, c.layout)
        for _, key in ipairs(sortedKeys(c.groups)) do
            local g = c.groups[key]
            out[#out + 1] = name .. " container group " .. key .. " filter=" .. fmt(ctx, g.filter) .. " max=" .. fmt(ctx, g.maxFrameCount)
                .. " frames=" .. #g.frames .. " sort=" .. fmt(ctx, g.sortMethod) .. "/" .. fmt(ctx, g.sortDirection)
                .. " tmpl=" .. fmt(ctx, g.templateNames)
        end
    end
end

-- Plain Lua state on a root button (unit, state, hfAttrs names, aura container geometry, buff button state).
local function stateLines(ctx, f)
    local name = ctx.names[f]
    local out = ctx.lines
    local scalars = {}
    for _, k in ipairs(sortedKeys(f)) do
        local v = rawget(f, k)
        if not SCALAR_FIELDS_SKIP[k] and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
            scalars[#scalars + 1] = tostring(k) .. "=" .. fmt(ctx, v)
        elseif type(v) == "table" and not isFrame(v) and not mock.isSecret(v) and (k == "missingNames") then
            scalars[#scalars + 1] = tostring(k) .. "=" .. fmt(ctx, v)
        end
    end
    out[#out + 1] = name .. " state " .. table.concat(scalars, " ")
    local hf = rawget(f, "hfAttrs")
    if hf then out[#out + 1] = name .. " hfAttrs " .. canonNameList(st(f).attrs, hf) end
    local containers = rawget(f, "auraContainers")
    if type(containers) == "table" then
        for _, kind in ipairs(sortedKeys(containers)) do
            local cs = containers[kind]
            out[#out + 1] = name .. " auras." .. kind .. " unit=" .. fmt(ctx, cs.unit) .. " key=" .. fmt(ctx, cs.appliedKey)
                .. " filter=" .. fmt(ctx, cs.geom and cs.geom.filter) .. " max=" .. fmt(ctx, cs.geom and cs.geom.max)
                .. " zone=" .. fmt(ctx, cs.zone)
        end
    end
end

-- ------------------------------------------------------------------ public API
-- Snapshot of the party frames (anchor subtree: member + pet buttons, aura rows / containers, buff buttons) plus the
-- smart and tank buff buttons. Deterministic for a given game state.
function PS.snapshotParty(ns)
    local ctx = newCtx()
    local UF, BB = ns.UnitFrames, ns.BuffButtons
    assert(UF and UF.anchor, "party frames were not created")
    local roots = { [UF.anchor] = true }
    local extraRoots = {}
    if BB and BB.smart then roots[BB.smart] = true; extraRoots[#extraRoots + 1] = BB.smart end
    if BB and BB.tank then roots[BB.tank] = true; extraRoots[#extraRoots + 1] = BB.tank end
    local members = {}
    for _, f in ipairs(mock.frames) do if inSubtree(f, roots) then members[#members + 1] = f end end
    buildNames(ctx, members)

    ctx.lines[#ctx.lines + 1] = "party buttons " .. #UF.buttons
    for i, b in ipairs(UF.buttons) do
        ctx.lines[#ctx.lines + 1] = "button " .. i .. " = " .. fmt(ctx, b) .. " unit=" .. fmt(ctx, b.unit)
    end
    for _, b in ipairs(UF.buttons) do stateLines(ctx, b) end
    for _, list in ipairs({ BB and BB.buttons or {}, BB and BB.extraButtons or {} }) do
        for _, b in ipairs(list) do if ctx.names[b] then stateLines(ctx, b) end end
    end
    for _, b in ipairs(extraRoots) do stateLines(ctx, b) end
    for _, f in ipairs(members) do frameLines(ctx, f) end
    return { lines = ctx.lines, strings = ctx.strings }
end

-- ------------------------------------------------------------------ scenarios
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
local function unit(name, class, role, hp, maxHp, extra)
    local u = { name = name, class = class, health = hp or 500, maxHealth = maxHp or 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
    for k, v in pairs(extra or {}) do u[k] = v end
    return u
end
local function aura(id, name, harmful, extra)
    local a = { spellId = id, name = name, icon = 1000 + id % 1000, duration = 60, expirationTime = 1040, applications = 0,
        isHarmful = harmful and true or false, isHelpful = not harmful, auraInstanceID = id, sourceUnit = "player" }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end

PS.FIXTURE_V0101 = "settings-v0.10.1.lua"

-- Each scenario: units, saved settings, group size. All names are made up.
PS.SCENARIOS = {
    {
        name = "solo_defaults",
        group = 0,
    },
    {
        name = "party3_paladin_example",
        group = 3,
        seed = true,
        units = {
            party1 = unit("Tank", "WARRIOR", "TANK", 900, 1000),
            party2 = unit("Wizard", "MAGE", "DAMAGER", 400, 700),
            party3 = unit("Priestess", "PRIEST", "HEALER", 700, 700),
            partypet1 = unit("Wolfie", "WARRIOR", nil, 300, 400),
        },
        setup = function(S)
            S.outOfRange.party2 = true
            S.dead.party3 = true
            S.auras.party1 = { aura(5001, "Shield Wall", false, { sourceUnit = "party1" }), aura(7001, "Slow", true, { dispelName = "Magic" }) }
            S.auras.party2 = { aura(7002, "Poison Sting", true, { dispelName = "Poison" }) }
        end,
    },
    {
        name = "party4_v0.10.1_save",
        group = 4,
        char = PS.FIXTURE_V0101,
        units = {
            party1 = unit("Tank", "WARRIOR", "TANK", 900, 1000),
            party2 = unit("Wizard", "MAGE", "DAMAGER", 250, 700),
            party3 = unit("Priestess", "PRIEST", "HEALER", 700, 700),
            party4 = unit("Brakkor", "WARRIOR", "DAMAGER", 1000, 1200),
            partypet2 = unit("Sparky", "MAGE", nil, 200, 200),
        },
        setup = function(S)
            S.auras.party4 = { aura(5002, "Battle Shout", false, { sourceUnit = "party4" }), aura(5003, "Blessing of Kings", false),
                aura(7003, "Curse of Tongues", true, { dispelName = "Curse" }), aura(7004, "Weakness", true) }
            S.auras.player = { aura(5004, "Blessing of Wisdom", false) }
        end,
    },
    -- (d) a 25-man raid with raid.layoutMode = "party": the party frames must look exactly like party4_v0.10.1_save
    -- (golden key = `sameAs`). Same units and auras; the raid is joined right after login.
    {
        name = "raid25_layoutMode_party",
        sameAs = "party4_v0.10.1_save",
        group = 4,
        char = PS.FIXTURE_V0101,
        afterLogin = function(ns)
            ns.db.raid.layoutMode = "party"
            mock.setRaid(25)
        end,
    },
}

function PS.scenario(name)
    for _, sc in ipairs(PS.SCENARIOS) do if sc.name == name then return sc end end
end

-- Boots the whole addon for a scenario exactly like the game: ADDON_LOADED, PLAYER_LOGIN, roster, a few frame updates
-- and one buff ticker pass. opts.afterLogin(ns, S) runs before the roster settles (later tests change raid settings there).
function PS.boot(sc, opts)
    opts = opts or {}
    local base = sc.sameAs and PS.scenario(sc.sameAs)
    if base then
        local own = sc
        sc = setmetatable({}, { __index = function(_, k)
            local v = own[k]
            if v == nil and (k == "units" or k == "setup") then return base[k] end
            return v
        end })
    end
    mock.install()
    local S = mock.state
    mock.enableContainers()
    S.units.player.class = "PALADIN"
    -- the mock's built-in party units are replaced by the scenario's (none when solo)
    S.units.party1, S.units.party2, S.units.party3 = nil, nil, nil
    for k, v in pairs(sc.units or {}) do S.units[k] = deepcopy(v) end
    if sc.setup then sc.setup(S) end
    local toc = assert(L.parseToc(), "no TOC")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if sc.char then _G.HealerForeverCharDB = Fx.loadSaved(HF_TESTS .. "/fixtures/" .. sc.char, "HealerForeverCharDB") end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if sc.seed then Fx.seed(ns) end
    if opts.afterLoad then opts.afterLoad(ns, S) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(sc.group or 0)
    if sc.afterLogin then sc.afterLogin(ns, S) end
    if opts.afterLogin then opts.afterLogin(ns, S) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
    mock.runOnUpdate(2, 0.5); mock.flushTimers()
    mock.tick(); mock.flushTimers()
    mock.runOnUpdate(1, 0.5); mock.flushTimers()
    return ns, S
end

-- ------------------------------------------------------------------ golden file I/O
PS.GOLDEN = "party-golden-0.10.1.lua"

local function q(s) return string.format("%q", s):gsub("\\\n", "\\n") end

function PS.serialize(golden)
    local out = { "-- GENERATED by tests/test_party_golden.lua (HF_UPDATE_GOLDEN=1 ./run-tests.sh party_golden). Do not edit by hand.",
        "-- Party frame snapshot of Healer Forever 0.10.1 (see tests/party_snapshot.lua). The raid layout must leave it identical.",
        "return {" }
    for _, name in ipairs(sortedKeys(golden)) do
        local snap = golden[name]
        out[#out + 1] = "[" .. q(name) .. "] = {"
        out[#out + 1] = "lines = {"
        for _, line in ipairs(snap.lines) do out[#out + 1] = q(line) .. "," end
        out[#out + 1] = "},"
        out[#out + 1] = "strings = {"
        for _, id in ipairs(sortedKeys(snap.strings)) do out[#out + 1] = "[" .. q(id) .. "] = " .. q(snap.strings[id]) .. "," end
        out[#out + 1] = "},"
        out[#out + 1] = "},"
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n") .. "\n"
end

function PS.goldenPath() return HF_TESTS .. "/fixtures/" .. PS.GOLDEN end

function PS.loadGolden()
    local chunk = loadfile(PS.goldenPath())
    if not chunk then return nil end
    setfenv(chunk, {})
    return chunk()
end

-- Compares a snapshot with the stored one. Returns nil when equal, else a readable report of the first differences.
function PS.diff(expected, actual, maxShown)
    maxShown = maxShown or 12
    local problems = {}
    local n = math.max(#expected.lines, #actual.lines)
    for i = 1, n do
        if expected.lines[i] ~= actual.lines[i] then
            problems[#problems + 1] = string.format("line %d\n    expected: %s\n    actual:   %s", i, tostring(expected.lines[i]), tostring(actual.lines[i]))
            if #problems >= maxShown then problems[#problems + 1] = "... (more differences)"; break end
        end
    end
    for id, text in pairs(expected.strings) do
        if actual.strings[id] ~= text then problems[#problems + 1] = "string " .. id .. " missing or changed" end
    end
    for id in pairs(actual.strings) do
        if expected.strings[id] == nil then problems[#problems + 1] = "new string " .. id end
    end
    if #problems == 0 then return nil end
    return table.concat(problems, "\n")
end

return PS
