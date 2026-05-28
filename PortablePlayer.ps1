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
    $TotalBytes = $res.ContentLength
    $res.Close()
} catch {
    Write-Host "[ERROR] Server blocked request. Cannot build threads."
    pause; exit
}

$ChunkSize = 5 * 1024 * 1024 # 5MB pieces
$TotalChunks = [math]::Ceiling($TotalBytes / $ChunkSize)
$TotalMB = [math]::Round($TotalBytes / 1MB, 2)

Write-Host "[SYSTEM] Original Filename Detected: $FileName"
Write-Host "[SYSTEM] Total File Size: $TotalMB MB"

# 4. CRITICAL UPGRADE: True Resume Support
$NextToDownload = 0
$NextToAppend = 0

if (Test-Path $OutFile) {
    $CurrentSize = (Get-Item $OutFile).Length
    $CompletedChunks = [math]::Floor($CurrentSize / $ChunkSize)
    $SafeBytes = $CompletedChunks * $ChunkSize
    
    # Clean up any corruption if the script was closed mid-glue
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

# Clean abandoned temp files from previous sessions
if (Test-Path $TempDir) { Remove-Item "$TempDir\*" -Force -Recurse -ErrorAction SilentlyContinue }

Write-Host "[SYSTEM] Engaging 10 Simultaneous Multi-Threads!`n"

# 5. Create a High-Performance Runspace Pool
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10)
$RunspacePool.Open()
$Jobs = @{}

# The Background Thread 
$ScriptBlock = {
    param($chunkId, $startByte, $endByte, $url, $tempDir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = 100
    
    $outFile = "$tempDir\$chunkId.tmp"
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $req.AddRange($startByte, $endByte)
        $res = $req.GetResponse()
        $stream = $res.GetResponseStream()
        $fs = [System.IO.File]::Create($outFile)
        $stream.CopyTo($fs)
        $fs.Close(); $stream.Close(); $res.Close()
        return $chunkId
    } catch { return "ERROR: $_" }
}

[Console]::CursorVisible = $false

# Timers & Trackers for Glitch-Free Speedometer
$StartTime = Get-Date
$LastTime = Get-Date
$LastBytes = $NextToAppend * $ChunkSize
$HighestBytesTracked = $LastBytes
$CurrentSpeed = 0
$MpvLaunched = if ($NextToAppend -gt 6) { $true } else { $false } # Don't auto-launch if we are resuming a nearly finished file

# 6. The Main Engine Loop
while ($NextToAppend -lt $TotalChunks) {
    $Now = Get-Date
    
    # Fire up to 10 connections
    while ($Jobs.Count -lt 10 -and $NextToDownload -lt $TotalChunks) {
        $start = $NextToDownload * $ChunkSize
        $end = $start + $ChunkSize - 1
        if ($end -ge $TotalBytes) { $end = $TotalBytes - 1 }

        $PowerShell = [powershell]::Create().AddScript($ScriptBlock).AddArgument($NextToDownload).AddArgument($start).AddArgument($end).AddArgument($Url).AddArgument($TempDir)
        $PowerShell.RunspacePool = $RunspacePool
        $Handle = $PowerShell.BeginInvoke()
        $Jobs[$NextToDownload] = [PSCustomObject]@{ PS = $PowerShell; Handle = $Handle }
        $NextToDownload++
    }

    # Sequence Check & File Glue
    if ($Jobs.ContainsKey($NextToAppend)) {
        $job = $Jobs[$NextToAppend]
        if ($job.Handle.IsCompleted) {
            $rawData = $job.PS.EndInvoke($job.Handle)
            $result = "$rawData" 
            $job.PS.Dispose()
            $Jobs.Remove($NextToAppend)

            if ($result -eq "$NextToAppend") {
                $tmpFile = "$TempDir\$NextToAppend.tmp"
                if (Test-Path $tmpFile) {
                    $in = [System.IO.File]::OpenRead($tmpFile)
                    $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                    $in.CopyTo($out)
                    $in.Close(); $out.Close()
                    Remove-Item $tmpFile -Force
                }
                $NextToAppend++
            } else {
                Write-Host "`n[WARNING] Thread crashed. Retrying block... (Error: $result)"
                $NextToDownload = $NextToAppend
                foreach ($k in $Jobs.Keys) { $Jobs[$k].PS.Stop(); $Jobs[$k].PS.Dispose() }
                $Jobs.Clear()
            }
        }
    }
    
    # 7. CRITICAL UPGRADE: Glitch-Free Telemetry Tracker
    $appendedBytes = if (Test-Path $OutFile) { (Get-Item $OutFile).Length } else { 0 }
    $tempBytes = 0
    foreach ($tmp in (Get-ChildItem -Path $TempDir -Filter "*.tmp" -ErrorAction SilentlyContinue)) {
        try { $tempBytes += $tmp.Length } catch {} # Ignores locked files safely
    }
    
    $currentBytes = $appendedBytes + $tempBytes
    
    # Prevents the "bouncing bytes" UI glitch during file transfers
    if ($currentBytes -gt $HighestBytesTracked) { $HighestBytesTracked = $currentBytes }
    else { $currentBytes = $HighestBytesTracked }

    # Calculate MB/s every 1 second perfectly
    $TimeSpan = ($Now - $LastTime).TotalSeconds
    if ($TimeSpan -ge 1) {
        $BytesDiff = $currentBytes - $LastBytes
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
