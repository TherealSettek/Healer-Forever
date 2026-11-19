-- Privacy before anything is published: no real character / account identifiers in anything that ships to GitHub or into the release zip.
-- (The markers are assembled at runtime so this file does not contain them itself.)
local L = require("loader")

local MARKERS = { "Is" .. "buli", "4152" .. "05454" }
local ROOTS = { "tests", "HealerForever", "scripts", ".github", "mockup" }
local EXTRA_FILES = { "CHANGELOG.md", "run-tests.sh", ".luacheckrc", ".gitignore" }

local function listFiles()
    local out = {}
    for _, dir in ipairs(ROOTS) do
        local p = io.popen('cd "' .. HF_ROOT .. '" && find "' .. dir .. '" -type f 2>/dev/null')
        for line in p:lines() do out[#out + 1] = line end
        p:close()
    end
    for _, f in ipairs(EXTRA_FILES) do if L.exists(HF_ROOT .. "/" .. f) then out[#out + 1] = f end end
    return out
end

describe("privacy: no real character or account identifiers in published files", function()
    it("neither the character name nor the account id appears in any file (contents)", function()
        local bad, n = {}, 0
        for _, rel in ipairs(listFiles()) do
            if not rel:find("%.zip$") and not rel:find("%.DS_Store$") then
                n = n + 1
                local src = L.readFile(HF_ROOT .. "/" .. rel)
                for _, m in ipairs(MARKERS) do if src:find(m, 1, true) then bad[#bad + 1] = rel .. " contains '" .. m .. "'" end end
            end
        end
        assertTrue(n > 60, "scanned " .. n .. " files")
        assertEquals(#bad, 0, table.concat(bad, "\n"))
    end)
    it("no file NAME contains them either (fixtures use neutral names)", function()
        for _, rel in ipairs(listFiles()) do
            for _, m in ipairs(MARKERS) do assertNil(rel:find(m, 1, true), rel) end
        end
        for _, f in ipairs({ "owner-char-v3.lua", "owner-char-pre-buffgroups.lua", "owner-account-v2.lua" }) do
            assertTrue(L.exists(HF_TESTS .. "/fixtures/" .. f), f)
        end
    end)
    it("synthetic fixtures are made up: marked SYNTHETIC, no error log, no preset names copied from the owner's fixtures", function()
        local SYNTHETIC = { "settings-v0.10.1.lua" }
        local GENERATED = { "party-golden-0.10.1.lua" }
        local ownerNames = {}
        for _, f in ipairs({ "owner-char-v3.lua", "owner-char-pre-buffgroups.lua", "owner-account-v2.lua" }) do
            local src = L.readFile(HF_TESTS .. "/fixtures/" .. f)
            for name in src:gmatch('%["name"%] = "([^"]+)"') do ownerNames[name] = true end
        end
        for _, f in ipairs(SYNTHETIC) do
            local path = HF_TESTS .. "/fixtures/" .. f
            assertTrue(L.exists(path), f)
            local src = L.readFile(path)
            assertTrue(src:find("SYNTHETIC", 1, true) ~= nil, f .. " must say it is synthetic")
            assertNil(src:find("migratedFrom", 1, true), f .. " looks like a real save (migratedFrom)")
            assertNil(src:find('%["errorLog"%] = {%s*{'), f .. " carries error log entries")
            for name in src:gmatch('%["name"%] = "([^"]+)"') do
                assertNil(ownerNames[name], f .. " reuses the owner's preset name '" .. name .. "'")
            end
        end
        for _, f in ipairs(GENERATED) do assertTrue(L.exists(HF_TESTS .. "/fixtures/" .. f), f) end
    end)
    it("the raid preview's fake names (RP.NAMES) are made up: no marker, no name from the owner's fixtures, never UnitName", function()
        local src = L.readFile(L.path("Frames/RaidPreview.lua"))
        local block = assert(src:match("RP%.NAMES = (%b{})"), "RP.NAMES table not found")
        local names = {}
        for n in block:gmatch('"([^"]+)"') do names[#names + 1] = n end
        assertEquals(#names, 40, "one made-up name per preview slot")
        local owner = ""
        for _, f in ipairs({ "owner-char-v3.lua", "owner-char-pre-buffgroups.lua", "owner-account-v2.lua" }) do
            owner = owner .. L.readFile(HF_TESTS .. "/fixtures/" .. f)
        end
        local seen = {}
        for _, n in ipairs(names) do
            assertNil(seen[n], "duplicate preview name " .. n); seen[n] = true
            for _, m in ipairs(MARKERS) do assertNil(n:find(m, 1, true), n) end
            if n ~= "You" then assertNil(owner:find('"' .. n, 1, true), "preview name " .. n .. " appears in the owner's saved data") end
        end
        local code = src:gsub("%-%-[^\n]*", "")
        assertNil(code:find("UnitName", 1, true), "the preview never reads a real player name")
        assertNil(code:find("UnitFullName", 1, true))
        assertNil(code:find("GetRaidRosterInfo", 1, true))
    end)
    it("no absolute path into the owner's game folder is baked into a test or the addon", function()
        for _, rel in ipairs(listFiles()) do
            if rel:find("^tests/") or rel:find("^HealerForever/") then
                local src = L.readFile(HF_ROOT .. "/" .. rel)
                assertNil(src:find("_forever" .. "_/W" .. "TF/" .. "Account/", 1, true), rel .. " refers to a real WTF account folder")
            end
        end
    end)
    it("the fixtures keep their content (md5 pinned) so the rename changed nothing", function()
        local function md5(path)
            local p = io.popen('md5 -q "' .. path .. '" 2>/dev/null || md5sum "' .. path .. '" | cut -d" " -f1')
            local s = p:read("*l"); p:close(); return s
        end
        assertEquals(md5(HF_TESTS .. "/fixtures/owner-char-v3.lua"), "dc6debef2e78ea7cd3c1619161fa4077")
        assertEquals(md5(HF_TESTS .. "/fixtures/owner-char-pre-buffgroups.lua"), "cd00e2d3e25d2744dbd40d2db0edf22a")
        assertEquals(md5(HF_TESTS .. "/fixtures/owner-account-v2.lua"), "31769ed0a2be0d0ae149b9e92199b281")
    end)
end)
