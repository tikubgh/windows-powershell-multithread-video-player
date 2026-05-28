# 1. Main Security Protocols
[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Url = Read-Host "`nPaste your Video URL here and press Enter"
$Url = $Url.Trim('"')

# 2. Strict Filename Extraction
try {
    # Strip tokens and grab the exact name from the URL
    $CleanUrl = $Url.Split('?')[0] 
    $uri = [System.Uri]$CleanUrl
    $FileName = [System.IO.Path]::GetFileName($uri.LocalPath)
    $FileName = [System.Uri]::UnescapeDataString($FileName)
    
    # Remove invalid Windows characters
    $FileName = $FileName -replace '[<>:"/\\|?*]', '' 
    
    # If the URL didn't have a valid video name, default to a standard name
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -notmatch "\.(mkv|mp4|ts|avi|webm)$") { 
        $FileName = "stream_video.mkv" 
    }
} catch { 
    $FileName = "stream_video.mkv" 
}

# 3. Setup Directories & Explicit Pathing
$BaseDir = Join-Path -Path $env:USERPROFILE -ChildPath "Downloads\PS_Stream"
$TempDir = Join-Path -Path $BaseDir -ChildPath "Chunks"
$OutFile = Join-Path -Path $BaseDir -ChildPath $FileName

if (!(Test-Path -LiteralPath $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
if (!(Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }

Write-Host "`n[SYSTEM] Pinging server for file metrics..."
try {
    $req = [System.Net.WebRequest]::Create($Url)
    $req.Method = "HEAD"
    $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    $res = $req.GetResponse()
    [long]$TotalBytes = $res.ContentLength
    $res.Close()
} catch {
    Write-Host "[ERROR] Server blocked request. Cannot build threads."
    pause; exit
}

[long]$ChunkSize = 5 * 1024 * 1024 
[long]$TotalChunks = [math]::Ceiling($TotalBytes / $ChunkSize)
$TotalMB = [math]::Round($TotalBytes / 1MB, 2)

Write-Host "`n=========================================================" -ForegroundColor Yellow
Write-Host " [SEARCHING DIRECTORY]: $BaseDir" -ForegroundColor Yellow
Write-Host " [TARGET FILENAME]    : $FileName" -ForegroundColor Yellow
Write-Host "=========================================================`n" -ForegroundColor Yellow

# 4. THE INTERACTIVE RESUME ENGINE
[long]$NextToDownload = 0
[long]$NextToAppend = 0

if (Test-Path -LiteralPath $OutFile) {
    Write-Host "`n=========================================================" -ForegroundColor Cyan
    Write-Host " [!] EXACT MATCH FOUND: $FileName ($TotalMB MB)" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    $Choice = Read-Host "Do you want to Resume this file or start Fresh? [Type 'R' for Resume / 'F' for Fresh]"
    
    if ($Choice -match "^[rR]") {
        Write-Host "`n[SYSTEM] Preparing to Resume..."
        $OutFileInfo = New-Object System.IO.FileInfo($OutFile)
        [long]$CurrentSize = $OutFileInfo.Length
        [long]$CompletedChunks = [math]::Floor($CurrentSize / $ChunkSize)
        [long]$SafeBytes = $CompletedChunks * $ChunkSize
        
        # Clean corrupted half-chunks
        if ($CurrentSize -gt $SafeBytes) {
            Write-Host "[SYSTEM] Cleaning up partial chunk data to align with 5MB sequence..."
            try {
                $fs = [System.IO.File]::Open($OutFile, 'Open', 'Write')
                $fs.SetLength($SafeBytes)
                $fs.Close()
            } catch {
                Write-Host "`n[ERROR] File is locked by your media player! Close MPV and restart."
                pause; exit
            }
        }
        
        $NextToDownload = $CompletedChunks
        $NextToAppend = $CompletedChunks
        Write-Host "[SYSTEM] RESUME SUCCESS! Locked onto Chunk $CompletedChunks ($([math]::Round($SafeBytes/1MB,2)) MB)..."
        
    } else {
        Write-Host "`n[SYSTEM] Deleting old file and starting fresh..."
        Remove-Item -LiteralPath $OutFile -Force
        if (Test-Path -LiteralPath $TempDir) { Remove-Item "$TempDir\*" -Force -Recurse -ErrorAction SilentlyContinue }
        [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0))
    }
} else {
    # FAIL-SAFE: Check if there are OTHER videos in the folder that the user might be trying to resume
    $ExistingVideos = Get-ChildItem -Path $BaseDir -File | Where-Object { $_.Name -match "\.(mkv|mp4|ts|avi|webm)$" }
    if ($ExistingVideos.Count -gt 0) {
        Write-Host "[WARNING] I did NOT find '$FileName'." -ForegroundColor Red
        Write-Host "However, I found these other half-downloaded files in the folder:" -ForegroundColor Red
        foreach ($vid in $ExistingVideos) {
            Write-Host "  -> $($vid.Name) ($([math]::Round($vid.Length/1MB, 2)) MB)" -ForegroundColor Red
        }
        Write-Host "`nIf you are trying to resume one of those, you MUST rename it to '$FileName' before continuing." -ForegroundColor Yellow
        $Proceed = Read-Host "Press Enter to start a fresh download of '$FileName', or close this window to rename your files"
    }

    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0))
    Write-Host "`n[SYSTEM] Starting fresh download..."
}

