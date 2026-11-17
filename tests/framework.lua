-- Tiny self-contained test framework (Lua 5.1 / LuaJIT). No dependencies.
local print = print
local xpcall = xpcall

local F = {}
F.passed, F.failed, F.skipped, F.warnings = 0, 0, 0, {}
F.failures = {}

local suiteStack = {}
local currentFile = "?"
function F.setFile(f) currentFile = f end

local function fullName(name)
    local parts = {}
    for _, s in ipairs(suiteStack) do parts[#parts + 1] = s end
    parts[#parts + 1] = name
    return currentFile .. " :: " .. table.concat(parts, " > ")
end

function F.describe(name, fn)
    suiteStack[#suiteStack + 1] = name
    local ok, err = xpcall(fn, debug.traceback)
    suiteStack[#suiteStack] = nil
    if not ok then
        F.failed = F.failed + 1
        F.failures[#F.failures + 1] = { name = fullName(name .. " (describe block)"), err = tostring(err) }
        print("  FAIL  " .. name .. " (describe block errored)")
    end
end

function F.it(name, fn)
    local ok, err = xpcall(fn, function(e)
        if type(e) == "table" then return e end
        if os.getenv("HF_TRACE") then return debug.traceback(tostring(e), 2) end
        return tostring(e)
    end)
    local label = fullName(name)
    if ok then
        F.passed = F.passed + 1
        print("  ok    " .. label)
    else
        F.failed = F.failed + 1
        if type(err) == "table" then err = tostring(err.message or err) end
        F.failures[#F.failures + 1] = { name = label, err = err }
        print("  FAIL  " .. label)
        print("        " .. tostring(err):gsub("\n", "\n        "))
    end
end

function F.skip(name, reason)
    F.skipped = F.skipped + 1
    print("  skip  " .. fullName(name) .. (reason and (" (" .. reason .. ")") or ""))
end

function F.warn(msg)
    F.warnings[#F.warnings + 1] = msg
    print("  WARN  " .. msg)
end

local function fail(msg, level) error(msg, level or 3) end

local function repr(v, depth)
    depth = depth or 0
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    if depth > 3 then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = "[" .. tostring(k) .. "]=" .. repr(v[k], depth + 1)
    end
    return "{" .. table.concat(out, ", ") .. "}"
end
F.repr = repr

local function deepEq(a, b, seen)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for k, v in pairs(a) do
        if not deepEq(v, b[k], seen) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
F.deepEq = deepEq

function F.assertEquals(actual, expected, msg)
    if actual ~= expected then
        fail((msg and (msg .. ": ") or "") .. "expected " .. repr(expected) .. " but got " .. repr(actual))
    end
end

function F.assertDeepEquals(actual, expected, msg)
    if not deepEq(actual, expected) then
        fail((msg and (msg .. ": ") or "") .. "expected " .. repr(expected) .. " but got " .. repr(actual))
    end
end

function F.assertTrue(v, msg) if not v then fail(msg or ("expected truthy, got " .. repr(v))) end end
function F.assertFalse(v, msg) if v then fail(msg or ("expected falsy, got " .. repr(v))) end end
function F.assertNil(v, msg) if v ~= nil then fail((msg or "expected nil") .. ", got " .. repr(v)) end end
function F.assertNotNil(v, msg) if v == nil then fail(msg or "expected non-nil") end end
function F.assertError(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then fail(msg or "expected an error but none was raised") end
    if pattern and not tostring(err):find(pattern) then
        fail("error did not match " .. repr(pattern) .. ": " .. tostring(err))
    end
end

-- expect(x):toBe / toEqual / toBeNil / toBeTruthy / toBeFalsy / toError / toContain
function F.expect(actual)
    local e = {}
    function e:toBe(x) F.assertEquals(actual, x) end
    function e:toEqual(x) F.assertDeepEquals(actual, x) end
    function e:toBeNil() F.assertNil(actual) end
    function e:toBeTruthy() F.assertTrue(actual) end
    function e:toBeFalsy() F.assertFalse(actual) end
    function e:toError(p) F.assertError(actual, p) end
    function e:toContain(x)
        if type(actual) == "string" then
            if not actual:find(x, 1, true) then fail("expected " .. repr(actual) .. " to contain " .. repr(x)) end
        else
            for _, v in pairs(actual) do if deepEq(v, x) then return end end
            fail("expected " .. repr(actual) .. " to contain " .. repr(x))
        end
    end
    return e
end

function F.install(env)
    env = env or _G
    env.describe, env.it, env.skip, env.warn = F.describe, F.it, F.skip, F.warn
    env.expect = F.expect
    env.assertEquals, env.assertDeepEquals = F.assertEquals, F.assertDeepEquals
    env.assertTrue, env.assertFalse = F.assertTrue, F.assertFalse
    env.assertNil, env.assertNotNil, env.assertError = F.assertNil, F.assertNotNil, F.assertError
end

return F
