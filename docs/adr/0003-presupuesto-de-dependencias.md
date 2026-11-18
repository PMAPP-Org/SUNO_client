# ADR-0003: Presupuesto de dependencias

- **Estado:** Aceptada
- **Fecha:** 2026-08-02

## Contexto

ADR-0001 del servidor señala como riesgo depender de paquetes de terceros de calidad desigual.

## Decisión

Toda dependencia directa nueva necesita una fila en [`DEPENDENCIES.md`](../../DEPENDENCIES.md) que diga qué resuelve, por qué esa y no otra y si cumple la regla: plugin oficial de flutter.dev/dart.dev/Google o más de 1000 likes en pub.dev con mantenimiento activo. También se anota la ausencia deliberada de un paquete. Las licencias nuevas las revisa `tool/check_new_licenses.py`.

## Consecuencias

- Un PR que añade una dependencia sin su fila no está completo.
- El archivo hay que mantenerlo: hoy está desactualizado (ver [`../bugs/problemas-conocidos.md`](../bugs/problemas-conocidos.md)).

## Referencias

- Paso 10 (`a13c2a5`); `DEPENDENCIES.md`.
