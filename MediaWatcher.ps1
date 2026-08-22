[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:Root 'config.json'
}
$script:LogDir = Join-Path $script:Root 'logs'
$script:StateDir = Join-Path $script:Root 'state'
$script:StatePath = Join-Path $script:StateDir 'state.json'
New-Item -ItemType Directory -Force -Path $script:LogDir, $script:StateDir | Out-Null

function Write-Log([string]$Message, [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO') {
    $line = '{0:o} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath (Join-Path $script:LogDir ('media-{0:yyyy-MM-dd}.log' -f (Get-Date))) -Value $line -Encoding utf8
    Write-Host $line
}

function Read-State {
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $raw = Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json
            $items = @{}
            if ($null -ne $raw.Items) {
                foreach ($property in $raw.Items.PSObject.Properties) {
                    $entry = @{}
                    foreach ($field in $property.Value.PSObject.Properties) { $entry[$field.Name] = $field.Value }
                    $items[$property.Name] = $entry
                }
            }
            return @{ Items = $items }
        }
        catch { Write-Log "State file was unreadable; starting with empty state: $_" WARN }
    }
    return @{ Items = @{} }
}

function Save-State([hashtable]$State) {
    $temp = "$($script:StatePath).new"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -Force -LiteralPath $temp -Destination $script:StatePath
}

function Get-VideoFiles([string]$Path, $Config) {
    $allowed = @($Config.VideoExtensions | ForEach-Object { $_.ToLowerInvariant() })
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $files = @(Get-Item -LiteralPath $Path) }
    else { $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue) }
    return @($files | Where-Object { $allowed -contains $_.Extension.ToLowerInvariant() -and $_.Length -ge [long]$Config.MinimumVideoBytes })
}

function Get-BatchFiles([string]$Path, $VideoFiles) {
    if (Test-Path -LiteralPath $Path -PathType Container) { return @($VideoFiles) }
    $video = Get-Item -LiteralPath $Path
    $escapedBase = [regex]::Escape($video.BaseName)
    $sidecars = @(Get-ChildItem -LiteralPath $video.DirectoryName -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -match '^(?i)\.(srt|sub|idx|ass|ssa|vtt)$' -and $_.BaseName -match "(?i)^$escapedBase(?:\.|$)"
    })
    return @($video) + $sidecars
}

function Get-Snapshot([string]$Path, $Config) {
    $files = Get-VideoFiles $Path $Config
    if ($files.Count -eq 0) { return $null }
    $batchFiles = Get-BatchFiles $Path $files
    $bytes = [long](($batchFiles | Measure-Object Length -Sum).Sum)
    $latest = ($batchFiles | Measure-Object LastWriteTimeUtc -Maximum).Maximum
    [pscustomobject]@{ Signature = "$($batchFiles.Count)|$bytes|$($latest.Ticks)"; LatestWriteUtc = $latest; Files = $files; BatchFiles = $batchFiles }
}

function Test-Unlocked($Files) {
    foreach ($file in $Files) {
        try {
            $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
            $stream.Dispose()
        } catch { return $false }
    }
    return $true
}

function Get-MediaClass([string]$Path, $Files) {
    $itemName = Split-Path -Leaf $Path
    $mediaNames = if (Test-Path -LiteralPath $Path -PathType Container) { @($Files | ForEach-Object { $_.FullName.Substring($Path.Length) }) } else { @($Files | ForEach-Object Name) }
    $text = (($itemName + ' ' + ($mediaNames -join ' ')) -replace '[._-]', ' ')
    $tv = 0; $movie = 0; $why = [System.Collections.Generic.List[string]]::new()
    $tvRules = @(
        @{ P='(?i)\bS\d{1,2}E\d{1,3}(?:E\d{1,3})?\b'; W=7; N='SxxExx episode marker' },
        @{ P='(?i)\b\d{1,2}x\d{1,3}\b'; W=7; N='1x01 episode marker' },
        @{ P='(?i)\bSeason\s*\d{1,2}\b'; W=5; N='season folder/name' },
        @{ P='(?i)\b(?:complete\s+)?series\b|\bepisodes?\b'; W=3; N='series/episode wording' },
        @{ P='(?i)\b(?:19|20)\d{2}[. -]\d{2}[. -]\d{2}\b'; W=5; N='dated episode marker' }
    )
    foreach ($rule in $tvRules) { if ($text -match $rule.P) { $tv += $rule.W; $why.Add($rule.N) } }
    if ($Files.Count -ge 3) { $tv += 4; $why.Add('multiple video files') }
    elseif ($Files.Count -eq 1 -and $Files[0].BaseName -match '(?i)(?:^|[ ._(])(?:19|20)\d{2}(?:[ ._)\[]|$)') { $movie += 4; $why.Add('single title with release year') }
    if ($text -match '(?i)\b(movie|film|bluray|bdrip|remux)\b') { $movie += 2; $why.Add('movie/release wording') }
    if ($tv -ge 5 -and $tv -ge ($movie + 2)) { return @{ Type='TV'; Score=$tv; Reason=($why -join ', ') } }
    if ($movie -ge 4 -and $movie -ge ($tv + 2)) { return @{ Type='Movie'; Score=$movie; Reason=($why -join ', ') } }
    $reason = if ($why.Count) { $why -join ', ' } else { 'no strong filename or folder indicators' }
    return @{ Type='Unknown'; Score=[Math]::Max($tv,$movie); Reason=$reason }
}

