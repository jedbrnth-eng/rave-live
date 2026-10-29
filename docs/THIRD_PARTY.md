# Third-party ideas and references

Code under `Sources/` is original unless a file says otherwise. Bundled third-party software and data are listed in
[CREDITS.md](../CREDITS.md). This file records **ideas** RAVE LIVE took from other projects (no code was copied), so the
lineage stays visible.

## Lyric styles (`Sources/RaveLiveApp/LyricStyles.swift`, `LyricsStage.swift`)
| Idea | Where it comes from | Licence | What we used |
|---|---|---|---|
| Word-by-word reveal, upcoming words dimmed, the sung word lifting slightly | Apple Music time-synced lyrics / Apple Music Sing (https://www.apple.com/newsroom/2022/12/apple-introduces-apple-music-sing/) | Proprietary | The look only; own implementation. |
| Spring-driven word entrances (scale/offset follow a damped spring) | Beautiful Lyrics for Spicetify by surfbryce (https://github.com/surfbryce/beautiful-lyrics) | No licence file (all rights reserved) | The idea only; no code read into or copied. `LyricFX.spring` is a textbook damped-spring step response. |
| Karaoke fill sweeping through each word | Karaoke apps; Lyrics Plus for Spicetify (https://github.com/spicetify/cli/tree/main/CustomApps/lyrics-plus) | LGPL-2.1 | The idea only. |
| Apple-Music-like lyric page with per-word timing | applemusic-like-lyrics (AMLL, https://github.com/Steve-xmh/applemusic-like-lyrics) | AGPL-3.0 | The idea only; no code used. |
| 1-3 big words at a time popping in (kinetic captions) | TikTok / CapCut captions (https://www.capcut.com/resource/types-of-captions) | Proprietary | The look only. |
| Text animated per character with a delay along the line | Resolume Text Animator (https://resolume.com/support/en/6/sources) | Proprietary | The idea behind Bass wave's per-letter ripple. |

What RAVE LIVE adds on top (not found in the projects above): word timing estimated from syllables and snapped to the
live beat grid when the lyrics only time whole lines, typography driven by the live analysis (kick punch, bass wave,
one frequency band per word, energy glow) and an Auto style that follows the energy and cuts to Pop on drops.

Fonts: only fonts that ship with macOS (SF Pro, SF Pro Rounded, Avenir Next Condensed) are used, by name at runtime.
No font files are bundled.
