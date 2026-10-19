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
    -- Optional manual override (e.g. pinning a specific ID). Leave empty
    -- to auto-generate one — the generated ID is persisted outside this
    -- file, see local_user_id_path() below, not written back here.
    user_id = ""
}

-- VARIABLES AND STATE
-- Endpoint URLs. Filled by build_endpoints() once yas.conf has been read,
-- so a server_address override actually takes effect.
local endpoints = {}

local function build_endpoints()
    local base = options.server_address:gsub("/+$", "")
    endpoints.skip_segments = base .. "/api/skipSegments"
    endpoints.viewed_video_sponsor_time = base .. "/api/viewedVideoSponsorTime"
    endpoints.user_stats = base .. "/api/userStats"
    endpoints.user_info = base .. "/api/userInfo"
end

-- curl limits, in seconds: a stalled server must never leave a request
-- (and the callbacks waiting on it) hanging indefinitely.
local CONNECT_TIMEOUT = 5
local MAX_TIME = 10

-- State variables
local state = {
    segments = nil,
    youtube_id = nil,
    has_valid_user_id = false,
    base_chapters = nil, -- video's own chapters, captured once, before SponsorBlock ones are added
    file_generation = 0, -- bumped on every end-file; async replies for older files are dropped
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
    keybindings_active = false,
    -- Set while hold_playback_open() is holding keep-open at "always" for
    -- the marking/dialog workflow; holds the value to restore it to.
    prev_keep_open = nil
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
local stats_loading = false -- a stats fetch is in flight; ignore repeat z presses

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

-- Kept outside the git-tracked config tree, in the XDG state dir - same
-- rationale and pattern as local_stats_path() below. Generated identity
-- state doesn't belong in script-opts/yas.conf, which mp.options treats
-- as user-editable config; a script silently rewriting it is the same
-- smell already fixed for the playlist/stats files.
local function local_user_id_path()
    local ok, path = pcall(mp.command_native, {"expand-path", "~/.local/state/mpv/yas_user_id"})
    if not ok or not path or path == "" then return nil end
    return path
end

-- Loads a previously generated user_id, if any, so future launches reuse
-- the same identity instead of minting a new one every session - which
-- would keep resetting submission history/reputation and always show
-- near-empty stats.
local function load_generated_user_id()
    local path = local_user_id_path()
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local id = f:read("*l") -- "*l", not "l": PUC Lua 5.1 rejects the short form
    f:close()
    if id then id = id:match("^%s*(.-)%s*$") end -- trim
    return id
end

-- Makes `path` readable and writable by its owner only. Best effort:
-- chmod doesn't exist on Windows, and failing here must not stop the script.
local function chmod_private(path)
    pcall(mp.command_native, {
        name = "subprocess",
        args = {"chmod", "600", path},
        playback_only = false
    })
end

-- Writes `content` to `path` so it is never readable by other users, not
-- even briefly: the file is created empty, restricted, and only then
-- filled (truncating keeps the mode). Creates the parent directory if
-- needed. Returns true on success.
local function write_private_file(path, content)
    local out, err = io.open(path, "w")
    if not out then
        -- io.open(path, "w") does not create missing parent directories
        -- on its own. Only shell out to mkdir -p in this rare fallback
        -- path (on actual write failure), not on every script load.
        pcall(function()
            local dir = utils.split_path(path) -- split_path returns (dir, filename); only dir wanted here
            mp.command_native({
                name = "subprocess",
                args = {"mkdir", "-p", dir},
                playback_only = false
            })
        end)
        out, err = io.open(path, "w")
    end
    if not out then return false, err end
    out:close()
    chmod_private(path)
    out, err = io.open(path, "w")
    if not out then return false, err end
    out:write(content)
    out:close()
    return true
end

-- Persists a freshly generated user_id to local_user_id_path().
local function persist_generated_user_id(user_id)
    local path = local_user_id_path()
    if not path then
        mp.msg.warn("⚠️ Could not resolve yas_user_id path; generated userID won't persist")
        return
    end
    local ok, err = write_private_file(path, user_id .. "\n")
    if not ok then
        mp.msg.warn("⚠️ Could not write " .. path .. " to persist generated userID: " .. tostring(err))
        return
    end
    mp.msg.info("💾 Saved generated userID to " .. path)
end

-- Local, per-installation tally of segments this script has actually
-- skipped/muted — independent of any user_id, and of SponsorBlock's own
-- server-side stats (which only count segments *you submitted*, and never
-- move just from watching/skipping). Mirrors the reference browser
-- extension's Config.config.skipCount / minutesSaved, which are likewise
-- purely local and have no server-side equivalent.
local local_stats = {
    skip_count = 0,
    minutes_saved = 0
}

-- Kept outside the git-tracked config tree (~~/ resolves inside it), in
-- the XDG state dir instead - plain ~/ path, not a ~~ meta-path: ~~state/
-- was tried for perpetual-playlist's IPC socket and proved unreliable on
-- some mpv builds (fell back into the config tree, or failed outright).
local function local_stats_path()
    local ok, path = pcall(mp.command_native, {"expand-path", "~/.local/state/mpv/yas_stats.conf"})
    if not ok or not path or path == "" then return nil end
    return path
end

local function load_local_stats()
    local path = local_stats_path()
    if not path then return end
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        -- Note: %a is letters only, not %w — must include "_" explicitly
        -- or "skip_count"/"minutes_saved" never match.
        local key, value = line:match("^([%a_]+)=([%d%.]+)$")
        if key == "skip_count" then
            local_stats.skip_count = tonumber(value) or 0
        elseif key == "minutes_saved" then
            local_stats.minutes_saved = tonumber(value) or 0
        end
    end
    f:close()
end

local function save_local_stats()
    local path = local_stats_path()
    if not path then return end
    local out, err = io.open(path, "w")
    if not out then
        -- io.open(path, "w") does not create missing parent directories
        -- on its own, so a fresh install/machine would otherwise
        -- silently never persist stats. Only shell out to mkdir -p here,
        -- in this rare fallback path (once, on actual write failure),
        -- not proactively on every script load.
        pcall(function()
            local dir = utils.split_path(path) -- split_path returns (dir, filename); only dir wanted here
            mp.command_native({
                name = "subprocess",
                args = {"mkdir", "-p", dir},
                playback_only = false
            })
        end)
        out, err = io.open(path, "w")
    end
    if not out then
        mp.msg.warn("⚠️ Could not write " .. path .. " to persist local stats: " .. tostring(err))
        return
    end
    out:write(("skip_count=%d\nminutes_saved=%.4f\n"):format(local_stats.skip_count, local_stats.minutes_saved))
    out:close()
end

-- Records one real skip/mute action toward the local tally and persists it
-- immediately — writes are rare (at most a handful per video), so there's
-- no need to batch them.
local function record_local_skip(segment)
    local_stats.skip_count = local_stats.skip_count + 1
    local_stats.minutes_saved = local_stats.minutes_saved + (segment.end_time - segment.start_time) / 60
    save_local_stats()
end

load_local_stats()

-- The private userID is SponsorBlock's only credential (there are no
-- passwords), so it must never reach the terminal or a --log-file.
-- Diagnostics use this masked form instead.
local function mask_user_id(id)
    if type(id) ~= "string" or #id < 12 then return "<hidden>" end
    return id:sub(1, 4) .. "…" .. id:sub(-4)
