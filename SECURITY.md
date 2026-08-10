# Seguridad

## Modelo de exposición

Codex Watch Bridge está diseñado para una red privada de ZeroTier. No debe publicarse el puerto `48720` mediante NAT, port forwarding, túneles públicos ni proxies accesibles desde Internet.

El tráfico HTTP viaja dentro del transporte cifrado de ZeroTier. La autenticación mediante token es una defensa adicional, no un sustituto de la red privada. Todos los miembros autorizados en la misma red ZeroTier deben considerarse capaces de intentar conectar con el bridge.

El socket puede aparecer como listener global en herramientas del sistema porque `Network.framework` no identifica de forma estable la interfaz virtual de ZeroTier cuando el tráfico llega desde redes móviles. El bridge cancela antes de leer datos cualquier conexión cuyo origen no pertenezca al CIDR asignado por ZeroTier; después aplica el token y el rate limiting.

## Datos sensibles

- El repositorio no debe contener direcciones de red reales, tokens, identificadores de red ZeroTier ni datos exportados de conversaciones.
- El token del bridge se guarda en Keychain y puede revocarse desde la aplicación de macOS.
- La URL privada se guarda en las preferencias locales del iPhone.
- Los mensajes y órdenes se procesan en memoria y no se persisten por la aplicación.

## Reporte de vulnerabilidades

No abras una issue pública con tokens, direcciones privadas, capturas de conversaciones o instrucciones de explotación contra una instalación real. Utiliza el canal privado de reporte de seguridad de GitHub si está habilitado para el repositorio.
