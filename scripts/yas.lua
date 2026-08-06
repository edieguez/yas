-- Yet Another Sponsorblock plugin for MPV
-- Based on
--   https://github.com/po5/mpv_sponsorblock
--   https://codeberg.org/jouni/mpv_sponsorblock_minimal

-- DEPENDENCIES AND OPTIONS
local utils = require "mp.utils"
local mpoptions = require "mp.options"
local assdraw = require 'mp.assdraw'

-- Default options
local options = {
    server_address = "https://sponsor.ajay.app",
    categories = "sponsor,selfpromo,interaction,intro,outro,preview,hook,filler",
    -- skip = seek past the segment; mute = mute audio for its duration.
    -- Other SponsorBlock action types (poi, full, chapter) are markers the
    -- reference extension doesn't auto-apply either, so they're not
    -- requested here.
    action_types = "skip,mute",
    user_id = ""
}

-- VARIABLES AND STATE
-- Endpoint variables
local endpoints = {
    skip_segments = ("%s/api/skipSegments"):format(options.server_address),
    viewed_video_sponsor_time = ("%s/api/viewedVideoSponsorTime"):format(options.server_address),
    user_stats = ("%s/api/userStats"):format(options.server_address)
}

-- State variables
local state = {
    segments = nil,
    youtube_id = nil,
    has_valid_user_id = false,
    base_chapters = nil, -- video's own chapters, captured once, before SponsorBlock ones are added
    active_mute_segment = nil, -- the "mute" segment currently muting audio, if any
    mute_before_segment = false -- mute state to restore once active_mute_segment ends
}

-- User stats caching variables
local user_stats_cache = {
    cached_data = nil,
    last_fetch_time = 0,
    cache_duration = 300 -- 5 minutes in seconds
}

-- Segment submission variables
local segment_submission = {
    marking_segment = false,
    start_time = nil,
    dialog_visible = false,
    keybindings_active = false
}

-- Set by show_segment_dialog() while its dialog is open, so end_file() can
-- remove its forced key bindings if the file changes while it's up
local segment_dialog_cleanup = nil

-- Overlay variables
local overlays = {
    stats = nil,
    toast = nil,
    toast_timer = nil
}

-- UI state
local stats_visible = false

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

-- INITIALIZATION
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
    mp.msg.info("🆔 Generated new local userID for submissions: " .. options.user_id)
end

