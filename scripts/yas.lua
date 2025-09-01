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

-- Generate local userID if not set (required for submissions)
if not options.user_id or #options.user_id < 30 then
    -- Generate a random 32-character userID for submissions
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local user_id = ""
    math.randomseed(os.time())
    for i = 1, 32 do
        local rand = math.random(1, #chars)
        user_id = user_id .. string.sub(chars, rand, rand)
    end
    options.user_id = user_id
    mp.msg.info("🆔 [yas] Generated new local userID for submissions: " .. options.user_id)
    mp.msg.info("💾 [yas] Add this to your yas.conf file: user_id=" .. options.user_id)
end

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
    user_stats = ("%s/api/userStats"):format(options.server_address),
    submit_segments = ("%s/api/skipSegments"):format(options.server_address)
}

-- State variables
local segments = nil
local youtube_id = nil

-- User stats caching variables
local cached_user_stats = nil
local last_stats_fetch_time = 0
local stats_cache_duration = 300 -- 5 minutes in seconds

-- Segment submission variables
local marking_segment = false
local segment_start_time = nil
local current_overlay = nil
local segment_dialog_visible = false

local function http_request(url, method, query_params, json_body)
    local curl_cmd = { "curl", "--location", "--silent" }
    method = method or "GET"

    if method == "GET" then
        table.insert(curl_cmd, "--get")
    else
        table.insert(curl_cmd, "--request")
        table.insert(curl_cmd, method)
    end

    table.insert(curl_cmd, url)

    -- Handle JSON body for POST requests
    if json_body then
        table.insert(curl_cmd, "--header")
        table.insert(curl_cmd, "Content-Type: application/json")
        table.insert(curl_cmd, "--data")
        table.insert(curl_cmd, json_body)
    elseif query_params then
        -- Handle URL parameters for GET requests
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

    -- Calculate box dimensions based on content (improved modernz-style approach)
    local max_line_length = 0
    for _, line in ipairs(lines) do
        -- More accurate length calculation - treat Unicode chars more conservatively
        local display_length = 0
        for i = 1, string.len(line) do
            local byte = string.byte(line, i)
            if byte and byte > 127 then
                -- Unicode character - slightly wider but not as much
                display_length = display_length + 1.2
            else
                -- ASCII character
                display_length = display_length + 1
            end
        end

        if display_length > max_line_length then
            max_line_length = display_length
        end
    end

    -- More precise character width calculation (modernz-inspired)
    -- Detect content type for appropriate sizing
    local is_stats_dialog = string.find(content, "SponsorBlock user stats") or string.find(content, "Overall Statistics")
    local is_category_dialog = string.find(content, "Submit Segment") or string.find(content, "Select category")

    local char_width_ratio, vertical_padding_ratio, horizontal_padding_ratio

    if is_category_dialog then
        -- Very tight fit for category selection dialog (what you love!)
        char_width_ratio = 0.58
        if base_font_size >= 24 then
            char_width_ratio = 0.56
        elseif base_font_size <= 16 then
            char_width_ratio = 0.6
        end
        vertical_padding_ratio = 0.3
        horizontal_padding_ratio = 0.5
    else
        -- More generous fit for stats dialog (longer content)
        char_width_ratio = 0.62
        if base_font_size >= 24 then
            char_width_ratio = 0.6
        elseif base_font_size <= 16 then
            char_width_ratio = 0.64
        end
        vertical_padding_ratio = 0.4
        horizontal_padding_ratio = 0.75
    end

    local char_width = base_font_size * char_width_ratio
    local line_height = base_font_size * 1.1   -- Consistent tight line height

    -- Adaptive padding based on content type
    local vertical_padding = base_font_size * vertical_padding_ratio
    local horizontal_padding = char_width * horizontal_padding_ratio

    -- Calculate precise content-fitted dimensions
    local content_width = max_line_length * char_width
    local box_width = content_width + (horizontal_padding * 2)
    local text_height = (#lines - 1) * line_height + base_font_size
    local box_height = text_height + (vertical_padding * 2)

    -- Center the dialog
    local box_x = (screen_width - box_width) / 2
    local box_y = (screen_height - box_height) / 2

    -- Round corner radius (inspired by modernz)
    local corner_radius = math.min(12, base_font_size * 0.6)

    -- Draw background box with rounded corners (modernz style)
    ass:new_event()
    ass:pos(box_x, box_y)
    ass:an(7)
    ass:append("{\\bord0\\shad0\\c&H000000&\\alpha&H20&}")  -- Slightly more opaque for better visibility
    ass:draw_start()
    -- Use round_rect_cw for rounded corners like modernz
    ass:round_rect_cw(0, 0, box_width, box_height, corner_radius)
    ass:draw_stop()

    -- Text content with precise positioning (single layer with clean styling)
    ass:new_event()
    ass:pos(box_x + horizontal_padding, box_y + vertical_padding)  -- Position with exact padding
    ass:an(7)  -- Top-left alignment
    -- Clean text styling without competing borders/shadows
    ass:append("{\\fs" .. base_font_size .. "\\fn@monospace\\c&HFFFFFF&\\bord0\\shad0\\q2}")
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

-- Segment Categories for submission dialog
local segment_categories = {
    {key = "sponsor", name = "Sponsor", desc = "Paid promotion, paid referrals and direct advertisements"},
    {key = "selfpromo", name = "Unpaid/Self Promotion", desc = "Similar to sponsor but for unpaid content"},
    {key = "interaction", name = "Interaction Reminder", desc = "Reminders to like, subscribe, follow, etc."},
    {key = "intro", name = "Intermission/Intro Animation", desc = "Intro sequences, animations, or intermissions"},
    {key = "outro", name = "Endcards/Credits", desc = "End credits, endcards, or outros"},
    {key = "preview", name = "Preview/Recap", desc = "Collection of clips showing what's coming up"},
    {key = "filler", name = "Filler Tangent", desc = "Tangential content that is not required"},
    {key = "music_offtopic", name = "Non-Music Section", desc = "Only for music videos, covers non-music portions"}
}

-- Create segment submission dialog content
local function create_segment_dialog_content(start_time, end_time, selected_index)
    selected_index = selected_index or 1
    local duration = end_time - start_time
    local lines = {}
    table.insert(lines, string.format("Submit Segment: %.1f - %.1f seconds (%.1fs)", start_time, end_time, duration))
    table.insert(lines, "")
    table.insert(lines, "Select category:")

    for i, category in ipairs(segment_categories) do
        local prefix = (selected_index == i) and "> " or "   "
        table.insert(lines, string.format("%s%d. %s", prefix, i, category.name))
    end

    table.insert(lines, "")
    table.insert(lines, "↑/↓: Navigate  Enter: Submit  Esc: Cancel")

    return table.concat(lines, "\n")
end

-- Submit segment to SponsorBlock API
local function submit_segment(start_time, end_time, category)
    if not youtube_id then
        mp.osd_message("❌ No YouTube video detected", 3)
        return
    end

    mp.msg.info(string.format("📤 [yas] Submitting %s segment: %.1f - %.1f", category, start_time, end_time))
    mp.msg.debug(string.format("🔑 [yas] Using userID: %s", options.user_id))

    -- Get video duration for submission
    local video_duration = mp.get_property_number("duration") or 0

    -- Create JSON payload in the format you discovered
    local json_payload = {
        videoID = youtube_id,
        userID = options.user_id,
        segments = {
            {
                segment = {start_time, end_time},
                category = category,
                actionType = "skip"
            }
        },
        service = "YouTube"
    }

    -- Add video duration if available
    if video_duration > 0 then
        json_payload.videoDuration = video_duration
    end

    -- Convert to JSON string
    local json_string = utils.format_json(json_payload)

    mp.msg.debug("📋 [yas] JSON payload for SponsorBlock submission:")
    mp.msg.debug(json_string)

    -- Make the request using JSON body
    local data, error_msg = http_request(endpoints.submit_segments, "POST", nil, json_string)

    if data then
        mp.osd_message("✅ Segment submitted successfully", 3)
        mp.msg.info("✅ [yas] Segment submitted successfully")
        mp.msg.info("📊 [yas] Response: " .. utils.to_string(data))
        -- Refresh segments to include our submission
        get_segments()
    else
        mp.osd_message("❌ Failed to submit segment: " .. (error_msg or "unknown error"), 5)
        mp.msg.warn("❌ [yas] Failed to submit segment: " .. (error_msg or "unknown error"))
    end
end

-- Show segment submission dialog
local function show_segment_dialog(start_time, end_time)
    segment_dialog_visible = true
    local selected_index = 1

    -- Function to update dialog content with current selection
    local function update_dialog_content()
        local content = create_segment_dialog_content(start_time, end_time, selected_index)
        show_stats_dialog(content)
    end

    -- Function to clean up all key bindings
    local function cleanup_bindings()
        mp.remove_key_binding("segment_dialog_up")
        mp.remove_key_binding("segment_dialog_down")
        mp.remove_key_binding("segment_dialog_enter")
        mp.remove_key_binding("segment_dialog_escape")
        -- Also remove number key bindings for backward compatibility
        for j = 1, #segment_categories do
            mp.remove_key_binding("segment_category_" .. j)
        end
    end

    -- Function to submit the selected segment
    local function submit_selected_segment()
        hide_stats_dialog()
        segment_dialog_visible = false
        cleanup_bindings()

        local category = segment_categories[selected_index]
        submit_segment(start_time, end_time, category.key)
    end

    -- Function to cancel dialog
    local function cancel_dialog()
        hide_stats_dialog()
        segment_dialog_visible = false
        cleanup_bindings()
        mp.osd_message("Segment submission cancelled", 2)
    end

    -- Function to move selection up
    local function move_up()
        selected_index = selected_index - 1
        if selected_index < 1 then
            selected_index = #segment_categories
        end
        update_dialog_content()
    end

    -- Function to move selection down
    local function move_down()
        selected_index = selected_index + 1
        if selected_index > #segment_categories then
            selected_index = 1
        end
        update_dialog_content()
    end

    -- Function to handle number key selection (for backward compatibility)
    local function handle_category_key(category_index)
        if category_index >= 1 and category_index <= #segment_categories then
            selected_index = category_index
            update_dialog_content()
        end
    end

    -- Initial display
    update_dialog_content()

    -- Bind arrow keys for navigation
    mp.add_forced_key_binding("UP", "segment_dialog_up", move_up)
    mp.add_forced_key_binding("DOWN", "segment_dialog_down", move_down)

    -- Bind Enter for submission
    mp.add_forced_key_binding("ENTER", "segment_dialog_enter", submit_selected_segment)

    -- Bind Escape to cancel
    mp.add_forced_key_binding("ESC", "segment_dialog_escape", cancel_dialog)

    -- Bind number keys for backward compatibility
    for i = 1, #segment_categories do
        mp.add_forced_key_binding(tostring(i), "segment_category_" .. i, function()
            handle_category_key(i)
        end)
    end
end

-- Toggle segment marking (like SponsorBlock extension)
local function toggle_segment_marking()
    if segment_dialog_visible then
        return -- Don't interfere with dialog
    end

    if not youtube_id then
        mp.osd_message("❌ SponsorBlock: YouTube video required", 3)
        return
    end

    local current_time = mp.get_property_number("time-pos")
    if not current_time then
        mp.osd_message("❌ Could not get current time", 3)
        return
    end

    if not marking_segment then
        -- Start marking
        segment_start_time = current_time
        marking_segment = true
        mp.osd_message(string.format("📍 Segment start marked at %.1f seconds", current_time), 3)
        mp.msg.info(string.format("📍 [yas] Segment start marked at %.1f seconds", current_time))
    else
        -- End marking and show dialog
        if current_time <= segment_start_time then
            mp.osd_message("❌ End time must be after start time", 3)
            return
        end

        local duration = current_time - segment_start_time
        if duration < 0.5 then
            mp.osd_message("❌ Segment too short (minimum 0.5 seconds)", 3)
            return
        end

        marking_segment = false
        mp.osd_message(string.format("🏁 Segment marked: %.1f - %.1f seconds", segment_start_time, current_time), 3)
        mp.msg.info(string.format("🏁 [yas] Segment marked: %.1f - %.1f seconds", segment_start_time, current_time))

        show_segment_dialog(segment_start_time, current_time)
    end
end

-- Cancel segment marking
local function cancel_segment_marking()
    if marking_segment then
        marking_segment = false
        segment_start_time = nil
        mp.osd_message("❌ Segment marking cancelled", 2)
        mp.msg.info("❌ [yas] Segment marking cancelled")
    end
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
    -- Reset segment submission state
    marking_segment = false
    segment_start_time = nil
    segment_dialog_visible = false
    if current_overlay then
        hide_stats_dialog()
    end
    mp.unobserve_property(skip_ads)
end

-- Keybinding to show user stats
if options.user_id and #options.user_id >= 30 and string.match(options.user_id, "^%w+$") then
    mp.msg.info(("ℹ️ [yas] Found user_id %s in config"):format(options.user_id))
    mp.add_key_binding("z", "show_user_stats", get_user_stats)

    -- Segment submission keybindings
    mp.add_key_binding(";", "toggle_segment_marking", toggle_segment_marking)
    mp.add_key_binding("ESC", "cancel_segment_marking", cancel_segment_marking)

    mp.msg.info("✅ [yas] Segment submission keybindings enabled:")
    mp.msg.info("   ; : Start/End segment marking")
    mp.msg.info("   Escape : Cancel segment marking")
else
    mp.msg.warn("⚠️ [yas] No valid user_id configured, user stats and segment submission disabled")
end

-- Register events
mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
