# yas
SponsorBlock plugin for MPV implemented (mostly) in Lua

## Features

- **Skip segments**: automatically skip sponsors, intros, outros and more,
  once per video, with a few seconds to undo a skip
- **Manual skip mode**: for chosen categories, show a prompt and skip only
  when you press the skip key
- **Mute segments**: mute-type segments mute the audio instead of skipping
- **Highlights**: jump to the part of the video most people came for
- **Full-video labels**: tells you when a whole video is sponsored,
  self-promotion or exclusive access
- **Voting**: upvote or downvote the segment you just hit
- **Submit segments**: mark and submit new segments, highlights, labels and
  chapters
- **User statistics**: your SponsorBlock contribution stats (press `z`)
- **Chapter integration**: segments and highlights appear as mpv chapters

## Installation

1. Copy `scripts/yas.lua` to your mpv `scripts` directory
2. Copy `script-opts/yas.conf` to your mpv `script-opts` directory and adjust it

## Configuration

Every option is listed with its default in `script-opts/yas.conf`. The most
useful ones:

| Option | Default | What it does |
| --- | --- | --- |
| `categories` | `sponsor,selfpromo,interaction,intro,outro,preview,hook,filler` | Categories to act on |
| `action_types` | `skip,mute` | `mute` segments are muted instead of skipped |
| `skip_once` | `yes` | Skip a segment only the first time; seeking back into it plays it |
| `manual_skip_categories` | *(empty)* | Categories that prompt instead of skipping, e.g. `filler,preview` |
| `skip_key` | `ENTER` | Skips in a prompt, undoes a skip, jumps to a highlight. Only bound while one of these is offered, and yields to your own `input.conf` bindings: if you bind `ENTER` there, choose another key. Empty = no prompts |
| `unskip_window` | `5` | Seconds after a skip during which `skip_key` undoes it (`0` = off) |
| `upvote_key` / `downvote_key` | `Ctrl+g` / `Ctrl+b` | Vote on the segment under the playhead, or the last one skipped |
| `highlight` | `yes` | Fetch highlights, add a chapter and offer a jump |
| `highlight_key` | `H` | Jump to the highlight at any time |
| `full_video_labels` | `yes` | Announce full-video labels |
| `server_address` | `https://sponsor.ajay.app` | SponsorBlock server or mirror |
| `user_id` | *(generated)* | Pin a private user ID (30+ letters/digits). Leave unset: one is generated and kept in `~/.local/state/mpv/yas_user_id` |

## Usage

### While watching
- Segments are fetched and handled automatically for YouTube videos.
- After a skip, press `Enter` within 5 seconds to undo it.
- In a manual-skip category, press `Enter` to skip.
- Near the start of a video with a highlight, press `Enter` to jump to it,
  or `H` at any time.
- Press `Ctrl+g` (good) or `Ctrl+b` (bad) to vote. A downvoted segment
  isn't skipped again in that video.
- Press `z` to show or hide your SponsorBlock statistics.

### Submitting segments
1. **Mark the start**: press `;`
2. **Mark the end**: press `;` again (`:` cancels marking)
3. **Pick a category**: `↑`/`↓`, or `1`–`9` to jump; the focused category's
   description is shown under the list
4. **Submit**: `Enter` (`Esc` cancels)

How the marks are used depends on the category:
- **Highlight**: a single point at the start mark
- **Exclusive Access**: a label for the whole video; the marks are ignored
- **Chapter**: asks for the chapter's name (needs mpv 0.38 or newer)
- **All others**: the marked range

### Keyboard shortcuts

| Key | Action | Binding name (for `input.conf`) |
| --- | --- | --- |
| `Enter` | Skip / undo / jump, when offered | (temporary) |
| `H` | Jump to the highlight | `yas/jump_to_highlight` |
| `Ctrl+g` / `Ctrl+b` | Upvote / downvote | `yas/upvote_segment`, `yas/downvote_segment` |
| `;` | Start/end segment marking | `yas/toggle_segment_marking` |
| `:` | Cancel segment marking | `yas/cancel_segment_marking` |
| `z` | Show/hide user statistics | `yas/show_user_stats` |

## Segment Categories

In the same order as the SponsorBlock browser extension:

1. **Sponsor**: paid promotion, paid referrals and direct advertisements
2. **Unpaid/Self Promotion**: merchandise, donations, collaborations
3. **Exclusive Access**: the whole video showcases something the creator got for free or early
4. **Interaction Reminder (Subscribe)**: reminders to like, subscribe, follow or comment
5. **Highlight**: the part of the video most people are looking for
6. **Intermission/Intro Animation**: pauses, intro animations, static frames
7. **Endcards/Credits**: credits or endcards at the end
8. **Preview/Recap**: what's coming up, or what already happened
9. **Hook/Greetings**: teasers and greetings that don't add information
10. **Tangents/Jokes**: tangential scenes or jokes not needed to follow the video
11. **Chapter**: a named chapter
12. **Music: Non-Music Section**: only for music videos, the parts that aren't music

## Development

### Running the tests

The test suite runs `scripts/yas.lua` outside mpv against a fake `mp` API
(`tests/support/mpv.lua`). Nothing touches the network: every `curl` call is
answered by fixtures. It needs only a Lua interpreter, no libraries.

```sh
make test            # LuaJIT, the interpreter mpv normally embeds
make test-verbose    # list every test, and why each known bug still fails
make test SPEC=skip  # only specs whose file name contains "skip"
make test-all        # every installed interpreter (luajit, lua5.1 ... lua5.4)
```

Without `make`: `luajit tests/run.lua`, from the repository root. On macOS,
Homebrew's mpv already depends on LuaJIT, so `luajit` is usually installed.

### Writing tests

Specs live in `tests/spec/*_spec.lua` and use `describe`, `it`, `before_each`
and the assertions in `tests/support/expect.lua`. `tests/support/fixtures.lua`
has `F.boot{...}`, which loads the script for a YouTube URL with canned API
responses and returns the harness `h`. Through `h` you can drive playback
(`h:set_time`, `h:press`, `h:fire`) and inspect the results (`h.requests`,
`h.seeks`, `h:screen()`, `h:log_text()`, `h.props`).

Tests for reported but unfixed bugs use `known_bug("ID", ...)`. They are
expected to fail. When a fix makes one pass, the run fails with **XPASS** as a
reminder to change it to a regular `it(...)`. The IDs match the code review
(H = high, M = medium, L = low).

## Requirements

- MPV with Lua support
- `curl` 7.87 or newer in your PATH (macOS 13+ and current Linux distributions ship it)
- Internet connection for SponsorBlock API access
- mpv 0.38 or newer only for submitting chapters (everything else works on older versions)
