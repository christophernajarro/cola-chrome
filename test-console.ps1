$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/cola-chrome.ps1"

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert (Test-QueueUrl 'https://staging.example/concierto?test=1&batch=2') 'URL valida rechazada'
foreach ($bad in @('file:///tmp/a', 'https://u:p@example.com', 'https://a b', 'https://a"b', 'http://')) {
    Assert (-not (Test-QueueUrl $bad)) "URL invalida aceptada: $bad"
}

# Procesos simulados: el test no abre Chrome ni termina procesos del equipo.
$script:Starts = [System.Collections.Generic.List[object]]::new()
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$PassThru, $RedirectStandardError)
    $process = [pscustomobject]@{ Id = 1; HasExited = $true }
    $process | Add-Member ScriptMethod Refresh { }
    $process | Add-Member ScriptMethod Dispose { }
    $script:Starts.Add($ArgumentList)
    return $process
}
function Remove-Item { param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction) }
$script:ChromePath = 'fake-chrome'
$script:Url = 'https://staging.example/?x=1&y=2'

Assert (Invoke-QueueCommand '2') 'No debe salir al abrir'
$first = $script:ChromeSessions[0].Id
Assert ($script:ChromeSessions.Count -eq 2) 'Debe abrir dos sesiones'
Assert ($script:ChromeSessions[0].Profile -ne $script:ChromeSessions[1].Profile) 'Perfiles compartidos'
Assert ($script:Starts[0][-1] -eq '"https://staging.example/?x=1&y=2"') 'URL mal escapada'
Invoke-QueueCommand '3' | Out-Null
Assert ($script:ChromeSessions[0].Id -eq $first) 'El incremento debe conservar sesiones'
Invoke-QueueCommand '1' | Out-Null
Assert ($script:ChromeSessions.Count -eq 1 -and $script:ChromeSessions[0].Id -eq $first) 'Reduccion incorrecta'
Invoke-QueueCommand 'r' | Out-Null
Assert ($script:ChromeSessions.Count -eq 1 -and $script:ChromeSessions[0].Id -ne $first) 'Reinicio sin nueva identidad'
Invoke-QueueCommand '0' | Out-Null
Assert ($script:ChromeSessions.Count -eq 0) 'Cierre incompleto'
Assert (-not (Invoke-QueueCommand 'q')) 'q debe salir'
foreach ($bad in @('-1', '1.5', 'nan')) {
    $rejected = $false
    try { Invoke-QueueCommand $bad | Out-Null } catch { $rejected = $true }
    Assert $rejected "Comando invalido aceptado: $bad"
}
Write-Host 'OK: URL, aislamiento de perfiles, ajuste, cierre y reinicio.'

