# Force UTF-8 Encoding to ensure clean dashboard rendering
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::Expect100Continue = $false 

Clear-Host
$Url = (Read-Host "`nPaste Video URL").Trim('"').Trim()

$BaseDir = "$env:USERPROFILE\Downloads\PS_Stream"; $TempDir = "$BaseDir\Chunks"
if (!(Test-Path $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }

# -----------------------------------------------------------
# LOCAL ROUTING & ISP MAPPING
# -----------------------------------------------------------
Write-Host "`n[NETWORK] Mapping Local Routing & ISP..." -ForegroundColor DarkGray
try {
    $NetInfo = Invoke-RestMethod -Uri "http://ip-api.com/json/" -UseBasicParsing -TimeoutSec 3
    $ISP = if ($NetInfo.isp) { $NetInfo.isp } else { "Unknown ISP" }
    $Loc = if ($NetInfo.city) { "$($NetInfo.city), $($NetInfo.country)" } else { "Unknown Location" }
} catch { $ISP = "Local/Unknown"; $Loc = "Offline/Hidden" }

Write-Host "[NETWORK] Extracting Metadata & Tricking Firewalls..." -ForegroundColor DarkGray
try {
    $req = [System.Net.HttpWebRequest]::Create($Url); $req.Method = "GET"; $req.UserAgent = "Mozilla/5.0"
    $req.AddRange(0, 0); $req.Timeout = 8000; $req.ReadWriteTimeout = 8000; $req.AllowAutoRedirect = $true
    
    $res = $req.GetResponse()
    if ($res.StatusCode -eq 206 -and $res.Headers["Content-Range"] -match "/(\d+)$") { [long]$TotalBytes = $matches[1] } 
    else { [long]$TotalBytes = $res.ContentLength }
    
    $cd = $res.Headers["Content-Disposition"]; $FileName = ""
    if (-not [string]::IsNullOrWhiteSpace($cd)) {
        if ($cd -match "filename\*\s*=\s*UTF-8''([^;]+)") { $FileName = [System.Uri]::UnescapeDataString($matches[1]) }
        elseif ($cd -match 'filename\s*=\s*"([^"]+)"') { $FileName = $matches[1] }
        elseif ($cd -match 'filename\s*=\s*([^;]+)') { $FileName = $matches[1] }
    }
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -eq "") {
        $Query = $res.ResponseUri.Query
        if ($Query -match "name=([^&]+)") { $FileName = [System.Uri]::UnescapeDataString($matches[1]) }
    }
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -eq "") {
        $FileName = [System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName(([System.Uri]($Url.Split('?')[0])).LocalPath))
    }

    $FileName = $FileName -replace '[<>:"/\\|?*]', ''
    if ([string]::IsNullOrWhiteSpace($FileName) -or $FileName -eq "download" -or $FileName -notmatch "\.") { $FileName = "stream_video.mkv" }
    
    $req.Abort(); if ($res) { $res.Close() }
} catch { 
    Write-Host "[WARNING] Server refused metadata ping. Initiating fallback..." -ForegroundColor Yellow
    $FileName = "stream_video.mkv"; [long]$TotalBytes = 2000000000 
}

[long]$ChunkSize = 5 * 1024 * 1024; [long]$TotalChunks = [math]::Ceiling($TotalBytes / $ChunkSize)
$TotalMB = [math]::Round($TotalBytes / 1MB, 2)
$OutFile = "$BaseDir\$FileName"

[long]$NextToDownload = 0; [long]$NextToAppend = 0; $TargetFile = $null

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
} else {
    if (Test-Path "$TempDir\*") { Remove-Item "$TempDir\*" -Force -Recurse }
    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0))
}

Get-ChildItem $TempDir -File | Where-Object { $_.Name -match "\.(tmp|done)$" } | Remove-Item -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------
# THE STABLE SEQUENTIAL ENGINE (Watchdog Enabled)
# -----------------------------------------------------------
$CurrentLimit = 1; $ThreadLocked = $false; $FailedChunks = New-Object System.Collections.Generic.List[long]

$RunspacePool = [runspacefactory]::CreateRunspacePool(1, 10); $RunspacePool.Open(); $Jobs = @{}
$ScriptBlock = {
    param([long]$id, [long]$start, [long]$end, $url, $temp)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; [Net.ServicePointManager]::DefaultConnectionLimit = 100
    try {
        $req = [System.Net.HttpWebRequest]::Create($url); $req.UserAgent = "Mozilla/5.0"; $req.AddRange($start, $end)
        $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
        $res = $req.GetResponse(); $stream = $res.GetResponseStream(); $fs = [System.IO.File]::Create("$temp\$id.tmp")
        $stream.CopyTo($fs); $fs.Close(); $stream.Close(); $res.Close(); [System.IO.File]::WriteAllText("$temp\$id.done", "OK")
    } catch { if ($req) { $req.Abort() } } 
}

$StartTime = Get-Date; $LastRampUp = Get-Date; $LastTime = Get-Date
[long]$HighestBytesTracked = $NextToAppend * $ChunkSize; [long]$LastBytes = $HighestBytesTracked
$CurrentSpeed = 0; $MpvLaunched = $false

