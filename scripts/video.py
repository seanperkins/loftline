#!/usr/bin/env python3
"""Builds a narrated training video from video/<id>/video.json (docs/VIDEO-PROCESS.md).

  scripts/video.py a1-first-cut              # voice, record, render
  scripts/video.py a1-first-cut voice        # one stage: voice | record | render | check
  scripts/video.py a1-first-cut check        # transcribe each voiced line with Whisper and flag differences
  scripts/video.py a1-first-cut --final      # refuses while any scene is a placeholder or a stand-in
  scripts/video.py a1-first-cut record --build   # rebuild the app before recording (default: --no-build)

Run it outside the Bash sandbox: the voice stage talks to breezy over ssh and the record stage runs scripts/ui.sh.
Voice files are cached by a hash of the voice id and the spoken text (.tmp/video-cache/voice). A cached line is never
re-voiced, because the voice model samples randomly and a new take would change the scene's timing.
Outputs go to .tmp/video/<id>/out: <id>.mp4 (chapters, soft subtitles), <id>.vtt, description.txt, transcript.md,
contact.png.
"""
import hashlib, json, os, re, shlex, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".tmp/video-cache/voice"
W, H, FPS = 1920, 1080, 30
# The app is shown at 85 % on a graphite frame; labels and notes live in the band below it, never over a control.
APP_W, APP_H, APP_X, APP_Y = 1632, 918, 144, 30
BAND_Y = APP_Y + APP_H
DELAY = 0.25          # silence before the voice starts in each scene
HOLD = 0.8            # picture held after the voice ends
END_HOLD = 2.0        # end card held after the closing line
POINTER_OPS = {"press", "move", "select", "selectToolpath", "scroll", "pointer"}
GRAPHITE, LIME, WHITE, GREY, AMBER = "#111317", "#C6EE3A", "#FFFFFF", "#9AA0A6", "#F5A524"


def run(args, **kw):
    print("+", " ".join(shlex.quote(str(a)) for a in args)[:200], flush=True)
    return subprocess.run([str(a) for a in args], check=True, **kw)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True, check=True).stdout.strip()
    return float(out)


def clip_length(ffconcat):
    """Length of a harness recording: the sum of its frame durations."""
    return sum(float(m) for m in re.findall(r"^duration ([\d.]+)", ffconcat.read_text(), re.M))


def load(video_id):
    spec = json.loads((ROOT / "video" / video_id / "video.json").read_text())
    lex = json.loads((ROOT / "video/lexicon.json").read_text())["rules"]
    voice = json.loads((ROOT / "video/voice.json").read_text())
    for s in spec["scenes"]:
        text = s.get("narration")
        if text:
            spoken = text
            for a, b in lex:
                spoken = spoken.replace(a, b)
            s["spoken"] = spoken
            s["key"] = hashlib.sha256(f"{voice['id']}\n{spoken}".encode()).hexdigest()[:16]
            s["voice"] = CACHE / f"{s['key']}.wav"
    return spec, voice


# ---------------------------------------------------------------- voice

def stage_voice(spec, voice):
    todo = [s for s in spec["scenes"] if "spoken" in s and not s["voice"].exists()]
    if not todo:
        print("voice: every line is cached")
        return
    CACHE.mkdir(parents=True, exist_ok=True)
    batch = ROOT / f".tmp/video/{spec['id']}/voice-batch.tsv"
    batch.parent.mkdir(parents=True, exist_ok=True)
    batch.write_text("".join(f"{s['key']}\t{s['spoken']}\n" for s in todo))
    host, d = voice["host"], voice["dir"]
    remote_tsv = f"batch-{spec['id']}.tsv"
    print(f"voice: {len(todo)} line(s) to voice on {host}")
    run(["scp", "-q", batch, f"{host}:{d}/{remote_tsv}"])
    run(["ssh", "-o", "BatchMode=yes", host,
         f"cd {d} && NARRATION={remote_tsv} {voice['python']} {voice['script']} {voice['reference']} v 2>&1 | grep -E 'audio in|Error'"])
    for s in todo:
        run(["scp", "-q", f"{host}:{d}/out/{s['key']}-v.wav", s["voice"]])


