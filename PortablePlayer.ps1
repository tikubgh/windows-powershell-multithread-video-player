# 1. Main Security Protocols
[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Url = Read-Host "`nPaste your Video URL here and press Enter"
$Url = $Url.Trim('"')

# 2. Dynamic Filename Extractor
try {
    $uri = [System.Uri]$Url
    $FileName = [System.IO.Path]::GetFileName($uri.LocalPath)
    $FileName = [System.Uri]::UnescapeDataString($FileName)
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -notmatch "\.") { $FileName = "stream_video.mkv" }
    $FileName = $FileName -replace '[<>:"/\\|?*]', '' 
} catch { 
    $FileName = "stream_video.mkv" 
}

# 3. Setup Clean Directories
$BaseDir = "$env:USERPROFILE\Downloads\PS_Stream"
$TempDir = "$BaseDir\Chunks"
$OutFile = "$BaseDir\$FileName"

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

# CRITICAL FIX: Explicit [long] 64-bit math prevents crashes on files larger than 2GB
[long]$ChunkSize = 5 * 1024 * 1024 
[long]$TotalChunks = [math]::Ceiling($TotalBytes / $ChunkSize)
$TotalMB = [math]::Round($TotalBytes / 1MB, 2)

Write-Host "[SYSTEM] Original Filename Detected: $FileName"
Write-Host "[SYSTEM] Total File Size: $TotalMB MB"

# 4. BULLETPROOF RESUME ENGINE
[long]$NextToDownload = 0
[long]$NextToAppend = 0

if (Test-Path $OutFile) {
    $OutFileInfo = New-Object System.IO.FileInfo($OutFile)
    [long]$CurrentSize = $OutFileInfo.Length
    [long]$CompletedChunks = [math]::Floor($CurrentSize / $ChunkSize)
    [long]$SafeBytes = $CompletedChunks * $ChunkSize
    
    # If the file was corrupted mid-glue, cleanly slice it back to the last safe 5MB chunk
    if ($CurrentSize -gt $SafeBytes) {
        $fs = [System.IO.File]::Open($OutFile, 'Open', 'Write')
        $fs.SetLength($SafeBytes)
        $fs.Close()
    }
    
    $NextToDownload = $CompletedChunks
    $NextToAppend = $CompletedChunks
    Write-Host "[SYSTEM] RESUME DETECTED! Resuming from Chunk $CompletedChunks ($([math]::Round($SafeBytes/1MB,2)) MB)"
} else {
    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0))
    Write-Host "[SYSTEM] Starting fresh download..."
}

# Wipe any ghost/abandoned temp files from previous closed sessions
if (Test-Path $TempDir) { Remove-Item "$TempDir\*" -Force -Recurse -ErrorAction SilentlyContinue }

Write-Host "[SYSTEM] Engaging 10 Simultaneous Multi-Threads!`n"

# 5. Create a High-Performance Runspace Pool
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10)
$RunspacePool.Open()
$Jobs = @{}

# The Background Thread (CRITICAL FIX: Signal File Architecture)
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
        
        # Create a physically verifiable '.done' file to signal success
        [System.IO.File]::WriteAllText($doneFile, "OK")
    } catch { }
}

[Console]::CursorVisible = $false

# Timers & Trackers for Glitch-Free Speedometer
$StartTime = Get-Date
$LastTime = Get-Date
[long]$LastBytes = $NextToAppend * $ChunkSize
[long]$HighestBytesTracked = $LastBytes
$CurrentSpeed = 0
$MpvLaunched = if ($NextToAppend -gt 6) { $true } else { $false }

# 6. The Main Engine Loop
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

    # 7. The Rock-Solid "Signal File" Sequence Check
    $DonePath = "$TempDir\$NextToAppend.done"
    $TmpPath = "$TempDir\$NextToAppend.tmp"
    
    if (Test-Path $DonePath) {
        # The physical file exists, meaning it is 100% safely downloaded
        $in = [System.IO.File]::OpenRead($TmpPath)
        $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $in.CopyTo($out)
        $in.Close(); $out.Close()
        
        # Cleanup and move forward
        Remove-Item $TmpPath -Force
        Remove-Item $DonePath -Force
        if ($Jobs.ContainsKey($NextToAppend)) { 
            $Jobs[$NextToAppend].PS.Dispose()
            $Jobs.Remove($NextToAppend)
        }
        $NextToAppend++
    } elseif ($Jobs.ContainsKey($NextToAppend) -and $Jobs[$NextToAppend].Handle.IsCompleted) {
        # If the thread exited but the '.done' file is missing, it crashed! Restart it.
        $Jobs[$NextToAppend].PS.Dispose()
        $Jobs.Remove($NextToAppend)
        $NextToDownload = $NextToAppend
        foreach ($k in $Jobs.Keys) { $Jobs[$k].PS.Stop(); $Jobs[$k].PS.Dispose() }
        $Jobs.Clear()
    }
    
    # 8. Glitch-Free Telemetry Tracker
    $OutFileInfo = New-Object System.IO.FileInfo($OutFile)
    $OutFileInfo.Refresh() # Forces Windows to ignore its cache and give us the real size
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

    # Calculate precise MB/s
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

    # 9. MPV Auto-Launch Engine
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

# 10. Final Cleanup
[Console]::CursorVisible = $true
$RunspacePool.Close()
$RunspacePool.Dispose()
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n`n[SYSTEM] Download 100% Complete! Temporary chunks deleted."
Write-Host "[SYSTEM] Final file saved to: $OutFile"
pause
