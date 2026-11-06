# Completed Projects

Small automation tools I built for my home lab and desktop, in Python and PowerShell. Each script stands alone, and its settings sit at the top of the file.

| Script | Language | What it does |
| --- | --- | --- |
| `CompressTVShows.py` | Python | Re-encodes a TV library to HEVC with ffmpeg, one show at a time |
| `compressMovies.py` | Python | The same engine for a movie library, largest files first |
| `restartSabnzbdOnfail.py` | Python | Watches the SABnzbd queue and fails stalled downloads so Sonarr retries them |
| `TwitchGamesAPIIntegration.ps1` | PowerShell | Sends a Windows notification when new streams start for games you follow |

## Media re-encoders

`CompressTVShows.py` and `compressMovies.py` shrink a video library by re-encoding it to HEVC (x265, CRF 22, preset `fast`). They replace each original once its converted copy checks out.

How they handle the messy parts:

- **Resume after a crash.** Each finished file is written to a CSV ledger and flushed to disk straight away, so a crash or reboot loses only the file in progress. Files already in the ledger at the same size are skipped on the next run.
- **Retry intermittent crashes.** x265 sometimes segfaults (exit code -11) on a file that converts fine on a second try. Those runs are retried up to 3 times with a pause between them. Any other error stops that show, and the script moves on to the next one.
- **Avoid known crash triggers.** Only the first video and audio streams are mapped, because files with 30+ subtitle tracks can crash ffmpeg. The probe size is raised for files with PGS subtitles. TrueHD/MLP audio is transcoded to AAC, because it can't be copied cleanly into MKV.
- **Replace safely.** The original is deleted only after the converted file exists and passes a size check, and the new file then takes the original's name.
- **Share the work between two machines.** The TV script works through shows from the end of the list, so a second machine can start from the top of the same library.

**Needs:** Python 3.8+, and `ffmpeg` and `ffprobe` with libx265 on your PATH.

**Set up:** at the top of the script, set

- `ROOT_DIR` to the library folder (one folder per show, or one folder per movie)
- `COMPLETED_CSV` to the full path of the ledger file, for example `/home/you/Logs/compressed.csv`

**Run:** `python3 CompressTVShows.py` or `python3 compressMovies.py`

> **Warning:** originals are replaced in place. Try it on a copy of a few files first.

## SABnzbd stall watchdog

`restartSabnzbdOnfail.py` keeps a SABnzbd download queue moving:

- It checks the queue through the SABnzbd API every 10 seconds.
- If the speed drops below 1 MB/s while items are queued, it makes SABnzbd drop its server connections so fresh ones open.
- If the same item stays stalled for 3 checks in a row, it pauses the job and deletes it with its files. SABnzbd then records a failed download, and Sonarr's failed-download handling grabs another copy.
- The tracker resets when the speed recovers or the queue empties.

**Needs:** Python 3, `requests` (`pip install requests`) and your SABnzbd API key.

**Set up:** set `HOST` (for example `"http://localhost"`), `PORT` (default `8080`) and `API_KEY` as quoted strings at the top of the file.

**Run:** `python3 restartSabnzbdOnfail.py`. It runs until you stop it.

## Twitch new-stream notifier

`TwitchGamesAPIIntegration.ps1` watches a list of games and tells you when someone starts streaming one:

- It reads game names from `Documents\TwitchDocs\GameList.txt`, one per line.
- On each pass it looks up every game in the Twitch Helix API, pages through live English-language streams, and picks out the ones that started in the last 10 minutes.
- It shows a Windows notification for streams it hasn't already reported.
- It gets an app access token through the OAuth client-credentials flow, and asks for your credentials again if Twitch rejects them.

**Credentials:** on first run the script asks for your Twitch client ID and secret. It stores them encrypted with Windows DPAPI in `Documents\APICredentials`, so only your Windows account on that PC can read them. Nothing is stored in the script.

**Needs:** Windows 10 or 11, Windows PowerShell 5.1 (the notification code uses Windows Runtime types), and a Twitch application's client ID and secret from the Twitch developer console.

**Run:** `powershell -File .\TwitchGamesAPIIntegration.ps1`
