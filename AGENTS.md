# AGENTS.md

Notes for coding agents working on Rabbit Ears: a tvOS app with an iOS companion that plays live
TV and recordings from a Tvheadend server. See `README.md` for what the app does.

## Layout

- One Xcode project, `AppleTV/RabbitEars/RabbitEars.xcodeproj`, with three targets:
  - `RabbitEars`: the tvOS app (tvOS 27). Its UI lives in `AppleTV/RabbitEars/RabbitEars/`.
  - `RabbitEars iOS`: iPhone/iPad, iOS 18 floor, dark mode only. Its code is in `iOS/`. The
    target excludes `iOS/Info.plist` through an exception set.
  - `RabbitEars TopShelf`: the tvOS Top Shelf extension, in `AppleTV/RabbitEars/TopShelf/`.
- `Shared/` is a synchronized group in both app targets: the Tvheadend client, Keychain, the
  playback controllers, captions, the guide filter and segments, recording durations and the theme.
  Code that differs per platform uses `#if os(tvOS)` (e.g. the metrics in `PlayerOverlays`), and the
  tvOS values must stay as they are.
- Both apps use the bundle id `site.kirsch.RabbitEars`. The app group is `group.site.kirsch.RabbitEars`.

## Building and running

- Prefix every raw `xcodebuild`, `simctl` or `devicectl` command with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The Makefile already sets it.
- Use the Makefile: `make run DEVICE=<id or name>` (tvOS) and `make run-ios DEVICE=<id or name>`
  build, install and launch in one step. Without `DEVICE` they show a menu, which needs a terminal.
- Build with `ARCHS=arm64`, as the Makefile does. LibDovi has no x86_64 simulator slice, so a
  Release simulator build fails at link time without it.
- The first build downloads AetherEngine's FFmpeg binaries, which takes about 4–5 minutes. Later
  builds take under a minute.
- Device builds of the Top Shelf extension need `XCFLAGS=-allowProvisioningUpdates`, because the
  app group needs an explicit App ID. If signing fails, the account may have a new Program License
  Agreement waiting to be accepted on the developer site. Only the user can accept it.
- To check that the simulator is running the current build, run
  `xcrun simctl get_app_container <udid> site.kirsch.RabbitEars app`, then
  `strings -a "<app>/RabbitEars.debug.dylib" | grep <text>`. An older copy of the project or
  DerivedData can leave a stale build installed. Copies under the old bundle id
  `site.kirsch.Switft-TVH-Client` are a separate app.

## Testing

- On iOS, test on a single iPhone sim only. Don't repeat UI tests across several iPhone
  models. For changes that depend on screen size, reason from the layout (safe areas, size
  classes), confirm on the iPhone 17, and list other sizes as untested.
- To skip server setup in a simulator:
  `xcrun simctl spawn <udid> defaults write site.kirsch.RabbitEars tvhServerURL <url>`.
- For taps and screenshots, use a throwaway UI-test project in a scratch directory that attaches
  with `XCUIApplication(bundleIdentifier:)`. Don't add it to the repo.
- Say plainly what you verified on screen and what you only compiled or launched.

## Playback: AetherEngine

- [AetherEngine](https://github.com/superuser404notfound/AetherEngine) is the only player, for
  both live TV and recordings. VLC was removed entirely. Don't reintroduce it, and don't suggest a
  pure AVFoundation player either: tvOS VideoToolbox has no MPEG-2 decoder (`codec mp2v`,
  `err=-12906`), and broadcast TV here is MPEG-2. AVSampleBufferDisplayLayer doesn't fail when
  this happens. It retries every frame without showing a picture.
- Live: `AetherLiveController` maps the engine's clock and its client-side DVR buffer onto the
  banner scrubber. This is not Tvheadend timeshift, and HTSP isn't used at all.
- In-progress recordings: `GrowingRecordingReader` reads `/dvrfile/<uuid>` from byte 0, follows
  the file as it grows, then switches to the channel's live stream. The whole recording becomes the
  Live view's rewind buffer. The live edge appears about 15 s behind, because the file trails the
  live stream.
- Recordings: `AetherRecordingController` plays `/dvrfile/<uuid>` with HTTP Range requests. Take
  the duration from the engine, not `stop - start`, because recordings include padding. The engine
  treats the end of a file as final, so playing or scrubbing past it reloads.
- Tvheadend 4.3's DVR grid has only the scheduled window. `Shared/RecordingDurations` probes
  finished files with `AetherEngine.probe(url:)` to get their real length.
- Captions: the engine decodes only CEA-608 CC1. It exposes one synthetic track (id 99608) once it
  sees caption data, and cues are plain text. Don't re-add a caption "Timing" setting: cues come
  from decoded frames, so they can't usefully be shifted earlier.
- Audio session: the engine sets up and activates the session for each playback. Don't activate it
  at launch, which can lock some HDMI setups to a stereo downmix. If surround audio gets downmixed,
  check this first.

## tvOS specifics

- **Remote input under SwiftUI focus** (measured on a device): only `sendEvent(_:)` on the
  `UIApplication` subclass sees a press's `.began` and `.ended`, plus the touch surface's continuous
  `.moved` touches. `onMoveCommand` fires once per press, with no release. `onKeyPress` and the
  `pressesBegan` overrides see nothing. A window pan recognizer only reaches `.began`.
  `RemoteScrubApplication` is installed through `NSPrincipalClass`, not
  `UIApplicationPrincipalClass`.
- Check the SDK headers before asserting how an input API behaves, and get a device trace before
  drawing conclusions. A real Apple TV can't stream logs, so add a temporary file logger that writes
  to `tmp/` in the app container and pull the file with
  `devicectl device copy from --domain-type appDataContainer`. Remove the logger afterwards.
- **Top Shelf extension**: its `productType` must be `com.apple.product-type.app-extension`. With
  `tv-app-extension`, tvOS 27 exits before any extension code runs, and the Home Screen quietly
  shows the static image instead. The extension can't read the app's defaults or Keychain, so
  `TopShelfPublisher` copies the server settings into the app group. To pull the rendered tiles from
  a device, use `devicectl device copy from --domain-type appGroupDataContainer --domain-identifier
  group.site.kirsch.RabbitEars --source Library`.

## iOS specifics

- Keep every player control on the single bottom banner, as on tvOS: no top bar and no transport
  controls in the middle. Tap the video to show or hide the banner. Long-press it for debug stats.
- iOS 27's floating tab bar stretches a SwiftUI ScrollView that touches its safe-area edge, and
  `safeAreaInsets.bottom` then counts the inset twice. The guide keeps an 8 pt gap above the tab bar
  for this reason.
- Each player measures its banner so captions sit above it (`CaptionOverlay(bottomClearance:)`).

## Tvheadend API

- Recording state comes from each EPG event's own `dvrState` and `dvrUuid`. While something is
  recording, the record button becomes **Stop** (`api/dvr/entry/stop`, which keeps what was
  recorded) or, for a scheduled recording, **Cancel** (`api/dvr/entry/cancel`), each behind a
  confirmation alert.
- Tvheadend returns 404 for an unknown uuid even on endpoints that exist. To check whether an
  endpoint exists, call it without a uuid: a real endpoint returns 400.
- `PlaybackRequest` moves credentials out of the URL and into a Basic auth header.
