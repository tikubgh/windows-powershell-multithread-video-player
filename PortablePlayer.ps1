[Net.ServicePointManager]::DefaultConnectionLimit = 100
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Url = (Read-Host "`nPaste Video URL").Trim('"')

$BaseDir = "$env:USERPROFILE\Downloads\PS_Stream"; $TempDir = "$BaseDir\Chunks"
if (!(Test-Path $TempDir)) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }

try {
    $req = [System.Net.WebRequest]::Create($Url); $req.Method = "HEAD"; $req.UserAgent = "Mozilla/5.0"
    $res = $req.GetResponse(); [long]$TotalBytes = $res.ContentLength; $res.Close()
} catch { Write-Host "[ERROR] Server blocked request."; pause; exit }

[long]$ChunkSize = 5 * 1024 * 1024; [long]$TotalChunks = [math]::Ceiling($TotalBytes / $ChunkSize)
$TotalMB = [math]::Round($TotalBytes / 1MB, 2)

try {
    $FileName = [System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName(([System.Uri]($Url.Split('?')[0])).LocalPath)) -replace '[<>:"/\\|?*]', ''
    if (!$FileName -or $FileName -notmatch "\.(mkv|mp4|ts|avi|webm)$") { $FileName = "stream_video.mkv" }
} catch { $FileName = "stream_video.mkv" }

$OutFile = "$BaseDir\$FileName"; [long]$NextToDownload = 0; [long]$NextToAppend = 0; $TargetFile = $null

# THE SMART MENU: Matches URL name exactly, or lists your folder contents to let you choose.
if (Test-Path $OutFile) {
    if ((Read-Host "`n[!] MATCH FOUND: $FileName. Resume (R) or Fresh (F)? [R/F]") -match "^[rR]") { $TargetFile = Get-Item $OutFile }
    else { Remove-Item $OutFile -Force }
} else {
    $OtherVids = @(Get-ChildItem $BaseDir -File | Where-Object { $_.Name -match "\.(mkv|mp4|ts|avi|webm)$" })
    if ($OtherVids.Count -gt 0) {
        Write-Host "`n[?] '$FileName' not found, but other downloads exist:" -ForegroundColor Yellow
        for ($i=0; $i -lt $OtherVids.Count; $i++) { Write-Host " [$($i+1)] $($OtherVids[$i].Name)" }
        Write-Host " [F] Start Fresh Download: $FileName"
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
        try { $fs = [System.IO.File]::Open($OutFile, 'Open', 'Write'); $fs.SetLength($SafeBytes); $fs.Close() } 
        catch { Write-Host "`n[ERROR] File locked by player!"; pause; exit }
    }
    $NextToDownload = $CompChunks; $NextToAppend = $CompChunks
} else {
    if (Test-Path "$TempDir\*") { Remove-Item "$TempDir\*" -Force -Recurse }
    [System.IO.File]::WriteAllBytes($OutFile, [byte[]]::new(0))
}

Get-ChildItem $TempDir -File | Where-Object { $_.Name -match "\.(tmp|done)$" } | Remove-Item -Force -ErrorAction SilentlyContinue

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

[Console]::CursorVisible = $false
$StartTime = Get-Date; $LastTime = Get-Date; [long]$HighestBytesTracked = $NextToAppend * $ChunkSize
[long]$LastBytes = $HighestBytesTracked; $CurrentSpeed = 0; $MpvLaunched = $false

while ($NextToAppend -lt $TotalChunks) {
    $Now = Get-Date
    while ($Jobs.Count -lt 10 -and $NextToDownload -lt $TotalChunks) {
        [long]$start = $NextToDownload * $ChunkSize; [long]$end = $start + $ChunkSize - 1
        if ($end -ge $TotalBytes) { $end = $TotalBytes - 1 }
        $PS = [powershell]::Create().AddScript($ScriptBlock).AddArgument($NextToDownload).AddArgument($start).AddArgument($end).AddArgument($Url).AddArgument($TempDir)
        $PS.RunspacePool = $RunspacePool; $Jobs[$NextToDownload] = [PSCustomObject]@{ PS = $PS; Handle = $PS.BeginInvoke() }; $NextToDownload++
    }

    $DoneP = "$TempDir\$NextToAppend.done"; $TmpP = "$TempDir\$NextToAppend.tmp"
    if (Test-Path $DoneP) {
        $in = $null; $out = $null
        try {
            $in = [System.IO.File]::OpenRead($TmpP); $out = [System.IO.File]::Open($OutFile, 'Append', 'Write', 'ReadWrite')
            $in.CopyTo($out); $in.Close(); $out.Close(); Remove-Item $TmpP, $DoneP -Force -ErrorAction SilentlyContinue
            if ($Jobs.ContainsKey($NextToAppend)) { $Jobs[$NextToAppend].PS.Dispose(); $Jobs.Remove($NextToAppend) }; $NextToAppend++
        } catch { if ($null -ne $in) { $in.Close() }; if ($null -ne $out) { $out.Close() } }
    } elseif ($Jobs.ContainsKey($NextToAppend) -and $Jobs[$NextToAppend].Handle.IsCompleted) {
        $Jobs[$NextToAppend].PS.Dispose(); $Jobs.Remove($NextToAppend); $NextToDownload = $NextToAppend
        foreach ($k in $Jobs.Keys) { $Jobs[$k].PS.Stop(); $Jobs[$k].PS.Dispose() }; $Jobs.Clear()
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
            try { Start-Process "mpv" "`"$OutFile`" --vo=gpu --hwdec=auto" -WindowStyle Normal -ErrorAction SilentlyContinue; $vSt = "[MPV PLAYING]" } 
            catch { $vSt = "[MPV ERR]" }
        } else { $vSt = "[LAUNCH IN: $(30 - [math]::Floor($Secs))s]" }
    } else { $vSt = "[MPV PLAYING]" }
    
    [Console]::Write(("`r--> $vSt PROG: $pct% | $downMB / $TotalMB MB | Spd: $CurrentSpeed MB/s | Thr: $($Jobs.Count)/10").PadRight(100))
    Start-Sleep -Milliseconds 100 
}

[Console]::CursorVisible = $true; $RunspacePool.Close(); $RunspacePool.Dispose()
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "`n`n[+] Download 100% Complete!"; pause
