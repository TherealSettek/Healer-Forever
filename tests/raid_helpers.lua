-- Shared helpers for the raid layout tests (test_raid_*.lua): boot the whole addon, join / leave raids, enter / leave
-- combat, read frame state, and the strict-macro parser. All player names are made up.
local mock = require("wow_mock")
local L = require("loader")
local Fx = require("fixtures")

local H = {}

function H.st(f) return rawget(f, "__s") end
function H.errstr() return table.concat(mock.errors, "\n---\n") end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end
H.deepcopy = deepcopy

function H.unit(name, class, role, hp, maxHp)
    return { name = name, class = class, health = hp or 500, maxHealth = maxHp or 500, power = 100, maxPower = 100, powerType = 0, role = role or "NONE" }
end

H.PARTY = {
    party1 = H.unit("Tankard", "WARRIOR", "TANK", 900, 1000), party2 = H.unit("Glimmer", "PRIEST", "HEALER"),
    party3 = H.unit("Fizzle", "MAGE", "DAMAGER", 300, 500), party4 = H.unit("Shade", "ROGUE", "DAMAGER"),
}

-- Boots the addon like the game. opts = { group = 4 (party members), seed = true (Paladin example bindings/preset),
-- char = saved table, raid = n (join a raid of n before login), raidOpts = {...}, setup = function(S), afterLoad = function(ns, S) }
function H.boot(opts)
    opts = opts or {}
    mock.install()
    local S = mock.state
    mock.enableContainers()
    S.units.player.class = "PALADIN"
    S.units.party1, S.units.party2, S.units.party3 = nil, nil, nil
    for k, v in pairs(opts.party or H.PARTY) do S.units[k] = deepcopy(v) end
    if opts.setup then opts.setup(S) end
    local toc = assert(L.parseToc(), "no TOC")
    local ns = {}
    for _, rel in ipairs(toc.files) do
        if rel:lower():match("%.lua$") then assert(pcall(L.loadFile, rel, ns)) end
    end
    if opts.char ~= nil then _G.HealerForeverCharDB = deepcopy(opts.char) end
    mock.fire("ADDON_LOADED", "HealerForever"); mock.flushTimers()
    if opts.seed ~= false and opts.char == nil then Fx.seed(ns) end
    if opts.afterLoad then opts.afterLoad(ns, S) end
    mock.fire("PLAYER_LOGIN"); mock.flushTimers()
    mock.setGroup(opts.group or 4)
    if opts.raid then mock.setRaid(opts.raid, opts.raidOpts) end
    mock.fire("PLAYER_ENTERING_WORLD", true, false); mock.flushTimers()
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
    mock.applyUnitWatch()
    mock.runOnUpdate(2, 0.5); mock.flushTimers()
    return ns, S
end

-- Roster change (join / leave / resize): GROUP_ROSTER_UPDATE plus the game's unit watch.
function H.roster(n, opts)
    if n then mock.setRaid(n, opts) end
    mock.fire("GROUP_ROSTER_UPDATE"); mock.flushTimers()
    mock.applyUnitWatch()
end

function H.enterCombat()
    mock.state.combat = true
    mock.fire("PLAYER_REGEN_DISABLED"); mock.flushTimers()
end

function H.leaveCombat()
    mock.state.combat = false
    mock.fire("PLAYER_REGEN_ENABLED"); mock.flushTimers()
    mock.applyUnitWatch()
end

function H.slash(msg)
    mock.printed = {}
    local ok, err = pcall(_G.SlashCmdList.HEALERFOREVER, msg)
    mock.flushTimers()
    return ok, err, table.concat(mock.printed, "\n")
end