end

-- Replaces every occurrence of the private userID in `text` (log lines,
-- curl command lines, JSON bodies) with its masked form.
local function redact(text)
    local id = options.user_id
    if type(text) ~= "string" or type(id) ~= "string" or id == "" then return text end
    local escaped = id:gsub("%p", "%%%0")
    return (text:gsub(escaped, mask_user_id(id)))
end

-- Generates a 32-character alphanumeric userID. Prefers the OS CSPRNG;
-- falls back to math.random seeded from several sources, so two installs
-- started in the same second still get different IDs.
local function generate_user_id()
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local out = {}
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(64)
        f:close()
        if bytes and #bytes == 64 then
            -- Rejection sampling: 248 = 4 * 62, keeps the distribution uniform
            for i = 1, #bytes do
                local b = bytes:byte(i)
                if b < 248 then
                    local n = b % #chars + 1
                    out[#out + 1] = chars:sub(n, n)
                    if #out == 32 then return table.concat(out) end
                end
            end
        end
    end
    local addr = tonumber(tostring({}):match("0x(%x+)") or "0", 16) or 0
    math.randomseed((os.time() + math.floor(os.clock() * 1e6) + addr) % 2147483647)
    for i = #out + 1, 32 do
        local n = math.random(1, #chars)
        out[i] = chars:sub(n, n)
    end
    return table.concat(out)
end

-- INITIALIZATION
-- Load options from config file: script-opts/yas.conf
mpoptions.read_options(options, "yas")
build_endpoints()

-- Resolve userID: a manual override in yas.conf wins; otherwise reuse a
-- previously generated one from the state dir; otherwise generate and
-- persist a new one (required for submissions).
if not options.user_id or #options.user_id < 30 then
    local existing_id = load_generated_user_id()
    if existing_id and #existing_id >= 30 then
        options.user_id = existing_id
        -- Files written by older versions were created world-readable
        chmod_private(local_user_id_path())
        mp.msg.info("🆔 Reusing previously generated local userID " .. mask_user_id(options.user_id))
    else
        local user_id = generate_user_id()
        options.user_id = user_id
        mp.msg.info("🆔 Generated new local userID for submissions " .. mask_user_id(user_id))
        persist_generated_user_id(user_id)
    end
end

-- The userID must never appear on curl's command line: mpv logs every
-- subprocess command at debug level (so --log-file captures it), and any
-- local user can read a process's arguments with ps. Instead it's kept in
-- an owner-only file that curl reads itself (name@file / --data @file).
-- If that file can't be written, requests fall back to passing it inline.
local USER_ID = setmetatable({}, { __tostring = function() return "<userID>" end })
local secret_path = nil
do
    local ok, path = pcall(mp.command_native, {"expand-path", "~/.local/state/mpv/yas_secret"})
    if ok and path and path ~= "" and options.user_id and options.user_id ~= "" then
        if write_private_file(path, options.user_id) then
            secret_path = path
        else
            mp.msg.warn("⚠️ Could not write " .. path .. "; the userID will be passed on curl's command line")
        end
    end
end

-- HELPER FUNCTIONS
-- Wraps a callback so an uncaught error inside it is logged and swallowed
-- instead of propagating into mpv's event dispatch. mpv gives a script no
-- safety net of its own here: an error escaping one of this script's
-- registered event/property callbacks kills its entire event loop, so no
-- further file-loaded/end-file/property-change events ever reach it again
-- for the rest of the session (looks like the plugin "crashed" and never
-- came back). Used to wrap every mpv-registered entry point below.
local function safe_call(fn, name)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            mp.msg.error(("💥 yas: unhandled error in %s: %s"):format(name, tostring(err)))
        end
    end
end

-- Friendly names for the curl exit codes users actually hit.
local CURL_ERRORS = {
    [6] = "couldn't resolve host",
    [7] = "couldn't connect to server",
    [28] = "request timed out",
    [35] = "TLS handshake failed",
}

-- Turns a finished curl subprocess into (data, error, http_code).
-- curl runs with --write-out "\n%{http_code}", so the status code is the
-- last line of stdout. Any non-2xx status is an error carrying the
-- server's own (usually actionable) message: SponsorBlock answers bad
-- submissions with plain-text 400/403/409/429 bodies.
local function parse_http_result(success, result, error_string)
    if not success or not result then
        return nil, "curl could not be run: " .. tostring(error_string or "unknown error")
    end
    if result.status < 0 then
        -- mpv couldn't start curl at all (e.g. not installed)
        return nil, ("curl could not be started (%s)"):format(tostring(result.error_string or result.status))
    end
    if result.status ~= 0 then
        local reason = CURL_ERRORS[result.status]
        return nil, ("curl failed with status %s%s"):format(
            tostring(result.status), reason and (" (" .. reason .. ")") or "")
    end

    local stdout = result.stdout or ""
    local body, code = stdout:match("^(.*)\n(%d%d%d)$")
    if not code then
        return nil, "No HTTP status in curl output"
    end
    code = tonumber(code)

    if code < 200 or code > 299 then
        local message = body:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 160)
        return nil, ("HTTP %d%s"):format(code, message ~= "" and (": " .. message) or ""), code
    end

    -- Parse JSON if the body looks like JSON; anything else (e.g. the
    -- "OK" acknowledgement of viewedVideoSponsorTime) is returned as text.
    if body:match("^%s*[%[%{]") then
        local data = utils.parse_json(body)
        if data == nil then
            return nil, "Invalid JSON response", code
        end
        return data, nil, code
    end
    return body, nil, code
end

-- Counter for temporary request-body files
local body_file_seq = 0

-- Adds one parameter to a curl command. GET parameters go in the query
-- string via --get/--data-urlencode; for POST they're appended to the URL
-- with --url-query (curl 7.87+) so the body stays free. The USER_ID
-- sentinel is read by curl from the owner-only secret file.
local function add_param(curl_cmd, method, key, value)
    local flag = method == "GET" and "--data-urlencode" or "--url-query"
    table.insert(curl_cmd, flag)
    if value == USER_ID then
        if secret_path then
            table.insert(curl_cmd, key .. "@" .. secret_path)
            return
        end
        value = options.user_id
    end
    -- tostring() because PUC Lua 5.1's %s rejects booleans (fetchCategoryStats = true)
    table.insert(curl_cmd, ("%s=%s"):format(key, tostring(value)))
end

-- Runs an HTTP request with curl WITHOUT blocking mpv: the subprocess runs
-- asynchronously and callback(data, error, http_code) is called when it
-- finishes. The callback is wrapped in safe_call, so an error inside it is
-- logged instead of killing the script's event loop.
--   query_params: table of parameters; use the USER_ID sentinel as a value
--                 to send the private userID without exposing it.
--   json_body:    string. If it contains the userID it is passed to curl
--                 through a temporary owner-only file, never inline.
function http_request(url, method, query_params, json_body, callback)
    method = method or "GET"
    callback = callback or function() end

    local curl_cmd = {
        "curl", "--location", "--silent",
        "--connect-timeout", tostring(CONNECT_TIMEOUT),
        "--max-time", tostring(MAX_TIME),
        "--write-out", "\n%{http_code}",
    }

    if method == "GET" then
        table.insert(curl_cmd, "--get")
    else
        table.insert(curl_cmd, "--request")
        table.insert(curl_cmd, method)
    end

    table.insert(curl_cmd, url)

    local body_file = nil
    if json_body then
        table.insert(curl_cmd, "--header")
        table.insert(curl_cmd, "Content-Type: application/json")
        table.insert(curl_cmd, "--data")
        if secret_path and options.user_id and json_body:find(options.user_id, 1, true) then
            body_file_seq = body_file_seq + 1
            body_file = ("%s.body%d.json"):format(secret_path, body_file_seq)
            if write_private_file(body_file, json_body) then
                table.insert(curl_cmd, "@" .. body_file)
            else
                body_file = nil
                table.insert(curl_cmd, json_body)
            end
        else
            table.insert(curl_cmd, json_body)
        end
    end
    if query_params then
        -- Sorted so commands (and logs) are deterministic
        local keys = {}
        for key in pairs(query_params) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do add_param(curl_cmd, method, key, query_params[key]) end
    end

    mp.msg.debug("🐚 curl command: " .. redact(table.concat(curl_cmd, " ")))

    local done = safe_call(function(success, result, error_string)
        if body_file then os.remove(body_file) end
        local data, err, code = parse_http_result(success, result, error_string)
        if err and code ~= 404 then -- 404 is routine ("no segments"); callers decide
            mp.msg.warn(("❌ HTTP %s %s failed: %s"):format(method, url, err))
        elseif err then
            mp.msg.debug(("HTTP %s %s: %s"):format(method, url, err))
        else
            mp.msg.debug("✅ HTTP request succeeded")
        end
        callback(data, err, code)
    end, "http callback")

    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = curl_cmd
    }, done)
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
-- Bumped by every get_segments() call; only the newest reply is applied
local segments_request_seq = 0