function Move-ToReview([string]$Path, $Config) {
    New-Item -ItemType Directory -Force -Path $Config.ReviewDestination | Out-Null
    $name = Split-Path -Leaf $Path
    $target = Join-Path $Config.ReviewDestination $name
    if (Test-Path -LiteralPath $target) { $target = Join-Path $Config.ReviewDestination ('{0}_{1:yyyyMMdd-HHmmss}' -f $name,(Get-Date)) }
    if ($DryRun) { Write-Log "DRY RUN: would move unknown item to $target"; return }
    Move-Item -LiteralPath $Path -Destination $target
    Write-Log "Moved unknown item to review: $target" WARN
}

function Invoke-FileBot([string]$Path, $BatchFiles, [string]$Type, $Config) {
    $destination = if ($Type -eq 'TV') { $Config.TvDestination } else { $Config.MovieDestination }
    $database = if ($Type -eq 'TV') { 'TheMovieDB::TV' } else { 'TheMovieDB' }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    if ($Config.InvocationMode -eq 'GuiPresetBridge') {
        $preset = if ($Type -eq 'TV') { $Config.TvPresetName } else { $Config.MoviePresetName }
        $inputs = if (Test-Path -LiteralPath $Path -PathType Container) { @($Path) } else { @($BatchFiles | ForEach-Object FullName) }
        $args = @('-script',(Join-Path $script:Root 'preset.groovy')) + $inputs + @('--def',"name=$preset","output=$destination","conflict=$($Config.ConflictPolicy)")
    } else {
        $inputs = if (Test-Path -LiteralPath $Path -PathType Container) { @($Path) } else { @($BatchFiles | ForEach-Object FullName) }
        $args = @('-rename') + $inputs
        if (Test-Path -LiteralPath $Path -PathType Container) { $args += '-r' }
        $args += @('--db',$database,'--action',$Config.Action,'--conflict',$Config.ConflictPolicy,'--output',$destination,'--format',$Config.PlexFormat)
        if ([bool]$Config.NonStrict) { $args += '-non-strict' }
    }
    if ($DryRun) { Write-Log "DRY RUN: $($Config.FileBotPath) $($args -join ' ')"; return 0 }
    Write-Log "Starting FileBot for $Type item: $Path"
    $output = & $Config.FileBotPath @args 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in ($output -split "`r?`n")) { if ($line) { Write-Log "FileBot: $line" } }
    if ($code -ne 0) { throw "FileBot exited with code $code" }
    return $code
}

$config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
foreach ($folder in @($config.WatchFolder,$config.MovieDestination,$config.TvDestination,$config.ReviewDestination)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
$state = Read-State
if (-not $state.ContainsKey('Items')) { $state.Items = @{} }
Write-Log "Watcher started for $($config.WatchFolder); mode=$($config.InvocationMode); once=$Once; dryRun=$DryRun"

do {
    $top = @(Get-ChildItem -LiteralPath $config.WatchFolder -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.PSIsContainer -or ($config.VideoExtensions -contains $_.Extension.ToLowerInvariant())
    })
    foreach ($item in $top) {
        $path = $item.FullName
        $key = $path.ToLowerInvariant()
        $snapshot = Get-Snapshot $path $config
        if ($null -eq $snapshot) { continue }
        if (-not $state.Items.ContainsKey($key)) { $state.Items[$key] = @{ Signature=''; StableCount=0; Retries=0; NextRetryUtc=''; Status='Waiting' } }
        $entry = $state.Items[$key]
        if ($entry.Signature -eq $snapshot.Signature) { $entry.StableCount = [int]$entry.StableCount + 1 } else { $entry.Signature=$snapshot.Signature; $entry.StableCount=1 }
        if (([datetime]::UtcNow - $snapshot.LatestWriteUtc).TotalSeconds -lt [int]$config.MinimumAgeSeconds) { continue }
        if ([int]$entry.StableCount -lt [int]$config.StableChecksRequired -or -not (Test-Unlocked $snapshot.BatchFiles)) { continue }
        if ($entry.NextRetryUtc -and [datetime]::Parse($entry.NextRetryUtc) -gt [datetime]::UtcNow) { continue }
        $class = Get-MediaClass $path $snapshot.Files
        Write-Log "Classified '$path' as $($class.Type) (score $($class.Score): $($class.Reason))"
        try {
            if ($class.Type -eq 'Unknown') {
                if ([bool]$config.MoveUnknownToReview) { Move-ToReview $path $config }
                $entry.Status='Review'; $entry.CompletedUtc=[datetime]::UtcNow.ToString('o')
            } else {
                Invoke-FileBot $path $snapshot.BatchFiles $class.Type $config | Out-Null
                $entry.Status='Completed'; $entry.CompletedUtc=[datetime]::UtcNow.ToString('o')
            }
        } catch {
            $entry.Retries = [int]$entry.Retries + 1
            $entry.Status='Failed'; $entry.LastError="$_."; $entry.NextRetryUtc=[datetime]::UtcNow.AddMinutes([int]$config.RetryDelayMinutes).ToString('o')
            Write-Log "Processing failed ($($entry.Retries)/$($config.MaxRetries)) for '$path': $_" ERROR
            if ([int]$entry.Retries -ge [int]$config.MaxRetries -and [bool]$config.MoveUnknownToReview) { Move-ToReview $path $config; $entry.Status='ReviewAfterFailure' }
        }
        Save-State $state
    }
    Save-State $state
    if (-not $Once) { Start-Sleep -Seconds ([int]$config.ScanIntervalSeconds) }
} while (-not $Once)


