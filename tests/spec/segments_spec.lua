local F = require("support.fixtures")

local function chapter_titles(h)
    local out = {}
    for _, c in ipairs(h.props["chapter-list"]) do out[#out + 1] = ("%g %s"):format(c.time, c.title) end
    return out
end

describe("fetching segments", function()
    it("requests the video's segments with the default categories and action types", function()
        local h = F.boot()
        local reqs = h:requests_to("GET", "/api/skipSegments")
        expect.count(reqs, 1)
        expect.eq(reqs[1].params.videoID, F.VIDEO_ID)
        expect.eq(reqs[1].params.categories,
            '["sponsor","selfpromo","interaction","intro","outro","preview","hook","filler","poi_highlight","exclusive_access"]')
        expect.eq(reqs[1].params.actionTypes, '["skip","mute","poi","full"]')
    end)

    it("sends the categories configured in yas.conf", function()
        local h = F.boot({ conf = { categories = "sponsor,intro", action_types = "skip",
                                    highlight = "no", full_video_labels = "no" } })
        local req = h:requests_to("GET", "/api/skipSegments")[1]
        expect.eq(req.params.categories, '["sponsor","intro"]')
        expect.eq(req.params.actionTypes, '["skip"]')
    end)

    it("trims spaces in comma-separated option lists", function()
        local h = F.boot({ conf = { categories = "sponsor, intro", highlight = "no", full_video_labels = "no" } })
        local req = h:requests_to("GET", "/api/skipSegments")[1]
        expect.eq(req.params.categories, '["sponsor","intro"]')
    end)

    it("does nothing for files that aren't YouTube videos", function()
        local h = F.boot({ path = "/videos/holiday.mp4" })
        expect.count(h.requests, 0)
        expect.eq(h:observer_count("time-pos"), 0)
    end)

    it("starts watching time-pos only when segments exist", function()
        local h = F.boot({ segments = {} })
        expect.eq(h:observer_count("time-pos"), 0)
        expect.contains(h:log_text("info"), "no segments found")
    end)

    it("treats a 404 as 'no segments', not as an error", function()
        local h = F.boot({ routes = { ["GET /api/skipSegments"] = { code = 404, body = "Not Found" } } })
        expect.eq(h:observer_count("time-pos"), 0)
        expect.contains(h:log_text("info"), "no segments found")
        expect.eq(h:log_text("warn"), "", "a 404 is routine, not a warning")
    end)

    it("ignores segments that arrive after the file changed", function()
        local h = F.boot({ segments = { F.SPONSOR }, no_file = true })
        h.manual_async = true
        h:fire("file-loaded")
        h:fire("end-file")
        h:flush_async()
        expect.eq(h:observer_count("time-pos"), 0)
        expect.eq(#h.props["chapter-list"], 0)
    end)

    it("doesn't block: segments apply only once the response arrives", function()
        local h = F.boot({ segments = { F.SPONSOR }, no_file = true })
        h.manual_async = true
        h:fire("file-loaded")
        expect.eq(h:observer_count("time-pos"), 0)
        h:flush_async()
        expect.eq(h:observer_count("time-pos"), 1)
    end)

    it("applies only the newest reply when requests overlap", function()
        local calls = 0
        local h, env = F.boot({ no_file = true, routes = { ["GET /api/skipSegments"] = function()
            calls = calls + 1
            return { code = 200, body = calls == 1 and { F.SPONSOR } or { F.SPONSOR, F.MUTE } }
        end } })
        h.manual_async = true
        h:fire("file-loaded")      -- slow first request
        env.segments.get()         -- refresh, e.g. after a submission
        -- deliver the refresh first, then the stale first reply
        local q = h.pending_async
        h.pending_async = { q[2], q[1] }
        h:flush_async()
        expect.eq(#h.props["chapter-list"], 4, "both segments from the newest reply")
    end)

    it("survives a failed request without watching time-pos", function()
        local h = F.boot({ routes = { ["GET /api/skipSegments"] = { curl_status = 6 } } })
        expect.eq(h:observer_count("time-pos"), 0)
        expect.contains(h:log_text("warn"), "SponsorBlock API request failed")
    end)

    it("drops malformed segments and keeps valid ones", function()
        local h = F.boot({ segments = {
            { UUID = "x1", category = "sponsor", segment = { 10 }, actionType = "skip" },
            { UUID = "", category = "sponsor", segment = { 10, 20 }, actionType = "skip" },
            { UUID = "x3", category = "sponsor", segment = { 50, 40 }, actionType = "skip" },
            { UUID = "x4", segment = { 1, 2 }, actionType = "skip" },
            F.SPONSOR,
        } })
        expect.eq(#h.props["chapter-list"], 2, "one valid segment = two chapter marks")
        expect.contains(h:log_text("warn"), "malformed")
    end)

    it("does not stack observers when segments are fetched again", function()
        local h, env = F.boot({ segments = { F.SPONSOR } })
        env.segments.get()
        env.segments.get()
        h:flush_async()
        expect.eq(h:observer_count("time-pos"), 1)
    end)
end)

describe("chapters", function()
    it("merges segment chapters with the video's own, in time order", function()
        local h = F.boot({
            segments = { F.SPONSOR, F.MUTE },
            chapters = { { title = "Intro", time = 0 }, { title = "Main", time = 80 } },
        })
        expect.eq(chapter_titles(h), {
            "0 Intro",
            "30 Sponsor (aaaaaa)",
            "60 Intro",
            "80 Main",
            "100 Unpaid/Self Promotion [Mute] (bbbbbb)",
            "120 Main",
        })
    end)

    it("rebuilds from the original chapters on re-fetch instead of duplicating", function()
        local h, env = F.boot({ segments = { F.SPONSOR }, chapters = { { title = "Intro", time = 0 } } })
        env.segments.get()
        h:flush_async()
        expect.eq(#h.props["chapter-list"], 3)
    end)

    it("clamps marks that fall past the end of the video", function()
        local h = F.boot({ duration = 600, segments = { F.segment("cccccc-outro", "outro", 590, 700) } })
        local last = h.props["chapter-list"][2]
        expect.eq(last.time, 599.999)
    end)

    it("titles chapters with the categories' display names", function()
        local h = F.boot({ segments = { F.segment("dddddd-music", "music_offtopic", 5, 9) } })
        expect.eq(h.props["chapter-list"][1].title, "Music: Non-Music Section (dddddd)")
    end)

    it("prettifies categories it doesn't know", function()
        local h = F.boot({ segments = { F.segment("eeeeee-new", "brand_new_thing", 5, 9) } })
        expect.eq(h.props["chapter-list"][1].title, "Brand new thing (eeeeee)")
    end)

    it("keeps the video's chapter name after a segment ends", function()
        local h = F.boot({ segments = { F.SPONSOR }, chapters = { { title = "Intro", time = 0 } } })
        expect.eq(h.props["chapter-list"][3].title, "Intro")
    end)
end)
