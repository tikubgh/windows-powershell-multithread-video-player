# 1. Main Security Protocols
[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Url = Read-Host "`nPaste your Video URL here and press Enter"
$Url = $Url.Trim('"')

# 2. Setup Directories & Lock Filename
$BaseDir = "$env:USERPROFILE\Downloads\PS_Stream"
$TempDir = "$BaseDir\Chunks"

if (!(Test-Path $BaseDir)) { New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null }
if (!(Test-Path $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }

Write-Host "`n[SYSTEM] Pinging server for exact file size..."
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

Write-Host "[SYSTEM] Total File Size: $TotalMB MB"

# 3. BULLETPROOF RESUME ENGINE
[long]$NextToDownload = 0
[long]$NextToAppend = 0

# Extract just the extension from the URL and lock the filename to "video.EXT"
$uri = [System.Uri]$Url
$Ext = [System.IO.Path]::GetExtension($uri.LocalPath)
if ([string]::IsNullOrWhiteSpace($Ext) -or $Ext -notmatch "^\.[a-zA-Z0-9]+$") { $Ext = ".mkv" }
$FileName = "video$Ext"
$OutFile = "$BaseDir\$FileName"

if (Test-Path $OutFile) {
    Write-Host "[SYSTEM] Found existing file: $FileName."
    
    $OutFileInfo = New-Object System.IO.FileInfo($OutFile)
    [long]$CurrentSize = $OutFileInfo.Length
    [long]$CompletedChunks = [math]::Floor($CurrentSize / $ChunkSize)
    [long]$SafeBytes = $CompletedChunks * $ChunkSize
    
    # If the file was corrupted mid-glue, cleanly slice it back to the last safe 5MB chunk
    if ($CurrentSize -gt $SafeBytes) {
        Write-Host "[SYSTEM] Cleaning up partial chunk data to align with 5MB sequence..."
        try {
            $fs = [System.IO.File]::Open($OutFile, 'Open', 'Write')
            $fs.SetLength($SafeBytes)
            $fs.Close()
        } catch {
            Write-Host "`n[ERROR] File is locked by your media player!"
            Write-Host "Please close MPV/VLC and restart the script to resume."
            pause; exit
        }
    }
    
    $NextToDownload = $CompletedChunks
    $NextToAppend = $CompletedChunks
    
    if ($CompletedChunks -gt 0) {
        Write-Host "[SYSTEM] RESUME SUCCESS! Resuming from Chunk $CompletedChunks ($([math]::Round($SafeBytes/1MB,2)) MB)..."
    } else {
        Write-Host "[SYSTEM] File was smaller than 5MB. Restarting the first block..."
    }
} else {
    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0))
    Write-Host "[SYSTEM] Starting fresh download: $FileName"
}

# Wipe any ghost/abandoned temp files from previous closed sessions
if (Test-Path $TempDir) { Remove-Item "$TempDir\*" -Force -Recurse -ErrorAction SilentlyContinue }

Write-Host "[SYSTEM] Engaging 10 Simultaneous Multi-Threads!`n"

# 4. Create a High-Performance Runspace Pool
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10)
$RunspacePool.Open()
$Jobs = @{}

# The Background Thread (Signal File Architecture)
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

# Timers & Trackers
$StartTime = Get-Date
$LastTime = Get-Date
[long]$LastBytes = $NextToAppend * $ChunkSize
[long]$HighestBytesTracked = $LastBytes
$CurrentSpeed = 0
$MpvLaunched = $false

# 5. The Main Engine Loop
while ($NextToAppend -lt $TotalChunks) {
    $Now = Get-Date
    
    # Fire up to 10 connections
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

    # 6. The Rock-Solid "Signal File" Sequence Check
    $DonePath = "$TempDir\$NextToAppend.done"
    $TmpPath = "$TempDir\$NextToAppend.tmp"
    
    if (Test-Path $DonePath) {
        $in = [System.IO.File]::OpenRead($TmpPath)
        $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $in.CopyTo($out)
        $in.Close(); $out.Close()
        
        Remove-Item $TmpPath -Force
        Remove-Item $DonePath -Force
        if ($Jobs.ContainsKey($NextToAppend)) { 
            $Jobs[$NextToAppend].PS.Dispose()
            $Jobs.Remove($NextToAppend)
        }
        $NextToAppend++
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
    
    if ($currentBytes -gt $HighestBytesTracked) { $HighestBytesTracked = $currentBytes }
    else { $currentBytes = $HighestBytesTracked }

    $TimeSpan = ($Now - $LastTime).TotalSeconds
    if ($TimeSpan -ge 1) {
        [long]$BytesDiff = $currentBytes - $LastBytes
        if ($BytesDiff -ge 0) {
            $CurrentSpeed = [math]::Round(($BytesDiff / 1MB) / $TimeSpan, 1)
        }
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
        } else {
            $vlcStatus = "[LAUNCH IN: ${SecondsLeft}s]"
        }
    } else {
        $vlcStatus = "[MPV PLAYING]"
    }
    
    $uiString = "--> $vlcStatus PROG: $pct% | Size: $downMB / $TotalMB MB | Speed: $CurrentSpeed MB/s | Threads: $activeThreads/10"
    [Console]::Write("`r" + $uiString.PadRight(110))
    
    Start-Sleep -Milliseconds 100 
}

# 9. Final Cleanup
[Console]::CursorVisible = $true
$RunspacePool.Close()
$RunspacePool.Dispose()
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n`n[SYSTEM] Download 100% Complete! Temporary chunks deleted."
Write-Host "[SYSTEM] Final file saved to: $OutFile"
pause
