# Now Playing probe

Measures how far a browser's macOS Now Playing position (what RAVE LIVE's lyrics follow) is from the media's real
`currentTime`. Used for PR #29 (YouTube in Zen/Firefox drops the position).

- `run.sh [seconds]` starts a local page that plays a generated tone, opens it in an **isolated** Zen profile
  (your own Zen profile and settings are not touched), records the Now Playing stream from the bundled
  mediaremote-adapter and the page's `currentTime`, then `score.py` prints the error over time.
- Silent by design: the page plays at element volume 0.001. Never mute the system volume for this, the user may be
  listening to music.
- Needs: RAVE LIVE installed in `~/Applications` (for the adapter), Zen in `/Applications`, ffmpeg, python3.
- Another app playing media at the same time can own Now Playing; check `score.py`'s anchor titles.
