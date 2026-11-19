# Changelog

What changed in each release, for the people who install it. Write what a
user notices (not the refactorings) under "Unreleased" as you make the
change; `tool/release.sh` moves it under the new version, and the release
page shows it above the generated list of commits. See
[docs/RELEASING.md](docs/RELEASING.md).

The entries up to 1.3.7 were written afterwards, from the code changes of
each release. A release with nothing a user would notice says so.

## Unreleased

## 1.3.12 - 2026-11-19

- New: a home screen widget. It shows the playing track with its cover and has Previous, Play/Pause and Next (Previous and Next are active while a track plays), plus a shuffle button that starts random songs like the app icon's "Random" shortcut. Make it taller for the album and the Previous button. After the app was closed, Play on the widget picks up the last track where you left off.

## 1.3.11 - 2026-11-17

- New: a "Random" shortcut on the app icon. Long-press the icon (or drag the shortcut to the home screen) to start random songs in one step, for example at bedtime. It opens the app and plays a fresh random pick, replacing what was playing.

## 1.3.10 - 2026-11-17

- Plays and skips aren't lost when the server fails for a moment (for example a busy database, or a proxy that can't reach Navidrome): they're sent again for up to an hour instead of being dropped at the first error.
- Logging out shows a "Logging out…" screen while the app clears its saved data (downloaded audio can take a moment), instead of leaving the old screens up, where a tap on Play or an album could fail. A second tap on Logout is ignored.

## 1.3.9 - 2026-11-16

- The artist list isn't downloaded again every 15 minutes: the app first asks the server whether the library changed, so the Artists tab opens faster on a slow connection.

## 1.3.8 - 2026-11-16

- The album and artist lists have a draggable scrollbar, to get through a big library quickly.

## 1.3.7 - 2026-11-15

- The song that is playing buffers up to 10 minutes ahead (at most 32 MB), so a track that is still streaming survives a longer network drop. Later tracks buffer as before.

## 1.3.6 - 2026-11-15

- Plays and skips reach subsoxy as they happened. "Now playing" reports are kept and retried (they were dropped when they couldn't be sent), and every report carries the time it happened. A song skipped while offline still counts as skipped, and one paused overnight before the next doesn't.

## 1.3.5 - 2026-11-15

- Login: password managers can fill in and save the server, user name and password. A failed login shows its message above the keyboard instead of behind it, and the Return key on the password field logs in.
- The password banner (after the password changed on the server) works with password managers too.
- The sleep timer's colors follow the app's theme, with better contrast in both themes, and its dialog scrolls on a phone in landscape.
- The restored queue could start at the wrong song if the app was killed while saving; the saved position is now only used for the queue it belongs to.

## 1.3.4 - 2026-11-15

- ReplayGain tags in M4A/MP4 files are read properly (including files tagged by QuickTime and large files), so the volume of those tracks is normalized.

## 1.3.3 - 2026-11-15

- The cover art of the notification, lock screen and Bluetooth displays is cached with the downloaded track, so it also shows offline.
- A cover the server refuses (for example after a password change) is no longer stored as a broken image, and covers aren't requested while the server rejects the password.
- Requests for streams, downloads and covers identify the app as `voidweaver/<version>` in the server's logs.

## 1.3.2 - 2026-11-15

- Fixed playback after a pause or stop in the background: the app could start playing without its notification, and Android then froze it.

## 1.3.1 - 2026-11-14

- Internal build change. Nothing to notice.

## 1.3.0 - 2026-11-14

- The APK is much smaller: it contains the native code for 64-bit ARM only (about 20 MB instead of 57 MB). A phone without 64-bit ARM refuses to install it instead of crashing at launch.

## 1.2.9 - 2026-11-14

- Accessibility: the theme and ReplayGain choices in Settings are read out together with their names by screen readers.

## 1.2.8 - 2026-11-14

- Many more album covers stay available offline: the cover cache keeps up to 3000 images for 90 days (it held 200 for 30).
- Counts read "1 song" and "12 songs" (and "1 album", ...).
- The session log says why the previous run ended when Android stopped the app (low memory, a hang, a crash), to help find the cause.

## 1.2.7 - 2026-11-13

- After the last track has played to its end, Play starts it again; before, Play did nothing at that point.
- Internal: the player's control logic was split up.

## 1.2.6 - 2026-11-12

- Internal (Flutter update). Nothing to notice.

## 1.2.5 - 2026-11-12

- If the network fails while a track is playing, playback goes on where it broke off once the network is back (within 10 minutes), instead of staying stopped.
- New: Settings → Session Log. It shows what the app did in this run and the previous one, and exports it to send along with a bug report. Passwords are masked, and nothing leaves the device unless you share it.

## 1.2.4 - 2026-11-12

- If the server refuses to send a file for ReplayGain (downloads disabled), the app tries the stream; if the password is refused it stops asking.
- Scrobbles are marked as sent right away, so a kill during a long backlog doesn't send them twice.
- A seek or stop during a skip no longer leaves playback in a wrong state.

## 1.2.3 - 2026-11-10

- Internal (tests). Nothing to notice.

## 1.2.2 - 2026-11-10

- Internal (tests). Nothing to notice.

## 1.2.1 - 2026-11-10

- A short network drop while the next track loads no longer cuts off the end of the current one: a failed load is tried again for about 25 seconds.
- When the server answers with an error instead of audio (unknown song, wrong password), the app reports it at once instead of retrying.
- After the password changed, tracks that aren't downloaded load again with the new password.
- The position is saved when you pause or seek while paused, not only while playing.
- Pressing Play while the saved queue is still being restored (for example when starting offline) now continues at the next downloaded track, or shows the error and lets Play try again at the saved position.
- A second seek during a slow skip is handled.

## 1.2.0 - 2026-11-10

- The player was rewritten around a single control loop: skips, pauses, seeks, loads and queue changes run one after the other, which removes a class of races (wrong track, stuck state). When a track can't be played, playback goes on at the next downloaded one, or stops on the failed track with a message.

## 1.1.11 - 2026-11-09

- A failed refresh of the album list keeps the albums on screen and shows the error, and the next sync tries again (it counted as up to date before).

## 1.1.10 - 2026-11-09

- Search: tapping a result shows a spinner on it, and further taps are ignored while it starts.
- Cached albums, searches and library data are kept in a bounded memory cache, so long sessions don't grow without limit.

## 1.1.9 - 2026-11-09

- Pressing next or previous quickly moves the skip's target on (the buttons stay enabled).

## 1.1.8 - 2026-11-08

- Internal cleanups. Nothing to notice.

## 1.1.7 - 2026-11-08

- Songs whose file has no ReplayGain tags aren't read again each time they play, which delayed their start; tags that extend past the first 256 KB are read in full.

## 1.1.6 - 2026-11-08

- Playback is more robust when loads, skips, stop and errors overlap.

## 1.1.5 - 2026-11-08

- Fixed a pause during a quick series of skips being undone: the track started playing again.

## 1.1.4 - 2026-11-07

- Less power use: the playback position is saved in a small file of its own instead of rewriting the app's settings every few seconds, and the player reports its position less often while the screen is off.

## 1.1.3 - 2026-11-07

- "Recently played" refreshes right after a play was counted, and "Recently added" is checked cheaply in the background while the app is open.
- Scrobbles that can't be sent are retried, with growing pauses and when the network is back; no timer runs while there's nothing to send.

## 1.1.2 - 2026-11-07

- One unreadable setting no longer keeps the app from starting, and if the app's storage can't be read the start can be retried.
- Dependency updates and build hardening.

## 1.1.1 - 2026-11-06

- First tagged release.
