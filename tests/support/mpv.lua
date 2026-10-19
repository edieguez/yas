-- A fake mpv for running scripts/yas.lua outside the player.
--
-- Each test builds a fresh harness with mpv.new{...}, then h:load() runs
-- the script afresh, so no state leaks between tests. The harness records everything the script does through
-- the mp API (requests, seeks, bindings, OSD text, logs) and lets the test
-- drive it (fire events, move time-pos, press keys).
--
-- Network: curl is never executed. Each `curl` subprocess call is parsed
-- into a request table and answered by the `http` handler given to new().

local json = require("support.json")

local M = {}

local SCRIPT = "scripts/yas.lua"

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function make_temp_dir()
    local base = os.tmpname()
    os.remove(base)
    os.execute("mkdir -p " .. shell_quote(base))
    return base
end

local function url_decode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function to_string(v, seen)
    seen = seen or {}
    if type(v) ~= "table" then return type(v) == "string" and ('"' .. v .. '"') or tostring(v) end
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. to_string(val, seen) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Parses a curl argument vector into {method, url, path, params, headers, body, args}.
-- curl's name@file / @file syntax: the value is read from a file.
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then error("curl stub: cannot read " .. path) end
    local s = f:read("*a")
    f:close()
    return s
end

local function parse_curl(args)
    local req = { method = nil, params = {}, headers = {}, args = args, flags = {}, files = {} }
    local i = 2
    while i <= #args do
        local a = args[i]
        if a == "--get" or a == "-G" then req.method = "GET"; req.flags[a] = true
        elseif a == "--request" or a == "-X" then i = i + 1; req.method = args[i]
        elseif a == "--header" or a == "-H" then
            i = i + 1
            local k, v = args[i]:match("^([^:]+):%s*(.*)$")
            if k then req.headers[k:lower()] = v end
        elseif a == "--data" or a == "-d" or a == "--data-raw" then
            i = i + 1
            req.body = args[i]
            if a ~= "--data-raw" and req.body:sub(1, 1) == "@" then
                req.files[#req.files + 1] = req.body:sub(2)
                req.body = read_file(req.body:sub(2))
            end
        elseif a == "--data-urlencode" or a == "--url-query" then
            req.flags[a] = true
            i = i + 1
            local k, v = args[i]:match("^([^=@]+)=(.*)$")
            if k then
                req.params[k] = v
            else
                local fk, path = args[i]:match("^([^=@]+)@(.+)$")
                if fk then
                    req.files[#req.files + 1] = path
                    req.params[fk] = read_file(path)
                end
            end
        elseif a == "--max-time" or a == "-m" or a == "--connect-timeout"
            or a == "--user-agent" or a == "-A" or a == "--write-out" or a == "-w" then
            i = i + 1
            req.flags[a] = args[i]
        elseif a:sub(1, 1) == "-" then
            req.flags[a] = true
        else
            req.url = a
        end
        i = i + 1
    end
    req.method = req.method or (req.body and "POST" or "GET")
    local base, query = (req.url or ""):match("^([^?]*)%??(.*)$")
    req.path = base:gsub("^https?://[^/]+", "")
    req.host = base:match("^https?://([^/]+)")
    for k, v in (query or ""):gmatch("([^&=]+)=([^&]*)") do req.params[url_decode(k)] = url_decode(v) end
    if req.body and (req.headers["content-type"] or ""):find("json") then
        req.json = json.decode(req.body)
    end
    return req
end

-- Turns a handler reply ({code, body} | {curl_status}) into what mpv's
-- subprocess command returns, honouring --write-out and --fail flags so a
-- fixed http_request() is testable with the same fixtures.
local function curl_result(req, reply)
    reply = reply or { code = 404, body = "Not Found" }
    if reply.curl_status then return { status = reply.curl_status, stdout = "" } end
    local code = reply.code or 200
    local body = reply.body or ""
    if type(body) == "table" then body = json.encode(body) end
    if code >= 400 and (req.flags["--fail"] or req.flags["-f"]) then
        return { status = 22, stdout = "" }
    end
    local status = 0
    if code >= 400 and req.flags["--fail-with-body"] then status = 22 end
    local wo = req.flags["--write-out"] or req.flags["-w"]
    if type(wo) == "string" then
        body = body .. wo:gsub("\\n", "\n"):gsub("%%{http_code}", tostring(code))
    end
    return { status = status, stdout = body }
end

local created = {}

-- Removes the temp HOME of every harness built so far (called by the runner).
function M.cleanup_all()
    for _, h in ipairs(created) do h:cleanup() end
    created = {}
end

function M.new(opts)
    opts = opts or {}
    local h = {
        home = make_temp_dir(),
        conf = opts.conf or {},
        props = {
            path = opts.path or "",
            ["http-header-fields"] = opts.http_header_fields or "",
            ["metadata/by-key/PURL"] = opts.purl or "",
            duration = opts.duration or 600,
            ["chapter-list"] = opts.chapters or {},
            mute = opts.mute or false,
            pause = false,
            ["keep-open"] = opts.keep_open or "yes",
            ["eof-reached"] = false,
            ["osd-dimensions"] = { w = 1280, h = 720, aspect = 16 / 9 },
        },
        http = opts.http,
        requests = {},
        logs = { fatal = {}, error = {}, warn = {}, info = {}, verbose = {}, debug = {}, trace = {} },
        all_logs = {},
        events = {},
        observers = {},
        bindings = {},
        timers = {},
        overlays = {},
        osd_history = {},
        commands = {},
        seeks = {},
    }
    if opts.time_pos then h.props["time-pos"] = opts.time_pos end

    -- Shared state dir between harnesses (simulates restarting mpv).
    if opts.home then h.home = opts.home else table.insert(created, h) end

    local mp = {}
    h.mp = mp

    local function log(level)
        return function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            local line = table.concat(parts, " ")
            table.insert(h.logs[level], line)
            table.insert(h.all_logs, level .. ": " .. line)
        end
    end
    mp.msg = { fatal = log("fatal"), error = log("error"), warn = log("warn"), info = log("info"),
               verbose = log("verbose"), debug = log("debug"), trace = log("trace") }

    -- Properties ---------------------------------------------------------
    function mp.get_property(name, def)
        local v = h.props[name]
        if v == nil or type(v) == "table" then return def end
        if type(v) == "boolean" then return v and "yes" or "no" end
        return tostring(v)
    end
    function mp.get_property_native(name, def)
        local v = h.props[name]
        if v == nil then return def end
        return v
    end
    function mp.get_property_bool(name, def)
        local v = h.props[name]
        if v == nil then return def end
        return v == true or v == "yes"
    end
    function mp.get_property_number(name, def)
        return tonumber(h.props[name]) or def
    end
    local function set(name, v)
        if name == "time-pos" then table.insert(h.seeks, v) end
        h.props[name] = v
        return true
    end
    mp.set_property = set
    mp.set_property_native = set
    mp.set_property_bool = set
    mp.set_property_number = set

    function mp.observe_property(name, _type, fn)
        table.insert(h.observers, { name = name, fn = fn })
        fn(name, h.props[name]) -- mpv delivers the current value right away
    end
    function mp.unobserve_property(fn)
        for i = #h.observers, 1, -1 do
            if h.observers[i].fn == fn then table.remove(h.observers, i) end
        end
    end

    -- Events, bindings, timers -------------------------------------------
    function mp.register_event(name, fn)
        h.events[name] = h.events[name] or {}
        table.insert(h.events[name], fn)
    end
    local function bind(forced)
        return function(key, name, fn)
            if type(name) == "function" then fn, name = name, nil end
            name = name or ("__anon_" .. tostring(fn))
            h.bindings[name] = { key = key, fn = fn, forced = forced }
        end
    end
    mp.add_key_binding = bind(false)
    mp.add_forced_key_binding = bind(true)
    function mp.remove_key_binding(name) h.bindings[name] = nil end

    function mp.add_timeout(seconds, fn)
        local t = { seconds = seconds, fn = fn, killed = false }
        function t:kill() self.killed = true end
        function t:resume() self.killed = false end
        table.insert(h.timers, t)
        return t
    end
    function mp.add_periodic_timer(seconds, fn)
        local t = mp.add_timeout(seconds, fn)
        t.periodic = true
        return t
    end

    -- Commands -----------------------------------------------------------
    local function expand(p)
        p = p:gsub("^~~/", h.home .. "/.config/mpv/")
        p = p:gsub("^~/", h.home .. "/")
        return p
    end

    local function subprocess(t)
        local args = t.args
        if args[1] == "curl" then
            local req = parse_curl(args)
            table.insert(h.requests, req)
            local reply = h.http and h.http(req)
            return curl_result(req, reply)
        elseif args[1] == "mkdir" or args[1] == "chmod" then
            local cmd = args[1]
            for i = 2, #args do cmd = cmd .. " " .. shell_quote(args[i]) end
            local ok = os.execute(cmd)
            return { status = (ok == 0 or ok == true) and 0 or 1, stdout = "" }
        end
        -- mpv reports a program it can't start as success=true with a
        -- negative status, not as a failed command
        return { status = -3, error_string = "init", stdout = "" }
    end

    -- Real mpv dumps every command it runs at debug level (player/command.c,
    -- mp_cmd_dump) - so a --log-file sees subprocess arguments verbatim.
    local function dump(t)
        local parts = {}
        for _, a in ipairs(t.args or t) do parts[#parts + 1] = tostring(a) end
        log("debug")("Run command: " .. table.concat(parts, " "))
    end

    function mp.command_native(t, def)
        dump(t)
        if t[1] == "expand-path" then return expand(t[2]) end
        if t.name == "subprocess" then return subprocess(t) end
        table.insert(h.commands, t)
        return def
    end
    function mp.command_native_async(t, cb)
        local ok, res = pcall(mp.command_native, t)
        local job = {}
        -- Queue the callback, like mpv does on its next event-loop turn.
        h.pending_async = h.pending_async or {}
        table.insert(h.pending_async, function()
            if cb then
                if ok then cb(true, res, nil) else cb(false, nil, tostring(res)) end
            end
        end)
        return job
    end
    function mp.abort_async_command() end
    function mp.commandv(...)
        table.insert(h.commands, { ... })
        return true
    end
    function mp.command(s) table.insert(h.commands, { s }); return true end

    -- OSD ------------------------------------------------------------------
    function mp.create_osd_overlay(format)
        local ov = { format = format, data = "", res_x = 0, res_y = 0, z = 0, hidden = false }
        function ov.update(self)
            if not self.hidden then table.insert(h.osd_history, self.data) end
            if self.compute_bounds then
                local plain = self.data:gsub("{[^}]*}", "")
                return { x0 = 0, y0 = 0, x1 = #plain * 12, y1 = 24 }
            end
        end
        function ov.remove(self) self.data = ""; self.removed = true end
        table.insert(h.overlays, ov)
        return ov
    end
    function mp.osd_message(text) table.insert(h.osd_history, text) end
    function mp.get_osd_size() return 1280, 720 end
    function mp.get_script_name() return "yas" end
    function mp.get_script_directory() return nil end
    function mp.get_time() return os.clock() end

    -- Modules required by the script ----------------------------------------
    h.utils = {
        parse_json = function(s)
            local v, e = json.decode(s)
            if v == nil then return nil, e end
            return v
        end,
        format_json = function(v) return json.encode(v) end,
        to_string = to_string,
        split_path = function(p)
            local dir, file = p:match("^(.*/)([^/]*)$")
            if not dir then return ".", p end
            return dir, file
        end,
        join_path = function(a, b) return a:gsub("/$", "") .. "/" .. b end,
        file_info = function(p)
            local f = io.open(p, "r")
            if not f then return nil end
            f:close()
            return { is_file = true }
        end,
    }
    h.options = {
        read_options = function(tbl, name, on_update)
            h.read_options_name = name
            h.on_options_update = on_update
            for k, v in pairs(h.conf) do
                if tbl[k] ~= nil then
                    local kind = type(tbl[k])
                    if kind == "number" then v = tonumber(v)
                    elseif kind == "boolean" then v = (v == "yes" or v == true)
                    else v = tostring(v) end
                    tbl[k] = v
                end
            end
        end,
    }
    h.assdraw = {
        ass_new = function()
            local a = { text = "" }
            local function app(s) a.text = a.text .. s end
            function a:new_event() if #self.text > 0 then app("\n") end end
            function a:an(n) app(("{\\an%d}"):format(n)) end
            function a:pos(x, y) app(("{\\pos(%s,%s)}"):format(x, y)) end
            function a:append(s) app(s) end
            function a:draw_start() app("{\\p1}") end
            function a:draw_stop() app("{\\p0}") end
            function a:round_rect_cw(...) app("m rrect") end
            function a:rect_cw(...) app("m rect") end
            function a:move_to(...) end
            function a:line_to(...) end
            return a
        end,
    }

    ----------------------------------------------------------------------------
    -- Harness API used by the specs
    ----------------------------------------------------------------------------

    -- Runs scripts/yas.lua and returns its sections (the table the file
    -- returns, which mpv ignores): yas.http, yas.segments, ... Tests may
    -- replace a section function (yas.http.request = ...) since sections
    -- call each other through these tables.
    --
    -- `extra` swaps globals (e.g. a fake `os` with a fixed clock) while the
    -- script loads; it keeps the values it captured.
    function h:load(path, extra)
        path = path or SCRIPT

        for name in pairs(package.loaded) do
            if name:match("^mp%.") then package.loaded[name] = nil end
        end
        -- mp.input exists since mpv 0.38; opts.no_input simulates older mpv
        package.preload["mp.input"] = not opts.no_input and function()
            return {
                get = function(t) self.input_prompt = t end,
                terminate = function() self.input_prompt = nil end,
            }
        end or nil
        package.preload["mp.utils"] = function() return self.utils end
        package.preload["mp.options"] = function() return self.options end
        package.preload["mp.assdraw"] = function() return self.assdraw end

        local globals = { mp = self.mp }
        for k, v in pairs(extra or {}) do globals[k] = v end
        local saved = {}
        for k, v in pairs(globals) do
            saved[k] = rawget(_G, k)
            rawset(_G, k, v)
        end

        local chunk, load_err = loadfile(path)
        local ok, result = false, load_err
        if chunk then ok, result = pcall(chunk) end

        for k in pairs(globals) do rawset(_G, k, saved[k]) end
        if not ok then error(result, 0) end

        self.yas = result
        self.env = result
        return result
    end

    function h:fire(name, data)
        for _, fn in ipairs(self.events[name] or {}) do fn(data or { event = name }) end
        if not self.manual_async then self:flush_async() end
    end

    -- Set h.manual_async = true to keep requests "in flight" until the
    -- test calls h:flush_async() itself (e.g. to change files meanwhile).

    -- Delivers queued command_native_async callbacks (repeatedly, since a
    -- callback may start another request).
    function h:flush_async()
        local guard = 0
        while self.pending_async and #self.pending_async > 0 do
            local q = self.pending_async
            self.pending_async = {}
            for _, cb in ipairs(q) do cb() end
            guard = guard + 1
            assert(guard < 100, "async callbacks never settled")
        end
    end

    -- Moves playback to `t` and notifies time-pos observers.
    function h:set_time(t)
        self.props["time-pos"] = t
        for _, o in ipairs(self.observers) do
            if o.name == "time-pos" then o.fn("time-pos", t) end
        end
        if not self.manual_async then self:flush_async() end
    end

    function h:observer_count(name)
        local n = 0
        for _, o in ipairs(self.observers) do if o.name == name then n = n + 1 end end
        return n
    end

    -- Presses a key: forced bindings win over normal ones, as in mpv.
    function h:press(key)
        local hit
        for _, b in pairs(self.bindings) do
            if b.key == key and (b.forced or not hit) then hit = b end
        end
        assert(hit, "no binding for key " .. key)
        hit.fn()
        if not self.manual_async then self:flush_async() end
    end

    function h:has_binding(key)
        for _, b in pairs(self.bindings) do if b.key == key then return true end end
        return false
    end

    function h:forced_count()
        local n = 0
        for _, b in pairs(self.bindings) do if b.forced then n = n + 1 end end
        return n
    end

    -- Expires every pending timer (e.g. hides toasts).
    function h:run_timers()
        local list = self.timers
        self.timers = {}
        for _, t in ipairs(list) do if not t.killed then t.fn() end end
    end

    -- Text currently drawn on the OSD, with ASS tags stripped.
    function h:screen()
        local out = {}
        for _, ov in ipairs(self.overlays) do
            if not ov.hidden and ov.data ~= "" then
                out[#out + 1] = (ov.data:gsub("{[^}]*}", ""):gsub("m r?rect", ""))
            end
        end
        return table.concat(out, "\n")
    end

    -- Everything ever drawn, tags stripped (toasts may already be gone).
    function h:osd_text()
        return (table.concat(self.osd_history, "\n"):gsub("{[^}]*}", ""):gsub("m r?rect", ""))
    end

    function h:requests_to(method, path)
        local out = {}
        for _, r in ipairs(self.requests) do
            if r.method == method and r.path == path then out[#out + 1] = r end
        end
        return out
    end

    function h:log_text(level)
        if level then return table.concat(self.logs[level], "\n") end
        return table.concat(self.all_logs, "\n")
    end

    function h:state_file(name)
        return self.home .. "/.local/state/mpv/" .. name
    end

    function h:read_state_file(name)
        local f = io.open(self:state_file(name), "r")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end

    function h:write_state_file(name, content)
        os.execute("mkdir -p " .. shell_quote(self.home .. "/.local/state/mpv"))
        local f = assert(io.open(self:state_file(name), "w"))
        f:write(content)
        f:close()
    end

    function h:cleanup()
        os.execute("rm -rf " .. shell_quote(self.home))
    end

    return h
end

-- Small router for the http handler: routes["GET /api/skipSegments"] = fn(req) | reply.
function M.router(routes)
    return function(req)
        local r = routes[req.method .. " " .. req.path]
        if type(r) == "function" then return r(req) end
        return r
    end
end

M.json = json
M.parse_curl = parse_curl

return M
