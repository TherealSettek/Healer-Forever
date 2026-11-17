-- Test runner: luajit tests/run.lua [filter]
local xpcall = xpcall
local script = arg and arg[0] or "tests/run.lua"
local testsDir = script:match("^(.*)/[^/]*$") or "."
local rootPipe = io.popen('cd "' .. testsDir .. '/.." && pwd')
local root = rootPipe:read("*l"); rootPipe:close()
HF_ROOT = root
HF_TESTS = root .. "/tests"
package.path = HF_TESTS .. "/?.lua;" .. package.path

local F = require("framework")
F.install(_G)
local mock = require("wow_mock")
local filters = {}
for i = 1, #(arg or {}) do filters[#filters + 1] = arg[i] end
local function wanted(base)
    if #filters == 0 then return true end
    for _, f in ipairs(filters) do if base:find(f, 1, true) then return true end end
    return false
end

local files = {}
local p = io.popen('ls "' .. HF_TESTS .. '"/test_*.lua 2>/dev/null')
for line in p:lines() do files[#files + 1] = line end
p:close()
table.sort(files)

print("HealerForever test suite (" .. (jit and jit.version or _VERSION) .. ")")
local skipMutation = os.getenv("HF_SKIP_MUTATION") == "1"
local announcedSkip = false
for _, file in ipairs(files) do
    local base = file:match("([^/]+)$")
    if skipMutation and base == "test_mutation.lua" and wanted(base) then
        if not announcedSkip then print("mutation tests skipped (HF_SKIP_MUTATION=1)"); announcedSkip = true end
    elseif wanted(base) then
        print("\n== " .. base)
        F.setFile(base)
        local chunk, err = loadfile(file)
        if not chunk then
            F.failed = F.failed + 1
            F.failures[#F.failures + 1] = { name = base .. " (load)", err = tostring(err) }
            print("  FAIL  could not load " .. base .. ": " .. tostring(err))
        else
            local ok, e = xpcall(chunk, debug.traceback)
            if not ok then
                F.failed = F.failed + 1
                F.failures[#F.failures + 1] = { name = base .. " (top level)", err = tostring(e) }
                print("  FAIL  top-level error in " .. base .. ": " .. tostring(e))
            end
        end
        mock.uninstall() -- always leave _G clean between files
    end
end

print("\n================ SUMMARY ================")
print(string.format("passed: %d   failed: %d   skipped: %d   warnings: %d",
    F.passed, F.failed, F.skipped, #F.warnings))
if #F.warnings > 0 then
    print("\nWarnings:")
    for _, w in ipairs(F.warnings) do print("  - " .. w) end
end
if F.failed > 0 then
    print("\nFailures:")
    for i, f in ipairs(F.failures) do
        print(string.format("%d) %s\n   %s", i, f.name, tostring(f.err):gsub("\n", "\n   ")))
    end
    print("\nRESULT: FAIL")
    os.exit(1)
end
print("\nRESULT: PASS")
os.exit(0)
