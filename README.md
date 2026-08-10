# Codex Watch

Aplicación experimental para seleccionar una tarea reciente de Codex desde el Apple Watch, consultar sus últimos mensajes, dictar una orden, revisarla y enviarla al Codex que se ejecuta en el Mac.

## Componentes

- `CodexWatch`: app compañera para iPhone y enlace con WatchConnectivity.
- `CodexWatch Watch App`: selector cronológico, dictado, revisión y envío.
- `CodexWatchBridge`: puente local autenticado que habla con `codex app-server`.

El puente detecta la red IPv4 activa de ZeroTier y cancela antes de leer datos cualquier conexión cuyo origen no pertenezca a su CIDR privado. Exige el token de acceso mostrado por la aplicación de macOS y no publica Bonjour ni procesa HTTP desde Wi-Fi, Ethernet física o loopback.

El icono de la barra de menús es verde solamente cuando tanto el servidor HTTP como `codex app-server` están disponibles; en cualquier otro estado es rojo. Los mensajes se cargan bajo demanda al abrir una tarea en el reloj, evitando sondear el historial de todas las tareas.

## Fuera de casa

Configura en la app del iPhone la URL privada del Mac, por ejemplo `http://<IP-PRIVADA>:48720`, y pega el token copiado desde el bridge. La dirección queda guardada únicamente en el dispositivo y no forma parte del código fuente. El token aleatorio de 256 bits se guarda en Keychain tanto en macOS como en iOS. Así puede alcanzar el puente desde otra red siempre que ZeroTier esté activo también en el iPhone. WatchConnectivity mantiene el Apple Watch desacoplado de este detalle: el reloj sigue hablando con el iPhone y el iPhone reenvía la orden por la red privada.

El servicio HTTP no debe exponerse directamente a Internet. ZeroTier cifra el transporte y el token añade una segunda comprobación en el puente. El cliente solo acepta URLs HTTP con una dirección IPv4 privada y el puerto `48720`.

## Controles de seguridad

- Allowlist dinámica del CIDR que comunica `zerotier-cli`; si ZeroTier no está activo, el servidor no se inicia y cualquier origen ajeno se cancela antes de leer datos.
- Token de 256 bits generado con `SecRandomCopyBytes`, almacenado en Keychain y comparado en tiempo constante.
- Bloqueo temporal tras cinco intentos de autenticación fallidos por origen.
- Máximo de 24 conexiones simultáneas y tiempo máximo de 30 segundos por conexión.
- Cabeceras limitadas a 16 KiB y cuerpo limitado a 64 KiB; no se admite `Transfer-Encoding`.
- Mensajes de error HTTP genéricos: los detalles internos solo se registran localmente.
- `/health` requiere la misma autenticación que el resto de endpoints.

La superficie y las limitaciones conocidas se documentan en [SECURITY.md](SECURITY.md).

## Puente del Mac

La compilación activa puede instalarse en `~/Applications/CodexWatchBridge.app`. Un LaunchAgent local puede iniciarla al abrir sesión. El icono rojo indica que Codex o la red privada no están listos; el verde confirma que ambos servicios responden. El endpoint `/health` solo está disponible a través de la dirección ZeroTier y requiere el token.
