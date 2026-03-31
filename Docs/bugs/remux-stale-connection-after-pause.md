# Bug: Remux session loses Plex connection after long pause

**Date:** 2026-03-31
**Status:** Fixed (untested)

## Symptoms

- Playback works initially
- User pauses for an extended period (minutes)
- Seeking or resuming fails — no new segments load
- No reconnection attempt visible

## Cause (Likely)

FFmpegRemuxSession opens a single HTTP connection to the Plex server during `open()`. After a long idle period, Plex (or an intermediate proxy/TCP timeout) closes the connection. When the user resumes or seeks, `av_read_frame()` and `avformat_seek_file()` fail on the dead socket.

The `reconnect=1` and `reconnect_streamed=1` options are set during `open()`, but FFmpeg's HTTP reconnect may not handle all timeout scenarios (especially idle keepalive drops vs mid-transfer failures).

## Potential Fixes

1. **Detect stale connection and reopen** — If `generateSegment()` fails with a network error, close and reopen the format context with the same URL/headers, then retry the segment
2. **Periodic keepalive** — Send a lightweight read periodically during pause to keep the HTTP connection alive
3. **Lazy reconnect on seek** — Before seeking, check if the connection is still alive; if not, reopen
4. **Set `reconnect_on_network_error=1`** — Additional FFmpeg HTTP option that may help

## Context

- Source URL format: `http://{plex-server}:32400/library/parts/{id}/{timestamp}/file.mkv?X-Plex-Token=...`
- FFmpeg options already set: `reconnect=1`, `reconnect_streamed=1`, `reconnect_delay_max=5`
- The format context is an actor (`FFmpegRemuxSession`) — reopening requires careful state management
