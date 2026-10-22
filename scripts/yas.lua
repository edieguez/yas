-- Yet Another SponsorBlock plugin for mpv
-- Based on
--   https://github.com/po5/mpv_sponsorblock
--   https://codeberg.org/jouni/mpv_sponsorblock_minimal
--
-- One file, in sections. Each section is a table of functions whose
-- private helpers live inside its own `do ... end` block, so nothing is
-- global and sections can only reach each other through those tables:
--
--   core        options, shared state, safe_call
--   categories  the 12 SponsorBlock categories, in the extension's order
--   timefmt     durations ("1m 5s") and positions ("12:34.2")
--   store       private files and the local skip tally (~/.local/state/mpv)
--   identity    the private user ID: resolve, mask, keep off command lines
--   http        async curl requests
--   detect      YouTube ID of the playing file
--   ui          toasts, the prompt line, the stats panel, the dialog
--   segments    fetch, chapters, skip/mute, prompts, highlights, votes
--   stats       the stats panel (z)
--   submit      marking (; :), the category dialog, submissions
--   (startup)   reads yas.conf, binds keys, registers mpv events
--
-- The file returns its sections; mpv ignores that, the test suite uses it.

local mp = mp
local os, io = os, io
local utils = require "mp.utils"
local mpoptions = require "mp.options"
local assdraw = require "mp.assdraw"

local core, categories, timefmt, store, identity, http, detect, ui, segments, stats, submit = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}

-- ----------------------------------------------------------------------------
-- CORE
-- Shared configuration and state of the plugin. Every other module reads
-- and writes these tables; nothing here talks to SponsorBlock or the OSD.
-- ----------------------------------------------------------------------------
do
    -- Default options; script-opts/yas.conf overrides them (see main.lua)
    core.options = {
        server_address = "https://sponsor.ajay.app",
        categories = "sponsor,selfpromo,interaction,intro,outro,preview,hook,filler",
        -- skip = seek past the segment; mute = mute audio for its duration.
        -- poi (highlights) and full (labels) are added by their own options.
        action_types = "skip,mute",
        -- Optional manual override (e.g. pinning a specific ID). Leave empty
        -- to auto-generate one — the generated ID is persisted outside this
        -- file (see lib/identity.lua), not written back here.
        user_id = "",

        -- Skip a segment only the first time playback enters it; seeking
        -- back into it afterwards plays it.
        skip_once = true,
        -- Categories that show a "press to skip" prompt instead of skipping
        -- automatically (comma-separated, e.g. "filler,preview").
        manual_skip_categories = "",
        -- Key that skips in a manual prompt, undoes the last skip, and jumps to
        -- a highlight when offered. Only bound while one of those is offered.
        skip_key = "ENTER",
        -- Seconds after a skip during which skip_key undoes it (0 = off).
        unskip_window = 5,
        -- Vote on the segment under the playhead (or the last one skipped).
        upvote_key = "Ctrl+g",
        downvote_key = "Ctrl+b",
        -- Highlights (poi_highlight): add a chapter, offer a jump near the
        -- start of the video, and bind highlight_key to jump at any time.
        highlight = true,
        highlight_key = "H",
        highlight_prompt_duration = 8,
        -- Announce full-video labels (the whole video is sponsored, self
        -- promotion or exclusive access).
        full_video_labels = true
    }

    -- Endpoint URLs. Filled by build_endpoints() once yas.conf has been read,
    -- so a server_address override actually takes effect.
    core.endpoints = {}

    function core.build_endpoints()
        local base = core.options.server_address:gsub("/+$", "")
        core.endpoints.skip_segments = base .. "/api/skipSegments"
        core.endpoints.viewed_video_sponsor_time = base .. "/api/viewedVideoSponsorTime"
        core.endpoints.user_stats = base .. "/api/userStats"
        core.endpoints.user_info = base .. "/api/userInfo"
        core.endpoints.vote_on_sponsor_time = base .. "/api/voteOnSponsorTime"
    end

    -- curl limits, in seconds: a stalled server must never leave a request
    -- (and the callbacks waiting on it) hanging indefinitely.
    core.CONNECT_TIMEOUT = 5
    core.MAX_TIME = 10

    -- Per-file playback state
    core.state = {
        segments = nil,
        youtube_id = nil,
        has_valid_user_id = false,
        base_chapters = nil, -- video's own chapters, captured once, before SponsorBlock ones are added
        file_generation = 0, -- bumped on every end-file; async replies for older files are dropped
        active_mute_segment = nil, -- the "mute" segment currently muting audio, if any
        mute_before_segment = false, -- mute state to restore once active_mute_segment ends
        highlight = nil, -- this video's poi_highlight segment, if any
        full_label = nil, -- this video's full-video label segment, if any
        last_segment = nil, -- last segment skipped/muted/prompted: the default vote target
        prompt_segment = nil, -- manual-skip segment whose prompt is showing
        -- uuid -> {skipped, counted, allowed, vote} for this file. Kept apart
        -- from the segment tables so it survives a segments refresh.
        seen = {},
        manual = {} -- set of categories that prompt instead of auto-skipping
    }

    -- Segment marking / submission workflow
    core.submission = {
        marking_segment = false,
        start_time = nil,
        dialog_visible = false,
        keybindings_active = false,
        -- Set while hold_playback_open() is holding keep-open at "always" for
        -- the marking/dialog workflow; holds the value to restore it to.
        prev_keep_open = nil,
        -- Set while the dialog is open, so end-file can remove its forced key
        -- bindings if the file changes while it's up
        dialog_cleanup = nil,
        -- A chapter-name text prompt is open (mp.input)
        input_open = false,
        close_input = nil
    }

    -- Wraps a callback so an uncaught error inside it is logged and swallowed
    -- instead of propagating into mpv's event dispatch. mpv gives a script no
    -- safety net of its own here: an error escaping one of this script's
    -- registered event/property callbacks kills its entire event loop, so no
    -- further file-loaded/end-file/property-change events ever reach it again
    -- for the rest of the session (looks like the plugin "crashed" and never
    -- came back). Used to wrap every mpv-registered entry point.
    function core.safe_call(fn, name)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                mp.msg.error(("💥 yas: unhandled error in %s: %s"):format(name, tostring(err)))
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- CATEGORIES
-- SponsorBlock categories, in the browser extension's order. Used by the
-- submission dialog, the stats panel, toasts and chapter titles.
--   action: the action type a submission of this category uses
--     skip  = a time range           poi  = a single point (start mark)
--     full  = a label for the whole video   chapter = a named time range
-- ----------------------------------------------------------------------------
do
    categories.list = {
        {key = "sponsor", name = "Sponsor", action = "skip",
         desc = "Paid promotion, paid referrals and direct advertisements"},
        {key = "selfpromo", name = "Unpaid/Self Promotion", action = "skip",
         desc = "Unpaid or self promotion: merchandise, donations, collaborations"},
        {key = "exclusive_access", name = "Exclusive Access", action = "full",
         desc = "The whole video showcases a product or service the creator got for free or early"},
        {key = "interaction", name = "Interaction Reminder (Subscribe)", action = "skip",
         desc = "Reminders to like, subscribe, follow or comment"},
        {key = "poi_highlight", name = "Highlight", action = "poi",
         desc = "The part of the video most people are looking for (uses the start mark)"},
        {key = "intro", name = "Intermission/Intro Animation", action = "skip",
         desc = "An interval without actual content: pauses, intro animations, static frames"},
        {key = "outro", name = "Endcards/Credits", action = "skip",
         desc = "Credits or YouTube endcards at the end of the video"},
        {key = "preview", name = "Preview/Recap", action = "skip",
         desc = "Clips showing what's coming up, or recapping what already happened"},
        {key = "hook", name = "Hook/Greetings", action = "skip",
         desc = "Teasers and greetings at the start that don't add information"},
        {key = "filler", name = "Tangents/Jokes", action = "skip",
         desc = "Tangential scenes or jokes not required to understand the video"},
        {key = "chapter", name = "Chapter", action = "chapter",
         desc = "A named chapter (asks for a name; needs mpv 0.38+)"},
        {key = "music_offtopic", name = "Music: Non-Music Section", action = "skip",
         desc = "Only for music videos: parts that aren't the music itself"}
    }

    categories.by_key = {}
    for _, c in ipairs(categories.list) do categories.by_key[c.key] = c end

    -- Display name of a category key ("selfpromo" -> "Unpaid/Self Promotion")
    function categories.name(key)
        local c = categories.by_key[key or ""]
        if c then return c.name end
        return ((key or "unknown"):gsub("^%l", string.upper):gsub("_", " "))
    end
