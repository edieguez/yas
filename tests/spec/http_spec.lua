local mpv = require("support.mpv")
local F = require("support.fixtures")

local API = "https://sponsor.ajay.app/api/test"

local function with_reply(reply)
    local h = mpv.new({ conf = { user_id = F.USER_ID }, http = function() return reply end })
    return h, h:load()
end

describe("http_request", function()
    it("sends GET parameters with --get and --data-urlencode", function()
        local h, env = with_reply({ code = 200, body = { ok = true } })
        local data, err = env.http_request(API, "GET", { videoID = "abc", categories = '["sponsor"]' })
        expect.is_nil(err)
        expect.eq(data, { ok = true })
        local req = h.requests[1]
        expect.eq(req.method, "GET")
        expect.truthy(req.flags["--get"], "uses --get")
        expect.eq(req.params, { videoID = "abc", categories = '["sponsor"]' })
    end)

    it("sends a JSON body with a Content-Type header for POST", function()
        local h, env = with_reply({ code = 200, body = "OK" })
        env.http_request(API, "POST", nil, '{"a":1}')
        local req = h.requests[1]
        expect.eq(req.method, "POST")
        expect.eq(req.headers["content-type"], "application/json")
        expect.eq(req.json, { a = 1 })
    end)

    it("parses JSON arrays", function()
        local _, env = with_reply({ code = 200, body = "[1, 2, 3]" })
        expect.eq(env.http_request(API), { 1, 2, 3 })
    end)

    it("returns non-JSON bodies as plain strings", function()
        local _, env = with_reply({ code = 200, body = "OK" })
        expect.eq(env.http_request(API), "OK")
    end)

    it("fails when curl exits non-zero", function()
        local _, env = with_reply({ curl_status = 7 })
        local data, err = env.http_request(API)
        expect.is_nil(data)
        expect.contains(err, "status 7")
    end)

    it("fails on an empty body", function()
        local _, env = with_reply({ code = 200, body = "" })
        local data, err = env.http_request(API)
        expect.is_nil(data)
        expect.eq(err, "Empty response")
    end)

    it("maps SponsorBlock's 'Not Found' body to a 404 error", function()
        local _, env = with_reply({ code = 404, body = "Not Found" })
        local data, err = env.http_request(API)
        expect.is_nil(data)
        expect.contains(err, "404")
    end)

    it("fails on malformed JSON", function()
        local _, env = with_reply({ code = 200, body = "{oops" })
        local data, err = env.http_request(API)
        expect.is_nil(data)
        expect.eq(err, "Invalid JSON response")
    end)

    known_bug("H1", "bounds every request with a curl timeout", function()
        local h, env = with_reply({ code = 200, body = "OK" })
        env.http_request(API)
        local f = h.requests[1].flags
        expect.truthy(f["--max-time"] or f["-m"], "expected --max-time on the curl command")
    end)

    known_bug("H2", "treats an HTTP error status with a text body as a failure", function()
        local _, env = with_reply({ code = 429, body = "Too many requests" })
        local data = env.http_request(API)
        expect.is_nil(data, "a 429 must not be returned as data")
    end)

    known_bug("H3", "uses server_address from yas.conf", function()
        local h = F.boot({ conf = { server_address = "https://sb.example.org" } })
        expect.eq(h.requests[1].host, "sb.example.org")
    end)
end)