# Clean abandoned temp chunks from past crashes
Get-ChildItem -Path $TempDir -File | Where-Object { $_.Name -like "*.tmp" -or $_.Name -like "*.done" } | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "[SYSTEM] Engaging 10 Simultaneous Multi-Threads!`n"

# 5. Create a High-Performance Runspace Pool
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10)
$RunspacePool.Open()
$Jobs = @{}

$ScriptBlock = {
    param([long]$chunkId, [long]$startByte, [long]$endByte, $url, $tempDir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = 100
    
    $outFile = "$tempDir\$chunkId.tmp"
    $doneFile = "$tempDir\$chunkId.done"
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $req.AddRange($startByte, $endByte)
        $res = $req.GetResponse()
        $stream = $res.GetResponseStream()
        $fs = [System.IO.File]::Create($outFile)
        $stream.CopyTo($fs)
        $fs.Close(); $stream.Close(); $res.Close()
        
        [System.IO.File]::WriteAllText($doneFile, "OK")
    } catch { }
}

[Console]::CursorVisible = $false

$StartTime = Get-Date
$LastTime = Get-Date
[long]$LastBytes = $NextToAppend * $ChunkSize
[long]$HighestBytesTracked = $LastBytes
$CurrentSpeed = 0
$MpvLaunched = if ($NextToAppend -gt 6) { $true } else { $false }

