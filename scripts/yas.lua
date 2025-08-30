-- Yet Another Sponsorblock plugin for MPV
-- Based on
--   https://github.com/po5/mpv_sponsorblock
--   https://codeberg.org/jouni/mpv_sponsorblock_minimal

local utils = require "mp.utils"
local mpoptions = require "mp.options"

-- Default options
local options = {
    server_address = "https://sponsor.ajay.app",
    categories = "sponsor,selfpromo,interaction,intro,outro,preview,hook,filler",
    user_id = ""
}

-- Load options from config file: script-opts/yas.conf
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
    skip_segments = ("%s/api/skipSegments"):format(options.server_address),
    viewed_video_sponsor_time = ("%s/api/viewedVideoSponsorTime"):format(options.server_address),
    user_stats = ("%s/api/userStats"):format(options.server_address)
}

-- State variables
local segments = nil
local youtube_id = nil

local function http_request(url, method, query_params)
    local curl_cmd = { "curl", "--location", "--silent" }
    method = method or "GET"
    if method == "GET" then
        table.insert(curl_cmd, "--get")
    else
        table.insert(curl_cmd, "--request")
        table.insert(curl_cmd, method)
    end
    table.insert(curl_cmd, url)
    if query_params then
        for key, value in pairs(query_params) do
            table.insert(curl_cmd, "--data-urlencode")
            table.insert(curl_cmd, ("%s=%s"):format(key, value))
        end
    end
    mp.msg.debug("🐚 [yas] curl command: " .. table.concat(curl_cmd, " "))

    local result = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = curl_cmd
    }

    -- Centralized error handling
    if not result then
        mp.msg.warn("❌ [yas] HTTP request failed: no result from curl")
        return nil, "No result from curl"
    end

    if result.status ~= 0 then
        mp.msg.warn("❌ [yas] HTTP request failed: curl status " .. tostring(result.status))
        return nil, "Curl failed with status " .. tostring(result.status)
    end

    if not result.stdout or result.stdout == "" then
        mp.msg.warn("❌ [yas] HTTP request failed: empty response")
        return nil, "Empty response"
    end

    if result.stdout == "Not Found" then
        mp.msg.warn("🚫 [yas] HTTP request failed: 404 Not Found")
        return nil, "404 Not Found"
    end

    -- Try to parse JSON if response looks like JSON
    local data = nil
    if result.stdout:match("^%s*[%[%{]") then
        data = utils.parse_json(result.stdout)
        if not data then
            mp.msg.warn("❌ [yas] HTTP request failed: invalid JSON response")
            return nil, "Invalid JSON response"
        end
    else
        -- For non-JSON responses (like simple POST acknowledgments)
        data = result.stdout
    end

    mp.msg.debug("✅ [yas] HTTP request succeeded")
    return data, nil
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
    mp.msg.debug("🔎 [yas] Detecting YouTube ID from path: " .. video_path)
    for _, url in ipairs(urls) do
        local candidate = string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
        if candidate and #candidate >= 11 then
            mp.msg.info("🆔 [yas] YouTube ID detected: " .. string.sub(candidate, 1, 11))
            return string.sub(candidate, 1, 11)
        end
    end
    mp.msg.warn("⚠️ [yas] No YouTube ID detected")
    return nil
end

