local F = require("support.fixtures")

describe("file lifecycle", function()
    it("stops watching time-pos when the file ends", function()
        local h = F.boot({ segments = { F.SPONSOR } })
        expect.eq(h:observer_count("time-pos"), 1)
        h:fire("end-file")
        expect.eq(h:observer_count("time-pos"), 0)
    end)

    it("starts fresh on the next file", function()
        local h = F.boot({ segments = { F.SPONSOR } })
        h:fire("end-file")
        h.props.path = "https://youtu.be/a-b_cDeFgHi"
        h.props["chapter-list"] = {}
        h:fire("file-loaded")
        local reqs = h:requests_to("GET", "/api/skipSegments")
        expect.eq(reqs[#reqs].params.videoID, "a-b_cDeFgHi")
        expect.eq(h:observer_count("time-pos"), 1)
    end)
end)

describe("error containment", function()
    it("logs an error in file-loaded and keeps handling later events", function()
        local h, env = F.boot({ no_file = true })
        local real = env.http.request
        env.http.request = function() error("boom") end
        expect.no_error(function() h:fire("file-loaded") end)
        expect.contains(h:log_text("error"), "unhandled error in file_loaded")
        env.http.request = real
        h:fire("end-file")
        h:fire("file-loaded")
        expect.count(h:requests_to("GET", "/api/skipSegments"), 1)
    end)

    it("contains an error raised while skipping", function()
        local h, env = F.boot({ segments = { F.SPONSOR } })
        env.segments.report_skip = function() error("boom") end
        expect.no_error(function() h:set_time(35) end)
        expect.eq(h.seeks, { 60.001 }, "the seek happens before the failing report")
        expect.contains(h:log_text("error"), "unhandled error in skip_ads")
    end)

    it("contains an error raised inside a key binding", function()
        local h, env = F.boot()
        env.http.request = function() error("boom") end
        expect.no_error(function() h:press("z") end)
        expect.contains(h:log_text("error"), "unhandled error in stats key")
    end)
end)

describe("toasts", function()
    it("cancels the previous toast's hide timer when a new one appears", function()
        local h, env = F.boot({ no_file = true })
        env.ui.toast("first")
        env.ui.toast("second")
        expect.truthy(h.timers[1].killed)
        expect.contains(h:screen(), "second")
        expect.not_contains(h:screen(), "first")
    end)

    it("disappears when its timer fires", function()
        local h, env = F.boot({ no_file = true })
        env.ui.toast("hello", "error", 5)
        expect.eq(h.timers[1].seconds, 5)
        h:run_timers()
        expect.eq(h:screen(), "")
    end)
end)
