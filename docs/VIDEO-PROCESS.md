# Making the training videos

Every narrated video is rebuilt from text files with one command. People write the script and film the machine;
the app's screens, the animation, the on-screen text, the voice and the subtitles are all generated. When the UI
changes, rerun the command; when the wording changes, only the changed lines get a new voice.

This extends rule 2 of [TRAINING-PLAN.md](TRAINING-PLAN.md) (nothing is captured by hand) from short clips to the
full videos.

## What a video is made of

One folder per video, `video/<id>/` (for example `video/a1-first-cut/`):

| File | Holds |
|---|---|
| `video.json` | The scenes, in order (below) |
| `cards/*.svg` | Title cards and overlays, from the brand templates in `video/templates/` |
| `footage/` | Camera clips of the machine (not in git; the masters live in shared storage) |

Each scene in `video.json` has:

- **`narration`**: one or two sentences, spoken over the scene.
- **`picture`**: one of
  - `steps`: harness steps (docs/UI-HARNESS.md), recorded as one clip;
  - `card`: an SVG card shown full screen;
  - `footage`: a camera clip with in and out times.
- **`text`** (optional): a lower third (a label plus a shortcut such as `⇧⌘J`) and where it sits on screen.
- **`zoom`** (optional): a region to push in on, as a fraction of the window.

A scene is one action. If the narration needs a third sentence, split the scene.

## The pipeline

### 1. Script

- Write the narration from the tutorial page on the website and from the matching Help topic, so the page, the
  Help and the video say the same thing.
- Use the UI's exact labels. A harness `capture` writes the accessibility tree (`.ax.txt`); check the button and
  menu names against it.
- Review the script as a pull request, before any rendering.

### 2. Voice

- Each scene's narration becomes one audio file, cached by a hash of the text and the voice. Changing one sentence
  re-voices one scene.
- **Voice model:** Kokoro-82M (Apache-2.0, per its Hugging Face model card), running on breezy (below). It is free,
  runs locally, and voices a 7 s line in about 1 s on the M2's CPU.
- **Never publish the macOS voice.** `say` is fine for a scratch check, but Apple's licence allows the system
  voices only for personal, non-commercial content. `say` also fails inside the Bash sandbox
  (`sandbox_extension_issue_file`).
- The script stays the same whichever voice reads it.
- A pronunciation list (`video/lexicon.json`) rewrites words for the voice only, not for the subtitles. For example:
  - G-code → "G code"
  - ⌘ → "Command"
  - GRBL → "gerbil"
  - Mach4 → "Mack four"
- The audio is normalised to −16 LUFS when the video is joined.

### 3. Picture

- All scenes become one harness scenario with one `record` per scene. Each recording gets a `wait` long enough to
  cover its narration plus a 0.8 s tail, because a clip shorter than its narration is frozen on its last frame.
  Footage is never sped up to fit.
- Use a 16:9 window. `[1280, 720]` records at 2560×1440 on a Retina screen, which leaves room to zoom in and still
  deliver sharp 1080p. Every scene records in light appearance (`"appearance": "light"`).
- The harness draws the pointer gliding onto each control (`press`, `move`, `select`) and scrubs the 3D cut
  (`simulate`).
- Full-window stills for the tutorial page come from `capture` steps in the same run, so the page's screenshots
  match the video's.
- Run `scripts/ui.sh` outside the Bash sandbox (docs/UI-HARNESS.md explains why).

### 4. Animation and text

- **Cards and lower thirds:** SVGs from brand templates (graphite `#111317`, lime `#C6EE3A`), rendered with
  `rsvg-convert` and laid over the video with ffmpeg's `overlay`.
  - The installed ffmpeg has no `drawtext` or `subtitles` filter, so text never goes through ffmpeg.
  - A lower third must not cover a control the scene is using. Each scene says where its text sits.
- **Camera moves:** `zoompan` for a slow push-in on a region; `fade` and `xfade` between scenes.
- **Endings.** Every video ends on an end card:
  - **Spoken:** one closing sentence that wraps up what was made, and nothing more. The card is never read aloud.
  - **Shown:** loftline.app. Add "Next: <title>" only when the video belongs to a series; a one-off video has no
    next card (`video.json` `next` is optional).
  - **Timing:** 2 s held after the voice, then a 1.5 s fade.

  The first test ended on the last app scene and felt cut off. A spoken "next video" line made the ending drag.
- **Not yet covered:** animated diagrams, such as material-top against spoilboard Z zero for A2. Decide the tool
  when A2 is written (Decisions, item 2).

### 5. Assemble and publish

- Each scene renders to its own MP4. These are joined, the audio is normalised, and the subtitles are attached as a
  soft track (`mov_text`). Burned-in subtitles would need an ffmpeg built with libass.
