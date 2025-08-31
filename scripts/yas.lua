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

-- User stats caching variables
local cached_user_stats = nil
local last_stats_fetch_time = 0
local stats_cache_duration = 300 -- 5 minutes in seconds

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

local function format_user_stats(data)
    if not data then return "No user stats available" end

    local lines = {}
    local username = data.userName or "Unknown User"
    table.insert(lines, "SponsorBlock user stats for " .. username)
    table.insert(lines, string.rep("=", 35))

    -- Overall stats
    if data.overallStats then
        table.insert(lines, "Overall Statistics:")
        if data.overallStats.minutesSaved then
            local hours = math.floor(data.overallStats.minutesSaved / 60)
            local minutes = math.floor(data.overallStats.minutesSaved % 60)
            table.insert(lines, string.format("  %-25s %s", "Time Saved:", hours .. "h " .. minutes .. "m"))
        end
        if data.overallStats.segmentCount then
            table.insert(lines, string.format("  %-25s %s", "Segments Submitted:", data.overallStats.segmentCount))
        end
    end

    -- Category breakdown
    if data.categoryCount then
        table.insert(lines, "")
        table.insert(lines, "Segments by Category:")
        local categories = {
            {key = "sponsor", name = "Sponsor"},
            {key = "intro", name = "Intro"},
            {key = "outro", name = "Outro"},
            {key = "interaction", name = "Interaction"},
            {key = "selfpromo", name = "Self Promo"},
            {key = "music_offtopic", name = "Music/Off-topic"},
            {key = "preview", name = "Preview"},
            {key = "filler", name = "Filler"},
            {key = "poi_highlight", name = "Highlight"},
            {key = "exclusive_access", name = "Exclusive Access"},
            {key = "chapter", name = "Chapter"}
        }

        for _, cat in ipairs(categories) do
            local count = data.categoryCount[cat.key]
            if count and count > 0 then
                table.insert(lines, string.format("  %-25s %s", cat.name .. ":", count))
            end
        end
    end

    -- Action type breakdown
    if data.actionTypeCount then
        table.insert(lines, "")
        table.insert(lines, "Segments by Action Type:")
        local actions = {
            {key = "skip", name = "Skip"},
            {key = "mute", name = "Mute"},
            {key = "full", name = "Full Video"},
            {key = "poi", name = "Point of Interest"},
            {key = "chapter", name = "Chapter"}
        }

        for _, action in ipairs(actions) do
            local count = data.actionTypeCount[action.key]
            if count and count > 0 then
                table.insert(lines, string.format("  %-25s %s", action.name .. ":", count))
            end
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Press 'z' to close")

    return table.concat(lines, "\n")
end

-- Dialog system (modernz-style)
local assdraw = require 'mp.assdraw'
local stats_overlay = nil

