# FileBot Media Automation for Windows

This package watches `I:\Pending Processing`, waits for media to stop changing and become exclusively readable, classifies each top-level file or folder, and sends it to FileBot. Movies go to `I:\Movies`; episodes go to `I:\TV Shows`; uncertain or repeatedly failing items go to `I:\Needs Review`.

Matching subtitle sidecars are processed in the same FileBot batch. For example, `Movie Name (2025).mkv`, `Movie Name (2025).srt`, and `Movie Name (2025).en.forced.srt` are passed together. Incoming folders are passed recursively, so all videos and subtitles in the release are handled as one batch.

## 1. Prerequisites

Install and license FileBot. Open PowerShell and confirm this works:

```powershell
filebot -version
```

If it does not, edit `FileBotPath` in `config.json` to the full path of `filebot.exe`.

## 2. Test safely

Put a representative movie and episode in the pending folder. From this package folder, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MediaWatcher.ps1 -Once -DryRun
```

Review the console and `logs` folder. A dry run does not move anything. Then perform one real pass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MediaWatcher.ps1 -Once
```

The default requires three unchanged scans, so a one-shot test of a new item must be run three times at least 20 seconds apart. Continuous mode handles this automatically:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\MediaWatcher.ps1
```

Stop it with Ctrl+C.

## 3. Start automatically with Windows

Run PowerShell as the same Windows user that owns the FileBot license, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-StartupTask.ps1
```

This creates a Scheduled Task that starts at logon, restarts after failures, and runs hidden. To remove it, run `Uninstall-StartupTask.ps1`.

## FileBot modes and presets

The default `InvocationMode` is `ExplicitCli`. It reproduces the requested behavior with current CLI options:

- Movie: `--db TheMovieDB --output "I:\Movies" --format "{plex}"`
- TV: `--db TheMovieDB::TV --output "I:\TV Shows" --format "{plex}"`
- Both use `--action move --conflict skip` and strict matching.

This corresponds to FileBot's standard Plex organization. Desktop presets and the CLI are separate by design, so preset names are not ordinary CLI arguments.

If the named desktop presets contain additional custom settings that must be preserved, set `InvocationMode` to `GuiPresetBridge`. The included `preset.groovy` uses FileBot's documented bridge technique to load `Organize Movies for Plex` or `Organize Episodes for Plex` from the desktop settings of the same Windows user. Test this mode with copies first. The bridge carries the preset's database, format, action, order, match mode, and language; the configured destination and conflict policy remain controlled by this automation.

## Classification and safety

TV evidence includes `S01E02`, `1x02`, season folders, episode/series wording, dated episodes, and multiple video files. Movie evidence includes a single title with a release year and common movie-release wording. A minimum confidence margin is required. Ambiguous items are never sent to FileBot; they go to `I:\Needs Review`.

The watcher ignores small/non-video files as primary items, waits for repeated identical size/timestamp snapshots across the video and matching subtitle sidecars, enforces a minimum age, and tests exclusive access before processing. `state\state.json` tracks stability, retry timing, completion, and errors. FileBot conflicts default to `skip`, preventing replacement of existing library files. Failures retry three times at 15-minute intervals and then move to review.

Useful configuration choices in `config.json`:

- Set `PlexFormat` to `{plex.id}` if you want TMDB IDs in Plex folder names.
- Set `NonStrict` to `true` only if strict matching rejects valid releases; it increases mismatch risk.
- Set `MoveUnknownToReview` to `false` to leave uncertain items in place.
- Adjust stability/age/retry values without changing the script.

## Operational notes

Mapped drive `I:` must be visible to the logged-on user. This is why the task runs at logon rather than as a system service. Do not point the watch folder inside either destination. Check `logs\media-YYYY-MM-DD.log` for every classification, FileBot result, retry, and review move.

