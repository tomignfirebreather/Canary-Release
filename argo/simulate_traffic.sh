#!/usr/bin/env bash
set -euo pipefail

# simulate_traffic.sh
# Uso:
#   ./simulate_traffic.sh TOOL URL ERROR_THRESHOLD REQUESTS CONCURRENCY DURATION
# Ejemplo:
#   ./simulate_traffic.sh curl http://demo.local/ 10 50 10 30s
#
TOOL="${1:-curl}"                       # curl | hey | wrk
URL="${2:-http://demo.local/}"          # URL a probar (ingress)
ERROR_THRESHOLD="${3:-10}"              # porcentaje máximo de errores permitido
REQUESTS="${4:-50}"                     # para curl/hey: requests totales (por endpoint)
CONCURRENCY="${5:-10}"                  # para hey/wrk
DURATION="${6:-30s}"                    # para wrk

# Auxiliar para imprimir y timestamp
ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "$(ts) simulate_traffic: tool=$TOOL url=$URL threshold=${ERROR_THRESHOLD}% requests=$REQUESTS concurrency=$CONCURRENCY duration=$DURATION"

# Funciones por herramienta
traffic_curl() {
  local errors=0
  for i in $(seq 1 "$REQUESTS"); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$URL" || echo "000")
    if [ "$code" != "200" ]; then
      errors=$((errors+1))
    fi
  done
  echo "$errors"
}

traffic_hey() {
  if ! command -v hey >/dev/null 2>&1; then
    echo "$(ts) simulate_traffic: hey no está instalado. Instalalo o usa curl/wrk." >&2
    return 2
  fi

  # Ejecuta hey y captura la sección "Status code distribution"
  out=$(hey -n "$REQUESTS" -c "$CONCURRENCY" "$URL" 2>&1) || true
  echo "$out" > /tmp/hey_output.$$  # para debugging
  # Extraer códigos y cuentas (líneas después de "Status code distribution:")
  codes=$(awk '/Status code distribution:/ {p=1; next} p && NF==0 {exit} p{print}' /tmp/hey_output.$$ || true)

  # sumar todo lo que no sea 200
  errors=0
  while read -r line; do
    [ -z "$line" ] && continue
    # formato típico: "  200  50"
    code=$(echo "$line" | awk '{print $1}')
    count=$(echo "$line" | awk '{print $2}')
    if [ "$code" != "200" ]; then
      errors=$((errors + count))
    fi
  done <<< "$codes"

  echo "$errors"
}

traffic_wrk() {
  if ! command -v wrk >/dev/null 2>&1; then
    echo "$(ts) simulate_traffic: wrk no está instalado. Instalalo o usa curl/hey." >&2
    return 2
  fi

  # Creamos script Lua temporal para que wrk cuente respuestas != 200
  lua_file=$(mktemp /tmp/wrk_XXXX.lua)
  cat > "$lua_file" <<'EOF'
counter = 0
request = function()
  return wrk.format(nil, nil)
end
response = function(status, headers, body)
  if status ~= 200 then
    counter = counter + 1
  end
end
done = function(summary, latency, requests)
  print("WRK_ERRORS:" .. counter)
end
EOF

  # correr wrk; imprimirá WRK_ERRORS:NUM al final
  out=$(wrk -t2 -c"$CONCURRENCY" -d"$DURATION" --timeout 20000s -s "$lua_file" "$URL" 2>&1) || true
  echo "$out" > /tmp/wrk_output.$$   # para debugging
  rm -f "$lua_file"

  # extraer WRK_ERRORS:\d+
  err_line=$(echo "$out" | grep -oE 'WRK_ERRORS:[0-9]+' || true)
  if [ -z "$err_line" ]; then
    # si no lo encontró, asumimos 0 errores (pero lo avisamos)
    echo "$(ts) simulate_traffic: wrk no devolvió WRK_ERRORS en salida. Ver /tmp/wrk_output.$$" >&2
    echo 0
    return 0
  fi
  echo "${err_line#WRK_ERRORS:}"
}

# Ejecuta la función correspondiente
case "$TOOL" in
  curl)
    ERRORS=$(traffic_curl)
    RET=$?
    ;;
  hey)
    ERRORS=$(traffic_hey)
    RET=$?
    ;;
  wrk)
    ERRORS=$(traffic_wrk)
    RET=$?
    ;;
  *)
    echo "Uso: $0 [curl|hey|wrk] [URL] [ERROR_THRESHOLD] [REQUESTS] [CONCURRENCY] [DURATION]" >&2
    exit 2
    ;;
esac

if [ "$RET" -ne 0 ]; then
  echo "$(ts) simulate_traffic: la herramienta $TOOL devolvió código $RET. Abortando." >&2
  exit 2
fi

# cálculos
TOTAL_REQUESTS=$(( REQUESTS ))
# En este script asumimos traffic hacia UN endpoint (el Ingress que routea entre stable/canary).
# Si querés medir v1+v2 por separado, podés invocar el script 2 veces hacia /v1 y /v2.
ERROR_PERCENT=0
if [ "$TOTAL_REQUESTS" -gt 0 ]; then
  ERROR_PERCENT=$(( ERRORS * 100 / TOTAL_REQUESTS ))
fi

echo "$(ts) simulate_traffic: resultados -> errors=$ERRORS total=$TOTAL_REQUESTS percent=${ERROR_PERCENT}% (threshold=${ERROR_THRESHOLD}%)"

if [ "$ERROR_PERCENT" -ge "$ERROR_THRESHOLD" ]; then
  echo "$(ts) simulate_traffic: ERROR: superado umbral de errores" >&2
  exit 1
fi

echo "$(ts) simulate_traffic: OK - errores dentro del umbral"
exit 0
