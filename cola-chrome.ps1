param(
    [string]$Url = '',
    [ValidateRange(-1, 10000)][int]$Sesiones = -1,
    [string]$ChromePath = '',
    [string]$ProxyFile = '',
    [switch]$ProxySeller,
    [ValidatePattern('^[A-Z]{2}$')][string]$ProxyCountry = 'PE',
    [switch]$Headless
)

$ErrorActionPreference = 'Stop'
$script:ChromeSessions = [System.Collections.Generic.List[object]]::new()
$script:Socks5Proxies = @()

function New-SessionBridge([int]$Index, [string]$Visitor) {
    $login = "$($script:ProxyCredential.UserName)_c_${ProxyCountry}_s_$Visitor"
    return [QueueSocksBridge]::new('res.proxy-seller.com', (10000 + $Index), $login,
        $script:ProxyCredential.GetNetworkCredential().Password)
}

function Read-Socks5Proxies([string]$Path) {
    $proxies = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $value = $line.Trim()
        if (-not $value -or $value.StartsWith('#')) { continue }
        if ($value -notmatch '://') { $value = "socks5://$value" }
        $parsed = $null
        if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$parsed) -or
            $parsed.Scheme -ne 'socks5' -or -not $parsed.Host -or
            $parsed.Port -lt 1 -or $parsed.Port -gt 65535 -or
            $value -match '[\s"\\,;=<>|]' -or $parsed.Query -or $parsed.Fragment -or
            $parsed.AbsolutePath -notin @('', '/')) {
            throw "SOCKS5 invalido en la linea $lineNumber. Usa host:puerto o socks5://host:puerto."
        }
        if ($parsed.UserInfo -or $value.Contains('@')) {
            throw "Linea ${lineNumber}: Chrome no admite autenticacion SOCKS5. Usa un proxy sin usuario/contrasena o autorizado por IP."
        }
        $serverHost = $parsed.IdnHost.TrimEnd('.').ToLowerInvariant()
        if ($parsed.HostNameType -eq [UriHostNameType]::IPv6) { $serverHost = "[$serverHost]" }
        $proxy = "socks5://${serverHost}:$($parsed.Port)"
        if (-not $seen.Add($proxy)) { throw "SOCKS5 repetido en la linea $lineNumber. Cada sesion necesita uno distinto." }
        $proxies.Add($proxy)
    }
    if (-not $proxies.Count) { throw 'El archivo SOCKS5 no contiene proxies.' }
    return $proxies.ToArray()
}

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
    if ($session.Bridge) { $session.Bridge.Dispose() }
    $session.Process.Dispose()
    try { Remove-Item -LiteralPath $session.Profile -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "Perfil temporal aun ocupado: $($session.Profile)" }
}

function Set-ChromeTotal([int]$Total) {
    if ($Total -lt 0 -or $Total -gt 10000) { throw 'Introduce un total entre 0 y 10000.' }
    if ($ProxySeller -and $Total -gt 1000) { throw 'Api-Tools admite hasta 1000 puertos distintos (10000-10999).' }
    if ($ProxyFile -and $Total -gt $script:Socks5Proxies.Count) {
        throw "Pides $Total sesiones y hay $($script:Socks5Proxies.Count) SOCKS5 distintos. No se ha cambiado el lote."
    }
    while ($script:ChromeSessions.Count -gt $Total) { Close-LastChrome }
    while ($script:ChromeSessions.Count -lt $Total) {
        $visitor = [Guid]::NewGuid().ToString('N')
        $profile = Join-Path ([IO.Path]::GetTempPath()) "cola-chrome-$visitor"
        $proxy = $null
        $bridge = $null
        $arguments = @(
            "--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check',
            '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
            '--disable-backgrounding-occluded-windows', '--new-window'
        )
        if ($ProxyFile -or $ProxySeller) {
            if ($ProxySeller) {
                $bridge = New-SessionBridge $script:ChromeSessions.Count $visitor
                $proxy = "socks5://127.0.0.1:$($bridge.Port)"
            } else { $proxy = $script:Socks5Proxies[$script:ChromeSessions.Count] }
            $arguments += @("--proxy-server=$proxy", '--proxy-bypass-list="<-loopback>"', '--disable-quic',
                            '--force-webrtc-ip-handling-policy=disable_non_proxied_udp')
        }
        if ($Headless) { $arguments += '--headless=new' }
        $arguments += "`"$Url`""
        # ponytail: en Mac Chrome escribe sus logs en la consola; en Windows no.
        $quiet = if ($env:OS -ne 'Windows_NT') { @{ RedirectStandardError = '/dev/null' } } else { @{} }
        try { $process = Start-Process -FilePath $ChromePath -ArgumentList $arguments -PassThru @quiet }
        catch { if ($bridge) { $bridge.Dispose() }; throw }
        $script:ChromeSessions.Add([pscustomobject]@{ Id = $visitor; Profile = $profile; Process = $process; Proxy = $proxy; Bridge = $bridge })
        $route = if ($proxy) { " - $proxy" } else { '' }
        Write-Host "Abriendo $($script:ChromeSessions.Count)/$Total - ID $visitor$route"
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
    if ($ProxySeller -and $ProxyFile) { throw 'Usa -ProxySeller o -ProxyFile, no ambos.' }
    if ($ProxySeller) {
        if (-not ('QueueSocksBridge' -as [type])) { Add-Type -Path "$PSScriptRoot/socks5-bridge.cs" }
        $login = Read-Host 'Login base de la lista especial Api-Tools (sin sufijos)'
        if ($login -notmatch '^api[a-zA-Z0-9]+$') { throw 'Usa el login base de Api-Tools, que empieza por api.' }
        $secret = Read-Host 'Password del proxy' -AsSecureString
        $script:ProxyCredential = [PSCredential]::new($login, $secret)
        [QueueSocksBridge]::AuthenticationPacket("${login}_c_${ProxyCountry}_s_$('0' * 32)",
            $script:ProxyCredential.GetNetworkCredential().Password) | Out-Null
        Write-Host "Api-Tools: pais $ProxyCountry; un puerto y una sesion SOCKS5 por Chrome."
    }
    if ($ProxyFile) {
        $script:Socks5Proxies = @(Read-Socks5Proxies $ProxyFile)
        Write-Host "SOCKS5 disponibles: $($script:Socks5Proxies.Count). Uno por sesion, en el orden del archivo."
    }
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