# 6. The Main Engine Loop
while ($NextToAppend -lt $TotalChunks) {
    $Now = Get-Date
    
    while ($Jobs.Count -lt 10 -and $NextToDownload -lt $TotalChunks) {
        [long]$start = $NextToDownload * $ChunkSize
        [long]$end = $start + $ChunkSize - 1
        if ($end -ge $TotalBytes) { $end = $TotalBytes - 1 }

        $PowerShell = [powershell]::Create().AddScript($ScriptBlock).AddArgument($NextToDownload).AddArgument($start).AddArgument($end).AddArgument($Url).AddArgument($TempDir)
        $PowerShell.RunspacePool = $RunspacePool
        $Handle = $PowerShell.BeginInvoke()
        $Jobs[$NextToDownload] = [PSCustomObject]@{ PS = $PowerShell; Handle = $Handle }
        $NextToDownload++
    }

    $DonePath = "$TempDir\$NextToAppend.done"
    $TmpPath = "$TempDir\$NextToAppend.tmp"
    
    # Sequence Check & Antivirus Bypass
    if (Test-Path -LiteralPath $DonePath) {
        $in = $null; $out = $null
        try {
            $in = [System.IO.File]::OpenRead($TmpPath)
            $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $in.CopyTo($out)
            $in.Close(); $out.Close()
            
            Remove-Item -LiteralPath $TmpPath -Force -ErrorAction Stop
            Remove-Item -LiteralPath $DonePath -Force -ErrorAction SilentlyContinue
            
            if ($Jobs.ContainsKey($NextToAppend)) { 
                $Jobs[$NextToAppend].PS.Dispose()
                $Jobs.Remove($NextToAppend)
            }
            $NextToAppend++
        } catch {
            if ($null -ne $in) { $in.Close() }
            if ($null -ne $out) { $out.Close() }
        }
    } elseif ($Jobs.ContainsKey($NextToAppend) -and $Jobs[$NextToAppend].Handle.IsCompleted) {
        $Jobs[$NextToAppend].PS.Dispose()
        $Jobs.Remove($NextToAppend)
        $NextToDownload = $NextToAppend
        foreach ($k in $Jobs.Keys) { $Jobs[$k].PS.Stop(); $Jobs[$k].PS.Dispose() }
        $Jobs.Clear()
    }
    
    # 7. Glitch-Free Telemetry Tracker
    $OutFileInfo = New-Object System.IO.FileInfo($OutFile)
    $OutFileInfo.Refresh() 
    [long]$appendedBytes = if ($OutFileInfo.Exists) { $OutFileInfo.Length } else { 0 }
    
    [long]$tempBytes = 0
    foreach ($tmp in (Get-ChildItem -Path $TempDir -Filter "*.tmp" -ErrorAction SilentlyContinue)) {
        $TmpInfo = New-Object System.IO.FileInfo($tmp.FullName)
        $TmpInfo.Refresh()
        if ($TmpInfo.Exists) { $tempBytes += $TmpInfo.Length }
    }
    
    [long]$currentBytes = $appendedBytes + $tempBytes
    if ($currentBytes -gt $HighestBytesTracked) { $HighestBytesTracked = $currentBytes } else { $currentBytes = $HighestBytesTracked }

    $TimeSpan = ($Now - $LastTime).TotalSeconds
    if ($TimeSpan -ge 1) {
        [long]$BytesDiff = $currentBytes - $LastBytes
        if ($BytesDiff -ge 0) { $CurrentSpeed = [math]::Round(($BytesDiff / 1MB) / $TimeSpan, 1) }
        $LastTime = $Now
        $LastBytes = $currentBytes
    }

    $pct = [math]::Round(($currentBytes / $TotalBytes) * 100, 2)
    $downMB = [math]::Round($currentBytes / 1MB, 2)
    $activeThreads = $Jobs.Count

    # 8. MPV Auto-Launch Engine
    $SecondsPassed = ($Now - $StartTime).TotalSeconds
    $SecondsLeft = 30 - [math]::Floor($SecondsPassed)
    
    if (-not $MpvLaunched) {
        if ($SecondsPassed -ge 30 -or $currentBytes -ge $TotalBytes) {
            $MpvLaunched = $true
            try {
                Start-Process "mpv" -ArgumentList "`"$OutFile`" --vo=gpu --hwdec=auto" -WindowStyle Normal -ErrorAction SilentlyContinue
                $vlcStatus = "[MPV PLAYING]"
            } catch { $vlcStatus = "[MPV ERR]" }
        } else { $vlcStatus = "[LAUNCH IN: ${SecondsLeft}s]" }
    } else { $vlcStatus = "[MPV PLAYING]" }
    
    $uiString = "--> $vlcStatus PROG: $pct% | Size: $downMB / $TotalMB MB | Speed: $CurrentSpeed MB/s | Threads: $activeThreads/10"
    [Console]::Write("`r" + $uiString.PadRight(110))
    Start-Sleep -Milliseconds 100 
}

# 9. Final Cleanup
[Console]::CursorVisible = $true
$RunspacePool.Close()
$RunspacePool.Dispose()
if (Test-Path -LiteralPath $TempDir) { Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n`n[SYSTEM] Download 100% Complete! Temporary chunks deleted."
Write-Host "[SYSTEM] Final file saved to: $OutFile"
pause
