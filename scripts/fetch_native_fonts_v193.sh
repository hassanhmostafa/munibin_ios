#!/bin/sh
set -eu

FONT_DIR="${SRCROOT}/www/assets/native-fonts"
MANIFEST="${FONT_DIR}/font-manifest-v193.tsv"
mkdir -p "${FONT_DIR}"

if [ ! -f "${MANIFEST}" ]; then
  echo "error: Missing Munibin native font manifest: ${MANIFEST}" >&2
  exit 1
fi

valid_woff2() {
  file="$1"
  [ -s "$file" ] || return 1
  [ "$(wc -c < "$file" | tr -d ' ')" -ge 1024 ] || return 1
  magic="$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')"
  [ "$magic" = "774f4632" ]
}

TAB="$(printf '\t')"
while IFS="$TAB" read -r filename primary fallback; do
  [ -n "${filename:-}" ] || continue
  case "$filename" in \#*) continue ;; esac

  destination="${FONT_DIR}/${filename}"
  if valid_woff2 "$destination"; then
    continue
  fi

  rm -f "$destination"
  downloaded=0
  for url in "$primary" "$fallback"; do
    [ -n "${url:-}" ] || continue
    echo "Vendoring Munibin font: ${filename}"
    if /usr/bin/curl -L --fail --silent --show-error --retry 3 --connect-timeout 20 --max-time 90 \
      -A 'Munibin-Native-Build/193' -o "$destination" "$url"; then
      if valid_woff2 "$destination"; then
        downloaded=1
        break
      fi
    fi
    rm -f "$destination"
  done

  if [ "$downloaded" -ne 1 ]; then
    echo "error: Unable to vendor native font ${filename}" >&2
    exit 1
  fi
done < "$MANIFEST"

# Every file referenced by the manifest must now exist and be a WOFF2.
while IFS="$TAB" read -r filename _rest; do
  [ -n "${filename:-}" ] || continue
  case "$filename" in \#*) continue ;; esac
  if ! valid_woff2 "${FONT_DIR}/${filename}"; then
    echo "error: Native font validation failed for ${filename}" >&2
    exit 1
  fi
done < "$MANIFEST"