# ---------------------------------------------------------------- record

def estimate(steps):
    t = 0.0
    for st in steps:
        op = st["op"]
        t += st.get("seconds", 0) if op in ("wait", "simulate") else 0
        t += 0.8 if op in POINTER_OPS else 0
        t += 0.6 if op in ("sheet", "closeSheet") else 0
    return t


def scenario(spec):
    steps = list(spec.get("setup", []))
    for s in spec["scenes"]:
        if s.get("card"):
            continue
        audio = duration(s["voice"]) if s.get("voice") and s["voice"].exists() else 3.0
        target = DELAY + audio + HOLD
        rec = list(s.get("steps", []))
        if s.get("simulate"):
            rec.append({"op": "simulate", "seconds": round(max(2.0, audio), 1)})
        fill = max(0.3, target - estimate(rec))
        steps += s.get("pre", [])
        steps += [{"op": "record", "name": s["id"], "fps": 15}, *rec,
                  {"op": "wait", "seconds": round(fill, 2)}, {"op": "endRecord"}]
    # The harness watchdog defaults to 180 s; a whole video records for minutes. Allow the waits plus a margin for
    # loading, calculating and opening sheets.
    timeout = min(3600, int(estimate(steps) * 1.5 + 180))
    return {"name": f"video {spec['id']}", "appearance": spec.get("appearance", "light"),
            "window": spec.get("window", [1280, 720]), "timeout": timeout, "steps": steps}


