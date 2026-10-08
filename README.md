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

Cada perfil tiene un GUID aleatorio para identificarlo en consola. Chrome y el servidor crean sus cookies normalmente: el GUID no sustituye la cookie de sesión de tu cola. Las sesiones comparten la conexión/IP del equipo. No se pulsan botones ni se saltan pasos de acceso. Usa los comandos de la consola para cerrar las ventanas.

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

La prueba simula procesos para verificar los comandos y el aislamiento de perfiles, sin abrir navegadores. La versión PowerShell aún necesita ejecutarse y validarse en un equipo con PowerShell; el entorno donde se preparó no lo tiene instalado. Las pruebas de la versión Python anterior no acreditan este script.

Referencia: [perfiles independientes mediante `user-data-dir`, documentación de Chrome](https://developer.chrome.com/docs/chromedriver/capabilities#use-a-custom-profile).
