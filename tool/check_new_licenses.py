"""Licencias de las dependencias que **introduce** un PR (ISO 27001 A.5.32).

`actions/dependency-review-action` compara licencias como identificadores
SPDX exactos, pero el grafo de dependencias de GitHub entrega las de pub en
minúsculas (`mit`, `bsd-3-clause`): la acción las da por inválidas y, peor,
un `gpl-3.0-only` en minúsculas no casaría con la lista de prohibidas. Este
script consulta la misma comparación del grafo (base...head del PR) y aplica
la política sin distinguir mayúsculas:

- licencia prohibida (copyleft fuerte, ver `DENY`) → falla;
- dependencia nueva sin licencia declarada en el grafo → falla, salvo que
  esté en `REVIEWED` (licencia comprobada a mano en pub.dev);
- en una expresión con `OR` basta una alternativa permitida
  (`MIT OR GPL-2.0-or-later` se usa bajo MIT).

Uso en CI: `python3 tool/check_new_licenses.py <owner/repo> <base_sha> <head_sha>`
con `GH_TOKEN` en el entorno. Solo biblioteca estándar y `gh`.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

DENY = {
    "gpl-2.0-only",
    "gpl-2.0-or-later",
    "gpl-3.0-only",
    "gpl-3.0-or-later",
    "agpl-3.0-only",
    "agpl-3.0-or-later",
    "sspl-1.0",
    # Identificadores SPDX antiguos con el mismo significado.
    "gpl-2.0",
    "gpl-2.0+",
    "gpl-3.0",
    "gpl-3.0+",
    "agpl-3.0",
}

#: Paquetes cuyo grafo de GitHub no trae licencia, comprobada a mano en
#: pub.dev (`/api/packages/<nombre>/score`, etiqueta `license:`). Revisar si
#: cambia la versión mayor.
REVIEWED = {
    # C5/C6: LICENSE del paquete publicado, verificado el 2026-10-19.
    "mobile_scanner": "bsd-3-clause",
    "pdf": "apache-2.0",
    "share_plus": "bsd-3-clause",
    "share_plus_platform_interface": "bsd-3-clause",
    "barcode": "apache-2.0",
    "bidi": "mit",
    "image": "mit",
    "path_parsing": "mit",
    "qr": "bsd-3-clause",
    "url_launcher_linux": "bsd-3-clause",
    "url_launcher_platform_interface": "bsd-3-clause",
    "url_launcher_web": "bsd-3-clause",
    "url_launcher_windows": "bsd-3-clause",
    "frontend_server_client": "bsd-3-clause",  # dart-lang; build_runner
    "package_info_plus": "bsd-3-clause",  # fluttercommunity; vía dependencias
    # Fase B (mapa): flutter_map y su árbol. Comprobadas en el LICENSE de cada
    # paquete publicado (pub-cache) el 2026-10-18.
    "latlong2": "apache-2.0",
    "dart_earcut": "mit",
    "dart_polylabel2": "bsd-3-clause",
    "mgrs_dart": "mit",
    "posix": "mit",
    "proj4dart": "mit",
    "simple_sparse_list": "bsd-3-clause",
    "unicode": "bsd-3-clause",
    "wkt_parser": "mit",
}

_OR = re.compile(r"\s+or\s+", re.IGNORECASE)
_AND = re.compile(r"\s+(?:and|with)\s+|[()]", re.IGNORECASE)


def is_denied(expression: str) -> bool:
    """`True` si **todas** las alternativas (`OR`) de la expresión SPDX
    contienen alguna licencia prohibida. Sin distinguir mayúsculas."""
    alternatives = _OR.split(expression.replace("(", " ").replace(")", " "))
    return all(
        any(part.strip().lower() in DENY for part in _AND.split(alt) if part.strip())
        for alt in alternatives
        if alt.strip()
    )


def violations(changes: list[dict]) -> list[str]:
    problems = []
    for change in changes:
        if change.get("change_type") != "added":
            continue
        package = change.get("name") or ""
        name = f"{change.get('manifest')} » {package}@{change.get('version')}"
        expression = (change.get("license") or "").strip()
        if not expression or expression.upper() == "NOASSERTION":
            expression = REVIEWED.get(package, "")
        if not expression:
            problems.append(f"{name}: sin licencia declarada")
        elif is_denied(expression):
            problems.append(f"{name}: licencia prohibida ({expression})")
    return problems


def main(repo: str, base: str, head: str) -> int:
    raw = subprocess.run(
        ["gh", "api", f"repos/{repo}/dependency-graph/compare/{base}...{head}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    changes = json.loads(raw)
    added = [c for c in changes if c.get("change_type") == "added"]
    problems = violations(changes)
    print(f"Dependencias nuevas revisadas: {len(added)}")
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
