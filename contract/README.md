# Contrato con el servidor (copia fijada)

La **fuente de verdad** del contrato de la API vive en el servidor:
[`PMAPP-Org/SUNO_server` → `server/openapi/`](https://github.com/PMAPP-Org/SUNO_server/tree/master/server/openapi).
Esta carpeta es una **copia fijada** de esos archivos en un commit concreto del servidor, el que indica [`SOURCE`](SOURCE):

| Archivo | Qué es | Quién lo usa aquí |
|---|---|---|
| `v1.yaml` | Contrato OpenAPI 3.1 de la API v1 (RD-03) | referencia para los clientes HTTP de `lib/data/http/` |
| `fixtures/forms_parity.json` | Casos del DSL de formularios (ADR-012) que deben dar el mismo resultado en el servidor y en la app | `test/core/forms/parity_test.dart`, `test/ui/forms/dynamic_form_test.dart` |

## Por qué una copia y no una referencia

- Los tests de la app se ejecutan sin red y sin el repositorio del servidor: el resultado de un commit no puede depender de lo que haya en el servidor hoy.
- Cambiar el contrato en la app es una **decisión explícita** en un PR que actualiza `SOURCE`, no algo que llega solo.

## Cómo se vigila que no se quede atrás

El workflow [`contract.yml`](../.github/workflows/contract.yml) comprueba dos cosas en cada PR y cada lunes:

1. **Integridad (bloqueante).** Estos archivos son idénticos a los del servidor en el commit de `SOURCE`. Nadie edita el contrato a mano en este repositorio: los cambios se hacen en el servidor.
2. **Desfase (aviso, no bloquea).** Si el contrato de `master` del servidor ya es distinto, el job lo anota en el resumen. Hay que actualizar la copia y ejecutar los tests de paridad.

## Actualizar a una versión nueva del contrato

```bash
REF=<sha o tag de SUNO_server>
for f in v1.yaml fixtures/forms_parity.json; do
  curl -fsSL "https://raw.githubusercontent.com/PMAPP-Org/SUNO_server/${REF}/server/openapi/${f}" -o "contract/${f}"
done
sed -i "s|^ref=.*|ref=${REF}|" contract/SOURCE
flutter test test/core/forms/
```

Si los tests de paridad fallan, el servidor y la app ya no están de acuerdo sobre qué formulario es válido. Se corrige antes de integrar.
