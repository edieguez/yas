-- Yet Another Sponsorblock plugin for MPV
local utils = require "mp.utils"
local mpoptions = require "mp.options"

-- Default options
local options = {
    server_address = "https://sponsor.ajay.app",
    categories = "sponsor,selfpromo,interaction,intro,outro,preview,hook,filler"
}

-- Load options from config file: yas.conf
mpoptions.read_options(options, "yas")

-- Parse categories into API-friendly format once
do
    local cats = {}
    for category in string.gmatch(options.categories, "([^,]+)") do
        table.insert(cats, '"' .. category .. '"')
    end
    options.categories = table.concat(cats, ",")
end

-- Endpoint variables
local endpoints = {
    skip_segments = ("%s/api/skipSegments"):format(options.server_address)
}

-- State variables
local segments = nil
local youtube_id = nil

local function curl(url, method, query_params)
    local curl_cmd = { "curl", "--location", "--silent" }
    if method == "GET" then
        table.insert(curl_cmd, "--get")
    else
        table.insert(curl_cmd, "--request")
        table.insert(curl_cmd, method)
    end
    table.insert(curl_cmd, url)

    for key, value in pairs(query_params) do
        table.insert(curl_cmd, "--data-urlencode")
        table.insert(curl_cmd, ("%s=%s"):format(key, value))
    end

    mp.msg.debug(table.concat(curl_cmd, " "))

    return mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = curl_cmd
    }
end

-- Detect YouTube video ID from multiple sources
local function detect_youtube_id()
    local video_path = mp.get_property("path", "")
    local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""
    local purl = mp.get_property("metadata/by-key/PURL", "")

    local urls = {
        "https?://youtu%.be/([%w-_]+).*",
        "https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
        "/watch.*[?&]v=([%w-_]+).*",
        "/embed/([%w-_]+).*",
        "-([%w-_]+)%." -- fallback
    }

    for _, url in ipairs(urls) do
        local candidate = string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
        if candidate and #candidate >= 11 then
            return string.sub(candidate, 1, 11)
        end
    end
    return nil
end

-- Fetch sponsorblock segments from API
local function get_segments()
    if not youtube_id then return end

    local response = curl(endpoints.skip_segments, "GET", {
        categories = ("[%s]"):format(options.categories),
        videoID = youtube_id
    })

    if not response or response.status ~= 0 or not response.stdout or response.stdout == "" then
        mp.msg.warn("SponsorBlock API request failed")
        return
    end

    if response.stdout == "Not Found" then
        mp.msg.warn("SponsorBlock API returned 404 Not Found")
        return
    end

    local parsed = utils.parse_json(response.stdout)
    if not parsed then
        mp.msg.warn("Failed to parse SponsorBlock JSON")
        return
    end

    segments = {}
    for _, seg in ipairs(parsed) do
        if seg.segment and #seg.segment == 2 then
            local start_time, end_time = tonumber(seg.segment[1]), tonumber(seg.segment[2])
            if start_time and end_time and end_time > start_time then
                table.insert(segments, {
                    start_time = start_time,
                    end_time = end_time,
                    category = seg.category or "unknown",
                    uuid = seg.UUID or "------",
                    action = seg.action or "unknown"
                })
            end
        end
    end

    if #segments > 0 then
        mp.msg.info(("SponsorBlock: %d segments found"):format(#segments))
        create_chapters()
        mp.observe_property("time-pos", "native", skip_ads)
    else
        mp.msg.info("SponsorBlock: no segments found")
    end
end

-- Create chapters in MPV UI
function create_chapters()
    if not segments then return end
    local chapters = mp.get_property_native("chapter-list") or {}
    local duration = mp.get_property_native("duration")

    for _, segment in ipairs(segments) do
        -- Start marker
        table.insert(chapters, {
            title = segment.category:gsub("^%l", string.upper):gsub("_", " ")
                .. " (" .. string.sub(segment.uuid, 1, 6) .. ")",
            time = (not duration or duration > segment.start_time)
                and segment.start_time or duration - 0.001
        })

        -- End marker
        table.insert(chapters, {
            title = "",
            time = (not duration or duration > segment.end_time)
                and segment.end_time or duration - 0.001
        })
    end

    -- Sort to avoid overlapping / unordered chapters
    table.sort(chapters, function(a, b) return a.time < b.time end)

    mp.set_property_native("chapter-list", chapters)
    mp.msg.debug("Updated chapter-list: " .. utils.to_string(chapters))
end

-- Skip segments automatically
function skip_ads(_, pos)
    if not pos or not segments then return end
    for _, segment in ipairs(segments) do
        if pos >= segment.start_time and pos < segment.end_time then
            mp.osd_message(("[sponsorblock] Skipped %s (%.1fs)"):format(
                segment.category,
                segment.end_time - segment.start_time
            ))
            mp.set_property("time-pos", segment.end_time + 0.001)
            return
        end
    end
end

-- MPV Events
local function file_loaded()
    youtube_id = detect_youtube_id()
    if not youtube_id then
        mp.msg.debug("No YouTube ID detected")
        return
    end

    get_segments()
end

-- Reset state on end of file
local function end_file()
    segments, youtube_id = nil, nil
    mp.unobserve_property(skip_ads)
end

-- Register events
mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
