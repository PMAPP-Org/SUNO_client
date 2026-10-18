"""Comprueba el mapa hallazgo → test del Paso 25 (copia de SUNO_server).

El mapa vive en SUNO_server (`docs/seguridad/hallazgos-tests.toml`) porque
cubre los dos repositorios. Mobile CI lo descarga y comprueba con esta copia
del script que **las evidencias de este repositorio** existen: si se renombra o
borra el test que cubre un hallazgo (H-01, H-04, H-05, H-10…), falla.

- Están los 21 hallazgos, H-01…H-21, sin repetir.
- Cada uno es `not_applicable` (con motivo) o tiene al menos una evidencia de
  tipo "test" o "stack".
- Cada evidencia del repositorio que se comprueba existe y contiene su texto.

Uso:
    python3 tool/check_findings_map.py --repo client --map hallazgos-tests.toml

Mantener igual que `infra/scripts/check_findings_map.py` de SUNO_server.
"""

from __future__ import annotations

import argparse
import sys
import tomllib
from pathlib import Path

EXPECTED = [f"H-{n:02d}" for n in range(1, 22)]
KINDS = {"test", "lint", "stack"}
REPOS = {"server", "client"}


def check(data: dict, repo: str, root: Path) -> list[str]:
    problems: list[str] = []
    findings = data.get("finding", [])
    ids = [f.get("id") for f in findings]
    if sorted(ids) != EXPECTED:
        missing = sorted(set(EXPECTED) - set(ids))
        extra = sorted(set(ids) - set(EXPECTED))
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        problems.append(f"hallazgos: faltan {missing}, sobran {extra}, repetidos {dupes}")

    checked = 0
    for finding in findings:
        fid = finding.get("id", "?")
        evidence = finding.get("evidence", [])
        if "not_applicable" in finding:
            if evidence or not str(finding["not_applicable"]).strip():
                problems.append(f"{fid}: not_applicable necesita motivo y ninguna evidencia")
            continue
        if not any(e.get("kind") in {"test", "stack"} for e in evidence):
            problems.append(f"{fid}: ninguna evidencia de tipo test o stack")
        for item in evidence:
            if item.get("repo") not in REPOS or item.get("kind") not in KINDS:
                problems.append(f"{fid}: evidencia mal formada {item}")
                continue
            if item["repo"] != repo:
                continue
            checked += 1
            path = root / item["path"]
            if not path.is_file():
                problems.append(f"{fid}: no existe {item['path']}")
            elif item["contains"] not in path.read_text(encoding="utf-8"):
                problems.append(f"{fid}: {item['path']} ya no contiene {item['contains']!r}")
    if checked == 0:
        problems.append(f"ninguna evidencia del repositorio {repo!r}: ¿mapa equivocado?")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", choices=sorted(REPOS), required=True)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--map", type=Path, default=Path("docs/seguridad/hallazgos-tests.toml"))
    args = parser.parse_args()

    data = tomllib.loads(args.map.read_text(encoding="utf-8"))
    problems = check(data, args.repo, args.root)
    if problems:
        print("Mapa hallazgo → test incompleto:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    count = len(data["finding"])
    print(f"OK: {count} hallazgos mapeados; evidencias de {args.repo} presentes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
