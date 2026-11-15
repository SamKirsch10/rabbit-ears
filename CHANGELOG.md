# Changelog

All notable changes to Rabbit Ears are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-15

The first tagged release of Rabbit Ears: a native Apple TV app, plus an iPhone/iPad
companion, for watching and recording live TV from a [Tvheadend](https://tvheadend.org) server.

### Added

#### Apple TV
- **Guide**: a channel grid showing what's on now and next. Pick a program to watch it live
  or set it to record. A channel filter limits the grid to the channel groups you choose.
- **Live TV**: pause and rewind live TV, with closed captions and a record button in the player.
- **Watch recordings that are still in progress**: picking a program that's recording now (from
  the guide or the DVR list) offers **Start from Beginning** or **Go to Live**. Either way it opens
  the Live view, and you can rewind through the whole recording. When the recording ends, playback
  carries on into the channel's live stream without reloading.
- **DVR**: browse, play, stop and delete recordings on the server.
- **Scrub thumbnails**: a preview still of the frame under the playhead while scrubbing a recording.
- **Remote scrubbing**: swipe on the touch surface to move the playhead by how far your finger
  travels, or hold a direction to scrub at a speed that ramps up. Works in live TV and recordings.
- **Top Shelf**: when Rabbit Ears is in the top row of the Home Screen, the area above it shows a
  tile per channel with what's on now and next. Selecting a tile opens that channel's live view.
  A fallback image is shown when the server can't be reached.
- **Top Shelf channel filter** in Settings, chosen separately from the guide's filter.
- **Caption settings**: text size, color, background and position.
- First-launch setup that asks for the server address and login, saving the login in the Keychain.

#### iPhone and iPad
- Guide in portrait and landscape, with program details and **Watch Live** / **Record** actions.
- The channel filter, recordings list and in-progress recording playback from the Apple TV app.
- Live TV and recording playback with the same player controls as the Apple TV app.
- **Picture in Picture** for live TV and recordings, which keeps playing when you leave the app.

#### Playback
- Video is played with [AetherEngine](https://github.com/superuser404notfound/AetherEngine), which
  decodes in software the MPEG-2 video common in broadcast TV. Apple's own video player can't
  decode MPEG-2.

[Unreleased]: https://github.com/SamKirsch10/rabbit-ears/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/SamKirsch10/rabbit-ears/releases/tag/v1.0.0
