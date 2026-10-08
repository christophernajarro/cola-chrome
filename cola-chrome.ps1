param(
    [string]$Url = '',
    [ValidateRange(-1, 10000)][int]$Sesiones = -1,
    [string]$ChromePath = '',
    [switch]$Headless
)

$ErrorActionPreference = 'Stop'
$script:ChromeSessions = [System.Collections.Generic.List[object]]::new()

function Test-QueueUrl([string]$Value) {
    $parsed = $null
    return ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed) -and
        $parsed.Scheme -in @('http', 'https') -and $parsed.Host -and
        -not $parsed.UserInfo -and $Value -notmatch '[\s"\\]')
}

function Find-Chrome {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'No se encontro Chrome. Indica su ruta con -ChromePath.'
}

function Close-LastChrome([int]$Index = ($script:ChromeSessions.Count - 1)) {
    $session = $script:ChromeSessions[$Index]
    $session.Process.Refresh()
    if (-not $session.Process.HasExited) {
        if ($env:OS -eq 'Windows_NT') {
            & taskkill.exe /PID $session.Process.Id /T /F 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -and -not $session.Process.HasExited) {
                throw "No se pudo cerrar Chrome $($session.Id)."
            }
        } else {
            Stop-Process -InputObject $session.Process -Force
        }
        if (-not $session.Process.WaitForExit(5000)) { throw 'Chrome sigue cerrandose; vuelve a intentar.' }
    }
    $script:ChromeSessions.RemoveAt($Index)
    $session.Process.Dispose()
    try { Remove-Item -LiteralPath $session.Profile -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "Perfil temporal aun ocupado: $($session.Profile)" }
}

function Set-ChromeTotal([int]$Total) {
    if ($Total -lt 0 -or $Total -gt 10000) { throw 'Introduce un total entre 0 y 10000.' }
    while ($script:ChromeSessions.Count -gt $Total) { Close-LastChrome }
    while ($script:ChromeSessions.Count -lt $Total) {
        $visitor = [Guid]::NewGuid().ToString('N')
        $profile = Join-Path ([IO.Path]::GetTempPath()) "cola-chrome-$visitor"
        $arguments = @(
            "--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check',
            '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
            '--disable-backgrounding-occluded-windows', '--new-window'
        )
        if ($Headless) { $arguments += '--headless=new' }
        $arguments += "`"$Url`""
        # ponytail: en Mac Chrome escribe sus logs en la consola; en Windows no.
        $quiet = if ($env:OS -ne 'Windows_NT') { @{ RedirectStandardError = '/dev/null' } } else { @{} }
        $process = Start-Process -FilePath $ChromePath -ArgumentList $arguments -PassThru @quiet
        $script:ChromeSessions.Add([pscustomobject]@{ Id = $visitor; Profile = $profile; Process = $process })
        Write-Host "Abriendo $($script:ChromeSessions.Count)/$Total - ID $visitor"
    }
    Write-Host "Sesiones administradas: $($script:ChromeSessions.Count)"
}

function Invoke-QueueCommand([string]$Command) {
    if ($Command -eq 'q') { return $false }
    if ($Command -eq 'r') {
        $total = $script:ChromeSessions.Count
        Set-ChromeTotal 0
        Set-ChromeTotal $total
    } else {
        $total = 0
        if (-not [int]::TryParse($Command, [ref]$total) -or $total -lt 0 -or $total -gt 10000) {
            throw 'Usa un numero de 0 a 10000, r para reiniciar o q para salir.'
        }
        Set-ChromeTotal $total
    }
    return $true
}

function Start-QueueConsole {
    if (-not $ChromePath) { $script:ChromePath = Find-Chrome }
    if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) { throw 'La ruta de Chrome no existe.' }
    while (-not (Test-QueueUrl $Url)) {
        if ($Url) { Write-Host 'URL invalida. Usa http:// o https://, sin espacios ni credenciales.' }
        $script:Url = Read-Host 'URL de staging'
    }
    Write-Host 'Numero = total deseado. Ejemplo: 10, luego 20 agrega otras 10.'
    Write-Host '0 = cerrar todas | r = reiniciar todas con perfiles nuevos | q = salir'
    try {
        if ($Sesiones -ge 0) { Set-ChromeTotal $Sesiones }
        while ($true) {
            $command = (Read-Host 'Total / r / q').Trim().ToLowerInvariant()
            try {
                if (-not (Invoke-QueueCommand $command)) { break }
            } catch { Write-Warning $_.Exception.Message }
        }
    } finally {
        # ponytail: solo procesos registrados por esta ejecucion; nunca cerrar Chrome por nombre.
        for ($index = $script:ChromeSessions.Count - 1; $index -ge 0; $index--) {
            try { Close-LastChrome $index }
            catch { Write-Warning $_.Exception.Message }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Start-QueueConsole }
