-- Yet Another Sponsorblock plugin for MPV
local utils = require "mp.utils"

-- Default options
local options = {
    server_address = "https://sponsor.ajay.app",
    categories = "sponsor,selfpromo,interaction,intro,outro,preview,hook,filler"
}

-- Load options from config file
mp.options = require "mp.options"
mp.options.read_options(options, "yas")

-- Endpoint variables
skip_segments_endpoint = ("%s/api/skipSegments"):format(options.server_address)

-- State variables
segments = nil
categories = nil

function file_loaded()
    mp.msg.debug("file_loaded() function")

    local video_path = mp.get_property("path", "")
    local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""

    local urls = {
        "https?://youtu%.be/([%w-_]+).*",
        "https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
        "/watch.*[?&]v=([%w-_]+).*",
        "/embed/([%w-_]+).*",
        "-([%w-_]+)%."
    }

    youtube_id = nil
    local purl = mp.get_property("metadata/by-key/PURL", "")
    for i,url in ipairs(urls) do
        youtube_id = youtube_id or string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
    end

    if not youtube_id or string.len(youtube_id) < 11 then return end
    youtube_id = string.sub(youtube_id, 1, 11)

    if not categories then
        parse_categories()
    end
    get_segments()
end

function get_segments()
    local cstr = ("categories=[%s]"):format(options.categories)
    local vstr = ("videoID=%s"):format(youtube_id)

    local curl_cmd = {
        "curl",
        "-L",
        "-s",
        "-G",
        "-d", cstr,
        "-d", vstr,
        skip_segments_endpoint
    }

    mp.msg.debug(table.concat(curl_cmd," "))

    local response = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = curl_cmd
    }

    segments = utils.parse_json(response.stdout)
    mp.msg.debug("get_segments() segments: ", utils.to_string(segments))

    -- Create chapters if segments were found
    if segments and #segments > 0 then
        create_chapters()
        mp.observe_property("time-pos", "native", skip_ads)
    end
end

function create_chapters()
    if not segments then return end

    local chapters = mp.get_property_native("chapter-list")
    local duration = mp.get_property_native("duration")

    for i, segment in ipairs(segments) do
        -- Start segment
        table.insert(chapters, {
            title=segment.category:gsub("^%l", string.upper):gsub("_", " ") .. " (" .. string.sub(segment.UUID, 1, 6) .. ")",
            time=(duration == nil or duration > segment.segment[1]) and segment.segment[1] or duration - .001
        })

        -- End segment
        table.insert(chapters, {
            title="",
            time=(duration == nil or duration > segment.segment[2]) and segment.segment[2] or duration - .001
        })
    end

    table.sort(chapters, time_sort)
    mp.msg.debug("chapter-list" .. utils.to_string(chapters))
    mp.set_property_native("chapter-list", chapters)
end

function time_sort(a, b)
    if a.time == b.time then
        return string.match(a.title, "segment end")
    end
    return a.time < b.time
end

function skip_ads(name, pos)
    if pos ~= nil then
        for _, segment in ipairs(segments) do
            local start_time = segment.segment[1]
            local end_time = segment.segment[2]
            if start_time <= pos and end_time > pos then
                -- Display message and skip to the end of the ad segment
                mp.osd_message(("[sponsorblock] skipping %ds"):format(math.floor(end_time - mp.get_property("time-pos"))))
                mp.set_property("time-pos", end_time + 0.001) -- Adding a small offset to avoid issues
                return
            end
        end
    end
end

function parse_categories()
    categories = {}
    for category in string.gmatch(options.categories, "([^,]+)") do
        table.insert(categories, '"' .. category .. '"')
    end
    options.categories = table.concat(categories, ",")
end

-- MPV events
mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
