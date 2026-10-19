local mpv = require("support.mpv")
local F = require("support.fixtures")

local API = "https://sponsor.ajay.app/api/test"

local function with_reply(reply)
    local h = mpv.new({ conf = { user_id = F.USER_ID }, http = function() return reply end })
    return h, h:load()
end

-- Calls the async http_request and returns what its callback received.
local function request(h, env, ...)
    local got
    local args = { ... }
    env.http_request(args[1], args[2], args[3], args[4], function(data, err, code)
        got = { data = data, err = err, code = code }
    end)
    expect.is_nil(got, "callback must not run before the request finishes")
    h:flush_async()
    expect.truthy(got, "callback was never called")
    return got.data, got.err, got.code
end

describe("http_request", function()
    it("sends GET parameters with --get and --data-urlencode", function()
        local h, env = with_reply({ code = 200, body = { ok = true } })
        local data, err, code = request(h, env, API, "GET", { videoID = "abc", categories = '["sponsor"]' })
        expect.is_nil(err)
        expect.eq(code, 200)
        expect.eq(data, { ok = true })
        local req = h.requests[1]
        expect.eq(req.method, "GET")
        expect.truthy(req.flags["--get"], "uses --get")
        expect.eq(req.params, { videoID = "abc", categories = '["sponsor"]' })
    end)

    it("stringifies boolean parameters (PUC Lua 5.1 %s rejects them)", function()
        local h, env = with_reply({ code = 200, body = "{}" })
        request(h, env, API, "GET", { fetchCategoryStats = true })
        expect.eq(h.requests[1].params.fetchCategoryStats, "true")
    end)

    it("sends a JSON body with a Content-Type header for POST", function()
        local h, env = with_reply({ code = 200, body = "OK" })
        request(h, env, API, "POST", nil, '{"a":1}')
        local req = h.requests[1]
        expect.eq(req.method, "POST")
        expect.eq(req.headers["content-type"], "application/json")
        expect.eq(req.json, { a = 1 })
    end)

    it("bounds every request with connect and total timeouts", function()
        local h, env = with_reply({ code = 200, body = "OK" })
        request(h, env, API)
        expect.truthy(h.requests[1].flags["--connect-timeout"])
        expect.truthy(h.requests[1].flags["--max-time"])
    end)

    it("parses JSON arrays", function()
        local h, env = with_reply({ code = 200, body = "[1, 2, 3]" })
        expect.eq((request(h, env, API)), { 1, 2, 3 })
    end)

    it("returns non-JSON bodies as plain strings", function()
        local h, env = with_reply({ code = 200, body = "OK" })
        expect.eq((request(h, env, API)), "OK")
    end)

    it("accepts an empty 2xx body", function()
        local h, env = with_reply({ code = 200, body = "" })
        local data, err = request(h, env, API)
        expect.eq(data, "")
        expect.is_nil(err)
    end)

    it("fails when curl exits non-zero, naming common causes", function()
        local h, env = with_reply({ curl_status = 28 })
        local data, err = request(h, env, API)
        expect.is_nil(data)
        expect.contains(err, "status 28 (request timed out)")
    end)

    it("fails on an HTTP error status and keeps the server's message", function()
        local h, env = with_reply({ code = 429, body = "Too many requests\n" })
        local data, err, code = request(h, env, API)
        expect.is_nil(data)
        expect.eq(code, 429)
        expect.eq(err, "HTTP 429: Too many requests")
    end)

    it("reports a 404 with its status code", function()
        local h, env = with_reply({ code = 404, body = "Not Found" })
        local data, err, code = request(h, env, API)
        expect.is_nil(data)
        expect.eq(code, 404)
        expect.contains(err, "HTTP 404")
    end)

    it("fails on malformed JSON", function()
        local h, env = with_reply({ code = 200, body = "{oops" })
        local data, err = request(h, env, API)
        expect.is_nil(data)
        expect.eq(err, "Invalid JSON response")
    end)

    it("explains when curl can't be started at all", function()
        local h, env = with_reply(nil)
        h.mp.command_native = (function(orig)
            return function(t, def)
                if t.name == "subprocess" then return { status = -3, error_string = "init", stdout = "" } end
                return orig(t, def)
            end
        end)(h.mp.command_native)
        local data, err = request(h, env, API)
        expect.is_nil(data)
        expect.eq(err, "curl could not be started (init)")
    end)

    it("sends POST parameters in the URL, as SponsorBlock expects", function()
        local h, env = with_reply({ code = 200, body = "" })
        request(h, env, API, "POST", { UUID = "abc" })
        expect.truthy(h.requests[1].flags["--url-query"])
        expect.eq(h.requests[1].params.UUID, "abc")
    end)

    it("contains an error raised inside the callback", function()
        local h, env = with_reply({ code = 200, body = "OK" })
        env.http_request(API, "GET", nil, nil, function() error("boom") end)
        expect.no_error(function() h:flush_async() end)
        expect.contains(h:log_text("error"), "unhandled error in http callback")
    end)

    it("uses server_address from yas.conf", function()
        local h = F.boot({ conf = { server_address = "https://sb.example.org/" } })
        expect.eq(h.requests[1].host, "sb.example.org")
        expect.eq(h.requests[1].path, "/api/skipSegments")
    end)
end)