def stage_record(spec, build):
    work = ROOT / f".tmp/video/{spec['id']}"
    work.mkdir(parents=True, exist_ok=True)
    branch = subprocess.run(["git", "branch", "--show-current"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    print(f"record: checkout is on branch {branch}")
    (work / "scenario.json").write_text(json.dumps(scenario(spec), indent=2, ensure_ascii=False))
    run_dir = work / "run"
    args = ["scripts/ui.sh", work / "scenario.json", "--out", run_dir, "--key", "--offscreen"]
    if not build:
        args.append("--no-build")
    run(args, cwd=ROOT)


# ---------------------------------------------------------------- cards

def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def wrap(text, width):
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    return lines + ([line] if line else [])


def svg(body, background=True):
    bg = f'<rect width="{W}" height="{H}" fill="{GRAPHITE}"/>' if background else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">{bg}{body}</svg>'


def text(x, y, s, size, fill, bold=False, font="Helvetica Neue"):
    weight = ' font-weight="bold"' if bold else ""
    return f'<text x="{x}" y="{y}" font-family="{font}"{weight} font-size="{size}" fill="{fill}">{esc(s)}</text>'


def card_svg(spec, s):
    kind = s["card"]
    if kind == "title":
        return svg(f'<rect x="160" y="470" width="12" height="140" fill="{LIME}"/>'
                   + text(210, 530, spec["title"], 72, WHITE, True) + text(210, 600, spec["subtitle"], 40, LIME))
    if kind == "end":
        body = f'<rect x="160" y="440" width="12" height="200" fill="{LIME}"/>'
        if spec.get("next"):
            body += text(210, 490, "Next", 34, GREY) + text(210, 560, spec["next"], 64, WHITE, True)
            body += text(210, 625, "loftline.app", 44, LIME)
        else:
            body += text(210, 560, "loftline.app", 64, LIME, True)
        return svg(body)
    if kind == "placeholder":
        body = (f'<rect x="0" y="0" width="{W}" height="16" fill="{AMBER}"/><rect x="0" y="{H-16}" width="{W}" height="16" fill="{AMBER}"/>'
                + text(160, 360, "FOOTAGE TO FILM", 40, AMBER, True)
                + text(160, 420, f"{s['chapter']} · {s['id']}", 30, GREY))
        for i, line in enumerate(wrap(s["footage"], 52)):
            body += text(160, 520 + i * 66, line, 52, WHITE)
        return svg(body)
    raise SystemExit(f"unknown card {kind!r} in scene {s['id']}")


def label_svg(label):
    words = label["text"]
    keys = label.get("keys", "")
    width = 60 + int(len(words) * 23) + (int(len(keys) * 30) + 40 if keys else 0)
    x, y = APP_X, BAND_Y + 18
    body = (f'<rect x="{x}" y="{y}" width="{width}" height="96" rx="14" fill="{GRAPHITE}" fill-opacity="0.9"/>'
            f'<rect x="{x}" y="{y}" width="10" height="96" fill="{LIME}"/>'
            + text(x + 36, y + 62, words, 40, WHITE, True))
    if keys:
        body += text(x + 56 + int(len(words) * 23), y + 62, keys, 38, LIME, font="Menlo")
    return svg(body, background=False)


def banner_svg(message):
    return svg(f'<text x="{APP_X + APP_W}" y="{BAND_Y + 76}" text-anchor="end" font-family="Helvetica Neue" '
               f'font-weight="bold" font-size="26" fill="{AMBER}">{esc("STAND-IN: " + message)}</text>', background=False)


def png(svg_text, path):
    path.with_suffix(".svg").write_text(svg_text)
    run(["rsvg-convert", path.with_suffix(".svg"), "-o", path])
    return path


# ---------------------------------------------------------------- render

def scene_length(spec, s, audio, clip):
    if s.get("card") == "title":
        return s.get("duration", 3.0)
    if s.get("card") == "end":
        return DELAY + audio + END_HOLD
    base = DELAY + audio + HOLD if audio else s.get("duration", 3.0)
    return max(base, clip) if clip else base


def render_scene(spec, s, work, out):
    audio = duration(s["voice"]) if "voice" in s else 0.0
    rec = work / "run" / f"{s['id']}.ffconcat"
    clip = clip_length(rec) if not s.get("card") else 0.0
    length = round(scene_length(spec, s, audio, clip), 3)
    inputs, filters = [], []
    if s.get("card"):
        inputs += ["-loop", "1", "-t", length, "-i", png(card_svg(spec, s), out / f"{s['id']}-card.png")]
        filters.append(f"[0:v]scale={W}:{H},fps={FPS},format=yuv420p,fade=t=in:d=0.3[v0]")
    else:
        if not rec.exists():
            raise SystemExit(f"no recording for scene {s['id']}: run the record stage")
        inputs += ["-f", "concat", "-safe", "0", "-i", rec]
        z = s.get("zoom")
        if z:
            frames = max(1, int(length * FPS))
            fit = (f"zoompan=z='1+({z['to']}-1)*on/{frames}':x='(iw-iw/zoom)*{z['x']}':y='(ih-ih/zoom)*{z['y']}'"
                   f":d=1:s={APP_W}x{APP_H}:fps={FPS}")
        else:
            fit = f"scale={APP_W}:{APP_H}:flags=lanczos"
        # Overlaid, not padded, so the window's transparent rounded corners show the frame behind them.
        filters.append(f"[0:v]fps={FPS},{fit},format=rgba[app]")
        filters.append(f"color=c={GRAPHITE}:s={W}x{H}:r={FPS}[frame]")
        filters.append("[frame][app]overlay=" + f"{APP_X}:{APP_Y}:shortest=1,format=yuv420p[v0]")
    v = "v0"
    overlays = []
    if s.get("label"):
        overlays.append((png(label_svg(s["label"]), out / f"{s['id']}-label.png"), f"between(t,0.3,{length - 0.3})"))
    if s.get("stand_in"):
        overlays.append((png(banner_svg(s["stand_in"]), out / f"{s['id']}-standin.png"), "1"))
    for i, (img, when) in enumerate(overlays, start=1):
        inputs += ["-i", img]
        filters.append(f"[{v}][{i}:v]overlay=0:0:enable='{when}',format=yuv420p[v{i}]")
        v = f"v{i}"
    last = s is spec["scenes"][-1]
    first = s is spec["scenes"][0]
    tail = f"tpad=stop_mode=clone:stop_duration={length},trim=duration={length},setpts=PTS-STARTPTS"
    if first:
        tail += ",fade=t=in:d=0.5"
    if last:
        tail += f",fade=t=out:st={length - 1.5}:d=1.5"
    elif s.get("card"):
        tail += f",fade=t=out:st={length - 0.3}:d=0.3"
    filters.append(f"[{v}]{tail}[vout]")
    a_in = len(overlays) + 1
    if audio:
        inputs += ["-i", s["voice"]]
        ms = int(DELAY * 1000)
        filters.append(f"[{a_in}:a]aresample=48000,aformat=channel_layouts=stereo,adelay={ms}|{ms},apad,atrim=duration={length}[aout]")
    else:
        inputs += ["-f", "lavfi", "-t", length, "-i", "anullsrc=r=48000:cl=stereo"]
        filters.append(f"[{a_in}:a]atrim=duration={length}[aout]")
    dest = out / f"scene-{s['id']}.mp4"
    run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", ";".join(filters),
         "-map", "[vout]", "-map", "[aout]", "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-r", FPS,
         "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", dest])
    return dest, duration(dest), audio


