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
3. Set your SponsorBlock user ID in the config for segment submission

## Configuration

Edit `script-opts/yas.conf`:

```ini
# Categories to skip (comma-separated)
categories=sponsor,selfpromo,interaction,intro,outro,preview,hook,filler

# Your SponsorBlock user ID (required for submitting segments)
# Get from https://sponsor.ajay.app/stats/ or browser extension
user_id=your_32_character_user_id_here
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

## Requirements

- MPV with Lua support
- `curl` command available in system PATH
- Internet connection for SponsorBlock API access
- Valid SponsorBlock user ID for segment submission
