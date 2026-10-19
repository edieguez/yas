local F = require("support.fixtures")

local function time_saved(env, minutes)
    for _, row in ipairs(env.format_user_stats({ overallStats = { minutesSaved = minutes } })) do
        if row.label == "Time Saved" then return row.value end
    end
end

local function fixed_clock(start)
    local clock = { now = start }
    clock.os = setmetatable({ time = function() return clock.now end }, { __index = os })
    return clock
end

describe("format_user_stats", function()
    it("handles missing data", function()
        local _, env = F.boot({ no_file = true })
        expect.eq(env.format_user_stats(nil)[1].text, "No user stats available")
    end)

    it("formats durations like the browser extension", function()
        local _, env = F.boot({ no_file = true })
        expect.eq(time_saved(env, 0), "0.0m")
        expect.eq(time_saved(env, 12.34), "12.3m")
        expect.eq(time_saved(env, 59.96), "1h 0.0m")
        expect.eq(time_saved(env, 1500.5), "1d 1h 0.5m")
        expect.eq(time_saved(env, 525660), "1y 1h 0.0m")
    end)

    it("lists only categories and action types with a count", function()
        local _, env = F.boot({ no_file = true })
        local labels = {}
        for _, row in ipairs(env.format_user_stats(F.USER_STATS)) do
            if row.label then labels[#labels + 1] = row.label .. "=" .. row.value end
        end
        expect.eq(labels, { "Time Saved=1d 1h 0.5m", "Segments Submitted=12",
                            "Sponsor=10", "Unpaid/Self Promotion=2", "Skip=11", "Mute=1" })
    end)
end)

describe("stats panel (z)", function()
    it("fetches user stats and view count, then draws the panel", function()
        local h = F.boot()
        h:press("z")
        local stats = h:requests_to("GET", "/api/userStats")[1]
        expect.eq(stats.params.userID, F.USER_ID)
        expect.eq(stats.params.fetchCategoryStats, "true")
        local screen = h:screen()
        expect.contains(screen, "SponsorBlock user stats for tester")
        expect.contains(screen, "1d 1h 0.5m")
        expect.contains(screen, "Saved others from 345 segments")
        expect.contains(screen, "You've skipped 0 segments")
    end)

    it("shows a loading toast and ignores z until the stats arrive", function()
        local h = F.boot()
        h.manual_async = true
        h:press("z")
        expect.contains(h:screen(), "Loading SponsorBlock stats…")
        h:press("z")
        h:flush_async()
        expect.count(h:requests_to("GET", "/api/userStats"), 1)
        expect.contains(h:screen(), "SponsorBlock user stats for tester")
        expect.not_contains(h:screen(), "Loading")
    end)

    it("doesn't open the panel over the next file if it changed while loading", function()
        local h = F.boot()
        h.manual_async = true
        h:press("z")
        h:fire("end-file")
        h:flush_async()
        expect.not_contains(h:screen(), "SponsorBlock user stats")
    end)

    it("toggles closed on the second press", function()
        local h = F.boot()
        h:press("z")
        h:press("z")
        expect.eq(h:screen(), "")
    end)

    it("reuses cached stats for five minutes", function()
        local clock = fixed_clock(1000)
        local h = F.boot({ env = { os = clock.os } })
        h:press("z"); h:press("z")
        clock.now = 1000 + 299
        h:press("z")
        expect.count(h:requests_to("GET", "/api/userStats"), 1)
        h:press("z")
        clock.now = 1000 + 301
        h:press("z")
        expect.count(h:requests_to("GET", "/api/userStats"), 2)
    end)

    it("shows stale stats if a refresh fails", function()
        local clock = fixed_clock(1000)
        local ok = true
        local h = F.boot({ env = { os = clock.os }, routes = {
            ["GET /api/userStats"] = function()
                if ok then return { code = 200, body = F.USER_STATS } end
                return { curl_status = 6 }
            end } })
        h:press("z"); h:press("z")
        ok, clock.now = false, 2000
        h:press("z")
        expect.contains(h:screen(), "SponsorBlock user stats for tester")
        expect.contains(h:log_text("warn"), "using cached data")
    end)

    it("shows an error toast when stats can't be fetched", function()
        local h = F.boot({ routes = { ["GET /api/userStats"] = { curl_status = 6 } } })
        h:press("z")
        expect.contains(h:screen(), "Failed to get user stats")
    end)

    it("omits the view count line if userInfo fails", function()
        local h = F.boot({ routes = { ["GET /api/userInfo"] = { curl_status = 6 } } })
        h:press("z")
        expect.not_contains(h:screen(), "Saved others")
        expect.contains(h:screen(), "Time Saved")
    end)

    it("closes when the file ends", function()
        local h = F.boot()
        h:press("z")
        h:fire("end-file")
        expect.eq(h:screen(), "")
    end)

    known_bug("L1", "keeps the per-user cache across files", function()
        local h = F.boot()
        h:press("z"); h:press("z")
        h:fire("end-file")
        h:fire("file-loaded")
        h:press("z")
        expect.count(h:requests_to("GET", "/api/userStats"), 1)
    end)
end)
