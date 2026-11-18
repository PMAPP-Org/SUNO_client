# ADR-0007: Equipos con outboxes propias por tipo, fuera del push de sync

- **Estado:** Aceptada
- **Fecha:** 2026-11-08

## Contexto

Lecturas de horómetro, preoperacionales, combustible, viajes e informes de uso son eventos que solo se crean (no se editan) y el servidor los expone como endpoints REST propios, no como entidades del pull.

## Decisión

- Una tabla outbox por tipo en Drift (`MeterReadingOutbox`, `InspectionOutbox`, `FuelFillOutbox`, `TripOutbox`, `UsageReportOutbox`) y cachés de catálogos (`EquipmentCache`, `FuelCatalogCache`, `TransportCatalogCache`).
- Cada envío lleva un `id` generado en el teléfono; el servidor trata el reenvío como idempotente.
- El `SyncCoordinator` las drena en el mismo ciclo (`syncEquipment`).

## Consecuencias

- No toca el protocolo de sync de registros ni su contrato de entidades.
- Cada tipo nuevo es una tabla y un cliente HTTP más; sin cuarentena común con los registros.

## Referencias

- Commit `06de511`; `lib/data/local/tables.dart`, `lib/core/equipment/`, `lib/data/http/equipment_api_client.dart`; servidor `server/suno/equipment/schemas.py` (`MeterReadingIn`: «reenviarla es idempotente»).
