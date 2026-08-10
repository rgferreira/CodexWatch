# Codex Watch

Aplicación experimental para seleccionar una tarea reciente de Codex desde el Apple Watch, consultar sus últimos mensajes, dictar una orden, revisarla y enviarla al Codex que se ejecuta en el Mac.

## Componentes

- `CodexWatch`: app compañera para iPhone y enlace con WatchConnectivity.
- `CodexWatch Watch App`: selector cronológico, dictado, revisión y envío.
- `CodexWatchBridge`: puente local autenticado que habla con `codex app-server`.

El puente escucha en el puerto `48720`, anuncia `_codexwatch._tcp` y exige el código de emparejamiento mostrado por la aplicación de macOS.

El icono de la barra de menús es verde solamente cuando tanto el servidor HTTP como `codex app-server` están disponibles; en cualquier otro estado es rojo. Los mensajes se cargan bajo demanda al abrir una tarea en el reloj, evitando sondear el historial de todas las tareas.

## Fuera de casa

Configura en la app del iPhone la URL privada del Mac, por ejemplo `http://<IP-PRIVADA>:48720`. La dirección queda guardada únicamente en el dispositivo y no forma parte del código fuente. Así puede alcanzar el puente desde otra red siempre que ZeroTier esté activo también en el iPhone. WatchConnectivity mantiene el Apple Watch desacoplado de este detalle: el reloj sigue hablando con el iPhone y el iPhone reenvía la orden por la red privada.

El servicio HTTP no debe exponerse directamente a Internet. ZeroTier cifra el transporte y el código de emparejamiento añade una segunda comprobación en el puente.

## Puente del Mac

La compilación activa está instalada en `~/Applications/CodexWatchBridge.app`. El LaunchAgent `~/Library/LaunchAgents/com.rgferreira.CodexWatchBridge.plist` la inicia al abrir sesión y vuelve a lanzarla únicamente si termina por un fallo. El estado puede comprobarse en `http://127.0.0.1:48720/health`.
