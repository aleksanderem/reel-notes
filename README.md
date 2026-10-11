# reel-notes — Claude Code plugin

Paste a link to a reel → Claude downloads the video, **watches the frames** (on-screen text, slides,
prompts, code), **listens to the speech**, extracts what matters, and saves a Markdown note to your
notes folder (optionally a git repo, so it syncs across machines and agents).

Works with Instagram reels, posts and carousels, TikTok, YouTube Shorts and anything else `yt-dlp`
can download.

**Carousels** (Instagram): every slide is saved in order — photos at full size, video slides cut into
frames and transcribed like a reel — and the contact sheets show the whole carousel at a glance.

## Why frames, not just audio

A lot of reels put the real content only on screen — a prompt on a slide, a list of tools, a code
snippet — while the voice-over is filler or music. The plugin extracts a frame at every scene change
(and at least every 4 s), builds contact sheets so Claude sees the whole reel at a glance, and can
cut full-resolution frames for any time range to read small text. Speech is transcribed locally with
whisper.cpp; names misheard in speech are corrected against what's on screen.

## Usage

```
/reel-notes:reel https://www.instagram.com/reel/XXXX/
/reel-notes:reel https://www.tiktok.com/@someone/video/123 focus on the tool names
```

Or just: "analyze this reel: <link>", "what did I save about prompts?".

Each reel becomes `<notes>/<id>.md` with frontmatter (title, source, author, tags, summary…) and
sections: in short / what matters / on screen vs. in speech / how to use it / notes. An index
`<notes>/README.md` is rebuilt on every save. Notes are written in the language you talk to Claude in.

## Requirements (macOS / Linux)

- `ffmpeg`, `jq`, `curl`, `yt-dlp`
- `whisper-cpp` (`whisper-cli`) and a model, e.g.
  `curl -L -o ~/models/ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin`
- For Instagram: `apify-cli` logged in (`npm i -g apify-cli && apify login`) — uses the
  `apify/instagram-scraper` Actor (about $0.002 per post). `yt-dlp` can't fetch Instagram without a login.

## Install

```
claude plugin marketplace add aleksanderem/reel-notes
claude plugin install reel-notes@reel-notes
```

## Settings

Set in `~/.claude/settings.json` → `"env"` (all optional):

| Variable | Default | What it does |
|---|---|---|
| `REEL_NOTES_REPO` | `~/reel-notes` | notes folder; if it's a git repo, notes are committed (and pushed when it has a remote) |
| `REEL_NOTES_SUBDIR` | `notes` | subfolder for reel notes inside the repo |
| `REEL_NOTES_MEDIA_DIR` | `~/reel-notes/media` | videos, frames, audio (never committed) |
| `REEL_NOTES_WHISPER_MODEL` | `~/models/ggml-small.bin` | whisper.cpp model |
| `REEL_NOTES_SCENE_THRESHOLD` | `0.08` | scene-change sensitivity |
| `REEL_NOTES_MAX_GAP_S` | `4` | longest gap between frames, seconds |
| `REEL_NOTES_TRACKER_URL` | — | a claude.ai artifact link; each new reel is also added to its `items` list (title, summary, points, status) so you can follow it on a phone |
| `REEL_NOTES_FORCE` | `0` | `1` = download and process again |

## Troubleshooting

- `HTTP Error 403` from YouTube/TikTok — update yt-dlp (`brew upgrade yt-dlp`); sites change often.
- `Apify returned no post` — the account is private or the link is wrong.
- `missing program X` — install it with the command shown in the message.

## Tests

`python3 -m pytest -q tests`

## License

MIT