-- Fetch sponsorblock segments from API
function get_segments()
    if not state.youtube_id then
        mp.msg.warn("⚠️ No YouTube ID, cannot fetch segments")
        return
    end
    mp.msg.info("🌐 Fetching SponsorBlock segments for video: " .. state.youtube_id)
    -- The answer arrives asynchronously: by then the user may have moved
    -- on to another file. Only apply it to the file that asked for it.
    local generation = state.file_generation
    segments_request_seq = segments_request_seq + 1
    local seq = segments_request_seq
    http_request(endpoints.skip_segments, "GET", {
        categories = ("[%s]"):format(options.categories),
        actionTypes = ("[%s]"):format(options.action_types),
        videoID = state.youtube_id
    }, nil, function(data, error_msg, code)
        if generation ~= state.file_generation then
            mp.msg.debug("⏭️ Ignoring segments for a file that is no longer playing")
            return
        end
        if seq ~= segments_request_seq then
            mp.msg.debug("⏭️ Ignoring segments superseded by a newer request")
            return
        end
        if code == 404 then
            -- SponsorBlock's way of saying "this video has no segments"
            mp.msg.info("ℹ️ SponsorBlock: no segments found")
            return
        end
        if not data then
            mp.msg.warn("❌ SponsorBlock API request failed: " .. (error_msg or "unknown error"))
            return
        end
        if type(data) ~= "table" then
            mp.msg.warn("❌ SponsorBlock API request failed: unexpected response " .. tostring(data))
            return
        end
        apply_segments(data)
    end)
