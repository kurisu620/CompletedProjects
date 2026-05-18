import csv
import subprocess
import os
import time
from pathlib import Path

ROOT_DIR      = r"" #Path to TV showa ie /mnt/Episodes or C:\Projects\Episodes
COMPLETED_CSV = r"" #Path to where you want to save a csv for what has been compressed ie /home/root/Logs or C:\users\Admin\Documents\Logs

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".avi", ".mov", ".wmv", ".m4v", ".ts", ".mpg", ".mpeg"}

# Audio codecs that can't be cleanly copied into MKV — transcode these instead
TRANSCODE_AUDIO_CODECS = {"truehd", "mlp"}

# How many times to retry a segfaulting conversion before giving up
MAX_RETRIES = 3
# Seconds to wait between retries (gives the OS time to reclaim memory)
RETRY_DELAY = 5


def load_completed(csv_path: str) -> dict:
    completed = {}
    p = Path(csv_path)

    if not p.exists():
        return completed

    with p.open("r", newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.get("Name") or row.get("name")
            size = row.get("Size") or row.get("size")
            if not name:
                continue
            try:
                row_size = int(size) if size not in (None, "") else None
            except ValueError:
                row_size = None

            if name not in completed:
                completed[name] = {"Size": row_size, "Row": row}

    return completed


def append_completed(csv_path: str, name: str, size: int) -> None:
    """
    Write a single completed entry to the CSV immediately and flush to disk.
    This ensures the record is persisted even if the script crashes mid-run.
    """
    p = Path(csv_path)
    file_exists = p.exists()

    with p.open("a", newline="", encoding="utf-8") as f:
        fieldnames = ["Name", "Size"]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        if not file_exists:
            writer.writeheader()
        writer.writerow({"Name": name, "Size": size})
        f.flush()
        os.fsync(f.fileno())


def probe_audio_codec(src: Path) -> str:
    """Return the first audio stream codec name (lowercase), or empty string on failure."""
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "a:0",
        "-show_entries", "stream=codec_name",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(src)
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return result.stdout.strip().lower()
    except Exception:
        return ""


def get_all_movies(root: Path, completed: dict) -> list:
    """
    Walk ROOT_DIR/[MovieFolder]/[MovieFile] and collect all unconverted
    video files, returned as a flat list sorted largest-to-smallest.
    """
    files = []

    for movie_dir in root.iterdir():
        if not movie_dir.is_dir():
            continue

        for item in movie_dir.iterdir():
            if not item.is_file():
                continue
            if item.suffix.lower() not in VIDEO_EXTENSIONS:
                continue
            if item.name.startswith("Converted "):
                continue

            key   = str(item)
            found = completed.get(key)
            if not (found and found.get("Size") == item.stat().st_size):
                files.append(item)

    # Largest first
    files.sort(key=lambda p: p.stat().st_size, reverse=True)
    return files


def build_ffmpeg_cmd(src_name: str, out_name: str, audio_codec: str) -> list:
    """
    Build the ffmpeg command for a given source file.

    - Maps only video stream 0 and audio stream 0 to avoid segfaults from
      files with large numbers of subtitle streams.
    - Transcodes TrueHD/MLP audio to AAC since those codecs cannot be
      cleanly copied into MKV.
    - Raises probesize/analyzeduration to handle files with complex streams.
    """
    if audio_codec in TRANSCODE_AUDIO_CODECS:
        audio_args = ["-c:a", "aac", "-b:a", "384k"]
        print(f"  Audio codec '{audio_codec}' detected — transcoding to AAC instead of copying.")
    else:
        audio_args = ["-c:a", "copy"]

    cmd = [
        "ffmpeg",
        "-probesize", "100M",
        "-analyzeduration", "100M",
        "-i", src_name,
        "-map", "0:v:0",
        "-map", "0:a:0",
        "-c:v", "libx265",
        "-crf", "22",
        "-preset", "fast",
    ] + audio_args + [
        out_name
    ]

    return cmd


def attempt_convert(src: Path, out_path: Path, audio_codec: str) -> subprocess.CompletedProcess:
    """Run ffmpeg once, cleaning up any partial output first."""
    if out_path.exists():
        out_path.unlink()

    cmd = build_ffmpeg_cmd(src.name, out_path.name, audio_codec)

    return subprocess.run(
        cmd,
        cwd=str(src.parent),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )


def run_ffmpeg_convert(src: Path) -> Path:
    """
    Convert src to HEVC, retrying up to MAX_RETRIES times on segfault (exit -11).

    Exit -11 is a SIGSEGV — often a transient x265 thread-pool race condition
    that goes away on a second attempt. Any other non-zero exit code is treated
    as a permanent failure and is not retried.
    """
    out_path    = src.parent / f"Converted {src.name}"
    audio_codec = probe_audio_codec(src)

    last_result = None
    for attempt in range(1, MAX_RETRIES + 1):
        if attempt > 1:
            print(f"  Retry {attempt - 1}/{MAX_RETRIES - 1} after {RETRY_DELAY}s ...")
            time.sleep(RETRY_DELAY)

        result = attempt_convert(src, out_path, audio_codec)

        if result.returncode == 0:
            if attempt > 1:
                print(f"  Succeeded on attempt {attempt}.")
            return out_path

        last_result = result

        if result.returncode != -11:
            # Not a segfault — retrying won't help
            break

        print(f"  Attempt {attempt} crashed (exit -11 / SIGSEGV).")

    raise RuntimeError(
        f"ffmpeg failed for {src} "
        f"(exit {last_result.returncode}, {attempt} attempt(s))\n"
        f"STDOUT:\n{last_result.stdout}\n\nSTDERR:\n{last_result.stderr}"
    )


def main():
    root      = Path(ROOT_DIR)
    completed = load_completed(COMPLETED_CSV)

    movies = get_all_movies(root, completed)

    if not movies:
        print("Nothing to convert.")
        return

    total = len(movies)
    print(f"Found {total} movie(s) to convert (largest first).")

    for idx, src in enumerate(movies, start=1):
        src_size   = src.stat().st_size
        movie_name = src.parent.name          # the individual movie folder name
        print(f"\n[{idx}/{total}] {movie_name} / {src.name} "
              f"({src_size / 1024**3:.2f} GB)")

        # ── Convert ───────────────────────────────────────────────────────────
        try:
            converted = run_ffmpeg_convert(src)
        except RuntimeError as e:
            print(f"  ERROR: {e}")
            print("  Skipping this movie and continuing.")
            continue

        if not converted.exists():
            print("  Converted file missing; skipping.")
            continue

        out_size = converted.stat().st_size
        if out_size < 20:
            print(f"  Converted file too small ({out_size} bytes); skipping.")
            converted.unlink(missing_ok=True)
            continue

        # ── Delete original & rename converted to original name ───────────────
        src.unlink()
        final_path = converted.parent / src.name
        if final_path.exists():
            final_path.unlink()
        converted.rename(final_path)

        new_size = final_path.stat().st_size

        # ── Write to CSV immediately ──────────────────────────────────────────
        append_completed(COMPLETED_CSV, str(final_path), new_size)
        completed[str(final_path)] = {"Size": new_size, "Row": None}

        print(f"  Done: {final_path.name} ({new_size / 1024**3:.2f} GB)  "
              f"[logged to CSV]")

    print("\nAll movies processed.")


if __name__ == "__main__":
    main()