-- Fetch sponsorblock segments from API
local function get_segments()
    if not youtube_id then
        mp.msg.warn("⚠️ [yas] No YouTube ID, cannot fetch segments")
        return
    end
    mp.msg.info("🌐 [yas] Fetching SponsorBlock segments for video: " .. youtube_id)
    local data, error_msg = http_request(endpoints.skip_segments, "GET", {
        categories = ("[%s]"):format(options.categories),
        videoID = youtube_id
    })
    if not data then
        mp.msg.warn("❌ [yas] SponsorBlock API request failed: " .. (error_msg or "unknown error"))
        return
    end
    segments = {}
    for _, seg in ipairs(data) do
        if seg.segment and #seg.segment == 2 then
            local start_time, end_time = tonumber(seg.segment[1]), tonumber(seg.segment[2])
            if start_time and end_time and end_time > start_time then
                table.insert(segments, {
                    uuid = seg.UUID,
                    short_uuid = string.sub(seg.UUID, 1, 6),
                    category = seg.category,
                    action = seg.action,
                    start_time = start_time,
                    end_time = end_time,
                    skip_reported = false
                })
            end
        end
    end
    if #segments > 0 then
        mp.msg.info(("✅ [yas] SponsorBlock: %d segments found"):format(#segments))
        create_chapters()
        mp.observe_property("time-pos", "native", skip_ads)
    else
        mp.msg.info("ℹ️ [yas] SponsorBlock: no segments found")
    end
end

-- Create chapters in MPV UI
function create_chapters()
    if not segments then
        mp.msg.debug("ℹ️ [yas] No segments to create chapters for")
        return
    end
    local chapters = mp.get_property_native("chapter-list") or {}
    local duration = mp.get_property_native("duration")
    for _, segment in ipairs(segments) do
        table.insert(chapters, {
            title = segment.category:gsub("^%l", string.upper):gsub("_", " ") .. " (" .. segment.short_uuid .. ")",
            time = (not duration or duration > segment.start_time) and segment.start_time or duration - 0.001
        })
        table.insert(chapters, {
            title = "",
            time = (not duration or duration > segment.end_time) and segment.end_time or duration - 0.001
        })
    end
    table.sort(chapters, function(a, b) return a.time < b.time end)
    mp.set_property_native("chapter-list", chapters)
    mp.msg.debug("📚 [yas] Updated chapter-list: " .. utils.to_string(chapters))
end

local function report_skip(segment)
    if not segment or segment.skip_reported then return end
    mp.msg.debug("📤 [yas] Reporting skip for segment " .. segment.short_uuid)
    local data, error_msg = http_request(("%s?UUID=%s"):format(endpoints.viewed_video_sponsor_time, segment.uuid), "POST")
    if data then
        mp.msg.info("✅ [yas] Reported skip for segment " .. segment.short_uuid)
        segment.skip_reported = true
    else
        mp.msg.warn("❌ [yas] Failed to report skip for segment " .. segment.short_uuid .. ": " .. (error_msg or "unknown error"))
    end
end

-- Skip segments automatically
function skip_ads(_, pos)
    if not pos or not segments then return end
    for _, segment in ipairs(segments) do
        if pos >= segment.start_time and pos < segment.end_time then
            mp.osd_message(("[sponsorblock] Skipped %s (%.1fs)"):format(segment.category, segment.end_time - segment.start_time), 3)
            mp.msg.info(("⏭️ [yas] Skipping segment: %s [%s - %s]"):format(segment.category, segment.start_time, segment.end_time))
            mp.set_property("time-pos", segment.end_time + 0.001)
            report_skip(segment)
            return
        end
    end
end

local function get_user_stats()
    mp.msg.info("🌐 [yas] Fetching user stats for userID: " .. options.user_id)
    local data, error_msg = http_request(endpoints.user_stats, "GET", {
        userID = options.user_id,
        fetchCategoryStats = true,
        fetchActionTypeStats = true
    })
    if not data then
        mp.msg.warn("❌ [yas] Failed to get user stats: " .. (error_msg or "unknown error"))
        return
    end
    mp.msg.info("📊 [yas] User stats: " .. utils.to_string(data))
end

-- MPV Events
local function file_loaded()
    mp.msg.info("🎬 [yas] File loaded event")
    youtube_id = detect_youtube_id()
    if not youtube_id then
        mp.msg.warn("⚠️ [yas] No YouTube ID detected on file load")
        return
    end
    get_segments()
end

-- Reset state on end of file
local function end_file()
    mp.msg.info("🛑 [yas] End of file event. Resetting state.")
    segments = nil
    youtube_id = nil
    mp.unobserve_property(skip_ads)
end

-- Keybinding to show user stats
if options.user_id and string.gmatch(options.user_id, "^\\w{36}$") then
    mp.msg.info(("ℹ️ [yas] Found user_id %s in config"):format(options.user_id))
    mp.add_key_binding("z", "show_user_stats", get_user_stats)
end

-- Register events
mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
