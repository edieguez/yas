-- Shared test data and a one-call "boot a YouTube video" helper.

local mpv = require("support.mpv")

local F = {}

F.VIDEO_ID = "dQw4w9WgXcQ"
F.URL = "https://www.youtube.com/watch?v=" .. F.VIDEO_ID
F.USER_ID = "AbCdEfGhIjKlMnOpQrStUvWxYz012345" -- 32 alphanumerics, valid

-- One segment as the SponsorBlock API returns it.
function F.segment(uuid, category, start_time, end_time, action)
    return { UUID = uuid, category = category, segment = { start_time, end_time },
             actionType = action or "skip", videoDuration = 600 }
end

F.SPONSOR = F.segment("aaaaaa-sponsor-uuid", "sponsor", 30, 60)
F.MUTE = F.segment("bbbbbb-mute-uuid", "selfpromo", 100, 120, "mute")

F.USER_STATS = {
    userID = "public-id",
    userName = "tester",
    overallStats = { minutesSaved = 1500.5, segmentCount = 12 },
    categoryCount = { sponsor = 10, intro = 0, selfpromo = 2 },
    actionTypeCount = { skip = 11, mute = 1 },
}

-- Default API fixtures; `routes` entries override them.
function F.routes(opts)
    opts = opts or {}
    local routes = {
        ["GET /api/skipSegments"] = { code = 200, body = opts.segments or {} },
        -- The server answers with Express' sendStatus(200), i.e. body "OK".
        ["POST /api/viewedVideoSponsorTime"] = { code = 200, body = "OK" },
        ["POST /api/skipSegments"] = function(req)
            local seg = req.json and req.json.segments and req.json.segments[1] or {}
            return { code = 200, body = { { UUID = "new-uuid", category = seg.category, segment = seg.segment } } }
        end,
        ["GET /api/userStats"] = { code = 200, body = F.USER_STATS },
        ["GET /api/userInfo"] = { code = 200, body = { viewCount = 345 } },
    }
    for k, v in pairs(opts.routes or {}) do routes[k] = v end
    return mpv.router(routes)
end

-- Builds a harness playing a YouTube video, loads the script and fires
-- file-loaded. Returns harness, script environment.
--   opts.segments  API segments for this video
--   opts.routes    route overrides (see F.routes)
--   opts.conf      yas.conf values (user_id defaults to F.USER_ID)
--   opts.no_file   don't fire file-loaded
--   any other key is passed to mpv.new (path, duration, chapters, mute...)
function F.boot(opts)
    opts = opts or {}
    local conf = opts.conf or {}
    if conf.user_id == nil and not opts.generate_id then conf.user_id = F.USER_ID end
    local h = mpv.new({
        path = opts.path or F.URL,
        conf = conf,
        http = opts.http or F.routes(opts),
        duration = opts.duration,
        chapters = opts.chapters,
        mute = opts.mute,
        keep_open = opts.keep_open,
        home = opts.home,
        http_header_fields = opts.http_header_fields,
        purl = opts.purl,
    })
    local env = h:load(nil, opts.env)
    if not opts.no_file then h:fire("file-loaded") end
    return h, env
end

-- Marks a segment from `a` to `b` with ; and opens the category dialog.
function F.mark(h, a, b)
    h:set_time(a)
    h:press(";")
    h:set_time(b)
    h:press(";")
end

return F
