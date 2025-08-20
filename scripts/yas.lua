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

-- Debug variables start
youtube_id = "kG22Z4vJhXY"
-- Debug variables end

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
end

function get_ranges()
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
    mp.msg.debug("get_ranges() segments: ", utils.to_string(segments))
end

function parse_categories()
    categories = {}
    for category in string.gmatch(options.categories, "([^,]+)") do
        table.insert(categories, '"' .. category .. '"')
    end
    options.categories = table.concat(categories, ",")
end

-- Init section
parse_categories()

-- MPV events
-- mp.register_event("file-loaded", file_loaded)
mp.add_key_binding("g", "test", get_ranges)