end

-- Turns the API's segment list into state.segments, chapters and the
-- time-pos observer that skips/mutes them.
function apply_segments(data)
    state.segments = {}
    for _, seg in ipairs(data) do
        -- Trust nothing from the API beyond "looks like a segment": a
        -- missing/malformed UUID or category would otherwise throw later
        -- (string.sub/gsub on nil) from inside the file-loaded handler,
        -- which is fatal for the whole script - see safe_call() below.
        if seg.segment and #seg.segment == 2
            and type(seg.UUID) == "string" and seg.UUID ~= ""
            and type(seg.category) == "string" and seg.category ~= ""
            and type(seg.actionType) == "string" then
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
        else
            mp.msg.warn("⚠️ Skipping malformed SponsorBlock segment: " .. utils.to_string(seg))
        end
    end
    if #state.segments > 0 then
        mp.msg.info(("✅ SponsorBlock: %d segments found"):format(#state.segments))
        create_chapters()
        -- Avoid stacking duplicate observers if segments are re-fetched
        -- mid-video (e.g. after a submission refresh). Always the same
        -- skip_ads_safe reference (defined after skip_ads() below) so
        -- unobserve matches what was actually observed.
        mp.unobserve_property(skip_ads_safe)
        mp.observe_property("time-pos", "native", skip_ads_safe)
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
            title = (segment.category or "unknown"):gsub("^%l", string.upper):gsub("_", " ")
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

-- Fire-and-forget: tells SponsorBlock a segment was skipped. Runs in the
-- background so the skip itself is never delayed by the network.
function report_skip(segment)
    if not segment or segment.skip_reported or segment.report_pending then return end
    segment.report_pending = true
    http_request(endpoints.viewed_video_sponsor_time, "POST", { UUID = segment.uuid }, nil,
        function(data, error_msg)
            segment.report_pending = false
            if data then
                mp.msg.info("✅ Reported skip for segment " .. segment.short_uuid)
                segment.skip_reported = true
            else
                mp.msg.warn("❌ Failed to report skip for segment " .. segment.short_uuid .. ": " .. (error_msg or "unknown error"))
            end
        end)
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
                    record_local_skip(segment)
                end
            else
                show_toast(("Skipped %s (%.1fs)"):format(segment.category, segment.end_time - segment.start_time), "info")
                mp.msg.info(("⏭️ Skipping segment: %s [%s - %s]"):format(segment.category, segment.start_time, segment.end_time))
                mp.set_property("time-pos", segment.end_time + 0.001)
                report_skip(segment)
                record_local_skip(segment)
            end
            return
        end
    end
end

-- The wrapped reference actually handed to mp.observe_property/
-- mp.unobserve_property everywhere - see safe_call() above.
skip_ads_safe = safe_call(skip_ads, "skip_ads")

-- Formats a minutes value as "Nd Nh N.Nm" (omitting zero-value leading
-- components), matching the reference browser extension's getFormattedHours().
local function format_duration(total_minutes)
    total_minutes = math.floor((total_minutes or 0) * 10 + 0.5) / 10 -- round to 1 decimal
    local years = math.floor(total_minutes / 525600)
    local days = math.floor(total_minutes / 1440) % 365
    local hours = math.floor(total_minutes / 60) % 24
    local minutes = total_minutes % 60
    local parts = {}
    if years > 0 then table.insert(parts, years .. "y") end
    if days > 0 then table.insert(parts, days .. "d") end
    if hours > 0 then table.insert(parts, hours .. "h") end
    table.insert(parts, ("%.1fm"):format(minutes))
    return table.concat(parts, " ")
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
            table.insert(rows, {label = "Time Saved", value = format_duration(data.overallStats.minutesSaved)})
        end
        if data.overallStats.segmentCount then
            table.insert(rows, {label = "Segments Submitted", value = tostring(data.overallStats.segmentCount)})
        end
    end

    -- "Your Work" style summary, matching the reference browser extension.
    -- "Saved others" is server-side data (segments you submitted, viewed by
    -- anyone); "You've skipped" is this installation's own local tally —
    -- SponsorBlock has no server-side concept of segments a viewer skipped.
    table.insert(rows, {text = ""})
    if data.viewCount and data.overallStats and data.overallStats.minutesSaved then
        table.insert(rows, {text = ("Saved others from %d segments (%s)"):format(
            data.viewCount, format_duration(data.overallStats.minutesSaved))})
    end
    table.insert(rows, {text = ("You've skipped %d segments (%s)"):format(
        local_stats.skip_count, format_duration(local_stats.minutes_saved))})

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

-- Virtual canvas size: behaves like a 720p canvas on displays up to 1080p
-- (res_x scales with aspect ratio, panels scale normally), but caps how
-- much further it grows above that so panels don't keep getting physically
-- bigger — in real rendered pixels — on very large/high-res displays; they
-- render at most as large as they would on a 1080p screen.
local REF_H = 720
local MAX_SCALE = 1080 / REF_H
local function get_virt_size()
    local osd = mp.get_property_native("osd-dimensions") or {}
    local real_h = (osd.h and osd.h > 0) and osd.h or REF_H
    local scale = math.min(real_h / REF_H, MAX_SCALE)
    local virt_h = real_h / scale
    local ar = osd.aspect
    if not ar or ar <= 0 then
        ar = (osd.w and osd.h and osd.h > 0) and (osd.w / osd.h) or (16 / 9)
    end
    return math.floor(virt_h * ar), math.floor(virt_h)
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

    -- Need to fetch new data (either no cache or cache expired). Both
    -- requests run in the background; the panel opens when they finish.
    if stats_loading then return end
    stats_loading = true
    local generation = state.file_generation
    show_toast("Loading SponsorBlock stats…", "info", MAX_TIME * 2)
    mp.msg.info("🌐 Fetching user stats for userID " .. mask_user_id(options.user_id))

    local function display(data)
        stats_loading = false
        if overlays.toast_timer then -- drop the "Loading…" toast
            overlays.toast_timer:kill()
            overlays.toast_timer = nil
            overlays.toast.data = ""
            overlays.toast:update()
        end
        -- The file changed while loading: keep the data, don't pop a
        -- panel up over the next video.
        if generation ~= state.file_generation then return end
        show_stats_dialog(format_user_stats(data))
        stats_visible = true
        mp.msg.debug("📊 User stats dialog displayed")
    end

    http_request(endpoints.user_stats, "GET", {
        userID = USER_ID,
        fetchCategoryStats = true,
        fetchActionTypeStats = true
    }, nil, function(data, error_msg)
        if type(data) ~= "table" then
            error_msg = error_msg or "unexpected response"
            -- If fetch fails but we have cached data, use it anyway
            if user_stats_cache.cached_data then
                mp.msg.warn("⚠️ Failed to fetch fresh stats, using cached data: " .. error_msg)
                display(user_stats_cache.cached_data)
            else
                stats_loading = false
                show_toast("Failed to get user stats: " .. error_msg, "error", 5)
                mp.msg.warn("❌ Failed to get user stats: " .. error_msg)
            end
            return
        end

        -- /api/userStats doesn't expose viewCount (segments *you* submitted,
        -- viewed by anyone) — fetch it separately from /api/userInfo. Best
        -- effort: if this fails, the "Saved others from..." line is just
        -- omitted rather than failing the whole dialog.
        http_request(endpoints.user_info, "GET", {
            userID = USER_ID,
            values = '["viewCount"]'
        }, nil, function(view_data)
            if type(view_data) == "table" and view_data.viewCount then
                data.viewCount = view_data.viewCount
            end

            -- Successfully fetched new data - update cache
            user_stats_cache.cached_data = data
            user_stats_cache.last_fetch_time = current_time
            mp.msg.info("📊 User stats fetched and cached")
            display(data)
        end)
    end)
end

-- SEGMENT SUBMISSION SYSTEM
-- Submit segment to SponsorBlock API
function submit_segment(start_time, end_time, category)
    if not state.youtube_id then
        show_toast("No YouTube video detected", "error")
        return
    end

    mp.msg.info(string.format("📤 Submitting %s segment: %.1f - %.1f", category, start_time, end_time))

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

    -- Make the request using JSON body; the answer arrives asynchronously
    show_toast("Submitting segment…", "info", MAX_TIME * 2)
    local generation = state.file_generation
    http_request(endpoints.skip_segments, "POST", nil, json_string, function(data, error_msg)
        if data then
            show_toast("Segment submitted successfully", "success")
            mp.msg.info("✅ Segment submitted successfully")
            mp.msg.info("📊 Response: " .. utils.to_string(data))
            -- Refresh segments to include our submission, if still on that video
            if generation == state.file_generation then get_segments() end
        else
            show_toast("Failed to submit segment: " .. (error_msg or "unknown error"), "error", 5)
            mp.msg.warn("❌ Failed to submit segment: " .. (error_msg or "unknown error"))
        end
    end)
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
        release_playback_open()

        local category = segment_categories[selected_index]
        submit_segment(start_time, end_time, category.key)
    end

    -- Function to cancel dialog
    function cancel_dialog()
        hide_stats_dialog()
        segment_submission.dialog_visible = false
        cleanup_bindings()
        release_playback_open()
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

-- Marking a segment (start pressed) or having its confirmation dialog
-- open must not let mpv auto-advance to the next playlist item mid-
-- workflow - most noticeably when the segment's end is meant to reach
-- the very end of the video: without this, mpv's native playlist
-- auto-advance (unaffected by the global keep-open=yes, which only
-- holds the true last playlist item open) fires the instant EOF is
-- reached, and end_file() below reactively wipes the in-progress
-- mark/dialog before the user can even press ; a second time or pick a
-- category. Runtime-toggling keep-open to "always" while marking/dialog
-- is active makes THIS file freeze at EOF too, exactly like the true-
-- last-item case already does - zero effect on ordinary playback since
-- the toggle only engages while the ; workflow is actually open.
function hold_playback_open()
    if segment_submission.prev_keep_open == nil then
        segment_submission.prev_keep_open = mp.get_property("keep-open", "yes")
        mp.set_property("keep-open", "always")
    end
end

-- Restores keep-open without trying to advance the playlist - used from
-- end_file(), where a transition (manual nav or otherwise) is already
-- underway, so forcing another one would be wrong.
function restore_keep_open()
    if segment_submission.prev_keep_open ~= nil then
        mp.set_property("keep-open", segment_submission.prev_keep_open)
        segment_submission.prev_keep_open = nil
    end
end

-- Restores keep-open and, if the hold left playback frozen at EOF
-- (segment ended up marked/submitted right at the end of the video),
-- advances to the next playlist item ourselves - reverting the property
-- alone doesn't retroactively resume mpv's already-made "freeze"
-- decision. "weak" is a no-op if there's no next item (true last
-- video), matching what keep-open=yes would already do on its own.
-- Explicitly unpauses too, since the freeze paused playback and that
-- pause state would otherwise carry into the next file.
function release_playback_open()
    local was_held = segment_submission.prev_keep_open ~= nil
    restore_keep_open()
    if was_held and mp.get_property_bool("eof-reached", false) then
        mp.commandv("playlist-next", "weak")
        mp.set_property_bool("pause", false)
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
        hold_playback_open()
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
        release_playback_open()
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

    -- Reset state variables. Bumping the generation makes any request
    -- still in flight for this file ignore its answer when it arrives.
    state.file_generation = state.file_generation + 1
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
    -- Restore only - a transition is already underway here (natural
    -- advance or manual nav away mid-mark), so forcing another one via
    -- release_playback_open() would be wrong. Safety net against
    -- keep-open=always leaking onto the next-loaded file.
    restore_keep_open()

    hide_stats_dialog()
    stats_visible = false
    mp.unobserve_property(skip_ads_safe)

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
        mp.msg.info(("Using user_id %s"):format(mask_user_id(options.user_id)))
        mp.msg.info("   z to show/hide user stats dialog")
        mp.add_key_binding("z", "show_user_stats", get_user_stats)
    end
end

-- Register events. Wrapped in safe_call() so an uncaught error in either
-- handler (e.g. from unexpected SponsorBlock API data) can't take down the
-- script's whole event loop - see safe_call() above.
mp.register_event("file-loaded", safe_call(file_loaded, "file_loaded"))
mp.register_event("end-file", safe_call(end_file, "end_file"))
