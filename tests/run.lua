-- Zero-dependency test runner for yas.
--
--   luajit tests/run.lua              run every spec in tests/spec/
--   luajit tests/run.lua skip stats   run specs whose file name contains "skip" or "stats"
--   YAS_VERBOSE=1 luajit tests/run.lua   print every test name
--
-- Works with LuaJIT (what mpv usually embeds) and Lua 5.1-5.4. Run it
-- from the repository root.
--
-- Spec API (globals inside spec files):
--   describe(name, fn)        group tests
--   before_each(fn)           runs before every test in the current group
--   it(name, fn)              a test; fails if fn raises
--   known_bug(id, name, fn)   a test for a reported, still-open bug: it is
--                             EXPECTED to fail. If it starts passing, the run
--                             fails with XPASS so the marker gets removed.
--   expect(...)               assertions, see tests/support/expect.lua

package.path = "tests/?.lua;" .. package.path

local mpv = require("support.mpv")
local expect = require("support.expect")

local verbose = os.getenv("YAS_VERBOSE") == "1"
local filters = { ... }

local results = { pass = 0, fail = 0, xfail = 0, xpass = 0 }
local failures = {}
local stack = {}

local function full_name(name)
    local parts = {}
    for _, g in ipairs(stack) do parts[#parts + 1] = g.name end
    parts[#parts + 1] = name
    return table.concat(parts, " > ")
end

local function run_test(name, fn, bug_id)
    local title = full_name(name)
    local crashed = false
    local ok, err = xpcall(function()
        for _, g in ipairs(stack) do
            for _, setup in ipairs(g.before) do setup() end
        end
        fn()
    end, function(e)
        if type(e) == "table" and e.expect then return e.message end
        crashed = true
        return debug.traceback(tostring(e), 2)
    end)
    mpv.cleanup_all()

    if bug_id and crashed then
        -- A known-bug test must fail on an expectation, not on a Lua error:
        -- a crash means the test (or harness) is broken, not that the bug is open.
        results.fail = results.fail + 1
        table.insert(failures, ("CRASH %s [%s]\n      %s"):format(title, bug_id, tostring(err):gsub("\n", "\n      ")))
        print("  CRASH " .. title .. " [" .. bug_id .. "]")
    elseif bug_id then
        if ok then
            results.xpass = results.xpass + 1
            table.insert(failures, ("XPASS %s [%s]\n      known bug now passes: remove the known_bug() marker"):format(title, bug_id))
            print("  XPASS " .. title .. " [" .. bug_id .. "]")
        else
            results.xfail = results.xfail + 1
            if verbose then
                print("  xfail " .. title .. " [" .. bug_id .. "]")
                print("        " .. tostring(err):gsub("\n", "\n        "))
            end
        end
    elseif ok then
        results.pass = results.pass + 1
        if verbose then print("  ok    " .. title) end
    else
        results.fail = results.fail + 1
        table.insert(failures, ("FAIL  %s\n      %s"):format(title, tostring(err):gsub("\n", "\n      ")))
        print("  FAIL  " .. title)
    end
end

function describe(name, fn)
    table.insert(stack, { name = name, before = {} })
    fn()
    table.remove(stack)
end

function before_each(fn)
    table.insert(stack[#stack].before, fn)
end

function it(name, fn) run_test(name, fn, nil) end

function known_bug(id, name, fn) run_test(name, fn, id) end

_G.expect = expect

local function list_specs()
    local files = {}
    local p = io.popen('ls tests/spec/*_spec.lua 2>/dev/null')
    if p then
        for line in p:lines() do files[#files + 1] = line end
        p:close()
    end
    table.sort(files)
    return files
end

local specs = list_specs()
if #specs == 0 then
    io.stderr:write("no specs found: run from the repository root\n")
    os.exit(2)
end

for _, file in ipairs(specs) do
    local selected = #filters == 0
    for _, f in ipairs(filters) do if file:find(f, 1, true) then selected = true end end
    if selected then
        print(file)
        local chunk, err = loadfile(file)
        if not chunk then
            results.fail = results.fail + 1
            table.insert(failures, "LOAD  " .. file .. "\n      " .. err)
        else
            local ok, e = pcall(chunk)
            if not ok then
                results.fail = results.fail + 1
                table.insert(failures, "ERROR " .. file .. "\n      " .. tostring(e))
            end
        end
    end
end

if #failures > 0 then
    print("\n" .. table.concat(failures, "\n\n"))
end

print(("\n%d passed, %d failed, %d known bugs (expected failures), %d known bugs now passing  [%s]")
    :format(results.pass, results.fail, results.xfail, results.xpass, _VERSION .. (jit and (" / " .. jit.version) or "")))

os.exit((results.fail + results.xpass) == 0 and 0 or 1)
