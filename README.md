# Codex Watch

Aplicación experimental para seleccionar una tarea reciente de Codex desde el Apple Watch, consultar sus últimos mensajes, grabar una orden de voz y enviarla al Codex que se ejecuta en el Mac.

## Componentes

- `CodexWatch`: app compañera para iPhone y enlace con WatchConnectivity.
- `CodexWatch Watch App`: selector cronológico, lectura de mensajes, dictado o grabación y envío de órdenes.
- `CodexWatchBridge`: puente local autenticado que habla con `codex app-server`.

El puente acepta conexiones procedentes de redes privadas, loopback y, cuando está disponible, del CIDR detectado de ZeroTier. Exige el token de acceso mostrado por la aplicación de macOS y no publica Bonjour.

El icono de la barra de menús es verde solamente cuando tanto el servidor HTTP como `codex app-server` están disponibles; en cualquier otro estado es rojo. Los mensajes se cargan bajo demanda al abrir una tarea en el reloj, evitando sondear el historial de todas las tareas.

La lista del Watch pide una copia fresca al abrirse y cada 10 segundos mientras permanece visible. La petición de WatchConnectivity despierta a la app compañera del iPhone, que consulta el bridge y responde directamente al reloj; además, el iPhone actualiza su copia cada 15 segundos mientras la app puede ejecutarse. Fuera de la lista se conserva la última copia para no gastar batería innecesariamente.

## Órdenes de voz

La app compañera ofrece dos rutas:

- **Dictado del Apple Watch:** el sistema del reloj convierte la voz en texto y la app envía ese texto a Codex. No usa la API de OpenAI.
- **OpenAI API:** el reloj graba una nota AAC/M4A y la transfiere sin transcribir al iPhone y al Mac. El bridge la envía al endpoint de transcripción de OpenAI y entrega el texto resultante a la tarea seleccionada. Esta opción genera facturación de API.

El Companion permite seleccionar cualquiera de los seis modelos de transcripción de ficheros admitidos: `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-mini-transcribe-2025-12-15`, `gpt-4o-transcribe-diarize` y `whisper-1`. La API key se configura en Codex Watch Bridge y se guarda únicamente en el llavero del Mac.

## Fuera de casa

Configura en la app del iPhone el método de conexión, la IP o nombre del Mac, el puerto y el token copiado desde el bridge. La dirección queda guardada únicamente en el dispositivo y no forma parte del código fuente. El token aleatorio de 256 bits se guarda en Keychain tanto en macOS como en iOS. WatchConnectivity mantiene el Apple Watch desacoplado de este detalle: el reloj habla con el iPhone y el iPhone reenvía la petición al Mac.

Para usarlo fuera de casa, la opción recomendada es una IP privada accesible mediante ZeroTier, Tailscale o WireGuard. En la misma red también puede usarse una IPv4 privada o un nombre `.local`. El cliente solo permite HTTP para esos destinos privados; un dominio o una IP pública exige HTTPS y un proxy seguro. El puerto HTTP `48720` del bridge no debe publicarse directamente en Internet.

## Controles de seguridad

- Allowlist de orígenes privados y loopback, complementada con el CIDR que comunica `zerotier-cli` cuando ZeroTier está activo; cualquier origen ajeno se cancela antes de leer datos.
- Token de 256 bits generado con `SecRandomCopyBytes`, almacenado en Keychain y comparado en tiempo constante.
- Bloqueo temporal tras cinco intentos de autenticación fallidos por origen.
- Máximo de 24 conexiones simultáneas y tiempo máximo de 90 segundos por conexión.
- Cabeceras limitadas a 16 KiB y cuerpo limitado a 2 MiB para admitir audio; no se admite `Transfer-Encoding`.
- Mensajes de error HTTP genéricos: los detalles internos solo se registran localmente.
- `/health` requiere la misma autenticación que el resto de endpoints.

La superficie y las limitaciones conocidas se documentan en [SECURITY.md](SECURITY.md).

## Puente del Mac

La compilación activa puede instalarse en `~/Applications/CodexWatchBridge.app`. Un LaunchAgent local puede iniciarla al abrir sesión. El icono rojo indica que Codex o el servidor privado no están listos; el verde confirma que ambos servicios responden. El endpoint `/health` solo acepta orígenes de red privada y requiere el token.
