[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Url = (Read-Host "`nPaste Video URL").Trim('"')

$BaseDir = "$env:USERPROFILE\Downloads\PS_Stream"; $TempDir = "$BaseDir\Chunks"
if (!(Test-Path $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }

Write-Host "`n[NETWORK] Tricking server to extract true IDM headers & final redirects..." -ForegroundColor DarkGray
try {
    # The 1-Byte Trick: Use GET instead of HEAD to bypass cloud provider blocks
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "GET" 
    $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    $req.AddRange(0, 0) 
    $res = $req.GetResponse()

    # Determine True File Size
    if ($res.StatusCode -eq 206 -and $res.Headers["Content-Range"] -match "/(\d+)$") {
        [long]$TotalBytes = $matches[1]
    } else {
        [long]$TotalBytes = $res.ContentLength
    }

    # -----------------------------------------------------------
    # ULTIMATE 4-TIER FILENAME EXTRACTOR
    # -----------------------------------------------------------
    $cd = $res.Headers["Content-Disposition"]
    $FileName = ""

    # Tier 1: IDM Header Extraction (Standard & UTF-8 encoded)
    if (-not [string]::IsNullOrWhiteSpace($cd)) {
        if ($cd -match "filename\*\s*=\s*UTF-8''([^;]+)") { $FileName = [System.Uri]::UnescapeDataString($matches[1]) }
        elseif ($cd -match 'filename\s*=\s*"([^"]+)"') { $FileName = $matches[1] }
        elseif ($cd -match 'filename\s*=\s*([^;]+)') { $FileName = $matches[1] }
    }

    # Tier 2: The Redirect Tracer (Catches the final hidden PikPak CDN path)
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -eq "") {
        $FinalUrl = $res.ResponseUri.LocalPath
        $FileName = [System.IO.Path]::GetFileName([System.Uri]::UnescapeDataString($FinalUrl))
    }

    # Tier 3: Query Parameter Sniffer (Checks for hidden tags like &name=Movie.mkv)
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -eq "") {
        $Query = $res.ResponseUri.Query
        if ($Query -match "name=([^&]+)") { $FileName = [System.Uri]::UnescapeDataString($matches[1]) }
        elseif ($Query -match "file=([^&]+)") { $FileName = [System.Uri]::UnescapeDataString($matches[1]) }
    }

    # Tier 4: Base Fallback (Strip raw URL)
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -eq "") {
        $FileName = [System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName(([System.Uri]($Url.Split('?')[0])).LocalPath))
    }

    # Final Cleanup & Sanitization
    $FileName = $FileName -replace '[<>:"/\\|?*]', ''
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -notmatch "\.") { 
        $FileName = "cloud_video.mkv" 
    }
    
    $res.Close()
} catch { Write-Host "[ERROR] Server blocked request. Ensure the link hasn't expired."; pause; exit }

[long]$ChunkSize = 5 * 1024 * 1024; [long]$TotalChunks = [math]::Ceiling($TotalBytes / $ChunkSize)
$TotalMB = [math]::Round($TotalBytes / 1MB, 2)
Write-Host "[NETWORK] Target File Identified: $FileName ($TotalMB MB)" -ForegroundColor White

[long]$NextToDownload = 0; [long]$NextToAppend = 0; $OutFile = "$BaseDir\$FileName"; $TargetFile = $null

Write-Host "[LOCAL] Checking disk for resume capabilities..." -ForegroundColor DarkGray
if (Test-Path $OutFile) {
    if ((Read-Host "`n[!] FOUND: $FileName. Resume (R) or Fresh (F)? [R/F]") -match "^[rR]") { $TargetFile = Get-Item $OutFile }
    else { Remove-Item $OutFile -Force }
} else {
    $OtherVids = @(Get-ChildItem $BaseDir -File | Where-Object { $_.Name -match "\.(mkv|mp4|ts|avi|webm)$" })
    if ($OtherVids.Count -gt 0) {
        Write-Host "`n[?] '$FileName' missing, but other downloads exist:" -ForegroundColor Yellow
        for ($i=0; $i -lt $OtherVids.Count; $i++) { Write-Host " [$($i+1)] $($OtherVids[$i].Name)" }
        $Choice = Read-Host "Type number to resume, or 'F' for fresh"
        if ($Choice -match "^\d+$" -and [int]$Choice -ge 1 -and [int]$Choice -le $OtherVids.Count) { 
            $TargetFile = $OtherVids[[int]$Choice - 1]; $OutFile = $TargetFile.FullName; $FileName = $TargetFile.Name 
        }
    }
}