local function show_stats_dialog(content)
    -- Create overlay if it doesn't exist
    if not stats_overlay then
        stats_overlay = mp.create_osd_overlay("ass-events")
    end

    -- Get screen dimensions
    local screen_width, screen_height, display_aspect = mp.get_osd_size()

    -- Create ASS content using assdraw
    local ass = assdraw.ass_new()

    -- Calculate content-based dimensions
    local lines = {}
    for line in content:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    -- Base font size for calculations
    local base_font_size = math.max(18, screen_height / 40)

    -- Calculate box dimensions based on content
    local max_line_length = 0
    for _, line in ipairs(lines) do
        if #line > max_line_length then
            max_line_length = #line
        end
    end

    -- Dynamic sizing based on content with padding
    local char_width = base_font_size * 0.5  -- More accurate character width for Courier New
    local line_height = base_font_size * 1.1  -- Tighter line height to match actual text
    local vertical_padding = base_font_size * 0.8  -- Padding proportional to font size
    local horizontal_padding = base_font_size * 1.2  -- Reduced horizontal padding

    local box_width = (max_line_length + 1) * char_width + horizontal_padding  -- Width fits content + one extra character spacing
    local text_height = (#lines - 1) * line_height + base_font_size  -- More accurate: (n-1) line spaces + 1 font height
    local box_height = text_height + vertical_padding
    local box_x = (screen_width - box_width) / 2
    local box_y = (screen_height - box_height) / 2

    ass:new_event()
    ass:pos(box_x, box_y)
    ass:an(7)
    ass:append("{\\bord2\\shad3\\c&H000000&\\3c&H666666&\\4c&H000000&\\alpha&H80&}")
    ass:draw_start()
    ass:rect_cw(0, 0, box_width, box_height)
    ass:draw_stop()

    -- Text content (using calculated font size)
    ass:new_event()
    ass:pos(box_x + horizontal_padding / 2, box_y + vertical_padding / 2)  -- Position text with half the padding from edges
    ass:an(7)  -- Top-left alignment like a book's index
    ass:append("{\\fs" .. base_font_size .. "\\fn" .. "Courier New" .. "\\c&HFFFFFF&\\bord1\\3c&H000000&\\q2}")
    ass:append(content:gsub("\n", "\\N"))

    -- Update overlay with calculated dimensions
    stats_overlay.data = ass.text
    stats_overlay.res_x = screen_width
    stats_overlay.res_y = screen_height
    stats_overlay:update()
end

local function hide_stats_dialog()
    if stats_overlay then
        stats_overlay.data = ""
        stats_overlay:update()
    end
end

local stats_visible = false

local function get_user_stats()
    -- If stats are already visible, hide them
    if stats_visible then
        hide_stats_dialog()
        stats_visible = false
        mp.msg.info("📊 [yas] User stats dialog closed")
        return
    end

    local current_time = os.time()

    -- Check if we have cached data that's still valid (within 5 minutes)
    if cached_user_stats and (current_time - last_stats_fetch_time) < stats_cache_duration then
        mp.msg.info("📊 [yas] Using cached user stats (fetched " .. (current_time - last_stats_fetch_time) .. "s ago)")
        local formatted_stats = format_user_stats(cached_user_stats)
        show_stats_dialog(formatted_stats)
        stats_visible = true
        return
    end

    -- Need to fetch new data (either no cache or cache expired)
    mp.msg.info("🌐 [yas] Fetching user stats for userID: " .. options.user_id)
    local data, error_msg = http_request(endpoints.user_stats, "GET", {
        userID = options.user_id,
        fetchCategoryStats = true,
        fetchActionTypeStats = true
    })
    if not data then
        -- If fetch fails but we have cached data, use it anyway
        if cached_user_stats then
            mp.msg.warn("⚠️ [yas] Failed to fetch fresh stats, using cached data: " .. (error_msg or "unknown error"))
            local formatted_stats = format_user_stats(cached_user_stats)
            show_stats_dialog(formatted_stats)
            stats_visible = true
        else
            mp.osd_message("❌ Failed to get user stats: " .. (error_msg or "unknown error"), 5)
            mp.msg.warn("❌ [yas] Failed to get user stats: " .. (error_msg or "unknown error"))
        end
        return
    end

    -- Successfully fetched new data - update cache
    cached_user_stats = data
    last_stats_fetch_time = current_time
    mp.msg.info("📊 [yas] User stats fetched and cached")

    local formatted_stats = format_user_stats(data)
    show_stats_dialog(formatted_stats)
    stats_visible = true
    mp.msg.info("📊 [yas] User stats dialog displayed")
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
    -- Clear user stats cache when file ends
    cached_user_stats = nil
    last_stats_fetch_time = 0
    mp.unobserve_property(skip_ads)
end

-- Keybinding to show user stats
if options.user_id and #options.user_id >= 32 and string.match(options.user_id, "^%w+$") then
    mp.msg.info(("ℹ️ [yas] Found user_id %s in config"):format(options.user_id))
    mp.add_key_binding("z", "show_user_stats", get_user_stats)
else
    mp.msg.warn("⚠️ [yas] No valid user_id configured, user stats keybinding disabled")
end

-- Register events
mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
