#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$DevPort = 3000
$DevUrl = "http://localhost:$DevPort"
$NodeVersion = '20.18.0'
$SetupDir = Join-Path $ProjectRoot '.host-setup'
$LogFile = Join-Path $SetupDir 'run.log'
$LockFile = Join-Path $SetupDir 'running.lock'
$PidFile = Join-Path $SetupDir 'dev.pid'

function Ensure-SetupDir {
    if (-not (Test-Path $SetupDir)) {
        New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    }
}

function Log([string]$Message) {
    Ensure-SetupDir
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-WinArch {
    if ([Environment]::Is64BitOperatingSystem) { return 'x64' }
    return 'x86'
}

function Get-LocalZipDir {
    return Join-Path $SetupDir "node-v$NodeVersion-win-$(Get-WinArch)"
}

function Refresh-NodePath {
    $zipDir = Get-LocalZipDir
    if (Test-Path (Join-Path $zipDir 'node.exe')) {
        if ($env:PATH -notlike "*$zipDir*") {
            $env:PATH = "$zipDir;$env:PATH"
        }
    }
    foreach ($dir in @(
        "$env:ProgramFiles\nodejs"
        "${env:ProgramFiles(x86)}\nodejs"
        "$env:LOCALAPPDATA\Programs\node"
    )) {
        if (Test-Path (Join-Path $dir 'node.exe')) {
            if ($env:PATH -notlike "*$dir*") {
                $env:PATH = "$dir;$env:PATH"
            }
        }
    }
}

function Get-NodeExe {
    Refresh-NodePath
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-NpmCli {
    $nodeDir = Split-Path -Parent (Get-NodeExe)
    if (-not $nodeDir) { return $null }
    $cli = Join-Path $nodeDir 'node_modules\npm\bin\npm-cli.js'
    if (Test-Path $cli) { return $cli }
    return $null
}

function Get-AssetSha256([string]$AssetName) {
    $sums = (Invoke-WebRequest -Uri "https://nodejs.org/dist/v$NodeVersion/SHASUMS256.txt" -UseBasicParsing).Content -split "`n"
    foreach ($line in $sums) {
        if ($line -match "^([a-f0-9]{64})\s+$AssetName$") { return $Matches[1] }
    }
    throw "SHA256 not found for $AssetName"
}

function Install-NodeViaZip {
    Ensure-SetupDir
    $arch = Get-WinArch
    $zipName = "node-v$NodeVersion-win-$arch.zip"
    $zipPath = Join-Path $SetupDir $zipName
    $extractDir = Get-LocalZipDir

    if (Test-Path (Join-Path $extractDir 'node.exe')) {
        $env:PATH = "$extractDir;$env:PATH"
        return (Get-NodeExe)
    }

    Log "node: zip download $zipName"
    Invoke-WebRequest -Uri "https://nodejs.org/dist/v$NodeVersion/$zipName" -OutFile $zipPath -UseBasicParsing

    $hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne (Get-AssetSha256 $zipName)) {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        throw 'ZIP SHA256 mismatch'
    }

    Log 'node: zip extract'
    Expand-Archive -Path $zipPath -DestinationPath $SetupDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    $env:PATH = "$extractDir;$env:PATH"
    return (Get-NodeExe)
}

function Install-NodeViaWinget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $false }
    Log 'node: winget install (fallback)'
    $proc = Start-Process -FilePath 'winget.exe' -ArgumentList @(
        'install', '--id', 'OpenJS.NodeJS.LTS', '--exact',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity', '--silent'
    ) -PassThru -Wait
    Refresh-NodePath
    if (($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189) -and (Get-NodeExe)) {
        Log 'node: winget ok'
        return $true
    }
    return $false
}

function Ensure-Node {
    $nodeExe = Get-NodeExe
    if ($nodeExe) { Log "node: $nodeExe"; return }
    Log 'node: not found, installing'
    if (Install-NodeViaZip) { Log 'node: zip ok'; return }
    if (Install-NodeViaWinget) { return }
    throw 'Node.js install failed'
}

function Test-DevPortOpen {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.BeginConnect('127.0.0.1', $DevPort, $null, $null).AsyncWaitHandle.WaitOne(1500, $false)
        if ($ok -and $c.Connected) { $c.Close(); return $true }
        $c.Close()
    } catch { }
    return $false
}

function Wait-ForDevServer([int]$TimeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-DevPortOpen) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-ForDevServer([int]$TimeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-DevPortOpen) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

Ensure-SetupDir

if (Test-DevPortOpen) {
    Log "already running $DevUrl"
    exit 0
}

if (Test-Path $LockFile) {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

try {
    if (-not (Test-Path (Join-Path $ProjectRoot 'package.json'))) {
        throw 'package.json not found — run this from the project folder'
    }

    Ensure-Node
    $nodeExe = Get-NodeExe
    $npmCli = Get-NpmCli
    if (-not $nodeExe -or -not $npmCli) { throw 'node or npm not found' }

    Log 'npm install'
    $installLog = Join-Path $SetupDir 'npm-install.log'
    & $nodeExe $npmCli install --no-fund --no-audit --loglevel=silent *> $installLog
    if ($LASTEXITCODE -ne 0) { throw "npm install exit $LASTEXITCODE" }

    $nextCli = Join-Path $ProjectRoot 'node_modules\next\dist\bin\next'
    if (-not (Test-Path $nextCli)) { throw 'next cli not found' }

    Log 'dev server start'
    $devLog = Join-Path $SetupDir 'dev.log'
    $devErrLog = Join-Path $SetupDir 'dev.err.log'
    if (Test-Path $devLog) { Remove-Item $devLog -Force }
    if (Test-Path $devErrLog) { Remove-Item $devErrLog -Force }

    $devProc = Start-Process -FilePath $nodeExe `
        -ArgumentList $nextCli, 'dev' `
        -WorkingDirectory $ProjectRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $devLog `
        -RedirectStandardError $devErrLog `
        -PassThru

    Set-Content -Path $PidFile -Value $devProc.Id
    Set-Content -Path $LockFile -Value $devProc.Id

    if (Wait-ForDevServer) {
        if (-not $devProc.HasExited) {
            Log "ready $DevUrl (server running in background)"
        } else {
            Log 'dev server exited early — see dev.log'
        }
    } else {
        Log 'dev server timeout — see dev.log'
    }
} catch {
    Log "error: $($_.Exception.Message)"
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    exit 1
}

exit 0
