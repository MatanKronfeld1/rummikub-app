<#
Dev loop with hot reload, from the repo root:

    .\run_dev.ps1                      # backend + Flutter web app in Chrome
    .\run_dev.ps1 -Device windows      # any `flutter devices` id
    .\run_dev.ps1 -Device web-server   # no browser launched; open http://localhost:5000
                                       # yourself (e.g. in incognito), -WebPort to change
    .\run_dev.ps1 -HostAddress 192.168.1.20   # a phone on the same Wi-Fi

Starts uvicorn with --reload in a second window (Python edits restart it by
itself), waits until it answers, then runs `flutter run` in this window so the
usual keys work: r = hot reload, R = hot restart, q = quit.

When flutter exits (q, Ctrl+C, or an error) the backend window and its reload
worker are stopped and anything still listening on the port is cleaned up.
See DEMO.md for the vision setup (same weights / ROBOFLOW_API_KEY rules as
run_demo.ps1).
#>
param(
    [int]$Port = 8000,
    [string]$Device = 'chrome',
    # Port of the app itself when -Device web-server is used.
    [int]$WebPort = 5000,
    # Address the app uses to reach the backend; set it for a phone/LAN device.
    [string]$HostAddress = '127.0.0.1',
    # Print what would run instead of starting the backend and the app.
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$backend = Join-Path $PSScriptRoot 'project_rummikub_backend'
$frontend = Join-Path $PSScriptRoot 'Project-Rummikub_frontend'
$classifier = Join-Path $PSScriptRoot 'classify\best.pt'
$detector = Join-Path $PSScriptRoot 'detect\best.pt'

# Same vision selection as run_demo.ps1; the backend window inherits these.
if ((Test-Path $classifier) -and (Test-Path $detector)) {
    $env:CLS_WEIGHTS = $classifier
    $env:DETECTOR_WEIGHTS = $detector
    Write-Host 'Vision: local detector + classifier (no Roboflow key needed).'
} elseif ($env:ROBOFLOW_API_KEY) {
    Write-Host 'Vision: forwarded to the Roboflow Workflow with ROBOFLOW_API_KEY from this shell.'
} else {
    Write-Warning 'No local weights and no ROBOFLOW_API_KEY: recognition will fail; manual entry still works.'
}

$uvicornArgs = @('-m', 'uvicorn', 'main:app', '--reload', '--host', '0.0.0.0', '--port', $Port)
$defines = @("--dart-define=SOLVER_URL=http://${HostAddress}:$Port/solve")
if ($Device -eq 'web-server') {
    # No browser is launched: open http://localhost:$WebPort yourself, e.g. in incognito.
    $defines += @('--web-port', $WebPort)
}
if ($HostAddress -ne '127.0.0.1') {
    $defines += "--dart-define=ROBOFLOW_WORKFLOW_URL=http://${HostAddress}:$Port/vision/workflow"
}

if ($DryRun) {
    Write-Host "[dry run] backend (in $backend): python $($uvicornArgs -join ' ')"
    Write-Host "[dry run] flutter (in $frontend): flutter run -d $Device $($defines -join ' ')"
    return
}

function Get-PortOwners([int]$LocalPort) {
    Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
}

if (Get-PortOwners $Port) {
    throw "Port $Port is already in use. Stop the other server or pass -Port."
}

$server = $null
try {
    $server = Start-Process python -WorkingDirectory $backend -ArgumentList $uvicornArgs -PassThru

    Write-Host "Waiting for the backend on port $Port..."
    $deadline = (Get-Date).AddSeconds(90)
    $ready = $false
    while (-not $ready -and (Get-Date) -lt $deadline) {
        if ($server.HasExited) {
            throw 'The backend exited during startup. Check its window for the error.'
        }
        try {
            Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null
            $ready = $true
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $ready) {
        throw "The backend did not answer on port $Port within 90 s."
    }

    Push-Location $frontend
    flutter run -d $Device @defines
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    Write-Host 'Stopping the backend...'
    if ($server -and -not $server.HasExited) {
        # /T takes the --reload worker down with its parent.
        & taskkill /PID $server.Id /T /F 2>&1 | Out-Null
    }
    # Safety net: an orphaned reload worker can outlive its parent.
    foreach ($owner in Get-PortOwners $Port) {
        Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
    }
}
