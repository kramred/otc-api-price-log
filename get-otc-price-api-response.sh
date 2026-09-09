#!/usr/bin/env bash
set -euo pipefail

# Configuration
BASE_URL="https://calculator.otc-service.com/en/open-telekom-price-api/v2/"
LIMIT_MAX=987654
LIMIT_FROM_STEP=500                # recordsPerPage; used for pagination, not really needed with limitMax
CURR_DATE="$(date -u +'%Y-%m-%d')" # current date in the format 2026-06-24
OUT_DIR="./${CURR_DATE}"           # where to store individual responses
COMBINED_FILE="${OUT_DIR}/all-results.json"
LOG_FILE="${OUT_DIR}/fetch.log"
GET_PAGES=1
PADDING_WIDTH=5

mkdir -p "${OUT_DIR}"

# Abort if combined file for this date already exists
if [[ -f "${OUT_DIR}/price-api-response_00000.json" ]]; then
  printf '"%s" already exists, aborting.\n' "${OUT_DIR}/price-api-response_00000.json" >&2
  exit 1
fi

log() {
  printf '\t%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG_FILE}" >&2
}

# Fetch a single page, given offset (limitFrom)
fetch_page() {
  local offset="$1"
  # Ensure padding width is set; default to 5 if not
  local width="${PADDING_WIDTH:-5}"

  # Zero-padded numeric label based on offset
  local padded
  padded=$(printf "%0*d" "${width}" "${offset}")

  local out_file="${OUT_DIR}/price-api-response_${padded}.json"

  log "Fetching with limitMax=${LIMIT_MAX} and offset=${offset} -> ${out_file}"
  # ?responseFormat=json&limitMax=99999&apiVersion=v2&nocache=0&limitFrom=0
  curl -sS "${BASE_URL}?responseFormat=json&limitMax=${LIMIT_MAX}&apiVersion=v2&nocache=0&limitFrom=${offset}" -o "${out_file}"

  # Basic validation
  local http_code
  http_code=$(jq -r '.response.httpCode // empty' "${out_file}" 2>/dev/null || echo "")
  if [[ "${http_code}" != "200" ]]; then
    log "ERROR: httpCode=${http_code:-N/A} for offset=${offset}"
    return 1
  fi
}

# Discover count and maxPages from the first page
discover_stats() {
  local first_file="${OUT_DIR}/price-api-response_00000.json"
  fetch_page 0

  local count max_pages records_per_page
  count=$(jq -r '.response.stats.count' "${first_file}")
  max_pages=$(jq -r '.response.stats.maxPages' "${first_file}")
  records_per_page=$(jq -r '.response.stats.recordsPerPage' "${first_file}")

  LIMIT_FROM_STEP=$records_per_page
  PADDING_WIDTH="$(( ${#count} + 1 ))"

  local padded
  padded=$(printf "%0*d" "${PADDING_WIDTH}" 0)

  local out_file="${OUT_DIR}/price-api-response_${padded}.json"
  [[ $first_file != $out_file ]] &&  mv -vn $first_file $out_file # adjust padding of first file if needed

  log "Stats: count=${count}, maxPages=${max_pages}, recordsPerPage=${records_per_page}"

  # Prefer maxPages if present; fall back to count/recordsPerPage
  if [[ "${max_pages}" != "null" && "${max_pages}" -gt 0 ]]; then
    GET_PAGES="${max_pages}"
  else
    # Calculate pages as ceil(count / records_per_page)
    local pages
    pages=$(( (count + records_per_page - 1) / records_per_page ))
    GET_PAGES="${pages}"
  fi
}

# Fetch all pages
fetch_all_pages() {
  discover_stats
  local pages="${GET_PAGES}"
  log "Will fetch ${GET_PAGES} pages in total..."

  local offset=${LIMIT_FROM_STEP}
  local page=2 # we got page 1 already when calling discover_stats

  while [[ "${page}" -le "${pages}" ]]; do
    fetch_page "${offset}"
    page=$((page + 1))
    offset=$((offset + LIMIT_FROM_STEP))
  done
}

# Combine all result arrays from stored files into one JSON
combine_results() {
  # This is only needed if results are paginated - with limitMax=99999 working, this is not needed
  log "Combining result arrays from ${OUT_DIR} into ${COMBINED_FILE}"

  jq -s '
    . as $files
    | def all_result_keys:
        [ $files[] | .response.result | keys[] ] | unique;
    def concat_key($k):
        [ $files[] | .response.result[$k] ] | add;

    {
      response: {
        combinedAt: now | strftime("%Y-%m-%d %H:%M:%S"),
        sourceUrl: "'"${BASE_URL}"'",
        stats: {
          totalCount: ($files | map(.response.stats.count) | max)
        },
        result: (
          reduce all_result_keys[] as $k
            ({}; . + { ($k): concat_key($k) })
        )
      }
    }
  ' "${OUT_DIR}"/price-api-response_*.json > "${COMBINED_FILE}"

  log "Combined file written to ${COMBINED_FILE}"
}

convert_to_csv() {
  log "Converting file to csv: ${OUT_DIR}/price-api-response_00000.csv"
  jq -r '.response.result | to_entries as $g | ($g[0].value[0] | keys_unsorted) as $cols | ($cols | @csv), ( $g[] | .value[] | [ .[$cols[]] ] | @csv )' "${OUT_DIR}/price-api-response_00000.json" > "${OUT_DIR}/price-api-response_00000.csv"
}

keep_if_changed() {
  local arr md5s nr
  log "Checking for changes vs. recorded data in ${OUT_DIR}/price-api-response_00000.csv"
  mapfile arr -t < <(find ./*/ -name price-api-response_00000.csv)
  log "md5sum of all csv files found:"
  echo 
  md5sum ${arr[@]}
  mapfile md5s -t < <(md5sum ${arr[@]} | awk '{print $1}')
  nr="${#md5s[@]}"
  if [[ ${md5s[$((nr-1))]} != ${md5s[$((nr-2))]} ]]; then
    log "Keeping ${OUT_DIR}/price-api-response_00000.json"
    git config --local user.name  "github-actions[bot]"
    git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"

    git add -A
    git commit -am "update with changes from $CURR_DATE"
    git push
  fi
}

main() {
  log "Starting OTC price API fetch"
  fetch_all_pages
  # combine_results
  convert_to_csv
  keep_if_changed
  log "Done"
}

main "$@"