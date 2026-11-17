-- Heuristic source scan: flags truth tests (if x / not x / x and / and x / or x) on values that come straight from
-- APIs that can return SECRET booleans/numbers, without an issecret() guard first. Plain Lua cannot make a secret
-- error on a truth test in the mock, so this scan is the safety net for that class of bug.
local M = {}

M.APIS = { "UnitInRange", "UnitIsVisible", "IsSpellInRange", "UnitIsUnit", "UnitIsDeadOrGhost", "UnitIsDead", "UnitIsGhost",
    "UnitIsConnected", "UnitThreatSituation", "UnitGroupRolesAssigned", "UnitAffectingCombat" }

local function strip(line)
    line = line:gsub("%-%-.*$", "")
    return line
end

local function indentOf(line) return #(line:match("^(%s*)")) end

-- truth-position uses of identifier `v` in `code`
local function truthUse(code, v)
    local p = "%f[%w_]" .. v .. "%f[^%w_]"
    local patterns = {
        "%f[%w_]if%s+" .. p .. "%s+then", "%f[%w_]if%s+not%s+" .. p .. "%s+then", "%f[%w_]elseif%s+" .. p, "%f[%w_]elseif%s+not%s+" .. p,
        "%f[%w_]and%s+" .. p .. "%f[^%w_.%[:]]", "%f[%w_]or%s+" .. p .. "%f[^%w_.%[:]]", "%f[%w_]not%s+" .. p .. "%f[^%w_.%[:]]",
        p .. "%s+and%f[^%w_]", p .. "%s+or%f[^%w_]", "%f[%w_]while%s+" .. p,
    }
    for _, pat in ipairs(patterns) do
        local s = code:find(pat)
        if s then
            -- exclude comparisons: `v == x` / `v ~= x` at the matched spot are handled elsewhere
            return true
        end
    end
    return false
end

-- returns list of { file, line, text, why }
function M.scan(path, rel, source)
    local findings = {}
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local tracked = {}   -- var -> { line, indent }
    for i, raw in ipairs(lines) do
        local code = strip(raw)
        -- expire tracked variables whose block ended
        for v, t in pairs(tracked) do
            if i - t.line > 30 or (code:match("%S") and indentOf(code) < t.indent and not code:match("^%s*end") and not code:match("^%s*else")) then tracked[v] = nil end
        end
        -- direct API call in a truth position
        for _, api in ipairs(M.APIS) do
            local call = "%f[%w_%.]" .. api:gsub("%.", "%%.") .. "%("
            -- `local x = API and API(unit)` only tests that the function exists
            local existsIdiom = code:find("=%s*[%w_%.]*" .. api .. "%s+and%s+[%w_%.]*" .. api .. "%(")
            if code:find(call) and not existsIdiom then
                local direct = code:find("%f[%w_]if%s+not%s+[%w_%.]*" .. api .. "%(") or code:find("%f[%w_]if%s+[%w_%.]*" .. api .. "%(")
                    or code:find("%f[%w_]and%s+[%w_%.]*" .. api .. "%(") or code:find("%f[%w_]or%s+[%w_%.]*" .. api .. "%(")
                    or code:find("%f[%w_]not%s+[%w_%.]*" .. api .. "%(") or code:find("%f[%w_]elseif%s+[%w_%.]*" .. api .. "%(")
                    or code:find("%f[%w_]return%s+not%s+[%w_%.]*" .. api .. "%(")
                if direct and not code:find("issecret", 1, true) and not code:find("flag(", 1, true) and not code:find("pcall", 1, true) then
                    findings[#findings + 1] = { file = rel, line = i, text = raw:gsub("^%s+", ""), why = "direct " .. api .. " result in a truth test" }
                end
            end
            -- assignment: local a, b = API(...)   (also  local x = Frame.API(...))
            local vars = code:match("^%s*local%s+([%w_,%s]+)%s*=%s*[%w_%.]*" .. api .. "%(")
            if vars then
                local first = vars:match("^%s*([%w_]+)")
                if first then tracked[first] = { line = i, indent = indentOf(code), api = api, guarded = false } end
            end
            local assigned = code:match("^%s*([%w_]+)%s*=%s*[%w_%.]*" .. api .. "%(")
            if assigned and not code:match("^%s*local") then tracked[assigned] = { line = i, indent = indentOf(code), api = api, guarded = false } end
        end
        -- uses of tracked variables
        for v, t in pairs(tracked) do
            if i > t.line then
                if code:find("issecret%(" .. v .. "%)") or code:find("issecretvalue%(" .. v .. "%)") or code:find("pcall") then
                    t.guarded = true
                end
                if truthUse(code, v) and not t.guarded and not code:find("issecret", 1, true) then
                    findings[#findings + 1] = { file = rel, line = i, text = raw:gsub("^%s+", ""), why = "'" .. v .. "' (from " .. t.api .. " at line " .. t.line .. ") used in a truth test before any issecret() guard" }
                end
            end
        end
    end
    return findings
end

return M
