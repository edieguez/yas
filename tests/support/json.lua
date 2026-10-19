-- Minimal JSON encode/decode, enough to stand in for mpv's
-- utils.parse_json / utils.format_json in tests. Not a general-purpose
-- library: no surrogate-pair handling, numbers via tonumber().

local json = {}

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function encode(v)
    local t = type(v)
    if v == nil or v == json.null then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then
        if v % 1 == 0 and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.17g", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return escapes[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "table" then
        local arr, n = is_array(v)
        local out = {}
        if arr and (n > 0 or next(v) == nil) then
            for i = 1, n do out[i] = encode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            out[#out + 1] = encode(k) .. ":" .. encode(v[k])
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    error("cannot encode " .. t)
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

function json.encode(v) return encode(v) end

function json.decode(s)
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local function err(msg) error(("json: %s at %d"):format(msg, pos), 0) end
    local value

    local function str()
        pos = pos + 1
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            if c == "" then err("unterminated string") end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if e == "u" then
                    local code = tonumber(s:sub(pos + 2, pos + 5), 16) or err("bad \\u")
                    if code < 128 then buf[#buf + 1] = string.char(code)
                    elseif code < 2048 then
                        buf[#buf + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
                    else
                        buf[#buf + 1] = string.char(224 + math.floor(code / 4096),
                            128 + math.floor(code / 64) % 64, 128 + code % 64)
                    end
                    pos = pos + 6
                else
                    buf[#buf + 1] = map[e] or e
                    pos = pos + 2
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then err("expected key") end
                local k = str()
                ws()
                if s:sub(pos, pos) ~= ":" then err("expected ':'") end
                pos = pos + 1
                obj[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then err("expected ',' or '}'") end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then err("expected ',' or ']'") end
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then err("unexpected character '" .. c .. "'") end
            pos = pos + #num
            return tonumber(num)
        end
    end

    local ok, result = pcall(function()
        local v = value()
        ws()
        if pos <= #s then err("trailing garbage") end
        return v
    end)
    if ok then return result end
    return nil, result
end

return json
