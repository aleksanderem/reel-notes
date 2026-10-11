---
name: reel
description: Analyzes a reel / short video (Instagram reel, post or carousel, TikTok, YouTube Shorts, Facebook) — downloads it, watches the frames (on-screen text, slides, prompts, code, tools shown) and listens to the speech, extracts what matters, and saves a note to the user's notes repo. Use when the user pastes a link to a reel / TikTok / Short or asks "analyze this reel", "what's in this video", "save this reel", "pull the prompts from this reel". Also for questions about previously saved reels ("what did I save about X", "find the reel about Y").
argument-hint: <reel URL> [what to focus on]
---

# Reel → note

Scripts live in `scripts/` next to this file (Claude Code prints the skill's base directory when
it loads). Below, `$S` = `<skill base directory>/scripts`.

Where things go (environment variables, set them in Claude Code `settings.json` → `env`):
- `REEL_NOTES_REPO` — notes folder or git repo (default `~/reel-notes`)
- `REEL_NOTES_SUBDIR` — subfolder for reel notes (default `notes`)
- `REEL_NOTES_MEDIA_DIR` — videos, frames, audio (default `~/reel-notes/media`)

`$NOTES` below = `$REEL_NOTES_REPO/$REEL_NOTES_SUBDIR` (with the defaults if unset; expand a leading `~`
to the home directory yourself — values from `settings.json` are not shell-expanded).

## Question about saved reels (no link)

If `$REEL_NOTES_REPO` is a git repo with a remote, `git -C "$REEL_NOTES_REPO" pull -q` first.
Read the index `$NOTES/README.md`, grep the notes for details. Answer briefly, with the source
link and the note file name.

## New reel — steps

1. **Already saved?** Pull (as above), then grep the id from the link (e.g. `DY4APJfzrvy`) in
   `$NOTES`. If a note exists, show its summary and ask whether to redo it. Don't download twice.

2. **Download and prepare.** `bash $S/fetch.sh "<url>"` (~30–60 s; Instagram goes through Apify,
   a fraction of a cent per reel). It prints the reel directory, which contains:
   - `meta.json` — author, caption, date, hashtags, latest comments
   - `transcript.txt` / `transcript.srt` — speech (language auto-detected; `.srt` has timestamps)
   - `sheet_NN.jpg` — contact sheets, 24 frames each (6 columns × 4 rows, read row by row);
     sheet 01 = frames 1–24, sheet 02 = 25–48, etc.
   - `frames/scene_NNN.jpg` — single frames (540 px); `frames.tsv` — frame, slide number, second
     in the video (`-` for a photo slide)
   - **carousel** (Instagram post with several slides): `slides.tsv` (file, image|video, alt text) and
     `slides/NN.jpg` / `slides/NN.mp4` — every slide in order, photos at full size. Video slides are
     cut into frames like a reel, and their speech is in `transcript.txt` under `### Slide N` headings
     (timestamps in `slides/NN.srt`). The contact sheets show all slides in order.
   On "missing program" / "Apify returned no post", tell the user the cause and the fix from the message.

3. **Read the text:** `meta.json` (caption + comments — creators often say "comment X and I'll send…",
   comments may contain links) and `transcript.txt`.

4. **Watch the video — mandatory, not just audio.** Many reels carry their content only on screen
   (slides with prompts, lists, code, app screenshots) while the speech is filler or music.
   - Open (Read) every `sheet_*.jpg` — see the whole reel and find where the content is.
   - Open frames with text or important visuals individually from `frames/`.
   - Small or dense text (a prompt on a slide, code, a table): take the time from `frames.tsv` and
     cut sharp frames: `bash $S/zoom.sh <dir> <from_s> <to_s> [fps] [slide]` (`slide` = slide number
     for a video slide of a carousel), then open the files in `hi/`. Photo slides: open
     `slides/NN.jpg` directly — they are full size.
     Scrolling text or text covered by captions — compare consecutive frames and piece it together.
   - Carousel: go through every slide in order — the content usually builds slide by slide
     (a list, steps, a prompt split across slides); keep that order in the note.
   - Note what is visible: captions, tool and site names, what the creator shows/does, numbers, charts.
   - Check names heard in speech against the screen (speech recognition mangles names,
     e.g. "Kurtz Guzzant" = Kurzgesagt).

5. **Extract what matters** — depending on what the reel is:
   - **prompts / instructions** → verbatim, in the original language, in code blocks; mark gaps with
     `⚠️` and say what was covered and how you filled it in
   - **a list of things (videos, books, tools)** → a table; if links are missing, find them
     (web search / Apify) and mark which ones are certain
   - **advice / knowledge** → concrete points, no filler
   - **a product / tool** → what it is, what it's for, link, price if mentioned
   If the user said what to focus on, that comes first.

6. **Write the note** to `<reel dir>/note.md` — in the language the user writes to you in
   (quotes and prompts stay in the original language), using exactly this layout. Frontmatter keys
   stay in English; values and section headings are in the note's language:

   ```markdown
   ---
   title: <short title: what this is about>
   source: <url>
   platform: <instagram|tiktok|youtube|facebook|other>
   id: <id printed by fetch.sh>
   author: "<@author>"
   published: <YYYY-MM-DD>
   added: <today YYYY-MM-DD>
   duration_s: <seconds; for a carousel: total of its video slides, 0 if photos only>
   slides: <number of slides — carousels only, drop the line otherwise>
   tags: [<3–6 lowercase tags, e.g. ai, prompts, marketing>]
   summary: <one sentence for the index>
   media: <reel dir>
   ---

   # <title>

   ## In short
   <2–3 sentences: what it is and what I get from it>

   ## What matters
   <points / table / prompts — per step 5>

   ## On screen vs. in speech
   <only if they differ or something is in just one of them; otherwise drop the section>

   ## How to use it
   <1–3 concrete steps for the user; drop if the reel is purely informational>

   ## Notes
   <uncertainties, covered fragments, "creator sends the full version after commenting X">
   ```

7. **Save:** `python3 -I $S/save.py <reel dir>/note.md`
   — copies it to `$NOTES/<id>.md`, rebuilds the index `README.md`, and in a git repo commits
   (and pulls/pushes if there is a remote). If the push fails, the note is saved locally — say so
   and give the reason.

8. **Reply** briefly: first line = what was saved and where (`$NOTES/<id>.md`), then the summary
   and the 3–5 most important points. Don't paste the whole note unless asked.

## Rules

- No secrets in notes (the notes repo may be shared) — skip tokens, passwords, private data seen on screen.
- Don't guess content you can't see or hear — mark the gap.
- Video, frames and audio stay local in the reel directory; only the note goes to the notes repo.