# Lock UI
Clear-Host
[Console]::CursorVisible = $false

while ($NextToAppend -lt $TotalChunks) {
    $Now = Get-Date
    
    if (-not $ThreadLocked -and $CurrentLimit -lt 10 -and ($Now - $LastRampUp).TotalSeconds -ge 2) {
        $CurrentLimit++; $LastRampUp = $Now
    }

    $CompletedKeys = @(); $StuckKeys = @()
    foreach ($k in $Jobs.Keys) { 
        if ($Jobs[$k] -and $Jobs[$k].Handle.IsCompleted) { $CompletedKeys += $k } 
        elseif ($Jobs[$k] -and ($Now - $Jobs[$k].Started).TotalSeconds -gt 45) { $StuckKeys += $k }
    }
    
    foreach ($k in $StuckKeys) {
        try { $Jobs[$k].PS.Stop(); $Jobs[$k].PS.Dispose() } catch {}
        $Jobs.Remove($k)
        Remove-Item "$TempDir\$k.tmp" -Force -ErrorAction SilentlyContinue
        if (-not $FailedChunks.Contains($k)) { $FailedChunks.Add($k) }
        if (-not $ThreadLocked) {
            $ThreadLocked = $true; $CurrentLimit = if ($Jobs.Count -gt 0) { $Jobs.Count } else { 1 }
        }
    }

    foreach ($k in $CompletedKeys) {
        $job = $Jobs[$k]; $Jobs.Remove($k)
        if ($null -ne $job -and $null -ne $job.PS) { try { $job.PS.Dispose() } catch {} }
        
        if ($k -ge $NextToAppend -and -not (Test-Path "$TempDir\$k.done")) {
            if (-not $FailedChunks.Contains($k)) { $FailedChunks.Add($k) }
            if (-not $ThreadLocked) {
                $ThreadLocked = $true; $CurrentLimit = if ($Jobs.Count -gt 0) { $Jobs.Count } else { 1 }
            }
        }
    }

    while ($Jobs.Count -lt $CurrentLimit -and ($NextToDownload -lt $TotalChunks -or $FailedChunks.Count -gt 0)) {
        if ($FailedChunks.Count -gt 0) { [long]$cId = $FailedChunks[0]; $FailedChunks.RemoveAt(0) } 
        else { [long]$cId = $NextToDownload; $NextToDownload++ }
        
        if (-not $Jobs.ContainsKey($cId)) {
            [long]$start = $cId * $ChunkSize; [long]$end = $start + $ChunkSize - 1; if ($end -ge $TotalBytes) { $end = $TotalBytes - 1 }
            $PS = [powershell]::Create().AddScript($ScriptBlock).AddArgument($cId).AddArgument($start).AddArgument($end).AddArgument($Url).AddArgument($TempDir)
            $Jobs[$cId] = [PSCustomObject]@{ PS = $PS; Handle = $PS.BeginInvoke(); Started = Get-Date }
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
            try { Start-Process "mpv" "`"$OutFile`" --vo=gpu --hwdec=auto" -WindowStyle Normal -ErrorAction SilentlyContinue; $vSt = "PLAYING" } catch { $vSt = "MPV ERROR" }
        } else { $vSt = "LAUNCHING IN $(30 - [math]::Floor($Secs))s" }
    } else { $vSt = "PLAYING" }
    
    # BULLETPROOF ASCII PROGRESS BAR WITH NEW ROUTING LINE
    $barLen = 40; $filled = [math]::Floor(($pct / 100) * $barLen); $empty = $barLen - $filled
    $bar = "#" * $filled + "-" * $empty
    
    $L1 = "=======================================================================".PadRight(80)
    $L2 = " [ HIGH-SPEED STREAMING ENGINE ]   Target: $FileName".PadRight(80)
    $L3 = "=======================================================================".PadRight(80)
    $L4 = " [ ROUTING  ] $ISP ($Loc)".PadRight(80)
    $L5 = " [ PROGRESS ] [$bar] $pct%".PadRight(80)
    $L6 = " [ METRICS  ] $downMB / $TotalMB MB  |  Speed: $CurrentSpeed MB/s".PadRight(80)
    $L7 = " [ STATUS   ] $vSt  |  Threads: $($Jobs.Count) Active (Limit $CurrentLimit)".PadRight(80)
    $L8 = "=======================================================================".PadRight(80)

    [Console]::SetCursorPosition(0, 0)
    [Console]::WriteLine($L1); [Console]::WriteLine($L2); [Console]::WriteLine($L3); [Console]::WriteLine($L4)
    [Console]::WriteLine($L5); [Console]::WriteLine($L6); [Console]::WriteLine($L7); [Console]::WriteLine($L8)

    Start-Sleep -Milliseconds 100 
}

[Console]::CursorVisible = $true; $RunspacePool.Close(); $RunspacePool.Dispose()
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "`n`n[+] Download 100% Complete!"; pause
