# Seguridad

## Modelo de exposición

Codex Watch Bridge está diseñado para redes privadas: VPN como ZeroTier, Tailscale o WireGuard. El listener se vincula exclusivamente a la IPv4 privada seleccionada y rechaza pares ajenos a su subred; no escucha en Wi-Fi/LAN ni debe publicarse el puerto HTTP `48720` mediante NAT, port forwarding o túneles públicos.

En una VPN cifrada, el tráfico HTTP queda protegido por ese transporte. Para un dominio o una IP pública, el Companion exige HTTPS y debe colocarse un proxy TLS seguro delante del bridge. Todos los equipos de la misma subred VPN deben considerarse capaces de intentar conectar con él.

El bridge vincula el socket a la dirección VPN detectada y cancela antes de leer datos cualquier conexión cuyo origen no sea loopback o el CIDR asignado; después aplica el token y el rate limiting.

## Datos sensibles

- El repositorio no debe contener direcciones de red reales, tokens, identificadores de red ZeroTier ni datos exportados de conversaciones.
- El token del bridge se guarda en Keychain y puede revocarse desde la aplicación de macOS.
- La API key de OpenAI se guarda en una entrada separada de Keychain en el Mac; nunca se envía al iPhone o al Watch ni se incluye en el repositorio.
- La URL privada se guarda en las preferencias locales del iPhone.
- Los mensajes y órdenes de texto se procesan en memoria. Las notas de voz se guardan transitoriamente durante el transporte y la transcripción y se eliminan después de procesarlas.
- El dictado del Apple Watch se procesa mediante el servicio elegido por watchOS. En el modo OpenAI API, el bridge envía el fichero de audio a OpenAI para su transcripción facturable.

## Reporte de vulnerabilidades

No abras una issue pública con tokens, direcciones privadas, capturas de conversaciones o instrucciones de explotación contra una instalación real. Utiliza el canal privado de reporte de seguridad de GitHub si está habilitado para el repositorio.
