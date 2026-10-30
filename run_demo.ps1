<#
Local demo in one command, from the repo root:

    .\run_demo.ps1                     # backend + Flutter web app in Chrome
    .\run_demo.ps1 -Device windows     # any `flutter devices` id
    .\run_demo.ps1 -Lan                # a phone on the same Wi-Fi

Starts the FastAPI backend (solver + vision proxy) in a second window, waits
until it answers, then runs the Flutter app against it. With classify\best.pt
and detect\best.pt present, vision runs locally and needs no Roboflow key;
otherwise set $env:ROBOFLOW_API_KEY in this shell first. See DEMO.md.

-Lan makes the backend listen on the network and points the app at this PC's
Wi-Fi address instead of 127.0.0.1, so a phone can reach it. Pass -HostAddress
to pick the address yourself.
#>
param(
    [int]$Port = 8000,
    [string]$Device = 'chrome',
    [switch]$Lan,
    [string]$HostAddress = '',
    # Print what would run instead of starting the backend and the app.
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$backend = Join-Path $PSScriptRoot 'project_rummikub_backend'
$frontend = Join-Path $PSScriptRoot 'Project-Rummikub_frontend'
$classifier = Join-Path $PSScriptRoot 'classify\best.pt'
$detector = Join-Path $PSScriptRoot 'detect\best.pt'

# -Lan: the app has to talk to this PC's network address, and uvicorn has to
# accept connections from other devices (it binds 127.0.0.1 by default).
if ($Lan -and -not $HostAddress) {
    $HostAddress = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Sort-Object { $_.InterfaceAlias -notlike '*Wi-Fi*' } |
        Select-Object -First 1).IPAddress
    if (-not $HostAddress) {
        throw 'Could not find a network address. Pass -HostAddress <your-ip>.'
    }
}
$bindHost = if ($HostAddress) { '0.0.0.0' } else { '127.0.0.1' }
$appHost = if ($HostAddress) { $HostAddress } else { '127.0.0.1' }

$visionEnv = ''
if ((Test-Path $classifier) -and (Test-Path $detector)) {
    $visionEnv = "`$env:CLS_WEIGHTS = '$classifier'; `$env:DETECTOR_WEIGHTS = '$detector'; "
    Write-Host 'Vision: local detector + classifier (no Roboflow key needed).'
} elseif ($env:ROBOFLOW_API_KEY) {
    Write-Host 'Vision: forwarded to the Roboflow Workflow with ROBOFLOW_API_KEY from this shell.'
} else {
    Write-Warning 'No local weights and no ROBOFLOW_API_KEY: recognition will fail; manual entry still works.'
}

if ($HostAddress) {
    Write-Host "Serving the app against http://${appHost}:$Port"
    Write-Host "Test this URL in the phone's browser first: http://${appHost}:$Port/health"
    Write-Host 'If that page does not load, allow the port once in an admin PowerShell:'
    Write-Host "  New-NetFirewallRule -DisplayName 'Rummikub backend $Port' -Direction Inbound -LocalPort $Port -Protocol TCP -Action Allow"
}

$backendCommand = "$visionEnv python -m uvicorn main:app --host $bindHost --port $Port"
if ($DryRun) {
    Write-Host "[dry run] backend: $backendCommand"
} else {
    Start-Process powershell -WorkingDirectory $backend -ArgumentList @(
        '-NoExit', '-Command', $backendCommand
    )
}

Write-Host "Waiting for the backend on port $Port..."
$deadline = (Get-Date).AddSeconds(90)
$ready = $false
while (-not $DryRun -and -not $ready -and (Get-Date) -lt $deadline) {
    try {
        Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null
        $ready = $true
    } catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $DryRun -and -not $ready) {
    throw "The backend did not start on port $Port. Check the backend window for the error."
}

Set-Location $frontend
# On web, /vision/workflow is derived from SOLVER_URL, so one define covers both.
# A phone calls Roboflow directly unless ROBOFLOW_WORKFLOW_URL points at this
# backend, which then runs the local pipeline and needs no key.
$defines = @("--dart-define=SOLVER_URL=http://${appHost}:$Port/solve")
if ($HostAddress) {
    $defines += "--dart-define=ROBOFLOW_WORKFLOW_URL=http://${appHost}:$Port/vision/workflow"
}
if ($DryRun) {
    Write-Host "[dry run] flutter: flutter run -d $Device $($defines -join ' ')"
} else {
    flutter run -d $Device @defines
}