if ($TargetFile) {
    $OutInfo = New-Object System.IO.FileInfo($OutFile); [long]$CurSize = $OutInfo.Length
    [long]$CompChunks = [math]::Floor($CurSize / $ChunkSize); [long]$SafeBytes = $CompChunks * $ChunkSize
    if ($CurSize -gt $SafeBytes) {
        try { $fs = [System.IO.File]::Open($OutFile, 'Open', 'Write'); $fs.SetLength($SafeBytes); $fs.Close() } catch { Write-Host "`n[ERROR] Locked by player!"; pause; exit }
    }
    $NextToDownload = $CompChunks; $NextToAppend = $CompChunks
    Write-Host "[LOCAL] Resuming from $([math]::Round($SafeBytes/1MB,2)) MB mark." -ForegroundColor Green
} else {
    if (Test-Path "$TempDir\*") { Remove-Item "$TempDir\*" -Force -Recurse }
    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0)); Write-Host "[LOCAL] Fresh download sequence initiated." -ForegroundColor Green
}

Get-ChildItem $TempDir -File | Where-Object { $_.Name -match "\.(tmp|done)$" } | Remove-Item -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------
# THE "SLOW-START" ADDITIVE ENGINE
# -----------------------------------------------------------
$CurrentLimit = 1; $ThreadLocked = $false; $FailedChunks = New-Object System.Collections.Generic.List[long]
Write-Host "`n[ENGINE] Starting with 1 Thread. Additive scaling initialized..." -ForegroundColor Magenta

$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10); $RunspacePool.Open(); $Jobs = @{}
$ScriptBlock = {
    param([long]$id, [long]$start, [long]$end, $url, $temp)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; [Net.ServicePointManager]::DefaultConnectionLimit = 100
    try {
        $req = [System.Net.HttpWebRequest]::Create($url); $req.UserAgent = "Mozilla/5.0"; $req.AddRange($start, $end)
        $res = $req.GetResponse(); $stream = $res.GetResponseStream(); $fs = [System.IO.File]::Create("$temp\$id.tmp")
        $stream.CopyTo($fs); $fs.Close(); $stream.Close(); $res.Close(); [System.IO.File]::WriteAllText("$temp\$id.done", "OK")
    } catch { } 
}

[Console]::CursorVisible = $false; $StartTime = Get-Date; $LastRampUp = Get-Date; $LastTime = Get-Date
[long]$HighestBytesTracked = $NextToAppend * $ChunkSize; [long]$LastBytes = $HighestBytesTracked
$CurrentSpeed = 0; $MpvLaunched = $false

