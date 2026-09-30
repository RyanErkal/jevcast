<#
.SYNOPSIS
    Jevcast tailnet agent for Windows. Tells the Tailnet view in Jevcast this PC's CPU, memory,
    disks, and uptime, the TCP ports it listens on, and what it shares with `tailscale serve`.

.DESCRIPTION
    Read only. It answers one request, GET /v1/status, on 127.0.0.1 port 61209, and never runs
    anything a request sends. `tailscale serve` shares that port with your tailnet only, not the
    internet, so no firewall rule is needed. Anyone on your tailnet can read the report.

    Set it up once, in PowerShell, from the folder with this file:
        powershell -ExecutionPolicy Bypass -File .\tailnet-agent.ps1 -Install
    This copies the script to %LOCALAPPDATA%\Jevcast, starts it at each sign-in with a scheduled
    task, and shares its port with `tailscale serve --bg --tcp 61209`.

    Remove it:
        powershell -ExecutionPolicy Bypass -File .\tailnet-agent.ps1 -Uninstall

    Print the report once, without the server:
        powershell -ExecutionPolicy Bypass -File .\tailnet-agent.ps1 -Once
#>
[CmdletBinding()]
param([switch]$Install, [switch]$Uninstall, [switch]$Once, [int]$Port = 61209)

$ErrorActionPreference = 'Stop'
$TaskName = 'Jevcast Tailnet Agent'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Jevcast'
$InstalledScript = Join-Path $InstallDir 'tailnet-agent.ps1'
# Ports, disks, and Serve change rarely and are slow to read, so they are read again after this many seconds.
$SlowPartSeconds = 25
$script:slowPart = $null
$script:slowPartAt = [datetime]::MinValue

function Get-TailscaleExe {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $path = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

# What this PC shares with `tailscale serve`, as Tailscale writes it. Null without Tailscale.
function Get-ServeConfig {
    $exe = Get-TailscaleExe
    if (-not $exe) { return $null }
    try {
        $text = (& $exe serve status --json 2>$null) -join "`n"
        if ($text.Trim()) { return ConvertFrom-Json -InputObject $text }
    } catch {}
    return $null
}

# TCP ports that other devices can reach: bound to every address or to a Tailscale address.
function Get-Listeners {
    $names = @{}
    foreach ($process in Get-Process) { $names[[int]$process.Id] = $process.ProcessName }
    $seen = @{}
    $list = @()
    foreach ($connection in Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue) {
        $address = [string]$connection.LocalAddress
        $reachable = $address -eq '0.0.0.0' -or $address -eq '::' -or $address -like '100.*' -or $address -like 'fd7a:115c:a1e0:*'
        $port = [int]$connection.LocalPort
        if (-not $reachable -or $seen.ContainsKey($port)) { continue }
        $seen[$port] = $true
        $list += [ordered]@{ port = $port; process = [string]$names[[int]$connection.OwningProcess] }
    }
    return , $list
}

function Get-SlowPart {
    if ($script:slowPart -and ((Get-Date) - $script:slowPartAt).TotalSeconds -lt $SlowPartSeconds) { return $script:slowPart }
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
            [ordered]@{ name = [string]$_.DeviceID; totalBytes = [double]$_.Size; freeBytes = [double]$_.FreeSpace }
        })
    $script:slowPart = @{ disks = $disks; listening = (Get-Listeners); serve = (Get-ServeConfig) }
    $script:slowPartAt = Get-Date
    return $script:slowPart
}

function Get-Report {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $slow = Get-SlowPart
    $report = [ordered]@{
        agent            = 'jevcast'
        version          = 1
        os               = [string]$os.Caption
        uptimeSeconds    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds)
        cpuPercent       = $cpu
        memoryTotalBytes = [double]$os.TotalVisibleMemorySize * 1024
        memoryUsedBytes  = ([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) * 1024
        disks            = $slow.disks
        listening        = $slow.listening
        serve            = $slow.serve
    }
    return ConvertTo-Json -InputObject $report -Depth 12 -Compress
}

# Reads the request line, answers, and closes. Only GET /v1/status has an answer.
function Send-Answer($client) {
    $client.ReceiveTimeout = 3000
    $client.SendTimeout = 3000
    $stream = $client.GetStream()
    $buffer = New-Object byte[] 8192
    $read = 0
    while ($read -lt $buffer.Length) {
        $count = $stream.Read($buffer, $read, $buffer.Length - $read)
        if ($count -le 0) { break }
        $read += $count
        if ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).Contains("`r`n`r`n")) { break }
    }
    $line = ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read) -split "`r`n")[0]
    if ($line -match '^GET /v1/status[ ?]') {
        $status = '200 OK'
        try { $body = Get-Report } catch { $status = '500 Internal Server Error'; $body = '{"error":"the report could not be read"}' }
    } else {
        $status = '404 Not Found'
        $body = '{"error":"not found"}'
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $stream.Write($head, 0, $head.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Start-Agent([int]$Port) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try { Send-Answer $client } catch {} finally { $client.Close() }
        }
    } finally {
        $listener.Stop()
    }
}

function Install-Agent([int]$Port) {
    $exe = Get-TailscaleExe
    if (-not $exe) { throw 'Tailscale is not installed on this PC.' }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ($PSCommandPath -ne $InstalledScript) { Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force }
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`" -Port $Port"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force `
        -Description 'Tells Jevcast on your Mac this PC''s load and the pages it shares on your tailnet.' | Out-Null
    & $exe serve --bg --tcp $Port "tcp://127.0.0.1:$Port"
    if ($LASTEXITCODE -ne 0) { throw "tailscale serve could not share port $Port." }
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "The Jevcast agent runs now and at each sign-in. Your tailnet reaches it on port $Port."
}

function Uninstall-Agent([int]$Port) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $exe = Get-TailscaleExe
    if ($exe) { & $exe serve --tcp $Port off }
    Remove-Item -LiteralPath $InstalledScript -Force -ErrorAction SilentlyContinue
    Write-Host 'The Jevcast agent is removed.'
}

# Dot-sourcing loads the functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Install) { Install-Agent $Port }
    elseif ($Uninstall) { Uninstall-Agent $Port }
    elseif ($Once) { Get-Report }
    else { Start-Agent $Port }
}
