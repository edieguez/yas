# yas
SponsorBlock plugin for MPV implemented (mostly) in Lua

## Features

- **Skip segments**: Automatically skip sponsored segments, intros, outros, and more
- **User statistics**: View your SponsorBlock contribution stats (press `z`)
- **Submit segments**: Mark and submit new segments to SponsorBlock database
- **Chapter integration**: Creates MPV chapters for sponsored segments

## Installation

1. Copy `yas.lua` to your MPV `scripts` directory
2. Copy `yas.conf.template` to `script-opts/yas.conf` and configure

## Configuration

Edit `script-opts/yas.conf`:

```ini
# Categories to skip (comma-separated)
categories=sponsor,selfpromo,interaction,intro,outro,preview,hook,filler

# Optional: pin a specific local user ID (required for submitting
# segments). This must be a randomly generated 30+ character string, NOT
# the public userID from the stats page. Leave commented out to
# auto-generate one (recommended) - the generated ID is stored in
# ~/.local/state/mpv/yas_user_id, not in this file.
# user_id=your_32_character_user_id_here
```

## Usage

### Viewing segments
- Segments are automatically fetched and skipped for YouTube videos
- Press `z` to view your SponsorBlock statistics

### Submitting segments
1. **Mark segment start**: Press `;`
2. **Mark segment end**: Press `;` again
3. **Navigate categories**: Use ↑/↓ arrow keys to navigate
4. **Submit segment**: Press `Enter` to submit selected category
5. **Cancel**: Press `Escape` to cancel marking

### Keyboard shortcuts
- `z` - Show user statistics
- `;` - Start/end segment marking
- `Escape` - Cancel segment marking
- `↑/↓` - Navigate categories (in submission dialog)
- `Enter` - Submit selected category (in submission dialog)
- `1-8` - Quick select category (in submission dialog)

## Segment Categories

1. **Sponsor** - Paid promotion, paid referrals and direct advertisements
2. **Unpaid/Self Promotion** - Similar to sponsor but for unpaid content
3. **Interaction Reminder** - Reminders to like, subscribe, follow, etc.
4. **Intermission/Intro Animation** - Intro sequences, animations, or intermissions
5. **Endcards/Credits** - End credits, endcards, or outros
6. **Preview/Recap** - Collection of clips showing what's coming up
7. **Filler Tangent** - Tangential content that is not required
8. **Non-Music Section** - Only for music videos, covers non-music portions

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
- Valid SponsorBlock user ID for segment submission