$proxyPath = [IO.Path]::GetTempFileName()
try {
    @('# Un proxy por linea', '', 'Proxy-A.example:01080', 'socks5://proxy-b.example:1081', 'socks5://[::1]:1082') |
        Set-Content -LiteralPath $proxyPath
    $script:ProxyFile = $proxyPath
    $script:Socks5Proxies = @(Read-Socks5Proxies $proxyPath)
    Assert ($script:Socks5Proxies.Count -eq 3) 'Lista de proxies incorrecta'
    Assert ($script:Socks5Proxies[0] -eq 'socks5://proxy-a.example:1080') 'Host/puerto sin normalizar'
    Assert ($script:Socks5Proxies[2] -eq 'socks5://[::1]:1082') 'IPv6 incorrecto'
    Invoke-QueueCommand '2' | Out-Null
    $firstProxy = $script:ChromeSessions[0].Proxy
    $firstId = $script:ChromeSessions[0].Id
    Assert ($script:ChromeSessions[1].Proxy -ne $firstProxy) 'Se repitio un SOCKS5'
    Assert ($script:Starts[-1] -contains '--proxy-server=socks5://proxy-b.example:1081') 'Falta proxy en Chrome'
    Assert ($script:Starts[-1] -contains '--proxy-bypass-list="<-loopback>"') 'Loopback no debe omitir el proxy'
    Assert ($script:Starts[-1] -contains '--disable-quic') 'QUIC debe desactivarse en modo SOCKS5'
    $rejected = $false
    try { Invoke-QueueCommand '4' | Out-Null } catch { $rejected = $true }
    Assert ($rejected -and $script:ChromeSessions.Count -eq 2) 'Faltan proxies: no debe modificar el lote'
    Invoke-QueueCommand '3' | Out-Null
    Assert ($script:ChromeSessions[0].Id -eq $firstId -and $script:ChromeSessions[0].Proxy -eq $firstProxy) 'Incremento cambio una sesion existente'
    Invoke-QueueCommand '1' | Out-Null
    Invoke-QueueCommand '2' | Out-Null
    Assert ($script:ChromeSessions[1].Proxy -eq $script:Socks5Proxies[1]) 'No libero el proxy sobrante'
    Invoke-QueueCommand 'r' | Out-Null
    Assert ($script:ChromeSessions[0].Id -ne $firstId -and $script:ChromeSessions[0].Proxy -eq $firstProxy) 'Reinicio debe renovar perfil y conservar asignacion de proxies'
    Invoke-QueueCommand '0' | Out-Null

    foreach ($invalid in @('http://proxy:80', 'proxy', 'proxy:0', 'proxy:65536', 'proxy:1080/path',
                          'proxy:1080?x=1', 'proxy:1080#x', 'proxy:1080,direct://',
                          'socks5://u:secreto@proxy:1080', 'socks5://@proxy:1080', '# vacio')) {
        Set-Content -LiteralPath $proxyPath -Value $invalid
        $rejected = $false
        try { Read-Socks5Proxies $proxyPath | Out-Null } catch {
            $rejected = $true
            Assert ($_.Exception.Message -notmatch 'secreto') 'No imprimir credenciales'
        }
        Assert $rejected "Proxy invalido aceptado: $invalid"
    }
    Set-Content -LiteralPath $proxyPath -Value @('PROXY.example:1080', 'socks5://proxy.example.:01080/')
    $rejected = $false
    try { Read-Socks5Proxies $proxyPath | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Proxies duplicados aceptados'
    Write-Host 'OK: SOCKS5 distintos, argumentos, capacidad, incremento, reduccion, reinicio y rechazo de credenciales.'
} finally {
    [IO.File]::Delete($proxyPath)
}

Add-Type -Path "$PSScriptRoot/socks5-bridge.cs"
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class QueueTestStream : MemoryStream {
    readonly MemoryStream input;
    public QueueTestStream(byte[] bytes) { input = new MemoryStream(bytes); }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
        token.ThrowIfCancellationRequested();
        return Task.FromResult(input.Read(buffer, offset, Math.Min(count, 1)));
    }
}
'@
$packet = [QueueSocksBridge]::AuthenticationPacket('demo', 'pass')
Assert (($packet -join ',') -eq '1,4,100,101,109,111,4,112,97,115,115') 'Paquete de autenticacion incorrecto'
foreach ($reply in @([byte[]](5,2,1,0), [byte[]](5,2,1,1), [byte[]](5,0), [byte[]](5))) {
    $client = [QueueTestStream]::new([byte[]](5,1,0))
    $remote = [QueueTestStream]::new($reply)
    $failed = $false
    try { [QueueSocksBridge]::Authenticate($client, $remote, $packet, [Threading.CancellationToken]::None).GetAwaiter().GetResult() }
    catch { $failed = $true }
    $success = $reply.Length -eq 4 -and $reply[3] -eq 0
    Assert ($failed -ne $success) 'No rechazo autenticacion fallida o respuesta truncada'
    if ($success) {
        Assert (($client.ToArray() -join ',') -eq '5,0') 'Respuesta incorrecta a Chrome'
        Assert (($remote.ToArray() -join ',') -eq ('5,1,2,' + ($packet -join ','))) 'Credenciales no enviadas al upstream'
    }
    $client.Dispose(); $remote.Dispose()
}
$script:ProxyFile = ''
$script:ProxySeller = $true
$script:Bridges = [Collections.Generic.List[object]]::new()
function New-SessionBridge($Index, $Visitor) {
    $bridge = [pscustomobject]@{ Port = (20000 + $Index); Visitor = $Visitor; Closed = $false }
    $bridge | Add-Member ScriptMethod Dispose { $this.Closed = $true }
    $script:Bridges.Add($bridge)
    return $bridge
}
Set-ChromeTotal 2
Assert ($script:ChromeSessions[0].Proxy -ne $script:ChromeSessions[1].Proxy) 'Puente repetido'
Set-ChromeTotal 0
Assert ($script:Bridges[0].Closed -and $script:Bridges[1].Closed) 'Puentes sin cerrar'
$failed = $false
try { Set-ChromeTotal 1001 } catch { $failed = $true }
Assert $failed 'Excedio el rango de puertos del proveedor'
Write-Host 'OK: autenticacion SOCKS5 fragmentada, fallo cerrado, puentes por sesion y limpieza.'