def stamp(t, vtt=True):
    h, rem = divmod(t, 3600)
    m, sec = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{sec:06.3f}" if vtt else (f"{int(h)}:{int(m):02d}:{int(sec):02d}" if h else f"{int(m)}:{int(sec):02d}")


def sentences(t):
    return [p.strip() for p in re.split(r"(?<=[.!?])\s+", t) if p.strip()]


def stage_render(spec, final):
    work = ROOT / f".tmp/video/{spec['id']}"
    out = work / "out"
    out.mkdir(parents=True, exist_ok=True)
    unfinished = [s["id"] for s in spec["scenes"] if s.get("card") == "placeholder" or s.get("stand_in")]
    if final and unfinished:
        raise SystemExit(f"--final refused: scenes still need footage: {', '.join(unfinished)}")
    missing = [s["id"] for s in spec["scenes"] if "voice" in s and not s["voice"].exists()]
    if missing:
        raise SystemExit(f"no voice yet for: {', '.join(missing)} (run the voice stage)")

    parts, cues, chapters, t = [], [], [], 0.0
    for s in spec["scenes"]:
        path, length, audio = render_scene(spec, s, work, out)
        parts.append(path)
        if not chapters or chapters[-1][0] != s["chapter"]:
            chapters.append([s["chapter"], t])
        if s.get("narration"):
            said = sentences(s["narration"])
            total = sum(len(x) for x in said)
            start = t + DELAY
            for x in said:
                span = audio * len(x) / total
                cues.append((start, start + span, x))
                start += span
        t += length

    for i, (name, start) in enumerate(chapters):
        end = chapters[i + 1][1] if i + 1 < len(chapters) else t
        if end - start < 10:
            print(f"warning: chapter {name!r} is {end - start:.1f} s; YouTube needs at least 10 s")
    if len(chapters) < 3:
        print("warning: YouTube needs at least three chapters")

    vid = spec["id"]
    vtt = out / f"{vid}.vtt"
    vtt.write_text("WEBVTT\n\n" + "".join(f"{i}\n{stamp(a)} --> {stamp(b)}\n{x}\n\n" for i, (a, b, x) in enumerate(cues, 1)))
    meta = out / "chapters.txt"
    meta.write_text(";FFMETADATA1\ntitle=" + spec.get("youtube_title", spec["title"]) + "\n" + "".join(
        f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={int(start * 1000)}\nEND={int((chapters[i + 1][1] if i + 1 < len(chapters) else t) * 1000)}\ntitle={name}\n"
        for i, (name, start) in enumerate(chapters)))
    listing = out / "parts.txt"
    listing.write_text("".join(f"file '{p}'\n" for p in parts))
    joined = out / "joined.mp4"
    run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", joined])
    final_mp4 = out / f"{vid}.mp4"
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", joined, "-i", meta, "-i", vtt,
         "-map", "0:v", "-map", "0:a", "-map", "2", "-map_metadata", "1", "-map_chapters", "1",
         "-c:v", "copy", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
         "-c:s", "mov_text", "-metadata:s:s:0", "language=eng", "-movflags", "+faststart", final_mp4])

    (out / "description.txt").write_text(
        spec.get("youtube_title", spec["title"]) + "\n\n" + "".join(f"{stamp(start, False)} {name}\n" for name, start in chapters)
        + "\nNarration: Sean Perkins's voice, generated with an AI voice model from his own recording.\n")
    (out / "transcript.md").write_text(f"# {spec['title']}: transcript\n\n" + "".join(
        f"## {name}\n\n" + " ".join(s["narration"] for s in spec["scenes"] if s["chapter"] == name and s.get("narration")) + "\n\n"
        for name, _ in chapters))
    # Contact sheet: one frame from the middle of each scene, for review.
    frames = []
    for s, p in zip(spec["scenes"], parts):
        f = out / f"mid-{s['id']}.png"
        run(["ffmpeg", "-loglevel", "error", "-y", "-ss", duration(p) / 2, "-i", p, "-frames:v", "1", "-vf", "scale=480:-2", f])
        frames.append(f)
    # Rows of five, appended (magick montage needs a font it cannot find on a plain macOS install).
    rows = [frames[i:i + 5] for i in range(0, len(frames), 5)]
    args = ["magick", "-background", "#222"]
    for row in rows:
        args += ["(", *row, "+append", ")"]
    run([*args, "-append", out / "contact.png"])
    print(f"wrote {final_mp4} ({t:.1f} s, {len(chapters)} chapters, {len(cues)} subtitle cues)")
    if unfinished:
        print(f"draft: placeholders or stand-ins remain in {', '.join(unfinished)}")