- Outputs for each video:
  - 1080p MP4;
  - `.vtt` subtitles, timed from the scene offsets and audio lengths, so no speech recognition is needed;
  - a poster PNG;
  - chapters, from the scene titles.
- The tutorial page embeds the video with the `.vtt` and shows the full transcript under it. The transcript is the
  narration text joined together.
- The voice is synthetic, so say so in the video description.

## The shape of a project video

Modelled on Vectric's "How to create a simple sign in Vectric software | Getting Started | V12 Tutorials"
(youtube.com/watch?v=ooTRI9rHydw, 2024, about 212,000 views, 21:33). It is Vectric's most-viewed official tutorial
in a YouTube search, and its subject is the closest to ours. The video's own chapters give its parts:

| Part | Vectric's time | What happens | LoftLine rule |
|---|---|---|---|
| 1. Open | 0:00–0:51 (4 %) | Says which products it applies to, shows the finished sign, and promises "after watching you can make a similar project from scratch" | Show the finished, cut piece in the first 15 s |
| 2. Job setup | 0:51–3:00 (10 %) | Size, thickness, units, Z zero on top, XY origin lower left; a short interface tour that points to a separate interface video | Same, and say where Z zero is out loud |
| 3. Design | 3:00–11:12 (38 %) | Rectangle, align, corner radius, text, holes, mirror. Each tool: click, type the exact number, Tab, Enter, Escape | One scene per tool; the lower third shows the number typed |
| 4. Toolpaths | 11:12–16:48 (26 %) | Check Material Setup first (safe Z, home); pocket; preview in 3D ("now is your time to correct it"); profile with tabs; preview | Preview after every toolpath, as Vectric does |
| 5. Save | 16:48–17:54 (5 %) | Post processor, one file per tool, names that show the cutting order | Same, plus reading the Export sheet's Z zero and deepest cut |
| 6. At the machine | 17:54–20:20 (11 %) | Fixtures the stock, fits the bit, sets XY at the corner, Z with a touch plate, loads from USB, cuts to music | Camera footage; **add the air cut**, which Vectric's video skips |
| 7. Close | 20:20–21:33 (6 %) | The finished sign, a recap, "rewatch any part", and a spoken teaser for the next video | One closing sentence and the silent end card (above) |

Lessons from the video:

1. **It is a project, not a feature tour.** Only the tools the sign needs appear. Everything deeper is deferred:
   "we have a great video called how to use the pocket toolpath". A flagship video therefore depends on a library
   of short feature videos to point to.
2. **Chapters.** It has chapters, and the same timestamps are listed in the description. Our scene titles become
   both.
3. **Narration is fast and unscripted:** about 210 words a minute, with filler ("go ahead", "so"). A written
   script at about 150 words a minute says the same in less time.
4. **The machine section shows the habits:** clamping, the touch plate, the dust shoe or enclosure. It does not
   show an air cut.
5. **Title pattern:** what you make, then the series, then the version. For example: "How to make a simple sign
   in LoftLine | First cuts | 1.0".

The other popular format is the long beginner course. IDC Woodcraft's "The Most Complete Vectric 101 Tutorial
for Beginners" runs 2:01:01 with 36 chapters. It is organised by menu: the interface, files, each drawing tool,
each toolpath, tabs, then saving and the post processor. It has about 161,000 views and a higher like rate than
Vectric's own video (5,533 likes against 1,232). Our equivalent is the chaptered playlist of feature videos, not
one long video.

## Machine footage

The harness cannot film the router, and every tutorial that ends at the machine ends with the air cut (TRAINING-PLAN
rule 3). Footage scenes come from a shot list in `video.json`:

1. Camera on a tripod, landscape, 4K 30 fps, fixed exposure. Film the whole bed, then close-ups of the spindle and
   of the controller screen.
2. Film the air cut exactly as TESTING.md §4 describes it:
   - Z zero lifted above the stock;
   - spindle off;
   - feed override around 50 %;
   - a hand visibly on the E-stop.
3. Safety glasses and hearing protection are on in every shot of a running spindle.
4. The machine's owner watches the rough cut and checks every machine scene against TESTING.md §4 before it is
   published.

## Review gates

