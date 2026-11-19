-- scripts/release.sh and the GitHub workflows. Everything runs in a temp copy (the repo's dist/ is never touched,
-- nothing is installed, no network).
local L = require("loader")

local ROOT = HF_ROOT
local function sh(cmd)
    local p = io.popen(cmd .. " 2>&1; echo \"__EXIT=$?\"")
    local out = p:read("*a"); p:close()
    local code = tonumber(out:match("__EXIT=(%d+)%s*$"))
    return out:gsub("__EXIT=%d+%s*$", ""), code
end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function mktemp()
    local base = os.getenv("TMPDIR") or "/tmp"
    local out = sh("mktemp -d " .. q((base:gsub("/$", "")) .. "/hf_release_XXXXXX"))
    return (out:gsub("%s+$", ""))
end
local made = {}
local function tree(opts)
    opts = opts or {}
    local t = mktemp(); made[#made + 1] = t
    sh("mkdir -p " .. q(t .. "/scripts") .. " && cp " .. q(ROOT .. "/scripts/release.sh") .. " " .. q(t .. "/scripts/release.sh")
        .. " && cp " .. q(ROOT .. "/scripts/release-tests.sh") .. " " .. q(t .. "/scripts/release-tests.sh"))
    sh("cp -R " .. q(ROOT .. "/HealerForever") .. " " .. q(t .. "/HealerForever"))
    local f = io.open(t .. "/run-tests.sh", "w"); f:write("#!/usr/bin/env bash\n" .. (opts.testsExit and ("echo 'simulated test run'; exit " .. opts.testsExit .. "\n") or "echo 'simulated test run'; exit 0\n")); f:close()
    sh("chmod +x " .. q(t .. "/run-tests.sh") .. " " .. q(t .. "/scripts/release.sh") .. " " .. q(t .. "/scripts/release-tests.sh"))
    -- things that must never end up in a release
    sh("mkdir -p " .. q(t .. "/tests/fixtures") .. " " .. q(t .. "/mockup") .. " " .. q(t .. "/.settings-backup/pre-ship") .. " " .. q(t .. "/.github/workflows"))
    for _, p in ipairs({ "/tests/test_x.lua", "/mockup/index.html", "/.settings-backup/pre-ship/char.lua", "/CHANGELOG.md", "/.gitignore" }) do
        local g = io.open(t .. p, "w"); g:write("x"); g:close()
    end
    -- junk inside the addon folder itself
    sh("touch " .. q(t .. "/HealerForever/.DS_Store") .. " " .. q(t .. "/HealerForever/.hidden") .. " " .. q(t .. "/HealerForever/Util/.DS_Store"))
    sh("mkdir -p " .. q(t .. "/HealerForever/.git/objects") .. " " .. q(t .. "/HealerForever/.vscode") .. " && touch " .. q(t .. "/HealerForever/.git/HEAD") .. " " .. q(t .. "/HealerForever/.vscode/settings.json"))
    if opts.toc then
        local f2 = io.open(t .. "/HealerForever/HealerForever.toc", "w"); f2:write(opts.toc); f2:close()
    end
    return t
end
local function release(t, version, env)
    return sh((env or "") .. " bash " .. q(t .. "/scripts/release.sh") .. " " .. (version ~= nil and q(version) or ""))
end
-- test-then-build wrapper (owner decision 2026-11-19: release.sh only builds, release-tests.sh runs the suite first)
local function releaseTests(t, version)
    return sh("bash " .. q(t .. "/scripts/release-tests.sh") .. " " .. (version ~= nil and q(version) or ""))
end
local function listing(zip)
    local out = sh("unzip -Z1 " .. q(zip))
    local names = {}
    for line in out:gmatch("[^\n]+") do names[#names + 1] = line end
    return names
end
local function cleanup()
    for _, t in ipairs(made) do
        if t:find("hf_release_", 1, true) then sh("rm -rf " .. q(t)) end
    end
    made = {}
end

describe("release: scripts/release.sh basics", function()
    local src = L.readFile(ROOT .. "/scripts/release.sh")
    local wrap = L.readFile(ROOT .. "/scripts/release-tests.sh")
    it("release.sh exists, is executable, is strict bash and only builds (it never runs the tests)", function()
        local _, code = sh("test -x " .. q(ROOT .. "/scripts/release.sh"))
        assertEquals(code, 0)
        assertNotNil(src:find("^#!/usr/bin/env bash")); assertNotNil(src:find("set -euo pipefail", 1, true))
        assertNil(src:find("./run-tests.sh", 1, true), "release.sh must not run the tests")
        assertNotNil(src:find("release-tests.sh", 1, true), "release.sh points at the test-then-build script")
    end)
    it("release-tests.sh exists, is executable, is strict bash, runs the full suite and then release.sh", function()
        local _, code = sh("test -x " .. q(ROOT .. "/scripts/release-tests.sh"))
        assertEquals(code, 0)
        assertNotNil(wrap:find("^#!/usr/bin/env bash")); assertNotNil(wrap:find("set -euo pipefail", 1, true))
        local a = wrap:find("./run-tests.sh", 1, true)
        local b = wrap:find('exec "$ROOT/scripts/release.sh"', 1, true)
        assertTrue(a and b and a < b, "tests first, then the build")
        assertNotNil(wrap:find("tests failed: aborting release", 1, true))
    end)
    it("the real TOC keeps the @project-version@ placeholder (only the copy is stamped)", function()
        assertNotNil(L.readFile(L.tocPath):find("## Version: @project-version@", 1, true))
    end)
    it("the old HF_RELEASE_SKIP_TESTS escape hatch is gone everywhere", function()
        assertNil(src:find("HF_RELEASE_SKIP_TESTS", 1, true), "release.sh")
        assertNil(wrap:find("HF_RELEASE_SKIP_TESTS", 1, true), "release-tests.sh")
        assertNil(L.readFile(ROOT .. "/.github/workflows/test.yml"):find("HF_RELEASE_SKIP_TESTS", 1, true), "test.yml")
    end)
end)

describe("release: version validation", function()
    it("rejects bad versions with exit 2 and a usage message, before running anything", function()
        local t = tree()
        for _, bad in ipairs({ "", "1.2", "v1.0.0", "1.0.0.0", "abc", "1.0.0-", "1..0", "1.0", "01", "1.2.x", " 1.0.0", "1.0.0 ", "-1.0.0", "1.0.0;rm -rf /", "../1.0.0" }) do
            local out, code = release(t, bad)
            assertEquals(code, 2, "should reject '" .. bad .. "': " .. out)
            assertNotNil(out:find("usage", 1, true))
            assertNil(out:find("simulated test run", 1, true), "tests must not run for an invalid version")
        end
        local out, code = sh("bash " .. q(t .. "/scripts/release.sh"))
        assertEquals(code, 2)
        local _, c2 = sh("test -e " .. q(t .. "/dist"))
        assertTrue(c2 ~= 0, "no dist directory may be created for a rejected version")
        cleanup()
    end)
    it("release-tests.sh rejects bad versions with exit 2 before running the tests", function()
        local t = tree()
        for _, bad in ipairs({ "", "1.2", "v1.0.0", "abc", "1.0.0;rm -rf /", "../1.0.0" }) do
            local out, code = releaseTests(t, bad)
            assertEquals(code, 2, "should reject '" .. bad .. "': " .. out)
            assertNotNil(out:find("usage", 1, true))
            assertNil(out:find("simulated test run", 1, true), "tests must not run for an invalid version")
        end
        local _, c2 = sh("test -e " .. q(t .. "/dist"))
        assertTrue(c2 ~= 0, "no dist directory may be created for a rejected version")
        cleanup()
    end)
    it("accepts valid semver (plain, prerelease, build metadata)", function()
        local t = tree()
        for _, ok in ipairs({ "1.0.0", "0.0.1-test", "0.9.0-beta.1", "2.3.4-rc.1+build.5", "10.20.30" }) do
            local out, code = release(t, ok)
            assertEquals(code, 0, ok .. ": " .. out)
            local _, c = sh("test -f " .. q(t .. "/dist/HealerForever-v" .. ok .. ".zip"))
            assertEquals(c, 0, "zip for " .. ok)
        end
        cleanup()
    end)
end)

describe("release: tests gate (release-tests.sh)", function()
    it("aborts (exit 1, no zip, no stage folder) when the test run fails", function()
        local t = tree({ testsExit = 1 })
        local out, code = releaseTests(t, "1.2.3")
        assertEquals(code, 1, out)
        assertNotNil(out:find("tests failed: aborting release", 1, true)); assertNotNil(out:find("simulated test run", 1, true))
        local _, c = sh("test -e " .. q(t .. "/dist"))
        assertTrue(c ~= 0, "nothing must be built after a failing test run")
        cleanup()
    end)
    it("a test runner exiting with any non-zero code aborts", function()
        for _, code in ipairs({ 2, 127 }) do
            local t = tree({ testsExit = code })
            local _, c = releaseTests(t, "1.0.0")
            assertEquals(c, 1)
            local _, d = sh("test -e " .. q(t .. "/dist"))
            assertTrue(d ~= 0, "nothing built after a failing test run")
            cleanup()
        end
    end)
    it("a passing test run is a precondition for the zip, and it ran first", function()
        local t = tree()
        local out, code = releaseTests(t, "1.2.3")
        assertEquals(code, 0, out)
        local a, b = out:find("simulated test run", 1, true), out:find("HealerForever-v1.2.3.zip", 1, true)
        assertTrue(a and b and a < b)
        local _, c = sh("test -f " .. q(t .. "/dist/HealerForever-v1.2.3.zip"))
        assertEquals(c, 0, "zip built by release.sh after the tests")
        cleanup()
    end)
    it("release.sh alone builds the zip without running the tests (even if they would fail)", function()
        local t = tree({ testsExit = 1 })
        local out, code = release(t, "1.2.3")
        assertEquals(code, 0, out)
        assertNil(out:find("simulated test run", 1, true), "release.sh must not run the tests")
        assertNotNil(out:find("release-tests.sh", 1, true), "it says where the tests are run")
        local _, c = sh("test -f " .. q(t .. "/dist/HealerForever-v1.2.3.zip"))
        assertEquals(c, 0)
        cleanup()
    end)
end)

describe("release: the zip", function()
    local t = tree()
    local out, code = release(t, "0.0.1-test")
    local zip = t .. "/dist/HealerForever-v0.0.1-test.zip"
    local names = listing(zip)
    it("is built", function() assertEquals(code, 0, out); assertTrue(#names > 20, "entries: " .. #names) end)
    it("its root is HealerForever/ (every entry lives under it)", function()
        for _, n in ipairs(names) do assertEquals(n:sub(1, 14), "HealerForever/", n) end
        local hasRoot = false
        for _, n in ipairs(names) do if n == "HealerForever/HealerForever.toc" then hasRoot = true end end
        assertTrue(hasRoot)
    end)
    it("the TOC inside is stamped with the version and no placeholder remains", function()
        local toc = sh("unzip -p " .. q(zip) .. " HealerForever/HealerForever.toc")
        assertNotNil(toc:find("## Version: 0.0.1-test", 1, true)); assertNil(toc:find("@project-version@", 1, true))
        for line in toc:gmatch("[^\n]+") do if line:find("^## Version") then assertEquals((line:gsub("\r", "")), "## Version: 0.0.1-test") end end
    end)
    it("every file listed in the TOC is in the zip (plus Bindings.xml)", function()
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        local toc = L.parseToc()
        for _, f in ipairs(toc.files) do assertTrue(set["HealerForever/" .. f:gsub("\\", "/")], f .. " missing from the zip") end
        assertTrue(set["HealerForever/Bindings.xml"], "Bindings.xml must ship")
    end)
    it("every shipped .lua/.xml file is in the zip (nothing forgotten)", function()
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        for _, f in ipairs(L.listAddonFiles()) do assertTrue(set["HealerForever/" .. f], f .. " missing") end
    end)
    it("contains no tests, mockup, settings backups, scripts, workflows or changelog", function()
        for _, n in ipairs(names) do
            for _, bad in ipairs({ "tests/", "mockup", "settings-backup", "scripts/", ".github", "CHANGELOG", "dist/", "run-tests", "fixtures" }) do
                assertNil(n:find(bad, 1, true), n .. " must not be in the zip (" .. bad .. ")")
            end
        end
    end)
    it("contains no dotfiles or dot-directories and no .DS_Store at any depth", function()
        for _, n in ipairs(names) do
            assertNil(n:find("/%.[^/]"), n); assertNil(n:find("DS_Store", 1, true), n)
        end
    end)
    it("contains no stage leftovers (*.tmp) and no stray LuaJIT/editor files", function()
        for _, n in ipairs(names) do assertNil(n:find("%.tmp$"), n); assertNil(n:find("%.swp$"), n); assertNil(n:find("~$"), n) end
    end)
    it("zip entries match the addon folder file for file (no extra, no missing)", function()
        local expected = {}
        local p = io.popen("cd " .. q(ROOT) .. " && find HealerForever -type f ! -name '.*' ! -path '*/.*' | sort")
        for line in p:lines() do expected[line] = true end
        p:close()
        local n = 0
        for _, name in ipairs(names) do
            if name:sub(-1) ~= "/" then
                n = n + 1
                if name ~= "HealerForever/HealerForever.toc" then assertTrue(expected[name], "unexpected file in the zip: " .. name) end
            end
        end
        local count = 0
        for _ in pairs(expected) do count = count + 1 end
        assertEquals(n, count)
    end)
    it("LICENSE.txt ships at HealerForever/LICENSE.txt, byte-identical, with the copyright line; the TOC declares X-License", function()
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        assertTrue(set["HealerForever/LICENSE.txt"], "LICENSE.txt is missing from the zip")
        local zipped = sh("unzip -p " .. q(zip) .. " HealerForever/LICENSE.txt")
        assertEquals(zipped, L.readFile(ROOT .. "/HealerForever/LICENSE.txt"))
        assertNotNil(zipped:find("Copyright (c) 2026 trtg. All rights reserved.", 1, true))
        assertNotNil(sh("unzip -p " .. q(zip) .. " HealerForever/HealerForever.toc"):find("## X-License: All Rights Reserved", 1, true))
    end)
    it("the shipped Lua files are byte-identical to the repo's (only the TOC differs)", function()
        for _, f in ipairs({ "Core.lua", "Util/Util.lua", "Frames/UnitFrames.lua", "Bindings.xml" }) do
            local zipped = sh("unzip -p " .. q(zip) .. " " .. q("HealerForever/" .. f))
            assertEquals(zipped, L.readFile(ROOT .. "/HealerForever/" .. f), f)
        end
    end)
    it("the file name carries the version and rebuilding the same version replaces the zip", function()
        local out2, code2 = release(t, "0.0.1-test")
        assertEquals(code2, 0, out2)
        assertEquals(#listing(zip), #names)
        local _, c = sh("test -d " .. q(t .. "/dist/HealerForever"))
        assertEquals(c, 0, "the staged folder is part of dist/ (gitignored)")
    end)
    it("prints a checksum of the zip", function()
        assertNotNil(out:find("[0-9a-f]+  ", 1) or out:find("[0-9a-f]+%s+" .. "[^\n]*HealerForever-v0.0.1-test.zip"))
    end)
    it("a TOC without the placeholder fails the version stamp check (exit 1) and builds no zip", function()
        local t2 = tree({ toc = "## Interface: 120005\n## Title: Healer Forever\n## Version: 9.9.9\n\nCore.lua\n" })
        local o, c = release(t2, "1.0.0")
        assertEquals(c, 1, o); assertNotNil(o:find("version stamp failed", 1, true))
        local _, c2 = sh("test -f " .. q(t2 .. "/dist/HealerForever-v1.0.0.zip"))
        assertTrue(c2 ~= 0)
    end)
    it("cleanup", function() cleanup(); assertTrue(true) end)
end)

describe("release: GitHub workflows", function()
    local test_yml = L.readFile(ROOT .. "/.github/workflows/test.yml")
    local function topKeys(src)
        local keys = {}
        for line in src:gmatch("[^\n]+") do
            local k = line:match("^([%w_%-]+):")
            if k then keys[#keys + 1] = k end
        end
        return keys
    end
    it("there is no release workflow (no GitHub Releases for now; zips are built locally with scripts/release.sh)", function()
        local _, code = sh("test -e " .. q(ROOT .. "/.github/workflows/release.yml")); assertTrue(code ~= 0, "release.yml must be absent")
        local out = sh("ls " .. q(ROOT .. "/.github/workflows"))
        assertNil(out:find("release", 1, true), "no workflow file may mention release: " .. out)
        assertNil(test_yml:find("action-gh-release", 1, true)); assertNil(test_yml:find("contents: write", 1, true))
    end)
    it("test.yml uses spaces only and has unique top-level keys name/on/jobs", function()
        assertNil(test_yml:find("\t"), "no tabs")
        local seen = {}
        for _, k in ipairs(topKeys(test_yml)) do assertNil(seen[k], "duplicate key " .. k); seen[k] = true end
        assertTrue(seen.name and seen.on and seen.jobs, "needs name/on/jobs")
    end)
    it("parses with a real YAML parser when one is available (PyYAML)", function()
        local _, has = sh("python3 -c 'import yaml'")
        if has ~= 0 then warn("PyYAML not installed: only structural YAML checks ran") return end
        local out, code = sh("python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert isinstance(d, dict) and \"jobs\" in d and (True in d or \"on\" in d)' " .. q(ROOT .. "/.github/workflows/test.yml"))
        assertEquals(code, 0, out)
    end)
    it("test.yml triggers only on push to main and on pull requests", function()
        assertNotNil(test_yml:find("on:\n  push:\n    branches:\n      %- main\n  pull_request:"))
        assertNil(test_yml:find("tags:", 1, true)); assertNil(test_yml:find("schedule", 1, true)); assertNil(test_yml:find("workflow_dispatch", 1, true))
        local out, code = sh("python3 -c 'import yaml' 2>/dev/null && python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); on=d.get(True, d.get(\"on\")); assert set(on.keys())=={\"push\",\"pull_request\"}; assert on[\"push\"][\"branches\"]==[\"main\"]' " .. q(ROOT .. "/.github/workflows/test.yml"))
        if code == 0 or out == "" then assertTrue(true) else assertEquals(code, 0, out) end
    end)
    it("test.yml installs the tooling, checks out, and runs HF_SKIP_MUTATION=1 ./run-tests.sh", function()
        assertNotNil(test_yml:find("HF_SKIP_MUTATION=1 ./run-tests.sh", 1, true))
        for _, pkg in ipairs({ "luajit", "luarocks", "luacheck" }) do assertNotNil(test_yml:find(pkg, 1, true), pkg) end
        assertNotNil(test_yml:find("actions/checkout@", 1, true)); assertNotNil(test_yml:find("runs-on: ubuntu-latest", 1, true))
    end)
    it("HF_SKIP_MUTATION=1 makes the runner skip test_mutation.lua and say so; without it the file is not skipped", function()
        local out = sh("cd " .. q(ROOT) .. " && HF_SKIP_MUTATION=1 luajit tests/run.lua test_mutation")
        assertNotNil(out:find("mutation tests skipped (HF_SKIP_MUTATION=1)", 1, true), out)
        assertNil(out:find("== test_mutation.lua", 1, true))
        assertNotNil(out:find("passed: 0   failed: 0", 1, true), out)
        local one = select(2, out:gsub("mutation tests skipped", ""))
        assertEquals(one, 1, "announced exactly once")
        local out2 = sh("cd " .. q(ROOT) .. " && env -u HF_SKIP_MUTATION HF_MUTANT=1 luajit tests/run.lua test_mutation")
        assertNotNil(out2:find("== test_mutation.lua", 1, true), out2)
        assertNil(out2:find("mutation tests skipped", 1, true))
    end)
    it("a value other than 1 does not skip", function()
        local out = sh("cd " .. q(ROOT) .. " && env HF_SKIP_MUTATION=0 HF_MUTANT=1 luajit tests/run.lua test_mutation")
        assertNil(out:find("mutation tests skipped", 1, true))
    end)
    it("referenced scripts exist and are executable", function()
        for _, f in ipairs({ "scripts/release.sh", "scripts/release-tests.sh", "run-tests.sh" }) do
            local _, c = sh("test -x " .. q(ROOT .. "/" .. f)); assertEquals(c, 0, f)
        end
    end)
    it("the repo ignores build output and local backups", function()
        local gi = L.readFile(ROOT .. "/.gitignore")
        for _, p in ipairs({ ".settings-backup/", "dist/", ".DS_Store" }) do assertNotNil(gi:find(p, 1, true), p) end
    end)
end)
