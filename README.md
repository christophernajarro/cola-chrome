# Cola Chrome — solo consola

Abre visitantes de prueba con perfiles independientes de Chrome. No usa Python, Selenium, `.venv` ni una interfaz web.

## Windows

Con Chrome instalado, abre PowerShell en la carpeta del repositorio:

```powershell
.\cola-chrome.ps1
```

También puedes iniciar directamente un lote:

```powershell
.\cola-chrome.ps1 -Url 'https://tu-staging.example/concierto' -Sesiones 10
```

Si PowerShell indica que los scripts están deshabilitados, permite scripts locales para esa sesión: `Set-ExecutionPolicy -Scope Process RemoteSigned`. En equipos administrados se respeta la política de la organización.

## Comandos

| Entrada | Acción |
| --- | --- |
| `10`, `20`, `50`… | Ajusta el total. Aumentar conserva las sesiones anteriores; reducir cierra las últimas. |
| `0` | Cierra todas y deja la consola lista para abrir otro lote. |
| `r` | Cierra y vuelve a abrir el total actual, con perfiles y cookies nuevos. |
| `q` | Cierra las sesiones y sale. |

Para corregir un exceso, escribe el total correcto. Para empezar desde cero con otra cantidad: `0` y después el nuevo número. Cada lote lanza los procesos sin esperar a que la página termine de cargar. No sincroniza las peticiones al milisegundo ni mide tiempos de carga. No hay timeout de navegación ni cierre automático.

Cada perfil tiene un GUID aleatorio para identificarlo en consola. Chrome y el servidor crean sus cookies normalmente: el GUID no sustituye la cookie de sesión de tu cola. Sin opciones de proxy, las sesiones comparten la conexión/IP del equipo. Usa los comandos de la consola para cerrar las ventanas.

## SOCKS5 por sesión

Con la lista especial **Api-Tools de Proxy-Seller**, ejecuta en Mac o PowerShell 7 de Windows:

```sh
pwsh -File ./cola-chrome.ps1 -ProxySeller -Sesiones 10
```

Pregunta el login base de Api-Tools, la contraseña oculta y la URL de staging. No necesitas `.env`, API key ni guardar credenciales. Por defecto selecciona Perú; puedes cambiarlo con `-ProxyCountry US`.

Cada Chrome obtiene perfil nuevo, puerto upstream distinto (10000–10999) y login con `_c_PE_s_<GUID>`. `r` renueva perfiles e identificadores de proxy; aumentar el total conserva las sesiones existentes. Máximo 1000 en este modo; la RAM/CPU pueden limitarlo mucho antes. Empieza con 10–20 y revisa el consumo. El proveedor asigna las IP de salida: comprueba las IP recibidas en tu staging; el script no verifica su unicidad ni garantiza que permanezcan disponibles.

Chrome no admite usuario/contraseña para SOCKS5: `socks5-bridge.cs` se carga con .NET incluido en PowerShell y abre un puente solo en `127.0.0.1` por sesión. Las credenciales permanecen en memoria, fuera de los argumentos de Chrome. El puente cierra con la sesión, espera hasta 15 segundos para conectar/autenticar y nunca cambia a conexión directa cuando falla. Está limitado a TCP. No cifra por sí mismo el tramo SOCKS5; usa HTTPS para tu staging.

Para una lista de proxies **sin autenticación o autorizados por IP**, copia `proxies.example.txt` a `proxies.local.txt` y reemplaza los ejemplos por un `socks5://host:puerto` por línea:

```sh
pwsh -File ./cola-chrome.ps1 -ProxyFile ./proxies.local.txt -Sesiones 10
```

Rechaza direcciones duplicadas y cantidades superiores al número de proxies antes de cambiar el lote. `r` conserva las direcciones del archivo. Los archivos `proxies*.txt` locales están excluidos de Git, salvo el ejemplo. No combines `-ProxyFile` con `-ProxySeller`. La lista común con login/contraseña no se admite en este modo; usa Api-Tools o autorización por IP.

Referencias: [conexión y sesiones de Proxy-Seller](https://docs.proxy-seller.com/api-v1/residential-proxy/connect-and-target-via-login), [limitaciones SOCKS5 de Chromium](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md#socks5-proxy-scheme). El valor de rotación `-2` del panel no está documentado en las páginas revisadas y el script no lo interpreta ni modifica.

Opciones: `-Headless` para Chrome sin ventanas, `-ChromePath 'ruta/al/chrome'` para una instalación no estándar. El script administra hasta 10000 sesiones, pero la capacidad real depende de la RAM y CPU; empieza con un lote pequeño.

## Mac

El mismo script requiere PowerShell 7 (`pwsh`) y Chrome:

```sh
pwsh -File ./cola-chrome.ps1
```

## Comprobación

```powershell
.\test-console.ps1
```

La prueba simula procesos y transportes para verificar los comandos, perfiles, asignación de proxies y autenticación SOCKS5, sin abrir navegadores ni consumir tráfico del proveedor. Validada con PowerShell 7 en Mac. La conexión real con Proxy-Seller y la ejecución en Windows requieren validación en esos entornos.

Referencia: [perfiles independientes mediante `user-data-dir`, documentación de Chrome](https://developer.chrome.com/docs/chromedriver/capabilities#use-a-custom-profile).