-- HELPER FUNCTIONS
function http_request(url, method, query_params, json_body)
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

    mp.msg.debug("🐚 curl command: " .. table.concat(curl_cmd, " "))

    local result = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = curl_cmd
    }

    -- Centralized error handling
    if not result then
        mp.msg.warn("❌ HTTP request failed: no result from curl")
        return nil, "No result from curl"
    end

    if result.status ~= 0 then
        mp.msg.warn("❌ HTTP request failed: curl status " .. tostring(result.status))
        return nil, "Curl failed with status " .. tostring(result.status)
    end

    if not result.stdout or result.stdout == "" then
        mp.msg.warn("❌ HTTP request failed: empty response")
        return nil, "Empty response"
    end

    if result.stdout == "Not Found" then
        mp.msg.warn("🚫 HTTP request failed: 404 Not Found")
        return nil, "404 Not Found"
    end

    -- Try to parse JSON if response looks like JSON
    local data = nil
    if result.stdout:match("^%s*[%[%{]") then -- Check if starts with [ or {
        data = utils.parse_json(result.stdout)
        if not data then
            mp.msg.warn("❌ HTTP request failed: invalid JSON response")
            return nil, "Invalid JSON response"
        end
    else
        -- For non-JSON responses (like simple POST acknowledgments)
        data = result.stdout
    end

    mp.msg.debug("✅ HTTP request succeeded")
    return data, nil
end

-- Detect YouTube video ID from multiple sources
function detect_youtube_id()
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
    mp.msg.debug("🔎 Detecting YouTube ID from path: " .. video_path)
    for _, url in ipairs(urls) do
        local candidate = string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
        if candidate and #candidate >= 11 then
            mp.msg.info("🆔 YouTube ID detected: " .. string.sub(candidate, 1, 11))
            return string.sub(candidate, 1, 11)
        end
    end
    mp.msg.warn("⚠️ No YouTube ID detected")
    return nil
end

-- CORE SPONSORBLOCK FUNCTIONALITY
-- Fetch sponsorblock segments from API
function get_segments()
    if not state.youtube_id then
        mp.msg.warn("⚠️ No YouTube ID, cannot fetch segments")
        return
    end
    mp.msg.info("🌐 Fetching SponsorBlock segments for video: " .. state.youtube_id)
    local data, error_msg = http_request(endpoints.skip_segments, "GET", {
        categories = ("[%s]"):format(options.categories),
        actionTypes = ("[%s]"):format(options.action_types),
        videoID = state.youtube_id
    })
    if not data then
        mp.msg.warn("❌ SponsorBlock API request failed: " .. (error_msg or "unknown error"))
        return
    end
    state.segments = {}
    for _, seg in ipairs(data) do
        if seg.segment and #seg.segment == 2 then
            local start_time, end_time = tonumber(seg.segment[1]), tonumber(seg.segment[2])
            if start_time and end_time and end_time > start_time then
                table.insert(state.segments, {
                    uuid = seg.UUID,
                    short_uuid = string.sub(seg.UUID, 1, 6),
                    category = seg.category,
                    action = seg.actionType, -- API field is "actionType", not "action"
                    start_time = start_time,
                    end_time = end_time,
                    skip_reported = false
                })
            end
        end
    end
    if #state.segments > 0 then
        mp.msg.info(("✅ SponsorBlock: %d segments found"):format(#state.segments))
        create_chapters()
        -- Avoid stacking duplicate observers if segments are re-fetched
        -- mid-video (e.g. after a submission refresh)
        mp.unobserve_property(skip_ads)
        mp.observe_property("time-pos", "native", skip_ads)
    else
        mp.msg.info("ℹ️ SponsorBlock: no segments found")
    end
end

-- Create chapters in MPV UI
function create_chapters()
    -- Capture the video's own chapters once per video, so re-running this
    -- (e.g. after a submission refresh) rebuilds from that baseline instead
    -- of piling SponsorBlock chapters on top of ones it already added
    if not state.base_chapters then
        state.base_chapters = mp.get_property_native("chapter-list") or {}
    end
    local chapters = {}
    for _, chapter in ipairs(state.base_chapters) do
        table.insert(chapters, chapter)
    end
    local duration = mp.get_property_native("duration")
    for _, segment in ipairs(state.segments) do
        table.insert(chapters, {
            title = segment.category:gsub("^%l", string.upper):gsub("_", " ")
                .. (segment.action == "mute" and " [Mute]" or "")
                .. " (" .. segment.short_uuid .. ")",
            time = (not duration or duration > segment.start_time) and segment.start_time or duration - 0.001
        })
        table.insert(chapters, {
            title = "",
            time = (not duration or duration > segment.end_time) and segment.end_time or duration - 0.001
        })
    end
    table.sort(chapters, function(a, b) return a.time < b.time end)
    mp.set_property_native("chapter-list", chapters)
    mp.msg.debug("📚 Updated chapter-list: " .. utils.to_string(chapters))
end

function report_skip(segment)
    if not segment or segment.skip_reported then return end
    local data, error_msg = http_request(("%s?UUID=%s"):format(endpoints.viewed_video_sponsor_time, segment.uuid), "POST")
    if data then
        mp.msg.info("✅ Reported skip for segment " .. segment.short_uuid)
        segment.skip_reported = true
    else
        mp.msg.warn("❌ Failed to report skip for segment " .. segment.short_uuid .. ": " .. (error_msg or "unknown error"))
    end
end

-- Skip segments automatically
function skip_ads(_, pos)
    if not pos or not state.segments then return end

    -- Leave an active "mute" segment: either playback moved past its end,
    -- or a manual seek jumped elsewhere while it was muting
    if state.active_mute_segment then
        local seg = state.active_mute_segment
        if pos < seg.start_time or pos >= seg.end_time then
            mp.set_property_bool("mute", state.mute_before_segment)
            state.active_mute_segment = nil
        end
    end

    for _, segment in ipairs(state.segments) do
        if pos >= segment.start_time and pos < segment.end_time then
            if segment.action == "mute" then
                if state.active_mute_segment ~= segment then
                    state.mute_before_segment = mp.get_property_bool("mute")
                    mp.set_property_bool("mute", true)
                    state.active_mute_segment = segment
                    show_toast(("Muted %s (%.1fs)"):format(segment.category, segment.end_time - segment.start_time), "info")
                    mp.msg.info(("🔇 Muting segment: %s [%s - %s]"):format(segment.category, segment.start_time, segment.end_time))
                    report_skip(segment)
                end
            else
                show_toast(("Skipped %s (%.1fs)"):format(segment.category, segment.end_time - segment.start_time), "info")
                mp.msg.info(("⏭️ Skipping segment: %s [%s - %s]"):format(segment.category, segment.start_time, segment.end_time))
                mp.set_property("time-pos", segment.end_time + 0.001)
                report_skip(segment)
            end
            return
        end
    end
end

-- Returns a list of rows for show_stats_dialog(): each is either
-- {text=...} (a plain line) or {label=..., value=...} (a two-column stat,
-- rendered with the value right-aligned in its own column — text padding
-- like "%-25s" only lines up in a monospace font, which we no longer use).
function format_user_stats(data)
    if not data then return {{text = "No user stats available"}} end

    local rows = {}
    local username = data.userName or "Unknown User"
    table.insert(rows, {text = "SponsorBlock user stats for " .. username})
    table.insert(rows, {text = ""})

    -- Overall stats
    if data.overallStats then
        table.insert(rows, {text = "Overall Statistics"})
        if data.overallStats.minutesSaved then
            local hours = math.floor(data.overallStats.minutesSaved / 60)
            local minutes = math.floor(data.overallStats.minutesSaved % 60)
            table.insert(rows, {label = "Time Saved", value = hours .. "h " .. minutes .. "m"})
        end
        if data.overallStats.segmentCount then
            table.insert(rows, {label = "Segments Submitted", value = tostring(data.overallStats.segmentCount)})
        end
    end

    -- Category breakdown
    if data.categoryCount then
        table.insert(rows, {text = ""})
        table.insert(rows, {text = "Segments by Category"})
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
                table.insert(rows, {label = cat.name, value = tostring(count)})
            end
        end
    end

    -- Action type breakdown
    if data.actionTypeCount then
        table.insert(rows, {text = ""})
        table.insert(rows, {text = "Segments by Action Type"})
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
                table.insert(rows, {label = action.name, value = tostring(count)})
            end
        end
    end

    table.insert(rows, {text = ""})
    table.insert(rows, {text = "Press 'z' to close"})

    return rows
end

-- UI AND DIALOG SYSTEM
-- Styled like playlist_manager.lua: a fixed virtual canvas (res_y=720,
-- res_x scaled to the display's aspect ratio) so panels are the same
-- physical size on any screen, real glyph-width measurement via a hidden
-- compute_bounds overlay instead of guessing per-character width, and no
-- forced font — text renders in mpv's default OSD font.
local FONT_SIZE = 24
local BG_ALPHA  = 0x50 -- background alpha, matches playlist_manager
local CORNER    = 8
local PAD       = 10
local LH        = FONT_SIZE * 1.2

-- Icons are plain glyphs, not emoji — libass/the default OSD font can't
-- render color emoji reliably, they'd show as tofu boxes.
local TOAST_STYLE = {
    info    = {color = "FFFFFF", icon = ""},   -- white
    success = {color = "44EE44", icon = "✓ "}, -- green
    error   = {color = "3C3CDC", icon = "✗ "}  -- red (ASS is BGR: this is RGB(220,60,60))
}

local measure_osd = mp.create_osd_overlay("ass-events")
measure_osd.hidden = true
measure_osd.compute_bounds = true
local text_width_cache = {}
local text_width_cache_count = 0

-- Virtual canvas width: res_y is fixed at 720, res_x scales with the
-- display's aspect ratio so pixels stay square on any screen.
local function get_virt_size()
    local osd = mp.get_property_native("osd-dimensions") or {}
    local ar = osd.aspect
    if not ar or ar <= 0 then
        ar = (osd.w and osd.h and osd.h > 0) and (osd.w / osd.h) or (16 / 9)
    end
    return math.floor(720 * ar), 720
end

-- Measures the rendered pixel width of `text` at FONT_SIZE on the current
-- virtual canvas, so panels fit their content exactly.
local function measure_text(text)
    if not text or #text == 0 then return 0 end
    if text_width_cache[text] then return text_width_cache[text] end
    local w = 0
    local width, height = get_virt_size()
    measure_osd.res_x = width
    measure_osd.res_y = height
    measure_osd.data = ("{\\fs%d\\bord0\\q2\\an7\\pos(0,0)}"):format(FONT_SIZE) .. text
    local bounds = measure_osd:update()
    if bounds and bounds.x0 and bounds.x1 then
        w = math.max(0, bounds.x1 - bounds.x0)
    end
    if w == 0 then w = math.ceil(#text * FONT_SIZE * 0.6) end -- fallback
    if text_width_cache_count > 200 then
        text_width_cache = {}
        text_width_cache_count = 0
    end
    text_width_cache[text] = w
    text_width_cache_count = text_width_cache_count + 1
    return w
end

-- kind: "info" (default), "success", or "error" — picks the text color.
function show_toast(message, kind, duration)
    kind = kind or "info"
    duration = duration or 3

    if not overlays.toast then
        overlays.toast = mp.create_osd_overlay("ass-events")
    end
    -- Cancel any pending hide from a previous toast so it doesn't blank
    -- this one out early.
    if overlays.toast_timer then
        overlays.toast_timer:kill()
        overlays.toast_timer = nil
    end

    local style = TOAST_STYLE[kind] or TOAST_STYLE.info
    local full = style.icon .. message

    local width, height = get_virt_size()
    local max_w = width - PAD * 4
    local cw = math.min(measure_text(full), max_w)
    local x, y = PAD * 2, PAD * 2

    local ass = assdraw.ass_new()

    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(("{\\bord0\\blur0\\1c&H000000&\\1a&H%02X&\\4a&Hff&}"):format(BG_ALPHA))
    ass:draw_start()
    local tpad = PAD / 2
    ass:round_rect_cw(-PAD, -tpad, cw + PAD, FONT_SIZE + tpad, CORNER, CORNER)
    ass:draw_stop()

    local clip = ("\\clip(0,0,%d,%d)"):format(math.floor(x + cw), height)
    ass:new_event()
    ass:an(4)
    ass:pos(x, y + FONT_SIZE / 2)
    ass:append(("{\\bord1\\1c&H%s&\\3c&H000000&\\fs%d\\fsp0\\q2%s}"):format(style.color, FONT_SIZE, clip))
    ass:append(full)

    overlays.toast.res_x = width
    overlays.toast.res_y = height
    overlays.toast.z = 2000
    overlays.toast.data = ass.text
    overlays.toast:update()

    overlays.toast_timer = mp.add_timeout(duration, function()
        if overlays.toast then
            overlays.toast.data = ""
            overlays.toast:update()
        end
        overlays.toast_timer = nil
    end)
end

-- Renders a centered panel from a list of rows (see format_user_stats()):
-- plain {text=...} lines, and {label=..., value=...} rows laid out as a
-- real two-column table — label left-aligned, value right-aligned in its
-- own column — since character padding only lines up in a monospace font.
function show_stats_dialog(rows)
    if not overlays.stats then
        overlays.stats = mp.create_osd_overlay("ass-events")
    end

    local width, height = get_virt_size()

    local label_w, value_w, plain_w = 0, 0, 0
    for _, row in ipairs(rows) do
        if row.label then
            label_w = math.max(label_w, measure_text(row.label))
            value_w = math.max(value_w, measure_text(row.value))
        elseif row.text and row.text ~= "" then
            plain_w = math.max(plain_w, measure_text(row.text))
        end
    end
    local gap = FONT_SIZE * 1.5
    local cw = math.max(label_w + gap + value_w, plain_w)
    cw = math.min(cw, width - PAD * 4)

    local box_w = cw + PAD * 2
    local box_h = #rows * LH + PAD * 2
    local x = (width - box_w) / 2
    local y = (height - box_h) / 2

    local ass = assdraw.ass_new()

    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(("{\\bord0\\blur0\\1c&H000000&\\1a&H%02X&\\4a&Hff&}"):format(BG_ALPHA))
    ass:draw_start()
    ass:round_rect_cw(0, 0, box_w, box_h, CORNER, CORNER)
    ass:draw_stop()

    -- One event per line/column (rather than a single \N-joined block) so
    -- the box height, computed from LH, always matches what actually gets
    -- drawn — ASS's own line spacing for \N doesn't necessarily match LH.
    local sty = ("{\\bord1\\1c&HFFFFFF&\\3c&H000000&\\fs%d\\fsp0\\q2}"):format(FONT_SIZE)
    for i, row in ipairs(rows) do
        local ry = y + PAD + (i - 1) * LH
        if row.label then
            ass:new_event()
            ass:an(7)
            ass:pos(x + PAD, ry)
            ass:append(sty .. row.label)

            local vw = measure_text(row.value)
            ass:new_event()
            ass:an(7)
            ass:pos(x + PAD + cw - vw, ry)
            ass:append(sty .. row.value)
        else
            ass:new_event()
            ass:an(7)
            ass:pos(x + PAD, ry)
            ass:append(sty .. (row.text or ""))
        end
    end

    overlays.stats.res_x = width
    overlays.stats.res_y = height
    overlays.stats.z = 2000
    overlays.stats.data = ass.text
    overlays.stats:update()
end

function hide_stats_dialog()
    if overlays.stats then
        overlays.stats.data = ""
        overlays.stats:update()
    end
end

-- Renders the segment-category picker with the focused row highlighted
-- (white box, dark text) the same way playlist_manager highlights its
-- focused playlist entry.
function draw_segment_dialog(start_time, end_time, selected_index)
    if not overlays.stats then
        overlays.stats = mp.create_osd_overlay("ass-events")
    end

    local width, height = get_virt_size()
    local header = ("Submit segment: %.1f–%.1fs (%.1fs)"):format(start_time, end_time, end_time - start_time)
    local footer = "↑/↓ Navigate   Enter Submit   Esc Cancel"
    local n = #segment_categories

    -- Reserve a fixed indent for the focus arrow so rows never shift
    -- between focused/unfocused — the arrow is drawn on top of it, not
    -- inline with the text.
    local arrow_w = measure_text("▶") + FONT_SIZE * 0.3

    local cw = math.max(measure_text(header), measure_text(footer))
    for i, category in ipairs(segment_categories) do
        local w = measure_text(i .. ". " .. category.name) + arrow_w
        if w > cw then cw = w end
    end
    cw = math.min(cw, width - PAD * 4)

    local box_w = cw + PAD * 2
    local box_h = (n + 3) * LH + PAD * 2 -- header + rows + gap + footer
    local x = (width - box_w) / 2
    local y = (height - box_h) / 2

    local sty = ("{\\bord1\\1c&HFFFFFF&\\3c&H000000&\\fs%d\\fsp0\\q2}"):format(FONT_SIZE)
    local focused_sty = ("{\\bord0\\1c&H222222&\\3c&H000000&\\fs%d\\fsp0\\q2}"):format(FONT_SIZE)

    local ass = assdraw.ass_new()

    -- Background
    ass:new_event()
    ass:an(7)
    ass:pos(x, y)
    ass:append(("{\\bord0\\blur0\\1c&H000000&\\1a&H%02X&\\4a&Hff&}"):format(BG_ALPHA))
    ass:draw_start()
    ass:round_rect_cw(0, 0, box_w, box_h, CORNER, CORNER)
    ass:draw_stop()

    -- Header
    ass:new_event()
    ass:an(7)
    ass:pos(x + PAD, y + PAD)
    ass:append(sty .. header)

    -- Category rows. box_y (an7, top-left) and text_y (an4, middle-left)
    -- are half a line apart so the row's text sits vertically centered in
    -- its own highlight box.
    for i, category in ipairs(segment_categories) do
        local box_y = y + PAD + (i + 0.5) * LH
        local text_y = box_y + LH / 2
        local focused = i == selected_index

        if focused then
            ass:new_event()
            ass:an(7)
            ass:pos(x, box_y)
            ass:append("{\\bord0\\blur0\\4a&Hff&\\1c&HFFFFFF&}")
            ass:draw_start()
            ass:rect_cw(0, 0, box_w, LH)
            ass:draw_stop()
        end

        if focused then
            ass:new_event()
            ass:an(4)
            ass:pos(x + PAD, text_y)
            ass:append(focused_sty .. "▶")
        end

        ass:new_event()
        ass:an(4)
        ass:pos(x + PAD + arrow_w, text_y)
        ass:append((focused and focused_sty or sty) .. i .. ". " .. category.name)
    end

    -- Footer hint
    ass:new_event()
    ass:an(7)
    ass:pos(x + PAD, y + PAD + (n + 2) * LH)
    ass:append(sty .. footer)

    overlays.stats.res_x = width
    overlays.stats.res_y = height
    overlays.stats.z = 2000
    overlays.stats.data = ass.text
    overlays.stats:update()
end

function get_user_stats()
    -- If stats are already visible, hide them
    if stats_visible then
        hide_stats_dialog()
        stats_visible = false
        mp.msg.debug("📊 User stats dialog closed")
        return
    end

    local current_time = os.time()

    -- Check if we have cached data that's still valid (within 5 minutes)
    if user_stats_cache.cached_data and (current_time - user_stats_cache.last_fetch_time) < user_stats_cache.cache_duration then
        mp.msg.debug("📊 Using cached user stats (fetched " .. (current_time - user_stats_cache.last_fetch_time) .. "s ago)")
        local formatted_stats = format_user_stats(user_stats_cache.cached_data)
        show_stats_dialog(formatted_stats)
        stats_visible = true
        return
    end

    -- Need to fetch new data (either no cache or cache expired)
    mp.msg.info("🌐 Fetching user stats for userID: " .. options.user_id)
    local data, error_msg = http_request(endpoints.user_stats, "GET", {
        userID = options.user_id,
        fetchCategoryStats = true,
        fetchActionTypeStats = true
    })
    if not data then
        -- If fetch fails but we have cached data, use it anyway
        if user_stats_cache.cached_data then
            mp.msg.warn("⚠️ Failed to fetch fresh stats, using cached data: " .. (error_msg or "unknown error"))
            local formatted_stats = format_user_stats(user_stats_cache.cached_data)
            show_stats_dialog(formatted_stats)
            stats_visible = true
        else
            show_toast("Failed to get user stats: " .. (error_msg or "unknown error"), "error", 5)
            mp.msg.warn("❌ Failed to get user stats: " .. (error_msg or "unknown error"))
        end
        return
    end

    -- Successfully fetched new data - update cache
    user_stats_cache.cached_data = data
    user_stats_cache.last_fetch_time = current_time
    mp.msg.info("📊 User stats fetched and cached")

    local formatted_stats = format_user_stats(data)
    show_stats_dialog(formatted_stats)
    stats_visible = true
    mp.msg.debug("📊 User stats dialog displayed")
end

-- SEGMENT SUBMISSION SYSTEM
-- Submit segment to SponsorBlock API
function submit_segment(start_time, end_time, category)
    if not state.youtube_id then
        show_toast("No YouTube video detected", "error")
        return
    end

    mp.msg.info(string.format("📤 Submitting %s segment: %.1f - %.1f", category, start_time, end_time))
    mp.msg.debug(string.format("🔑 Using userID: %s", options.user_id))

    -- Get video duration for submission
    local video_duration = mp.get_property_number("duration") or 0

    -- Create JSON payload in the format you discovered
    local json_payload = {
        videoID = state.youtube_id,
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

    -- Make the request using JSON body
    local data, error_msg = http_request(endpoints.skip_segments, "POST", nil, json_string)

    if data then
        show_toast("Segment submitted successfully", "success")
        mp.msg.info("✅ Segment submitted successfully")
        mp.msg.info("📊 Response: " .. utils.to_string(data))
        -- Refresh segments to include our submission
        get_segments()
    else
        show_toast("Failed to submit segment: " .. (error_msg or "unknown error"), "error", 5)
        mp.msg.warn("❌ Failed to submit segment: " .. (error_msg or "unknown error"))
    end
end

-- Show segment submission dialog
function show_segment_dialog(start_time, end_time)
    segment_submission.dialog_visible = true
    local selected_index = 1

    -- Function to update dialog content with current selection
    function update_dialog_content()
        draw_segment_dialog(start_time, end_time, selected_index)
    end

    -- Function to clean up all key bindings
    function cleanup_bindings()
        mp.remove_key_binding("segment_dialog_up")
        mp.remove_key_binding("segment_dialog_down")
        mp.remove_key_binding("segment_dialog_enter")
        mp.remove_key_binding("segment_dialog_escape")
        -- Also remove number key bindings for backward compatibility
        for j = 1, #segment_categories do
            mp.remove_key_binding("segment_category_" .. j)
        end
        segment_dialog_cleanup = nil
    end
    segment_dialog_cleanup = cleanup_bindings

    -- Function to submit the selected segment
    function submit_selected_segment()
        hide_stats_dialog()
        segment_submission.dialog_visible = false
        cleanup_bindings()

        local category = segment_categories[selected_index]
        submit_segment(start_time, end_time, category.key)
    end

    -- Function to cancel dialog
    function cancel_dialog()
        hide_stats_dialog()
        segment_submission.dialog_visible = false
        cleanup_bindings()
        show_toast("Segment submission cancelled", "info", 2)
    end

    -- Function to move selection up
    function move_up()
        selected_index = selected_index - 1
        if selected_index < 1 then
            selected_index = #segment_categories
        end
        update_dialog_content()
    end

    -- Function to move selection down
    function move_down()
        selected_index = selected_index + 1
        if selected_index > #segment_categories then
            selected_index = 1
        end
        update_dialog_content()
    end

    -- Function to handle number key selection (for backward compatibility)
    function handle_category_key(category_index)
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
function toggle_segment_marking()
    if segment_submission.dialog_visible then
        return -- Don't interfere with dialog
    end

    if not state.youtube_id then
        show_toast("SponsorBlock: YouTube video required", "error")
        return
    end

    local current_time = mp.get_property_number("time-pos")
    if not current_time then
        show_toast("Could not get current time", "error")
        return
    end

    if not segment_submission.marking_segment then
        -- Start marking
        segment_submission.start_time = current_time
        segment_submission.marking_segment = true
        show_toast(string.format("Segment start marked at %.1f seconds", current_time), "info")
        mp.msg.info(string.format("📍 Segment start marked at %.1f seconds", current_time))
    else
        -- End marking and show dialog
        if current_time <= segment_submission.start_time then
            show_toast("End time must be after start time", "error")
            return
        end

        local duration = current_time - segment_submission.start_time
        if duration < 0.5 then
            show_toast("Segment too short (minimum 0.5 seconds)", "error")
            return
        end

        segment_submission.marking_segment = false
        show_toast(string.format("Segment marked: %.1f - %.1f seconds", segment_submission.start_time, current_time), "info")
        mp.msg.info(string.format("🏁 Segment marked: %.1f - %.1f seconds", segment_submission.start_time, current_time))

        show_segment_dialog(segment_submission.start_time, current_time)
    end
end

-- KEYBINDING MANAGEMENT
function activate_segment_keybindings()
    if segment_submission.keybindings_active then return end

    mp.add_key_binding(";", "toggle_segment_marking", toggle_segment_marking)
    mp.add_key_binding(":", "cancel_segment_marking", cancel_segment_marking)

    segment_submission.keybindings_active = true
    mp.msg.info("✅ Segment submission keybindings enabled:")
    mp.msg.info("   ; to Start/End segment marking")
    mp.msg.info("   : to Cancel segment marking")
end

function deactivate_segment_keybindings()
    if not segment_submission.keybindings_active then return end

    mp.remove_key_binding("toggle_segment_marking")
    mp.remove_key_binding("cancel_segment_marking")

    segment_submission.keybindings_active = false
    mp.msg.info("🚫 Segment submission keybindings disabled")
end

function check_and_update_keybindings()
    local should_activate = state.has_valid_user_id and state.youtube_id

    if should_activate and not segment_submission.keybindings_active then
        activate_segment_keybindings()
    elseif not should_activate and segment_submission.keybindings_active then
        deactivate_segment_keybindings()
    end

    if not state.has_valid_user_id then
        mp.msg.warn("⚠️ No valid user_id configured, segment submission disabled")
    elseif not state.youtube_id then
        mp.msg.warn("⚠️ No YouTube video detected, segment submission disabled")
    end
end

-- Cancel segment marking
function cancel_segment_marking()
    if segment_submission.marking_segment then
        segment_submission.marking_segment = false
        segment_submission.start_time = nil
        show_toast("Segment marking cancelled", "info", 2)
        mp.msg.info("❌ Segment marking cancelled")
    end
end

-- MPV EVENTS
-- MPV Events
function file_loaded()
    mp.msg.info("🎬 File loaded event. Looking for YouTube ID")
    state.youtube_id = detect_youtube_id()

    -- Check and update keybindings based on current state
    check_and_update_keybindings()

    if state.youtube_id then
        get_segments()
    end
end

-- Reset state on end of file
function end_file()
    mp.msg.debug("🛑 End of file event. Resetting state.")

    -- If a "mute" segment was actively muting audio, restore mute state
    -- before it (and this video) go away
    if state.active_mute_segment then
        mp.set_property_bool("mute", state.mute_before_segment)
        state.active_mute_segment = nil
    end

    -- Reset state variables
    state.segments = nil
    state.youtube_id = nil
    state.base_chapters = nil
    user_stats_cache.cached_data = nil
    user_stats_cache.last_fetch_time = 0

    -- If the segment submission dialog was open, remove its forced key
    -- bindings instead of leaving them bound to this video's closures
    if segment_submission.dialog_visible and segment_dialog_cleanup then
        segment_dialog_cleanup()
    end
    segment_submission.marking_segment = false
    segment_submission.start_time = nil
    segment_submission.dialog_visible = false

    hide_stats_dialog()
    stats_visible = false
    mp.unobserve_property(skip_ads)

    -- Deactivate segment submission keybindings
    deactivate_segment_keybindings()
end

do
    -- Parse comma-separated option lists into API-friendly JSON array contents once
    local function to_json_list(csv)
        local items = {}
        for item in string.gmatch(csv, "([^,]+)") do
            table.insert(items, '"' .. item .. '"')
        end
        return table.concat(items, ",")
    end
    options.categories = to_json_list(options.categories)
    options.action_types = to_json_list(options.action_types)

    if options.user_id and #options.user_id >= 30 and options.user_id:match("^[%w]+$") then
        state.has_valid_user_id = true
        mp.msg.info(("Found user_id %s in config"):format(options.user_id))
        mp.msg.info("   z to show/hide user stats dialog")
        mp.add_key_binding("z", "show_user_stats", get_user_stats)
    end
end

-- Register events
mp.register_event("file-loaded", file_loaded)
mp.register_event("end-file", end_file)
