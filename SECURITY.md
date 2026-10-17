# Política de seguridad

## Reportar una vulnerabilidad

**No abras un issue público** para una vulnerabilidad: este repositorio es público.

Usa el reporte privado de GitHub: pestaña **Security → Report a vulnerability** de este repositorio. Solo lo ven los mantenedores. Si no está disponible, escribe a los mantenedores de [`.github/CODEOWNERS`](.github/CODEOWNERS) pidiendo un canal privado, sin incluir los detalles en el primer mensaje.

Si el fallo está en la API, el panel de administración o la infraestructura, repórtalo en [`PMAPP-Org/SUNO_server`](https://github.com/PMAPP-Org/SUNO_server/security). Si no sabes de qué lado está, hazlo aquí: lo movemos nosotros.

Incluye, si puedes:
- qué versión de la app o qué commit;
- cómo reproducirlo (modelo de teléfono y versión de Android/iOS si importa);
- qué impacto crees que tiene.

## Qué puedes esperar

| Paso | Plazo |
|---|---|
| Acuse de recibo | 3 días hábiles |
| Evaluación inicial y severidad | 7 días hábiles |
| Corrección | Según la severidad: 7 días si es crítica, 30 si es alta, 90 si es media ([política del SGSI](https://github.com/PMAPP-Org/SUNO_server/blob/master/docs/seguridad/politicas.md), §4) |

Te avisaremos cuando esté corregida y, si quieres, te mencionaremos en las notas de la release.

## Alcance

Entra en el alcance el código de este repositorio y los APK publicados en sus releases. **No** se permite probar contra el servidor de producción ataques de denegación de servicio, ingeniería social ni acceso a datos de otras personas.

Lo que más nos interesa:
- validación de TLS (RD-01);
- cifrado de la base de datos local y de los tokens;
- interpretación de plantillas de formulario (RD-06: una plantilla es dato, nunca código);
- fugas de datos personales en logs o en el almacenamiento del teléfono.

## Versiones soportadas

Solo la última release publicada recibe correcciones de seguridad.
