-- Assertions for the yas specs. Each raises {expect=true, message=...}
-- so the runner can print a clean message instead of a traceback.

local E = {}

local function show(v)
    if type(v) == "string" then return ("%q"):format(v) end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. show(x) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function fail(msg, extra)
    local info = debug.getinfo(3, "Sl")
    local where = info and (info.short_src .. ":" .. info.currentline) or "?"
    error({ expect = true, message = where .. ": " .. msg .. (extra and ("\n" .. extra) or "") }, 0)
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then
        if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-9 end
        return false
    end
    for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function E.eq(actual, expected, msg)
    if not deep_equal(actual, expected) then
        fail((msg and (msg .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual))
    end
end

function E.neq(actual, unexpected, msg)
    if deep_equal(actual, unexpected) then
        fail((msg and (msg .. ": ") or "") .. "did not expect " .. show(unexpected))
    end
end

function E.truthy(v, msg)
    if not v then fail(msg or ("expected a truthy value, got " .. show(v))) end
end

function E.falsy(v, msg)
    if v then fail(msg or ("expected a falsy value, got " .. show(v))) end
end

function E.is_nil(v, msg)
    if v ~= nil then fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. show(v)) end
end

-- Plain-text substring check (no Lua patterns).
function E.contains(haystack, needle, msg)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        fail((msg and (msg .. ": ") or "") .. "expected text to contain " .. show(needle),
            "      in: " .. show(haystack))
    end
end

function E.not_contains(haystack, needle, msg)
    if type(haystack) == "string" and haystack:find(needle, 1, true) then
        fail((msg and (msg .. ": ") or "") .. "expected text NOT to contain " .. show(needle),
            "      in: " .. show(haystack))
    end
end

function E.matches(s, pattern, msg)
    if type(s) ~= "string" or not s:match(pattern) then
        fail((msg and (msg .. ": ") or "") .. "expected " .. show(s) .. " to match " .. pattern)
    end
end

function E.count(list, n, msg)
    if #list ~= n then
        fail((msg and (msg .. ": ") or "") .. ("expected %d item(s), got %d"):format(n, #list))
    end
end

function E.raises(fn, msg)
    if pcall(fn) then fail(msg or "expected an error") end
end

function E.no_error(fn, msg)
    local ok, err = pcall(fn)
    if not ok then fail((msg and (msg .. ": ") or "") .. "unexpected error: " .. tostring(err)) end
end

return E
