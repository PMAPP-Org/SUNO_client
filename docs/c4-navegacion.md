# C4: navegación a la asignación

Desde **Mis asignaciones**, el botón de direcciones abre la orientación al
punto planificado. En el mapa, la ficha de la asignación ofrece **Ir a la
asignación**, junto al acceso existente a la visita. Las asignaciones sin
coordenadas válidas no ofrecen navegación.

La pantalla muestra distancia en línea recta, precisión y azimut inicial
respecto al norte geográfico. El norte está arriba; la flecha no utiliza el
magnetómetro ni sigue la orientación del teléfono. Los cálculos son locales y
funcionan sin conexión. Dentro del margen de precisión se oculta el rumbo y
se pide comprobar el punto en campo; no se marca la asignación como hecha.

El GPS se cancela al salir o al pasar a segundo plano. Al regresar se pide una
posición nueva. Una lectura caduca a los 30 segundos; posiciones no finitas,
fuera de WGS84 o con precisión inválida se descartan. Se informa de permisos
denegados, GPS apagado, pérdida de señal, baja precisión y ubicación simulada.

**Abrir ruta en Google Maps** entrega exclusivamente la latitud y longitud
del destino a una aplicación externa. No transmite el título, los atributos
de la asignación, credenciales ni la posición actual. El proveedor externo
puede solicitar ubicación por su cuenta. Si Google Maps no está instalado,
el sistema abre su página en el navegador. Puede necesitar conexión; esto no
afecta al rumbo local. La pantalla avisa de esta transferencia antes de abrir.
Las coordenadas se muestran en el CRS de Ajustes; la URL siempre usa WGS84.

La implementación usa el plugin oficial
[`url_launcher`](https://pub.dev/packages/url_launcher) y el formato universal
de [Maps URLs](https://developers.google.com/maps/documentation/urls/get-started).
No necesita claves de Google ni permisos adicionales de ubicación.

## Verificación

Las pruebas automatizadas cubren azimuts cardinales, distancia conocida,
antimeridiano, puntos coincidentes y antípodas, coordenadas inválidas, URL sin
datos adicionales, errores y caducidad de GPS, permisos pendientes al salir,
reintentos concurrentes, pausa y reanudación, apertura externa fallida,
coordenadas proyectadas, accesos desde mapa/lista y pantalla pequeña con letra
grande.

Pendiente de dispositivo real (Android/iOS):

- Recorrer dos puntos conocidos y comprobar rumbo, distancia y precisión.
- Repetir sin conexión; comprobar que la orientación local permanece operativa.
- Abrir la ruta con Google Maps instalado y sin instalar, y regresar a SUNO.
- Apagar el GPS, negar permisos, recuperarlos en Ajustes y volver.
- Bloquear el teléfono y comprobar que la navegación libera el GPS; desbloquear
  y esperar una lectura nueva.

C5 (formularios) y C6 (exportación) siguen pendientes. Este bloque no cambia
el contrato del servidor, las bases de datos, el OTP ni la sincronización con
la app cerrada.
