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
    param($FilePath, $ArgumentList, [switch]$PassThru)
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
