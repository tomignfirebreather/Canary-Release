#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-canary-tp}"
ROLLOUT="${ROLLOUT:-demo-rollout}"
TRAFFIC_TOOL="${1:-curl}"   # curl | hey | wrk
SIM_SCRIPT="${SIM_SCRIPT:-./simulate_traffic.sh}"
PAUSE="${PAUSE:-30}"        # segundos entre patch y prueba
ERROR_THRESHOLD="${ERROR_THRESHOLD:-10}"  # usado solo para imprimir (simulate_traffic tiene su propio umbral)

# Pesos del Canary
WEIGHTS=(5 10 15 30 50 100)

echo "Iniciando Canary Rollout: rollout=$ROLLOUT namespace=$NAMESPACE"
echo "Herramienta de tráfico: $TRAFFIC_TOOL"
echo "Pesos: ${WEIGHTS[*]}"

install_hey_if_needed() {
  if [[ "$TRAFFIC_TOOL" == "hey" ]]; then
    if ! command -v hey &> /dev/null; then
      echo "hey no encontrado. Intentando instalarlo..."
      if command -v go &> /dev/null; then
        echo "Usando 'go install' para instalar hey..."
        GOBIN=$(go env GOBIN)
        if [ -z "$GOBIN" ]; then
          # Fallback if GOBIN is not set, usually defaults to $HOME/go/bin
          export PATH=$PATH:$HOME/go/bin
        else
          export PATH=$PATH:$GOBIN
        fi
        go install github.com/rakyll/hey@latest
        if ! command -v hey &> /dev/null; then
          echo "Error: Fallo la instalacion de hey. Asegurate de que GOBIN este en tu PATH o instalalo manualmente." >&2
          exit 1
        fi
        echo "hey instalado correctamente."
      else
        echo "Error: 'go' no esta instalado, no se puede instalar 'hey' automaticamente. Por favor, instala 'go' y 'hey' manualmente." >&2
        exit 1
      fi
    fi
  fi
}

install_hey_if_needed

# Comprobar existencia del rollout
if ! kubectl get rollout "$ROLLOUT" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Error: rollout $ROLLOUT no se encuentra en namespace $NAMESPACE" >&2
  exit 1
fi

# Obtener índice del primer setWeight si no se conoce (intento razonable)
# Si tu rollout ya tiene un setWeight en steps[0], este valor es correcto.
STEP_INDEX=0

for W in "${WEIGHTS[@]}"; do
  echo
  echo "========================================"
  echo "Aplicando peso $W% (parcheando steps[$STEP_INDEX].setWeight)"
  echo "========================================"

  kubectl patch rollout "$ROLLOUT" -n "$NAMESPACE" --type='json' \
    -p="[ { \"op\": \"replace\", \"path\": \"/spec/strategy/canary/steps/${STEP_INDEX}/setWeight\", \"value\": ${W} } ]"

  echo "Esperando ${PAUSE}s para estabilización..."
  sleep "${PAUSE}"

  # Ejecutar la prueba de tráfico (simulate_traffic.sh)
  if [ ! -x "$SIM_SCRIPT" ]; then
    echo "Error: $SIM_SCRIPT no encontrado o no ejecutable. Asegurate de colocarlo y chmod +x." >&2
    # intentar rollback antes de salir
    kubectl argo rollouts undo "$ROLLOUT" -n "$NAMESPACE" || true
    exit 1
  fi

  echo "Lanzando prueba de tráfico con $TRAFFIC_TOOL ..."
  if ! "$SIM_SCRIPT" "$TRAFFIC_TOOL" "http://demo.local/" "$ERROR_THRESHOLD" 50 10 30s; then
    echo "⚠️  Pruebas superaron el umbral. Ejecutando rollback..."
    kubectl argo rollouts undo "$ROLLOUT" -n "$NAMESPACE" || true
    exit 1
  fi

  echo "Peso $W% OK. Continuando..."
done

echo
echo "✅ Canary rollout completado al 100% para $ROLLOUT"
kubectl argo rollouts get rollout "$ROLLOUT" -n "$NAMESPACE" || true