while ($NextToAppend -lt $TotalChunks) {
    $Now = Get-Date
    
    if (-not $ThreadLocked -and $CurrentLimit -lt 10 -and ($Now - $LastRampUp).TotalSeconds -ge 2) {
        $CurrentLimit++; $LastRampUp = $Now
    }

    $CompletedKeys = @()
    foreach ($k in $Jobs.Keys) { if ($Jobs[$k] -and $Jobs[$k].Handle.IsCompleted) { $CompletedKeys += $k } }
    
    foreach ($k in $CompletedKeys) {
        $job = $Jobs[$k]; $Jobs.Remove($k)
        if ($null -ne $job -and $null -ne $job.PS) { try { $job.PS.Dispose() } catch {} }
        
        if ($k -ge $NextToAppend -and -not (Test-Path "$TempDir\$k.done")) {
            if (-not $FailedChunks.Contains($k)) { $FailedChunks.Add($k) }
            if (-not $ThreadLocked) {
                $ThreadLocked = $true; $CurrentLimit = if ($Jobs.Count -gt 0) { $Jobs.Count } else { 1 }
                Write-Host "`n[NETWORK] Connection drop detected. Locking limit perfectly to $CurrentLimit threads." -ForegroundColor Yellow
            }
        }
    }

    while ($Jobs.Count -lt $CurrentLimit -and ($NextToDownload -lt $TotalChunks -or $FailedChunks.Count -gt 0)) {
        if ($FailedChunks.Count -gt 0) { [long]$cId = $FailedChunks[0]; $FailedChunks.RemoveAt(0) } 
        else { [long]$cId = $NextToDownload; $NextToDownload++ }
        
        if (-not $Jobs.ContainsKey($cId)) {
            [long]$start = $cId * $ChunkSize; [long]$end = $start + $ChunkSize - 1; if ($end -ge $TotalBytes) { $end = $TotalBytes - 1 }
            $PS = [powershell]::Create().AddScript($ScriptBlock).AddArgument($cId).AddArgument($start).AddArgument($end).AddArgument($Url).AddArgument($TempDir)
            $PS.RunspacePool = $RunspacePool; $Jobs[$cId] = [PSCustomObject]@{ PS = $PS; Handle = $PS.BeginInvoke() }
        }
    }

    $DoneP = "$TempDir\$NextToAppend.done"; $TmpP = "$TempDir\$NextToAppend.tmp"
    if (Test-Path $DoneP) {
        $in = $null; $out = $null
        try {
            $in = [System.IO.File]::OpenRead($TmpP); $out = [System.IO.File]::Open($OutFile, 'Append', 'Write', 'ReadWrite')
            $in.CopyTo($out); $in.Close(); $out.Close(); Remove-Item $TmpP, $DoneP -Force -ErrorAction SilentlyContinue
            $NextToAppend++
        } catch { if ($null -ne $in) { $in.Close() }; if ($null -ne $out) { $out.Close() } }
    }
    
    $OutInfo = New-Object System.IO.FileInfo($OutFile); $OutInfo.Refresh()
    [long]$cBytes = if ($OutInfo.Exists) { $OutInfo.Length } else { 0 }
    foreach ($t in (Get-ChildItem $TempDir -Filter "*.tmp" -ErrorAction SilentlyContinue)) {
        $ti = New-Object System.IO.FileInfo($t.FullName); $ti.Refresh(); if ($ti.Exists) { $cBytes += $ti.Length }
    }
    if ($cBytes -gt $HighestBytesTracked) { $HighestBytesTracked = $cBytes } else { $cBytes = $HighestBytesTracked }

    $tSpan = ($Now - $LastTime).TotalSeconds
    if ($tSpan -ge 1) {
        if ($cBytes - $LastBytes -ge 0) { $CurrentSpeed = [math]::Round((($cBytes - $LastBytes) / 1MB) / $tSpan, 1) }
        $LastTime = $Now; $LastBytes = $cBytes
    }
    $pct = [math]::Round(($cBytes / $TotalBytes) * 100, 2); $downMB = [math]::Round($cBytes / 1MB, 2)

    $Secs = ($Now - $StartTime).TotalSeconds
    if (-not $MpvLaunched) {
        if ($Secs -ge 30 -or $cBytes -ge $TotalBytes) {
            $MpvLaunched = $true
            try { Start-Process "mpv" "`"$OutFile`" --vo=gpu --hwdec=auto" -WindowStyle Normal -ErrorAction SilentlyContinue; $vSt = "[MPV PLAYING]" } catch { $vSt = "[MPV ERR]" }
        } else { $vSt = "[LAUNCH IN: $(30 - [math]::Floor($Secs))s]" }
    } else { $vSt = "[MPV PLAYING]" }
    
    [Console]::Write(("`r--> $vSt PROG: $pct% | $downMB / $TotalMB MB | Spd: $CurrentSpeed MB/s | Thr: $($Jobs.Count)/$CurrentLimit").PadRight(100)); Start-Sleep -Milliseconds 100 
}

[Console]::CursorVisible = $true; $RunspacePool.Close(); $RunspacePool.Dispose()
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "`n`n[+] Download 100% Complete!"; pause
