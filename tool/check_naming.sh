#!/usr/bin/env bash
# Guardia de nombres: la app se llama SUNO y el concepto "registro".
# Falla si aparece `visitacampo` o "visit"/"visita" fuera de las excepciones.
#
# No se revisan el CHANGELOG ni `.gitleaksignore` (historia: citan los nombres de
# entonces) ni esta guardia (nombra lo que busca). Las citas a documentos de
# `plans/` del servidor (`plans/....md`) se permiten: esos documentos históricos
# conservan su nombre. Tampoco el identificador `visitacampo/form@N` del DSL: es
# un dato con el que se guardaron plantillas, y la app lo sigue aceptando
# (`legacyDslVersion` en `lib/core/forms/form_definition.dart`).
set -euo pipefail
cd "$(dirname "$0")/.."
allowed='^(visited|revisit|revisited|revisitar|visitados|visitante|visitantes)$'
status=0
while IFS= read -r file; do
	case "$file" in
	CHANGELOG.md | .gitleaksignore | tool/check_naming.sh | plans/* | *.png | *.jpg | *.jpeg | *.gif | *.ico | *.pdf | *.ttf | *.woff | *.woff2 | *.mbtiles | *.jar | *.keystore) continue ;;
	esac
	[ -f "$file" ] || continue
	words="$( { printf '%s\n' "$file"; cat "$file"; } |
		sed -E -e 's#plans/[A-Za-z0-9_./-]+\.md# #g' -e 's#visitacampo/form@[0-9]+# #g' |
		grep -oiE '[a-z_]*visit[a-z_]*' | grep -viE "$allowed" | sort -u || true)"
	if [ -n "$words" ]; then
		echo "$file: $(echo "$words" | tr '\n' ' ')"
		status=1
	fi
done < <(git ls-files)
if [ "$status" -ne 0 ]; then
	echo "check_naming: quedan nombres viejos (visitacampo / visit / visita); renómbralos a suno / record / registro." >&2
fi
exit "$status"
