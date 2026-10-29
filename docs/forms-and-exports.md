# Formularios C5 y exportaciones C6

La captura admite grupos repetibles con añadir/eliminar registros, valores
iniciales y códigos QR. El QR puede escribirse manualmente y nunca se abre como
enlace. Los valores iniciales solo se aplican al crear una visita o añadir una
fila; editar una visita conserva sus respuestas, incluso las vacías.

La validación usa el contrato fijado en `contract/SOURCE`, con los mismos casos
de paridad que el servidor. Los errores de grupos conservan rutas de fila y
campo. La captura elimina campos ocultos y encola fotos/firmas de las filas
con el mismo mecanismo transaccional y de sincronización que los demás adjuntos.
El detalle muestra las filas; el mapa incluye las líneas y polígonos anidados.

Para importar un XLSForm se usa el administrador del servidor: abre la plantilla
y selecciona **Importar XLSForm**. Las reglas y el subconjunto admitido están en
[`SUNO_server/docs/forms-and-exports.md`](https://github.com/PMAPP-Org/SUNO_server/blob/8546e55f867dcae69d2e01f870a95869028137ce/docs/forms-and-exports.md).

En el detalle de visita, OWNER, ADMIN y SUPERVISOR disponen de **Exportar visita**:
PDF o GeoJSON, mediante el diálogo de compartir/guardar del dispositivo. Funciona
sin conexión, usando la fuente Inter incluida. Los archivos indican que proceden
del dispositivo y el estado local de sincronización. Los PDF incluyen referencias
de fotos y firmas; sus archivos no se incrustan. No se descargan recursos remotos.

El GeoJSON usa WGS84, longitud/latitud, con una entidad por ubicación o geometría
y rutas como `predios.0.lindero`. Conserva las respuestas completas y las visitas
sin GPS (geometría nula). Los grupos repetibles también se exportan.

Las exportaciones locales usan los roles de la sesión y no producen eventos de
descarga en el servidor. Para lotes GeoPackage o exportaciones centralizadas con
auditoría se usa el administrador, que aplica permisos y aislamiento por organización.

Verificación física pendiente en Android/iOS: permiso y lectura de QR, cancelar
y reanudar cámara, compartir/guardar ambos formatos, abrirlos desde otra app.
Android incluye el modelo de ML Kit para que el escaneo no requiera red.
Las versiones antiguas de la app rechazan tipos desconocidos: actualizar los
dispositivos antes de publicar plantillas con `repeat` o `qr`.