1. **Script PR:** wording, labels, safety steps.
2. **Rough render:**
   - `scripts/video.py <id> check` passes;
   - a listen-through for pronunciation. Whisper hears "Jobe Setup" as "Job Setup", so `check` cannot catch a word
     read as a name; fix it in `video/lexicon.json` (A1's "Job Setup" is voiced as "job setup");
   - pacing;
   - whether the narration matches what is on screen, using the render's `contact.png` (one frame per scene).
3. **Safety check** of the machine scenes (step 4 above).

## Keeping videos current

- Each render writes the app version and the git commit into the MP4's metadata.
- The release checklist reruns the videos. Audio comes from the cache, so only the picture changes.
- A scene whose harness steps fail (a renamed button, a moved control) stops the render and names the step, just
  as a failing scenario does now.

## Proof of concept (2026-11-01)

A three-scene cut of A1 was rendered on this machine:

- a title card;
- the sample sign with a push-in on the toolpath list;
- the 3D simulation with a lower third.

It was voiced first with `say`, then again with Kokoro `af_heart` on breezy, with soft subtitles and a `.vtt` file. Output: 1920×1080 H.264, AAC, a
`mov_text` track, 29.9 s. The script is `.tmp/video-poc/compose.sh` (not committed); it becomes `scripts/video.sh`.

What it showed:

1. **Freeze-frames.** The sample clip ran 4.1 s against 7.3 s of narration and froze for the difference. The
   recording's waits have to come from the audio lengths (step 3).
2. **Blank 3D view.** The 3D view was blank for the first second of its scene because the stock builds after the
   switch. Switch to 3D and `wait` before `record`.
3. **Narration out of step.** The narration ended while the simulation still had seven seconds to run. Long actions
   need their sentences cued to events in the recording (work item 2).
4. **Lower third over controls.** The lower third covered the simulation transport bar, hence the per-scene text
   position.

## Work to build

1. **Done: `scripts/video.py <id> [voice|record|render|check] [--final]`.** It reads `video/<id>/video.json`, voices
   lines on breezy into a cache, records with the harness, draws the cards, and assembles the video with chapters
   and subtitles. `check` transcribes each voiced line with Whisper and flags lines that differ from the script.
2. **A harness event timeline.** `record` also writes `<name>.events.json`: each step's time in the clip and the
   frame of the control it acted on. The compositor uses it to:
   - zoom onto the control;
   - draw a highlight ring around it;
   - start a sentence when its action happens.
3. **Open menus in the harness.** Captures show the window only, so a step like Help ▸ Welcome to LoftLine cannot
   show the open menu. Until then, the scene uses a lower third with the menu path.
4. **Done: the pronunciation list** (`video/lexicon.json`) and the voice settings (`video/voice.json`).
5. **Done: brand cards** (title, end, footage placeholder, stand-in banner, lower third), drawn by
   `scripts/video.py`.

## The free stack

| Part | Tool | Licence | Where it runs |
|---|---|---|---|
| Screens | the UI harness (`scripts/ui.sh`) | ours | the Mac with the app build |
| Voice | Kokoro-82M | Apache-2.0 | breezy |
| Cards, zooms, fades, joining | rsvg-convert, ffmpeg | LGPL / GPL tools, output unrestricted | either Mac |
| Animated diagrams | Motion Canvas, when A2 needs one | MIT | either Mac |
| Hosting | YouTube, embedded on the tutorial page | free | — |

**Voice service on breezy.** `~/sites/loftline-voice` holds:
- a uv virtualenv (Python 3.12, `kokoro`, `soundfile`);
- `espeak-ng` from Homebrew;
- `speak.py`, which reads `narration.tsv` (scene id, tab, text) and writes `out/<scene>-<voice>.wav` at 24 kHz.

`scripts/video.sh` copies the narration over with `scp`, runs `speak.py` over `ssh breezy`, and copies the WAVs
back into the cache. Breezy is on the tailnet; the commands need the Bash sandbox off.

**Voices tried:** `af_heart` (US, female), `am_michael` (US, male), `bm_george` (British, male).

**Avoid:**
- F5-TTS's official weights (CC-BY-NC) and XTTS-v2 (Coqui Public Model License). Both are non-commercial only.
- Remotion, unless Mobility Labs has three people or fewer. Above that its company licence applies.

## Decisions needed from Sean

1. **Voice: decided 2026-11-01, Sean's cloned voice.**
   - Kokoro stock voices stay installed as a fallback.
   - **The clone.** Chatterbox (MIT on Hugging Face) runs on breezy:
     - Files: `~/sites/loftline-voice/.venv-cb`, `clone.py`, and `sean-ref.wav`, a 10.8 s cut of a Voice Memo.
     - Speed: about 8 s of compute per second of speech on the M2 (MPS).
     - Install fix: needs `setuptools<81`, or its watermarker fails to import.
     - Output carries Resemble's inaudible Perth watermark.
   - **Sean records each script.** Every wording change means recording again.
2. **Video host:** YouTube (free) or a paid player without YouTube branding.
3. **Appearance: decided 2026-11-01, light.** Measured website data puts dark mode at roughly 18–38 % of visitors, so most viewers run light. Cards and lower thirds keep the graphite brand.
4. **Filming:** who films the machine, and on which machine (the Avid PRO6096 is the only one on hand).