end

-- ----------------------------------------------------------------------------
-- TIMEFMT
-- Time formatting: everything shown on screen goes through these.
-- ----------------------------------------------------------------------------
do
    -- A length of time: "45s" / "12.5s" under a minute, then "1m 5s",
    -- "1h 2m 3s", "1d 4h", "1y 2d"... Zero parts are left out.
    function timefmt.duration(seconds)
        seconds = math.max(0, tonumber(seconds) or 0)
        if seconds < 59.95 then
            local tenths = math.floor(seconds * 10 + 0.5) / 10
            if tenths == math.floor(tenths) then return ("%ds"):format(tenths) end
            return ("%.1fs"):format(tenths)
        end
        local total = math.floor(seconds + 0.5)
        local units = {
            {"y", 365 * 86400}, {"d", 86400}, {"h", 3600}, {"m", 60}, {"s", 1}
        }
        local parts = {}
        for _, unit in ipairs(units) do
            local n = math.floor(total / unit[2])
            total = total - n * unit[2]
            if n > 0 then parts[#parts + 1] = n .. unit[1] end
        end
        return table.concat(parts, " ")
    end

    -- Stats durations come in minutes from the API and the local tally
    function timefmt.minutes(total_minutes)
        return timefmt.duration((total_minutes or 0) * 60)
    end

    -- A position in the video, like a seekbar: "0:10.0", "12:34.2",
    -- "1:02:03.4". decimals: digits after the seconds (default 1; 0 = none).
    function timefmt.timestamp(seconds, decimals)
        decimals = decimals or 1
        local scale = 10 ^ decimals
        seconds = math.floor(math.max(0, tonumber(seconds) or 0) * scale + 0.5) / scale
        local h = math.floor(seconds / 3600)
        local m = math.floor(seconds / 60) % 60
        local sec = seconds - h * 3600 - math.floor(seconds / 60) % 60 * 60
        local sec_text = decimals > 0
            and ("%0" .. (3 + decimals) .. "." .. decimals .. "f"):format(sec)
            or ("%02d"):format(sec)
        if h > 0 then return ("%d:%02d:%s"):format(h, m, sec_text) end
        return ("%d:%s"):format(m, sec_text)
    end
end

-- ----------------------------------------------------------------------------
-- STORE
-- Files in the XDG state directory (~/.local/state/mpv): private files
-- for the user ID, and the local tally of skipped segments.
--
-- Kept outside the git-tracked config tree (~~/ resolves inside it), as a
-- plain ~/ path, not a ~~ meta-path: ~~state/ was tried for
-- perpetual-playlist's IPC socket and proved unreliable on some mpv builds
-- (fell back into the config tree, or failed outright).
-- ----------------------------------------------------------------------------
do
    -- Absolute path of `name` in the state directory, or nil
    function store.path(name)
        local ok, path = pcall(mp.command_native, {"expand-path", "~/.local/state/mpv/" .. name})
        if not ok or not path or path == "" then return nil end
        return path
    end

    -- Makes `path` readable and writable by its owner only. Best effort:
    -- chmod doesn't exist on Windows, and failing here must not stop the script.
    function store.chmod_private(path)
        pcall(mp.command_native, {
            name = "subprocess",
            args = {"chmod", "600", path},
            playback_only = false
        })
    end

    -- io.open(path, "w") does not create missing parent directories on its
    -- own. Only shell out to mkdir -p in this rare fallback path (on actual
    -- write failure), not on every script load.
    local function open_for_write(path)
        local out, err = io.open(path, "w")
        if out then return out end
        pcall(function()
            local dir = utils.split_path(path) -- split_path returns (dir, filename); only dir wanted here
            mp.command_native({
                name = "subprocess",
                args = {"mkdir", "-p", dir},
                playback_only = false
            })
        end)
        return io.open(path, "w")
    end

    -- Writes `content` to `path` so it is never readable by other users, not
    -- even briefly: the file is created empty, restricted, and only then
    -- filled (truncating keeps the mode). Creates the parent directory if
    -- needed. Returns true on success.
    function store.write_private_file(path, content)
        local out, err = open_for_write(path)
        if not out then return false, err end
        out:close()
        store.chmod_private(path)
        out, err = io.open(path, "w")
        if not out then return false, err end
        out:write(content)
        out:close()
        return true
    end

    -- Local, per-installation tally of segments this script has actually
    -- skipped/muted — independent of any user_id, and of SponsorBlock's own
    -- server-side stats (which only count segments *you submitted*, and never
    -- move just from watching/skipping). Mirrors the reference browser
    -- extension's Config.config.skipCount / minutesSaved, which are likewise
    -- purely local and have no server-side equivalent.
    store.local_stats = {
        skip_count = 0,
        minutes_saved = 0
    }

    function store.load_local_stats()
        local path = store.path("yas_stats.conf")
        if not path then return end
        local f = io.open(path, "r")
        if not f then return end
        for line in f:lines() do
            -- Note: %a is letters only, not %w — must include "_" explicitly
            -- or "skip_count"/"minutes_saved" never match.
            local key, value = line:match("^([%a_]+)=([%d%.]+)$")
            if key == "skip_count" then
                store.local_stats.skip_count = tonumber(value) or 0
            elseif key == "minutes_saved" then
                store.local_stats.minutes_saved = tonumber(value) or 0
            end
        end
        f:close()
    end

    function store.save_local_stats()
        local path = store.path("yas_stats.conf")
        if not path then return end
        local out, err = open_for_write(path)
        if not out then
            mp.msg.warn("⚠️ Could not write " .. path .. " to persist local stats: " .. tostring(err))
            return
        end
        out:write(("skip_count=%d\nminutes_saved=%.4f\n"):format(store.local_stats.skip_count, store.local_stats.minutes_saved))
        out:close()
    end

    -- Records one real skip/mute action toward the local tally and persists it
    -- immediately — writes are rare (at most a handful per video), so there's
    -- no need to batch them.
    function store.record_local_skip(segment)
        store.local_stats.skip_count = store.local_stats.skip_count + 1
        store.local_stats.minutes_saved = store.local_stats.minutes_saved + (segment.end_time - segment.start_time) / 60
        store.save_local_stats()
    end
end

-- ----------------------------------------------------------------------------
-- IDENTITY
-- The private SponsorBlock user ID: resolving it (yas.conf override, a
-- previously generated one, or a new one), keeping it out of logs and off
-- curl's command line.
--
-- The private userID is SponsorBlock's only credential (there are no
-- passwords): it must never reach the terminal, a --log-file, or another
-- user's `ps`.
-- ----------------------------------------------------------------------------
do
    -- Pass this as a request parameter value to send the user ID: curl reads
    -- it from the owner-only secret file (see lib/http.lua).
    identity.USER_ID = setmetatable({}, { __tostring = function() return "<userID>" end })

    -- Owner-only file holding the ID for curl; nil if it couldn't be written
    identity.secret_path = nil

    -- Diagnostics use this masked form instead of the ID
    function identity.mask(id)
        if type(id) ~= "string" or #id < 12 then return "<hidden>" end
        return id:sub(1, 4) .. "…" .. id:sub(-4)
    end

    -- Replaces every occurrence of the private userID in `text` (log lines,
    -- curl command lines, JSON bodies) with its masked form.
    function identity.redact(text)
        local id = core.options.user_id
        if type(text) ~= "string" or type(id) ~= "string" or id == "" then return text end
        local escaped = id:gsub("%p", "%%%0")
        return (text:gsub(escaped, identity.mask(id)))
    end

    -- Generates a 32-character alphanumeric userID. Prefers the OS CSPRNG;
    -- falls back to math.random seeded from several sources, so two installs
    -- started in the same second still get different IDs.
    function identity.generate()
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

    -- Generated identity state lives in the state dir, not in
    -- script-opts/yas.conf, which mp.options treats as user-editable config.
    local GENERATED_ID_FILE = "yas_user_id"

    -- Loads a previously generated user_id, if any, so future launches reuse
    -- the same identity instead of minting a new one every session - which
    -- would keep resetting submission history/reputation and always show
    -- near-empty stats.
    local function load_generated()
        local path = store.path(GENERATED_ID_FILE)
        if not path then return nil end
        local f = io.open(path, "r")
        if not f then return nil end
        local id = f:read("*l") -- "*l", not "l": PUC Lua 5.1 rejects the short form
        f:close()
        if id then id = id:match("^%s*(.-)%s*$") end -- trim
        return id
    end

    local function persist_generated(user_id)
        local path = store.path(GENERATED_ID_FILE)
        if not path then
            mp.msg.warn("⚠️ Could not resolve yas_user_id path; generated userID won't persist")
            return
        end
        local ok, err = store.write_private_file(path, user_id .. "\n")
        if not ok then
            mp.msg.warn("⚠️ Could not write " .. path .. " to persist generated userID: " .. tostring(err))
            return
        end
        mp.msg.info("💾 Saved generated userID to " .. path)
    end

    -- Resolves core.options.user_id: a manual override in yas.conf wins;
    -- otherwise a previously generated one is reused; otherwise a new one is
    -- generated and persisted (required for submissions). Then writes the
    -- owner-only secret file curl reads it from.
    function identity.resolve()
        local options = core.options
        if not options.user_id or #options.user_id < 30 then
            local existing_id = load_generated()
            if existing_id and #existing_id >= 30 then
                options.user_id = existing_id
                -- Files written by older versions were created world-readable
                store.chmod_private(store.path(GENERATED_ID_FILE))
                mp.msg.info("🆔 Reusing previously generated local userID " .. identity.mask(options.user_id))
            else
                local user_id = identity.generate()
                options.user_id = user_id
                mp.msg.info("🆔 Generated new local userID for submissions " .. identity.mask(user_id))
                persist_generated(user_id)
            end
        end

        -- mpv logs every subprocess command at debug level (so --log-file
        -- captures it), and any local user can read a process's arguments with
        -- ps: curl reads the ID from this file instead (name@file / --data
        -- @file). If it can't be written, requests pass the ID inline.
        local path = store.path("yas_secret")
        if path and options.user_id and options.user_id ~= "" then
            if store.write_private_file(path, options.user_id) then
                identity.secret_path = path
            else
                mp.msg.warn("⚠️ Could not write " .. path .. "; the userID will be passed on curl's command line")
            end
        end

        core.state.has_valid_user_id = options.user_id and #options.user_id >= 30
            and options.user_id:match("^[%w]+$") and true or false
    end