-- Every violation (hard and soft) as one readable string; "" when there are none.
function H.violations()
    local out = {}
    for _, v in ipairs(mock.violations) do out[#out + 1] = tostring(v.frame) .. ":" .. tostring(v.method) .. " " .. tostring(v.args and v.args[1]) end
    for _, v in ipairs(mock.softViolations) do out[#out + 1] = tostring(v.frame) .. ":" .. tostring(v.method) end
    return table.concat(out, "\n")
end

function H.shownRaidButtons(ns)
    local out = {}
    for _, b in ipairs(ns.RaidFrames.buttons) do if H.st(b).shown then out[#out + 1] = b end end
    return out
end

-- Party buttons the player can actually see (shown AND every parent shown, like the client).
function H.visiblePartyButtons(ns)
    local out = {}
    for _, b in ipairs(ns.UnitFrames.buttons) do if mock.isVisible(b) then out[#out + 1] = b end end
    return out
end

H.PARTY_SOFT_DRIVER = "[group:raid] hide; show"
H.RAID_SOFT_DRIVER = "[group:raid] show; hide"
function H.driver(frame) return (H.st(frame).stateDrivers or {}).visibility end

function H.shownPartyButtons(ns)
    local out = {}
    for _, b in ipairs(ns.UnitFrames.buttons) do if H.st(b).shown then out[#out + 1] = b end end
    return out
end

-- The TOPLEFT offset of a raid button inside the raid anchor (last SetPoint), as x, y (y downwards positive).
function H.cellOf(button)
    local pts = H.st(button).points
    local p = pts[#pts]
    if not p then return nil end
    return p[4], -p[5]
end

-- ---------------------------------------------------------------- strict macro parser (same rules as test_strict_macros)
local FORBIDDEN = { "@player", "@target", "@mouseover", "@focus", "@cursor", "@pet", "target=", "@none" }
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function H.macroProblems(text, u)
    local problems = {}
    if type(text) ~= "string" or text == "" then return { "empty macro" } end
    if #text > 255 then problems[#problems + 1] = "longer than 255 characters (" .. #text .. ")" end
    for line in text:gmatch("[^\n]+") do
        local cmd, rest = line:match("^/(%a+)%s+(.*)$")
        if not cmd then
            problems[#problems + 1] = "not a slash-command line: " .. line
        elseif cmd ~= "cast" and cmd ~= "target" then
            problems[#problems + 1] = "unexpected command /" .. cmd
        else
            for clause in rest:gmatch("[^;]+") do
                clause = trim(clause)
                local conds, action = clause:match("^%[(.-)%]%s*(.*)$")
                if not conds then
                    problems[#problems + 1] = "bare clause: '" .. clause .. "' in " .. line
                else
                    local units = {}
                    for x in conds:gmatch("@([%w_]+)") do units[#units + 1] = x end
                    if #units ~= 1 or units[1] ~= u then problems[#problems + 1] = "clause does not name @" .. u .. " exactly once: [" .. conds .. "]" end
                    for _, bad in ipairs(FORBIDDEN) do
                        if conds:find(bad, 1, true) and not (u == "player" and bad == "@player") then
                            problems[#problems + 1] = "forbidden " .. bad .. " in [" .. conds .. "]"
                        end
                    end
                    if cmd == "cast" and not (conds:find(",help,nodead", 1, true) or conds:find(",dead", 1, true)) then
                        problems[#problems + 1] = "cast clause lacks help,nodead or dead: [" .. conds .. "]"
                    end
                    if cmd == "cast" and action == "" then problems[#problems + 1] = "cast clause without a spell: [" .. conds .. "]" end
                end
            end
        end
    end
    return problems
end

-- Every macro text on a secure button: { name, text }, plus a list of forbidden type=spell / spell attributes.
function H.macrosOf(btn)
    local out, bad = {}, {}
    for k, v in pairs(H.st(btn).attrs) do
        k = tostring(k)
        if k:find("macrotext", 1, true) and not k:match("^hf%-") then out[#out + 1] = { name = k, text = v }
        elseif k:match("^hf%-dtext") or k:match("^hf%-mtext") then out[#out + 1] = { name = k, text = v } end
        if (k:match("type%d*$") or k:match("type%-HFB%d+$")) and v == "spell" then bad[#bad + 1] = k .. "=spell" end
        if k:match("^%*?spell") then bad[#bad + 1] = "spell attribute " .. k end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out, bad
end

-- Attributes ClickCast sets on a button (anything but the unit token and the secure snippets / state attributes).
function H.clickAttrs(btn)
    local out = {}
    for k in pairs(H.st(btn).attrs) do
        k = tostring(k)
        if k ~= "unit" and not k:match("^_on") then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

return H
