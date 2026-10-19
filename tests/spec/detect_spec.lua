local mpv = require("support.mpv")
local F = require("support.fixtures")

local function detect(opts)
    local h = mpv.new(opts)
    local env = h:load()
    return env.detect_youtube_id(), h
end

describe("detect_youtube_id", function()
    it("reads a youtube.com/watch URL", function()
        expect.eq(detect({ path = F.URL }), F.VIDEO_ID)
    end)

    it("ignores extra query parameters around v=", function()
        expect.eq(detect({ path = "https://www.youtube.com/watch?list=PL123&v=dQw4w9WgXcQ&t=42s" }), F.VIDEO_ID)
    end)

    it("reads a youtu.be short link", function()
        expect.eq(detect({ path = "https://youtu.be/dQw4w9WgXcQ?t=42" }), F.VIDEO_ID)
    end)

    it("reads an /embed/ URL", function()
        expect.eq(detect({ path = "https://www.youtube.com/embed/dQw4w9WgXcQ?start=3" }), F.VIDEO_ID)
    end)

    it("reads the legacy /v/ URL", function()
        expect.eq(detect({ path = "https://www.youtube.com/v/dQw4w9WgXcQ" }), F.VIDEO_ID)
    end)

    it("keeps - and _ inside IDs", function()
        expect.eq(detect({ path = "https://www.youtube.com/watch?v=a-b_cDeFgHi" }), "a-b_cDeFgHi")
    end)

    it("falls back to the Referer header for direct stream URLs", function()
        local id = detect({
            path = "https://rr3---sn-abc.googlevideo.com/videoplayback?expire=1",
            http_header_fields = "Referer: https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        })
        expect.eq(id, F.VIDEO_ID)
    end)

    it("falls back to the PURL metadata tag of downloaded files", function()
        local id = detect({ path = "/videos/some file.mkv", purl = "https://www.youtube.com/watch?v=dQw4w9WgXcQ" })
        expect.eq(id, F.VIDEO_ID)
    end)

    it("reads old yt-dlp file names (Title-ID.ext)", function()
        expect.eq(detect({ path = "/videos/Rick Astley - Never Gonna Give You Up-dQw4w9WgXcQ.webm" }), F.VIDEO_ID)
    end)

    it("returns nil and warns for non-YouTube URLs", function()
        local id, h = detect({ path = "https://vimeo.com/76979871" })
        expect.is_nil(id)
        expect.contains(h:log_text("warn"), "No YouTube ID detected")
    end)

    known_bug("M2", "does not treat any dashed local file name as a video ID", function()
        expect.is_nil((detect({ path = "/home/me/Videos/my-holiday-video-2023.mp4" })))
    end)

    known_bug("M2", "reads current yt-dlp file names (Title [ID].ext)", function()
        expect.eq(detect({ path = "/videos/Rick Astley - Never Gonna Give You Up [dQw4w9WgXcQ].webm" }), F.VIDEO_ID)
    end)

    known_bug("M2", "reads /shorts/ URLs", function()
        expect.eq(detect({ path = "https://www.youtube.com/shorts/dQw4w9WgXcQ" }), F.VIDEO_ID)
    end)

    known_bug("M2", "reads /live/ URLs", function()
        expect.eq(detect({ path = "https://www.youtube.com/live/dQw4w9WgXcQ" }), F.VIDEO_ID)
    end)
end)