end

-- ----------------------------------------------------------------------------
-- HTTP
-- HTTP requests through curl, run asynchronously so mpv never blocks.
-- ----------------------------------------------------------------------------
do
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
    function http.parse_result(success, result, error_string)
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

    -- Adds one parameter to a curl command. GET parameters go in the query
    -- string via --get/--data-urlencode; for POST they're appended to the URL
    -- with --url-query (curl 7.87+) so the body stays free. The USER_ID
    -- sentinel is read by curl from the owner-only secret file.
    local function add_param(curl_cmd, method, key, value)
        local flag = method == "GET" and "--data-urlencode" or "--url-query"
        table.insert(curl_cmd, flag)
        if value == identity.USER_ID then
            if identity.secret_path then
                table.insert(curl_cmd, key .. "@" .. identity.secret_path)
                return
            end
            value = core.options.user_id
        end
        -- tostring() because PUC Lua 5.1's %s rejects booleans (fetchCategoryStats = true)
        table.insert(curl_cmd, ("%s=%s"):format(key, tostring(value)))
    end

    -- Runs an HTTP request with curl WITHOUT blocking mpv: the subprocess runs
    -- asynchronously and callback(data, error, http_code) is called when it
    -- finishes. The callback is wrapped in safe_call, so an error inside it is
    -- logged instead of killing the script's event loop.
    --   query_params: table of parameters; use identity.USER_ID as a value
    --                 to send the private userID without exposing it.
    --   json_body:    string, sent inline: it must not contain the userID
    --                 (mpv logs the command line); use query_params for it.
    function http.request(url, method, query_params, json_body, callback)
        method = method or "GET"
        callback = callback or function() end

        local curl_cmd = {
            "curl", "--location", "--silent",
            "--connect-timeout", tostring(core.CONNECT_TIMEOUT),
            "--max-time", tostring(core.MAX_TIME),
            "--write-out", "\n%{http_code}",
        }

        if method == "GET" then
            table.insert(curl_cmd, "--get")
        else
            table.insert(curl_cmd, "--request")
            table.insert(curl_cmd, method)
        end

        table.insert(curl_cmd, url)

        if json_body then
            table.insert(curl_cmd, "--header")
            table.insert(curl_cmd, "Content-Type: application/json")
            table.insert(curl_cmd, "--data")
            table.insert(curl_cmd, json_body)
        end
        if query_params then
            -- Sorted so commands (and logs) are deterministic
            local keys = {}
            for key in pairs(query_params) do keys[#keys + 1] = key end
            table.sort(keys)
            for _, key in ipairs(keys) do add_param(curl_cmd, method, key, query_params[key]) end
        end

        mp.msg.debug("🐚 curl command: " .. identity.redact(table.concat(curl_cmd, " ")))

        local done = core.safe_call(function(success, result, error_string)
            local data, err, code = http.parse_result(success, result, error_string)
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
end

-- ----------------------------------------------------------------------------
-- DETECT
-- Finds the YouTube video ID of the file being played.
-- ----------------------------------------------------------------------------
do
    -- Checks the path, then the Referer header (direct stream URLs), then the
    -- PURL metadata tag of downloaded files.
    function detect.youtube_id()
        local video_path = mp.get_property("path", "")
        local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""
        local purl = mp.get_property("metadata/by-key/PURL", "")
        local urls = {
            "https?://youtu%.be/([%w-_]+).*",
            "https?://w?w?w?%.?youtube%.com/v/([%w-_]+)",
            "/watch.*[?&]v=([%w-_]+)",
            "/embed/([%w-_]+)",
            "/shorts/([%w-_]+)",
            "/live/([%w-_]+)",
        }
        -- Downloaded files: yt-dlp's "Title [ID].ext" and the older
        -- "Title-ID.ext". An ID is exactly 11 characters; anything else is
        -- just a dash in a file name.
        local files = {
            "%[([%w-_]+)%]%.%w+$",
            ".*-([%w-_]+)%.%w+$",
        }
        mp.msg.debug("🔎 Detecting YouTube ID from path: " .. video_path)
        for _, url in ipairs(urls) do
            local candidate = string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
            if candidate and #candidate >= 11 then
                mp.msg.info("🆔 YouTube ID detected: " .. string.sub(candidate, 1, 11))
                return string.sub(candidate, 1, 11)
            end
        end
        for _, file in ipairs(files) do
            local candidate = string.match(video_path, file)
            if candidate and #candidate == 11 then
                mp.msg.info("🆔 YouTube ID detected: " .. candidate)
                return candidate
            end
        end
        mp.msg.warn("⚠️ No YouTube ID detected")
        return nil
    end
end

-- ----------------------------------------------------------------------------
-- UI
-- On-screen drawing: toasts, the key-prompt line, the stats panel and the
-- category dialog.
--
-- Styled like playlist_manager.lua: a fixed virtual canvas (res_y=720,
-- res_x scaled to the display's aspect ratio) so panels are the same
-- physical size on any screen, real glyph-width measurement via a hidden
-- compute_bounds overlay instead of guessing per-character width, and no
-- forced font — text renders in mpv's default OSD font.
-- ----------------------------------------------------------------------------
do
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

    -- panel: stats panel and category dialog (one at a time)
    local overlays = {
        panel = nil,
        toast = nil,
        toast_timer = nil,
        prompt = nil
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

    local function show(ov, data, width, height)
        ov.res_x = width
        ov.res_y = height
        ov.z = 2000
        ov.data = data
        ov:update()
    end

    local function clear(ov)
        if ov then
            ov.data = ""
            ov:update()
        end
    end

    local function panel_overlay()
        if not overlays.panel then
            overlays.panel = mp.create_osd_overlay("ass-events")
        end
        return overlays.panel
    end

    -- Draws a one-line rounded "pill" with `message` into overlay `ov`,
    -- right-aligned against the bottom-right corner. `row` 0 is the bottom
    -- line (toasts), row 1 the line above it (key prompts). kind picks the
    -- text color.
    local function render_pill(ov, message, kind, row)
        local style = TOAST_STYLE[kind or "info"] or TOAST_STYLE.info
        local full = style.icon .. message

        local width, height = get_virt_size()
        local max_w = width - PAD * 4
        local cw = math.min(measure_text(full), max_w)
        local x = width - PAD * 2 - cw
        local y = height - PAD * 2 - FONT_SIZE - row * (FONT_SIZE + PAD * 2)

        local ass = assdraw.ass_new()

        ass:new_event()
        ass:an(7)
        ass:pos(x, y)
        ass:append(("{\\bord0\\blur0\\1c&H000000&\\1a&H%02X&\\4a&Hff&}"):format(BG_ALPHA))
        ass:draw_start()
        local tpad = PAD / 2
        ass:round_rect_cw(-PAD, -tpad, cw + PAD, FONT_SIZE + tpad, CORNER, CORNER)
        ass:draw_stop()

        local clip = ("\\clip(%d,0,%d,%d)"):format(math.floor(x), math.floor(x + cw), height)
        ass:new_event()
        ass:an(4)
        ass:pos(x, y + FONT_SIZE / 2)
        ass:append(("{\\bord1\\1c&H%s&\\3c&H000000&\\fs%d\\fsp0\\q2%s}"):format(style.color, FONT_SIZE, clip))
        ass:append(full)

        show(ov, ass.text, width, height)
    end

    -- A short message in the bottom-right corner.
    -- kind: "info" (default), "success", or "error" — picks the text color.
    function ui.toast(message, kind, duration)
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

        render_pill(overlays.toast, message, kind, 0)

        overlays.toast_timer = mp.add_timeout(duration, function()
            clear(overlays.toast)
            overlays.toast_timer = nil
        end)
    end

    -- Removes the current toast right away.
    function ui.hide_toast()
        if overlays.toast_timer then
            overlays.toast_timer:kill()
            overlays.toast_timer = nil
        end
        clear(overlays.toast)
    end

    -- The key prompt ("ENTER to skip", "to undo", "to jump") gets its own
    -- line just above the toasts: it stays exactly as long as the key is
    -- bound and can't be painted over by an unrelated toast.
    function ui.show_prompt(message)
        if not overlays.prompt then
            overlays.prompt = mp.create_osd_overlay("ass-events")
        end
        render_pill(overlays.prompt, message, "info", 1)
    end

    function ui.hide_prompt()
        clear(overlays.prompt)
    end

    -- Renders a centered panel from a list of rows (see stats.format()):
    -- plain {text=...} lines, and {label=..., value=...} rows laid out as a
    -- real two-column table — label left-aligned, value right-aligned in its
    -- own column — since character padding only lines up in a monospace font.
    function ui.show_panel(rows)
        local ov = panel_overlay()
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

        show(ov, ass.text, width, height)
    end

    function ui.hide_panel()
        clear(overlays.panel)
    end

    -- Renders the segment-category picker with the focused row highlighted
    -- (white box, dark text) the same way playlist_manager highlights its
    -- focused playlist entry.
    function ui.draw_dialog(start_time, end_time, selected_index)
        local ov = panel_overlay()
        local list = categories.list

        local width, height = get_virt_size()
        local header = ("Submit segment: %s → %s (%s)"):format(
            timefmt.timestamp(start_time), timefmt.timestamp(end_time), timefmt.duration(end_time - start_time))
        local footer = "↑/↓ Navigate   1–9 Jump   Enter Submit   Esc Cancel"
        local n = #list
        local focused_category = list[selected_index]
        local desc = focused_category and focused_category.desc or ""

        -- Reserve a fixed indent for the focus arrow so rows never shift
        -- between focused/unfocused — the arrow is drawn on top of it, not
        -- inline with the text.
        local arrow_w = measure_text("▶") + FONT_SIZE * 0.3

        local cw = math.max(measure_text(header), measure_text(footer))
        local desc_sty = ("{\\bord1\\1c&HBBBBBB&\\3c&H000000&\\fs%d\\fsp0\\q2}"):format(math.floor(FONT_SIZE * 0.8))
        for i, category in ipairs(list) do
            local w = measure_text(i .. ". " .. category.name) + arrow_w
            if w > cw then cw = w end
        end
        cw = math.min(cw, width - PAD * 4)

        local box_w = cw + PAD * 2
        local box_h = (n + 4) * LH + PAD * 2 -- header + rows + description + gap + footer
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
        for i, category in ipairs(list) do
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

        -- What the focused category means. Clipped to the panel: some
        -- descriptions are longer than the widest row.
        ass:new_event()
        ass:an(7)
        ass:pos(x + PAD, y + PAD + (n + 1.75) * LH)
        ass:append(desc_sty .. ("{\\clip(%d,0,%d,%d)}"):format(math.floor(x), math.floor(x + box_w - PAD), height) .. desc)

        -- Footer hint
        ass:new_event()
        ass:an(7)
        ass:pos(x + PAD, y + PAD + (n + 3) * LH)
        ass:append(sty .. footer)

        show(ov, ass.text, width, height)
    end
end

-- ----------------------------------------------------------------------------
-- SEGMENTS
-- What happens while a video plays: fetching its segments, chapters,
-- skipping and muting, the skip/undo/highlight prompts, and votes.
-- ----------------------------------------------------------------------------
do
    local options, state, endpoints = core.options, core.state, core.endpoints

    -- FETCHING

    -- Bumped by every segments.get() call; only the newest reply is applied
    local request_seq = 0

    -- Fetches this video's segments from the API (asynchronously)
    function segments.get()
        if not state.youtube_id then
            mp.msg.warn("⚠️ No YouTube ID, cannot fetch segments")
            return
        end
        mp.msg.info("🌐 Fetching SponsorBlock segments for video: " .. state.youtube_id)
        -- The answer arrives asynchronously: by then the user may have moved
        -- on to another file. Only apply it to the file that asked for it.
        local generation = state.file_generation
        request_seq = request_seq + 1
        local seq = request_seq
        http.request(endpoints.skip_segments, "GET", {
            categories = ("[%s]"):format(options.categories),
            actionTypes = ("[%s]"):format(options.action_types),
            videoID = state.youtube_id
        }, nil, function(data, error_msg, code)
            if generation ~= state.file_generation then
                mp.msg.debug("⏭️ Ignoring segments for a file that is no longer playing")
                return
            end
            if seq ~= request_seq then
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
            segments.apply(data)
        end)
    end

    -- Turns the API's segment list into state.segments, chapters and the
    -- time-pos observer that skips/mutes them.
    function segments.apply(data)
        state.segments = {}
        state.highlight = nil
        local new_full_label = nil
        for _, seg in ipairs(data) do
            -- Trust nothing from the API beyond "looks like a segment": a
            -- missing/malformed UUID or category would otherwise throw later
            -- (string.sub/gsub on nil) from inside the file-loaded handler.
            if seg.segment and #seg.segment == 2
                and type(seg.UUID) == "string" and seg.UUID ~= ""
                and type(seg.category) == "string" and seg.category ~= ""
                and type(seg.actionType) == "string" then
                local start_time, end_time = tonumber(seg.segment[1]), tonumber(seg.segment[2])
                local entry = {
                    uuid = seg.UUID,
                    short_uuid = string.sub(seg.UUID, 1, 6),
                    category = seg.category,
                    action = seg.actionType, -- API field is "actionType", not "action"
                    start_time = start_time,
                    end_time = end_time,
                    skip_reported = false
                }
                if seg.actionType == "poi" then
                    -- A highlight is a single point: [t, t]
                    if options.highlight and start_time and not state.highlight then
                        state.highlight = entry
                    end
                elseif seg.actionType == "full" then
                    -- A label for the whole video; its times are meaningless
                    if options.full_video_labels and not new_full_label then
                        new_full_label = entry
                    end
                elseif start_time and end_time and end_time > start_time
                    and (seg.actionType == "skip" or seg.actionType == "mute") then
                    table.insert(state.segments, entry)
                end
            else
                mp.msg.warn("⚠️ Skipping malformed SponsorBlock segment: " .. utils.to_string(seg))
            end
        end
        -- Announce a full-video label once per file (not again on refresh).
        -- It's a toast; prompts (highlight, undo) use their own line above it.
        state.full_label = new_full_label
        if new_full_label and not state.full_label_announced then
            state.full_label_announced = true
            ui.toast("Entire video: " .. categories.name(new_full_label.category), "info", 6)
            mp.msg.info("🏷️ Full-video label: " .. new_full_label.category)
        end

        if state.highlight then
            segments.offer_highlight()
        end

        if #state.segments > 0 or state.highlight then
            segments.create_chapters()
        end
        if #state.segments > 0 then
            mp.msg.info(("✅ SponsorBlock: %d segments found"):format(#state.segments))
            -- Avoid stacking duplicate observers if segments are re-fetched
            -- mid-video (e.g. after a submission refresh). Always the same
            -- segments.observer reference so unobserve matches what was observed.
            mp.unobserve_property(segments.observer)
            mp.observe_property("time-pos", "native", segments.observer)
        else
            mp.msg.info("ℹ️ SponsorBlock: no segments found")
        end
    end

    -- Adds segment and highlight chapters to mpv's chapter list
    function segments.create_chapters()
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
        if state.highlight then
            table.insert(chapters, { title = "Highlight", time = state.highlight.start_time })
        end
        for _, segment in ipairs(state.segments) do
            table.insert(chapters, {
                title = categories.name(segment.category)
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
    function segments.report_skip(segment)
        if not segment or segment.skip_reported or segment.report_pending then return end
        segment.report_pending = true
        http.request(endpoints.viewed_video_sponsor_time, "POST", { UUID = segment.uuid }, nil,
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

    -- Per-file record for a segment, keyed by UUID (see state.seen)
    local function seen(segment)
        local rec = state.seen[segment.uuid]
        if not rec then
            rec = {}
            state.seen[segment.uuid] = rec
        end
        return rec
    end

    -- THE SKIP KEY

    -- The single temporary "action" bound to skip_key: skip (manual prompt),
    -- undo (after a skip) or jump (highlight). Bound only while offered, so
    -- the key keeps its normal meaning the rest of the time. A normal (not
    -- forced) binding: it overrides mpv's built-in ENTER (playlist-next) but
    -- yields to the user's input.conf and to forced-input UIs such as the
    -- console, uosc menus or a text prompt.
    local action = { fn = nil, timer = nil }

    function segments.clear_action()
        if action.timer then
            action.timer:kill()
            action.timer = nil
        end
        if action.fn then
            action.fn = nil
            mp.remove_key_binding("yas_action")
            ui.hide_prompt()
        end
    end

    -- Offers `fn` on skip_key with `text` shown on the prompt line, for
    -- `seconds` (nil = until cleared). Returns false when it can't be offered.
    local function offer_action(fn, seconds, text)
        segments.clear_action()
        if options.skip_key == "" then return false end
        -- Never compete with the submission dialog or a text prompt
        local submission = core.submission
        if submission.dialog_visible or submission.input_open then return false end
        action.fn = fn
        mp.add_key_binding(options.skip_key, "yas_action", core.safe_call(function()
            local f = action.fn
            segments.clear_action()
            if f then f() end
        end, "skip key"))
        if seconds then
            action.timer = mp.add_timeout(seconds, segments.clear_action)
        end
        ui.show_prompt(text)
        return true
    end

    local function duration_text(segment)
        return ("%s (%s)"):format(categories.name(segment.category), timefmt.duration(segment.end_time - segment.start_time))
    end

    -- SKIPPING

    -- Seeks past a segment, reports it and offers to undo.
    local function do_skip(segment)
        local rec = seen(segment)
        rec.skipped = true
        state.last_segment = segment
        mp.msg.info(("⏭️ Skipping segment: %s [%s - %s]"):format(segment.category, segment.start_time, segment.end_time))
        mp.set_property("time-pos", segment.end_time + 0.001)
        segments.report_skip(segment)
        if not rec.counted then
            rec.counted = true
            store.record_local_skip(segment)
        end

        local message = "Skipped " .. duration_text(segment)
        local offered = options.unskip_window > 0 and offer_action(function()
            -- Undo: go back and let this segment play for the rest of the file
            seen(segment).allowed = true
            mp.set_property("time-pos", segment.start_time)
            ui.toast("Playing " .. categories.name(segment.category), "info", 2)
            mp.msg.info("↩️ Unskipped segment " .. segment.short_uuid)
        end, options.unskip_window, message .. " · " .. options.skip_key .. " to undo")
        if not offered then
            ui.toast(message, "info")
        end
    end

    function segments.clear_skip_prompt()
        if state.prompt_segment then
            state.prompt_segment = nil
            segments.clear_action()
        end
    end

    local function show_skip_prompt(segment)
        -- By UUID: a segments refresh creates new tables for the same segment
        if state.prompt_segment and state.prompt_segment.uuid == segment.uuid then
            state.prompt_segment = segment
            return
        end
        segments.clear_skip_prompt()
        state.last_segment = segment
        if offer_action(function()
            state.prompt_segment = nil
            do_skip(segment)
        end, nil, duration_text(segment) .. " · " .. options.skip_key .. " to skip") then
            state.prompt_segment = segment
        end
    end

    -- time-pos observer: skips, mutes or prompts for the segments at `pos`.
    -- Segments overlap across categories, so every one under the playhead
    -- is considered; only an actual skip (a seek) ends the pass.
    function segments.on_time_pos(_, pos)
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

        -- Withdraw a manual-skip prompt once playback leaves its segment
        if state.prompt_segment then
            local seg = state.prompt_segment
            if pos < seg.start_time or pos >= seg.end_time then segments.clear_skip_prompt() end
        end

        for _, segment in ipairs(state.segments) do
            if pos >= segment.start_time and pos < segment.end_time then
                local rec = seen(segment)
                if rec.allowed then
                    -- Undone or downvoted: let it play
                elseif segment.action == "mute" then
                    -- Compared by UUID: a segments refresh creates new tables
                    if not state.active_mute_segment or state.active_mute_segment.uuid ~= segment.uuid then
                        state.mute_before_segment = mp.get_property_bool("mute")
                        mp.set_property_bool("mute", true)
                        state.active_mute_segment = segment
                        state.last_segment = segment
                        ui.toast("Muted " .. duration_text(segment), "info")
                        mp.msg.info(("🔇 Muting segment: %s [%s - %s]"):format(segment.category, segment.start_time, segment.end_time))
                        segments.report_skip(segment)
                        if not rec.counted then
                            rec.counted = true
                            store.record_local_skip(segment)
                        end
                    end
                elseif options.skip_once and rec.skipped then
                    -- Already skipped once this file: the viewer came back on purpose
                elseif state.manual[segment.category] then
                    show_skip_prompt(segment)
                else
                    do_skip(segment)
                    return
                end
            end
        end
    end

    -- The wrapped reference actually handed to mp.observe_property and
    -- mp.unobserve_property everywhere. Looks segments.on_time_pos up on each call.
    segments.observer = core.safe_call(function(...) return segments.on_time_pos(...) end, "skip_ads")

    -- HIGHLIGHTS

    function segments.jump_to_highlight()
        if not state.highlight then
            ui.toast("This video has no highlight", "info", 2)
            return
        end
        mp.set_property("time-pos", state.highlight.start_time)
        ui.toast("Jumped to the highlight", "info", 2)
    end

    -- Binds highlight_key and, when playback is still before the highlight
    -- (the first time per file), offers a jump on skip_key.
    function segments.offer_highlight()
        if not state.highlight_bound and options.highlight_key ~= "" then
            mp.add_key_binding(options.highlight_key, "jump_to_highlight",
                core.safe_call(segments.jump_to_highlight, "highlight key"))
            state.highlight_bound = true
        end
        if state.highlight_offered then return end
        state.highlight_offered = true
        local pos = mp.get_property_number("time-pos") or 0
        local at = state.highlight.start_time
        if pos < at - 1 then
            offer_action(segments.jump_to_highlight, options.highlight_prompt_duration,
                ("Highlight at %s · %s to jump"):format(timefmt.timestamp(at, 0), options.skip_key))
        end
    end

    -- VOTING

    -- The segment to vote on: the one under the playhead, else the last one
    -- skipped, muted or prompted.
    local function vote_target()
        local pos = mp.get_property_number("time-pos")
        if pos and state.segments then
            for _, segment in ipairs(state.segments) do
                if pos >= segment.start_time and pos < segment.end_time then return segment end
            end
        end
        return state.last_segment
    end

    -- vote_type: 1 = upvote, 0 = downvote
    function segments.vote(vote_type)
        local segment = vote_target()
        if not segment then
            ui.toast("No segment to vote on", "info", 2)
            return
        end
        local rec = seen(segment)
        local word = vote_type == 1 and "Upvoted" or "Downvoted"
        if rec.vote == vote_type then
            ui.toast(("Already %s this segment"):format(word:lower()), "info", 2)
            return
        end
        if rec.vote_pending then return end
        rec.vote_pending = true
        local generation = state.file_generation
        http.request(endpoints.vote_on_sponsor_time, "POST", {
            UUID = segment.uuid,
            userID = identity.USER_ID,
            type = vote_type
        }, nil, function(data, error_msg)
            rec.vote_pending = false
            -- The file changed meanwhile: rec belongs to a table end-file
            -- discarded, and the toast would land on the next video
            if generation ~= state.file_generation then return end
            if data then
                rec.vote = vote_type
                if vote_type == 0 then
                    -- Don't keep skipping or muting a segment the viewer says
                    -- is wrong, starting right now
                    rec.allowed = true
                    if state.prompt_segment and state.prompt_segment.uuid == segment.uuid then
                        segments.clear_skip_prompt()
                    end
                    if state.active_mute_segment and state.active_mute_segment.uuid == segment.uuid then
                        mp.set_property_bool("mute", state.mute_before_segment)
                        state.active_mute_segment = nil
                    end
                end
                ui.toast(("%s %s segment"):format(word, categories.name(segment.category)), "success")
                mp.msg.info(("🗳️ %s segment %s"):format(word, segment.short_uuid))
            else
                ui.toast("Vote failed: " .. (error_msg or "unknown error"), "error", 5)
            end
        end)
    end

    -- END OF FILE

    -- Restores sound, drops prompts and forgets this file's segments.
    function segments.reset()
        -- If a "mute" segment was actively muting audio, restore mute state
        -- before it (and this video) go away
        if state.active_mute_segment then
            mp.set_property_bool("mute", state.mute_before_segment)
            state.active_mute_segment = nil
        end

        state.segments = nil
        state.base_chapters = nil
        state.highlight = nil
        state.highlight_offered = false
        state.full_label = nil
        state.full_label_announced = false
        state.last_segment = nil
        state.seen = {}
        segments.clear_skip_prompt()
        segments.clear_action()
        if state.highlight_bound then
            mp.remove_key_binding("jump_to_highlight")
            state.highlight_bound = false
        end
        mp.unobserve_property(segments.observer)
    end
end

-- ----------------------------------------------------------------------------
-- STATS
-- The user stats panel (z): fetching, caching and formatting.
-- ----------------------------------------------------------------------------
do
    local cache = {
        data = nil,
        fetched_at = 0,
        duration = 300 -- 5 minutes in seconds
    }
    local visible = false
    local loading = false -- a fetch is in flight; ignore repeat z presses

    -- Returns a list of rows for ui.show_panel(): each is either
    -- {text=...} (a plain line) or {label=..., value=...} (a two-column stat,
    -- rendered with the value right-aligned in its own column).
    function stats.format(data)
        if not data then return {{text = "No user stats available"}} end

        local rows = {}
        local username = data.userName or "Unknown User"
        table.insert(rows, {text = "SponsorBlock user stats for " .. username})
        table.insert(rows, {text = ""})

        -- Overall stats
        if data.overallStats then
            table.insert(rows, {text = "Overall Statistics"})
            if data.overallStats.minutesSaved then
                table.insert(rows, {label = "Time Saved", value = timefmt.minutes(data.overallStats.minutesSaved)})
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
                data.viewCount, timefmt.minutes(data.overallStats.minutesSaved))})
        end
        local local_stats = store.local_stats
        table.insert(rows, {text = ("You've skipped %d segments (%s)"):format(
            local_stats.skip_count, timefmt.minutes(local_stats.minutes_saved))})

        -- Category breakdown, in the same order and names as the dialog
        if data.categoryCount then
            table.insert(rows, {text = ""})
            table.insert(rows, {text = "Segments by Category"})
            for _, cat in ipairs(categories.list) do
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

    -- z: shows the panel (from cache if fresh, else fetched) or hides it
    function stats.toggle()
        local state = core.state

        -- The category dialog draws in the same panel and keeps its keys
        if core.submission.dialog_visible then return end

        -- If stats are already visible, hide them
        if visible then
            ui.hide_panel()
            visible = false
            mp.msg.debug("📊 User stats dialog closed")
            return
        end

        local current_time = os.time()

        -- Check if we have cached data that's still valid (within 5 minutes)
        if cache.data and (current_time - cache.fetched_at) < cache.duration then
            mp.msg.debug("📊 Using cached user stats (fetched " .. (current_time - cache.fetched_at) .. "s ago)")
            ui.show_panel(stats.format(cache.data))
            visible = true
            return
        end

        -- Need to fetch new data (either no cache or cache expired). Both
        -- requests run in the background; the panel opens when they finish.
        if loading then return end
        loading = true
        local generation = state.file_generation
        ui.toast("Loading SponsorBlock stats…", "info", core.MAX_TIME * 2)
        mp.msg.info("🌐 Fetching user stats for userID " .. identity.mask(core.options.user_id))

        local function display(data)
            loading = false
            ui.hide_toast() -- drop the "Loading…" toast
            -- The file changed while loading: keep the data, don't pop a
            -- panel up over the next video.
            if generation ~= state.file_generation then return end
            ui.show_panel(stats.format(data))
            visible = true
            mp.msg.debug("📊 User stats dialog displayed")
        end

        http.request(core.endpoints.user_stats, "GET", {
            userID = identity.USER_ID,
            fetchCategoryStats = true,
            fetchActionTypeStats = true
        }, nil, function(data, error_msg)
            if type(data) ~= "table" then
                error_msg = error_msg or "unexpected response"
                -- If fetch fails but we have cached data, use it anyway
                if cache.data then
                    mp.msg.warn("⚠️ Failed to fetch fresh stats, using cached data: " .. error_msg)
                    display(cache.data)
                else
                    loading = false
                    ui.toast("Failed to get user stats: " .. error_msg, "error", 5)
                    mp.msg.warn("❌ Failed to get user stats: " .. error_msg)
                end
                return
            end

            -- /api/userStats doesn't expose viewCount (segments *you* submitted,
            -- viewed by anyone) — fetch it separately from /api/userInfo. Best
            -- effort: if this fails, the "Saved others from..." line is just
            -- omitted rather than failing the whole dialog.
            http.request(core.endpoints.user_info, "GET", {
                userID = identity.USER_ID,
                values = '["viewCount"]'
            }, nil, function(view_data)
                if type(view_data) == "table" and view_data.viewCount then
                    data.viewCount = view_data.viewCount
                end

                -- Successfully fetched new data - update cache
                cache.data = data
                cache.fetched_at = current_time
                mp.msg.info("📊 User stats fetched and cached")
                display(data)
            end)
        end)
    end

    -- End of file: close the panel and drop the cache
    function stats.reset()
        cache.data = nil
        cache.fetched_at = 0
        if visible then ui.hide_panel() end
        visible = false
    end
end

-- ----------------------------------------------------------------------------
-- SUBMIT
-- Marking a segment (; and :), the category dialog and submitting it.
-- ----------------------------------------------------------------------------
do
    local options, state, submission = core.options, core.state, core.submission

    -- category: an entry of categories.list. Its action decides the shape
    -- of the submission: a range (skip), a point (poi, uses the start mark), a
    -- whole-video label (full) or a named range (chapter, asks for the name).
    function submit.submit(start_time, end_time, category, chapter_name)
        if not state.youtube_id then
            ui.toast("No YouTube video detected", "error")
            return
        end

        local action_type = category.action or "skip"
        local segment = {start_time, end_time}
        if action_type == "poi" then
            segment = {start_time, start_time}
        elseif action_type == "full" then
            segment = {0, 0}
        elseif action_type == "chapter" and not chapter_name then
            -- mp.input (text prompts) exists since mpv 0.38
            local ok, input = pcall(require, "mp.input")
            if not ok or type(input) ~= "table" or not input.get then
                ui.toast("Submitting chapters needs mpv 0.38 or newer", "error", 5)
                return
            end
            -- The prompt may outlive the file (playback continues meanwhile):
            -- remember which video the marks belong to.
            local generation = state.file_generation
            segments.clear_skip_prompt()
            segments.clear_action()
            submission.input_open = true
            submission.close_input = function()
                submission.input_open = false
                submission.close_input = nil
                input.terminate()
            end
            input.get({
                prompt = "Chapter name: ",
                submit = function(text)
                    if submission.close_input then submission.close_input() end
                    if generation ~= state.file_generation then
                        ui.toast("Chapter not submitted: the video changed", "error", 4)
                        return
                    end
                    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if text == "" then
                        ui.toast("Chapter submission cancelled: no name given", "info", 3)
                    else
                        submit.submit(start_time, end_time, category, text)
                    end
                end,
                closed = function()
                    submission.input_open = false
                    submission.close_input = nil
                end
            })
            return
        end

        mp.msg.info(string.format("📤 Submitting %s (%s) segment: %.1f - %.1f",
            category.key, action_type, segment[1], segment[2]))

        -- Get video duration for submission
        local video_duration = mp.get_property_number("duration") or 0

        local json_payload = {
            videoID = state.youtube_id,
            segments = {
                {
                    segment = segment,
                    category = category.key,
                    actionType = action_type,
                    description = chapter_name
                }
            },
            service = "YouTube"
        }

        -- Add video duration if available
        if video_duration > 0 then
            json_payload.videoDuration = video_duration
        end

        local json_string = utils.format_json(json_payload)

        -- The answer arrives asynchronously
        ui.toast("Submitting segment…", "info", core.MAX_TIME * 2)
        local generation = state.file_generation
        -- The server reads userID from the query as well as the body; the
        -- query keeps it in the owner-only secret file, off the command line
        http.request(core.endpoints.skip_segments, "POST", { userID = identity.USER_ID }, json_string, function(data, error_msg)
            if data then
                ui.toast(category.name .. " submitted successfully", "success")
                mp.msg.info("✅ Segment submitted successfully")
                mp.msg.info("📊 Response: " .. utils.to_string(data))
                -- Refresh segments to include our submission, if still on that video
                if generation == state.file_generation then segments.get() end
            else
                ui.toast("Failed to submit segment: " .. (error_msg or "unknown error"), "error", 5)
                mp.msg.warn("❌ Failed to submit segment: " .. (error_msg or "unknown error"))
            end
        end)
    end

    -- KEEP-OPEN HOLD
    --
    -- Marking a segment (start pressed) or having its confirmation dialog
    -- open must not let mpv auto-advance to the next playlist item mid-
    -- workflow - most noticeably when the segment's end is meant to reach
    -- the very end of the video: without this, mpv's native playlist
    -- auto-advance (unaffected by the global keep-open=yes, which only
    -- holds the true last playlist item open) fires the instant EOF is
    -- reached, and end-file reactively wipes the in-progress mark/dialog
    -- before the user can even press ; a second time or pick a category.
    -- Runtime-toggling keep-open to "always" while marking/dialog is active
    -- makes THIS file freeze at EOF too, exactly like the true-last-item case
    -- already does - zero effect on ordinary playback since the toggle only
    -- engages while the ; workflow is actually open.
    local function hold_playback_open()
        if submission.prev_keep_open == nil then
            submission.prev_keep_open = mp.get_property("keep-open", "yes")
            mp.set_property("keep-open", "always")
        end
    end

    -- Restores keep-open without trying to advance the playlist - used at
    -- end-file, where a transition (manual nav or otherwise) is already
    -- underway, so forcing another one would be wrong.
    local function restore_keep_open()
        if submission.prev_keep_open ~= nil then
            mp.set_property("keep-open", submission.prev_keep_open)
            submission.prev_keep_open = nil
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
    local function release_playback_open()
        local was_held = submission.prev_keep_open ~= nil
        restore_keep_open()
        if was_held and mp.get_property_bool("eof-reached", false) then
            mp.commandv("playlist-next", "weak")
            mp.set_property_bool("pause", false)
        end
    end

    -- CATEGORY DIALOG

    local DIALOG_BINDINGS = { "segment_dialog_up", "segment_dialog_down", "segment_dialog_enter", "segment_dialog_escape" }
    local NUMBER_KEYS = math.min(9, #categories.list)

    function submit.show_dialog(start_time, end_time)
        segments.clear_skip_prompt()
        segments.clear_action() -- the dialog owns ENTER while it's open
        submission.dialog_visible = true
        local list = categories.list
        local selected_index = 1

        local function redraw()
            ui.draw_dialog(start_time, end_time, selected_index)
        end

        local function cleanup_bindings()
            for _, name in ipairs(DIALOG_BINDINGS) do mp.remove_key_binding(name) end
            for j = 1, NUMBER_KEYS do mp.remove_key_binding("segment_category_" .. j) end
            submission.dialog_cleanup = nil
        end
        submission.dialog_cleanup = cleanup_bindings

        local function close()
            ui.hide_panel()
            submission.dialog_visible = false
            cleanup_bindings()
            release_playback_open()
        end

        local function submit_selected()
            close()
            submit.submit(start_time, end_time, list[selected_index])
        end

        local function cancel()
            close()
            ui.toast("Segment submission cancelled", "info", 2)
        end

        local function move(delta)
            selected_index = (selected_index - 1 + delta) % #list + 1
            redraw()
        end

        local function jump(index)
            if index >= 1 and index <= #list then
                selected_index = index
                redraw()
            end
        end

        redraw()

        mp.add_forced_key_binding("UP", "segment_dialog_up", function() move(-1) end)
        mp.add_forced_key_binding("DOWN", "segment_dialog_down", function() move(1) end)
        mp.add_forced_key_binding("ENTER", "segment_dialog_enter", submit_selected)
        mp.add_forced_key_binding("ESC", "segment_dialog_escape", cancel)
        -- Number keys jump to the first nine categories
        for i = 1, NUMBER_KEYS do
            mp.add_forced_key_binding(tostring(i), "segment_category_" .. i, function() jump(i) end)
        end
    end

    -- MARKING

    -- ; : marks the start, then the end, then opens the dialog
    function submit.toggle_marking()
        if submission.dialog_visible then
            return -- Don't interfere with dialog
        end

        if not state.youtube_id then
            ui.toast("SponsorBlock: YouTube video required", "error")
            return
        end

        local current_time = mp.get_property_number("time-pos")
        if not current_time then
            ui.toast("Could not get current time", "error")
            return
        end

        if not submission.marking_segment then
            -- Start marking
            submission.start_time = current_time
            submission.marking_segment = true
            hold_playback_open()
            ui.toast("Segment start marked at " .. timefmt.timestamp(current_time), "info")
            mp.msg.info(string.format("📍 Segment start marked at %.1f seconds", current_time))
        else
            -- End marking and show dialog
            if current_time <= submission.start_time then
                ui.toast("End time must be after start time", "error")
                return
            end

            local duration = current_time - submission.start_time
            if duration < 0.5 then
                ui.toast("Segment too short (minimum " .. timefmt.duration(0.5) .. ")", "error")
                return
            end

            submission.marking_segment = false
            ui.toast(("Segment marked: %s → %s"):format(
                timefmt.timestamp(submission.start_time), timefmt.timestamp(current_time)), "info")
            mp.msg.info(string.format("🏁 Segment marked: %.1f - %.1f seconds", submission.start_time, current_time))

            submit.show_dialog(submission.start_time, current_time)
        end
    end

    -- : cancels marking
    function submit.cancel_marking()
        if submission.marking_segment then
            submission.marking_segment = false
            submission.start_time = nil
            release_playback_open()
            ui.toast("Segment marking cancelled", "info", 2)
            mp.msg.info("❌ Segment marking cancelled")
        end
    end

    -- KEY BINDINGS (only while a YouTube video plays and the ID is valid)

    local function activate_bindings()
        if submission.keybindings_active then return end

        mp.add_key_binding(";", "toggle_segment_marking", submit.toggle_marking)
        mp.add_key_binding(":", "cancel_segment_marking", submit.cancel_marking)
        mp.add_key_binding(options.upvote_key, "upvote_segment", core.safe_call(function() segments.vote(1) end, "upvote"))
        mp.add_key_binding(options.downvote_key, "downvote_segment", core.safe_call(function() segments.vote(0) end, "downvote"))

        submission.keybindings_active = true
        mp.msg.info("✅ Segment submission keybindings enabled:")
        mp.msg.info("   ; to Start/End segment marking")
        mp.msg.info("   : to Cancel segment marking")
        mp.msg.info(("   %s / %s to upvote / downvote a segment"):format(options.upvote_key, options.downvote_key))
    end

    local function deactivate_bindings()
        if not submission.keybindings_active then return end

        mp.remove_key_binding("toggle_segment_marking")
        mp.remove_key_binding("cancel_segment_marking")
        mp.remove_key_binding("upvote_segment")
        mp.remove_key_binding("downvote_segment")

        submission.keybindings_active = false
        mp.msg.info("🚫 Segment submission keybindings disabled")
    end

    function submit.update_bindings()
        local should_activate = state.has_valid_user_id and state.youtube_id

        if should_activate and not submission.keybindings_active then
            activate_bindings()
        elseif not should_activate and submission.keybindings_active then
            deactivate_bindings()
        end

        if not state.has_valid_user_id then
            mp.msg.warn("⚠️ No valid user_id configured, segment submission disabled")
        elseif not state.youtube_id then
            mp.msg.warn("⚠️ No YouTube video detected, segment submission disabled")
        end
    end

    -- End of file: close prompts and the dialog, drop marks, release keep-open
    function submit.reset()
        if submission.close_input then
            submission.close_input() -- a chapter-name prompt for this video
        end
        -- Remove the dialog's forced key bindings instead of leaving them
        -- bound to this video's closures
        if submission.dialog_visible and submission.dialog_cleanup then
            submission.dialog_cleanup()
            ui.hide_panel()
        end
        submission.marking_segment = false
        submission.start_time = nil
        submission.dialog_visible = false
        -- Restore only - a transition is already underway here (natural
        -- advance or manual nav away mid-mark), so forcing another one via
        -- release_playback_open() would be wrong. Safety net against
        -- keep-open=always leaking onto the next-loaded file.
        restore_keep_open()
        deactivate_bindings()
    end
end

-- ----------------------------------------------------------------------------
-- STARTUP
-- ----------------------------------------------------------------------------
do
    local options, state = core.options, core.state

    -- INITIALIZATION

    store.load_local_stats()

    -- Load options from config file: script-opts/yas.conf
    mpoptions.read_options(options, "yas")
    core.build_endpoints()
    identity.resolve()

    -- Parse comma-separated option lists (trimming spaces) into the JSON
    -- array contents the API expects, adding what the enabled features need:
    -- highlights (poi_highlight / poi), full-video labels (exclusive_access /
    -- full) and manual-skip categories (a category set to prompt must also be
    -- fetched, or it never appears).
    do
        local function parse_list(csv)
            local items, set = {}, {}
            for item in string.gmatch(csv or "", "([^,]+)") do
                item = item:match("^%s*(.-)%s*$")
                if item ~= "" and not set[item] then
                    items[#items + 1] = item
                    set[item] = true
                end
            end
            return items, set
        end
        local function add(list, item)
            for _, existing in ipairs(list) do if existing == item then return end end
            list[#list + 1] = item
        end
        local function to_json_list(list)
            local quoted = {}
            for i, item in ipairs(list) do quoted[i] = '"' .. item .. '"' end
            return table.concat(quoted, ",")
        end

        local categories = parse_list(options.categories)
        local action_types = parse_list(options.action_types)
        if options.highlight then
            add(categories, "poi_highlight")
            add(action_types, "poi")
        end
        if options.full_video_labels then
            add(categories, "exclusive_access")
            add(action_types, "full")
        end
        local manual_list, manual = parse_list(options.manual_skip_categories)
        state.manual = manual
        for _, category in ipairs(manual_list) do add(categories, category) end
        options.categories = to_json_list(categories)
        options.action_types = to_json_list(action_types)
    end

    if state.has_valid_user_id then
        mp.msg.info(("Using user_id %s"):format(identity.mask(options.user_id)))
        mp.msg.info("   z to show/hide user stats dialog")
        mp.add_key_binding("z", "show_user_stats", stats.toggle)
    end

    -- MPV EVENTS

    local function file_loaded()
        mp.msg.info("🎬 File loaded event. Looking for YouTube ID")
        state.youtube_id = detect.youtube_id()

        -- Check and update keybindings based on current state
        submit.update_bindings()

        if state.youtube_id then
            segments.get()
        end
    end

    local function end_file()
        mp.msg.debug("🛑 End of file event. Resetting state.")
        -- Bumping the generation makes any request still in flight for this
        -- file ignore its answer when it arrives.
        state.file_generation = state.file_generation + 1
        state.youtube_id = nil
        segments.reset()
        submit.reset()
        stats.reset()
    end

    -- Wrapped in safe_call() so an uncaught error in either handler (e.g. from
    -- unexpected SponsorBlock API data) can't take down the script's whole
    -- event loop.
    mp.register_event("file-loaded", core.safe_call(file_loaded, "file_loaded"))
    mp.register_event("end-file", core.safe_call(end_file, "end_file"))
end

return {
    core = core,
    categories = categories,
    timefmt = timefmt,
    store = store,
    identity = identity,
    http = http,
    detect = detect,
    ui = ui,
    segments = segments,
    stats = stats,
    submit = submit,
}