CHECK = r"""
import json, re, sys, difflib, mlx_whisper
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
def words(n):
    n = int(n)
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else ONES[n % 10])
    return str(n)
def spell(m):
    whole, _, frac = m.group(0).partition(".")
    return " " + words(whole) + ("" if not frac else " point " + " ".join(ONES[int(d)] for d in frac)) + " "
def norm(t):
    # Compare letters only: Whisper writes "24", "Z0", "tool paths"; the script says "twenty-four", "Z zero", "toolpaths".
    t = re.sub(r"\d+(\.\d+)?", spell, re.sub(r"(?<=[a-z])\.(?=[a-z])", " dot ", t.lower()))
    return list(re.sub(r"[^a-z]+", "", t))
bad = 0
for key, path, spoken in json.load(sys.stdin):
    heard = mlx_whisper.transcribe(path, path_or_hf_repo=sys.argv[1])["text"].strip()
    a, b = norm(spoken), norm(heard)
    ratio = difflib.SequenceMatcher(None, a, b).ratio()
    flag = "OK " if ratio >= 0.95 else "CHECK"
    bad += ratio < 0.95
    print(f"{flag} {ratio:.2f} {key}\n   said: {spoken}\n  heard: {heard}" if ratio < 0.95 else f"{flag} {ratio:.2f} {key}")
print(f"{bad} line(s) to listen to")
"""


def stage_check(spec):
    """Transcribes each voiced line with Whisper and flags the ones that differ from the script (a dropped word,
    a mispronunciation). Needs a Python with mlx-whisper: VIDEO_QA_PYTHON, default .tmp/video-qa/.venv/bin/python."""
    py = os.environ.get("VIDEO_QA_PYTHON", str(ROOT / ".tmp/video-qa/.venv/bin/python"))
    model = os.environ.get("VIDEO_QA_MODEL", "mlx-community/whisper-small.en-mlx")
    lines = [[s["id"], str(s["voice"]), s["spoken"]] for s in spec["scenes"] if "voice" in s and s["voice"].exists()]
    subprocess.run([py, "-c", CHECK, model], input=json.dumps(lines), text=True, check=True)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    video_id, rest = args[0], args[1:]
    stages = [a for a in rest if not a.startswith("--")] or ["voice", "record", "render"]
    spec, voice = load(video_id)
    for stage in stages:
        if stage == "voice":
            stage_voice(spec, voice)
        elif stage == "record":
            stage_record(spec, "--build" in rest)
        elif stage == "render":
            stage_render(spec, "--final" in rest)
        elif stage == "check":
            stage_check(spec)
        else:
            raise SystemExit(f"unknown stage {stage!r}")


if __name__ == "__main__":
    main()
