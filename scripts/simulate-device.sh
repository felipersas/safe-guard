#!/bin/bash
# SafeGuard - Simulador de Dispositivo ESP32
# Publica dados de aceleracao, velocidade e alertas via MQTT.
#
# Uso:
#   ./simulate-device.sh                    # dispositivo padrao
#   ./simulate-device.sh -d esp32-002       # dispositivo customizado
#   ./simulate-device.sh -b 54.x.x.x       # broker remoto (EC2)
#   ./simulate-device.sh --fall             # forcar queda imediata

set -e

DEVICE="esp32-001"
BROKER="localhost"
PORT=1883
INTERVAL=1.0
FALL_CHANCE=3
DURATION=0
FORCE_FALL=false

usage() {
    cat <<EOF
SafeGuard - Simulador de Dispositivo

Opcoes:
  -d, --device   ID do dispositivo          (padrao: esp32-001)
  -b, --broker   Host do broker MQTT        (padrao: localhost)
  -p, --port     Porta do broker MQTT       (padrao: 1883)
  -i, --interval Intervalo entre leituras s  (padrao: 1.0)
  -t, --time     Duracao total em segundos   (padrao: infinito)
  -f, --fall     Forcar queda imediata
  -c, --chance   % chance de queda por ciclo (padrao: 3)
  -h, --help     Esta ajuda

Exemplos:
  $0                                    # simulacao infinita
  $0 -d esp32-002 -b 54.x.x.x          # dispositivo 2, broker EC2
  $0 -t 60                             # rodar por 60 segundos
  $0 -f                                # forcar queda imediata
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--device)   DEVICE="$2";      shift 2 ;;
        -b|--broker)   BROKER="$2";      shift 2 ;;
        -p|--port)     PORT="$2";        shift 2 ;;
        -i|--interval) INTERVAL="$2";    shift 2 ;;
        -t|--time)     DURATION="$2";    shift 2 ;;
        -f|--fall)     FORCE_FALL=true;  shift   ;;
        -c|--chance)   FALL_CHANCE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0             ;;
        *)             echo "Opcao desconhecida: $1"; usage; exit 1 ;;
    esac
done

# ── Publicar no MQTT ──────────────────────────────────────
publish() {
    local topic="$1"
    local payload="$2"
    # Tenta docker exec primeiro, senao usa mosquitto_pub direto
    if docker exec safeguard-mosquitto mosquitto_pub \
        -h "$BROKER" -p "$PORT" -t "$topic" -m "$payload" 2>/dev/null; then
        return 0
    elif command -v mosquitto_pub &>/dev/null; then
        mosquitto_pub -h "$BROKER" -p "$PORT" -t "$topic" -m "$payload"
        return 0
    else
        echo "ERRO: nem docker nem mosquitto_pub disponivel" >&2
        return 1
    fi
}

# ── Gerar dados de aceleracao normal ──────────────────────
# Magnitude em torno de 1g com ruido (simula caminhada leve)
normal_acceleration() {
    local x=$(awk -v seed=$RANDOM 'BEGIN{srand(seed); printf "%.2f", (rand()-0.5)*0.8}')
    local y=$(awk -v seed=$RANDOM 'BEGIN{srand(seed+1); printf "%.2f", (rand()-0.5)*0.8}')
    local z=$(awk -v seed=$RANDOM 'BEGIN{srand(seed+2); printf "%.2f", 0.98+(rand()-0.5)*0.2}')
    local mag=$(awk -v x="$x" -v y="$y" -v z="$z" 'BEGIN{printf "%.2f", sqrt(x*x+y*y+z*z)}')
    echo "{\"x\":$x,\"y\":$y,\"z\":$z,\"magnitude\":$mag,\"device\":\"$DEVICE\"}"
}

# ── Gerar dados de aceleracao brusca (sem queda) ──────────
# Magnitude entre 1.5g e 2.5g
bump_acceleration() {
    local x=$(awk -v seed=$RANDOM 'BEGIN{srand(seed); printf "%.2f", (rand()-0.3)*3}')
    local y=$(awk -v seed=$RANDOM 'BEGIN{srand(seed+1); printf "%.2f", (rand()-0.3)*3}')
    local z=$(awk -v seed=$RANDOM 'BEGIN{srand(seed+2); printf "%.2f", 1.0+(rand()-0.5)*2}')
    local mag=$(awk -v x="$x" -v y="$y" -v z="$z" 'BEGIN{printf "%.2f", sqrt(x*x+y*y+z*z)}')
    echo "{\"x\":$x,\"y\":$y,\"z\":$z,\"magnitude\":$mag,\"device\":\"$DEVICE\"}"
}

# ── Gerar dados de velocidade normal ──────────────────────
normal_velocity() {
    local val=$(awk -v seed=$RANDOM 'BEGIN{srand(seed); printf "%.2f", rand()*2}')
    echo "{\"velocidade\":$val,\"device\":\"$DEVICE\"}"
}

# ── Simular sequencia completa de queda ───────────────────
simulate_fall() {
    echo -e "\n  ${RED}!!! QUEDA DETECTADA !!!${NC}"

    # Fase 1: Impacto brusco (magnitude > 3g)
    local ix=$(awk -v seed=$RANDOM 'BEGIN{srand(seed); printf "%.2f", 1.5+rand()*2}')
    local iy=$(awk -v seed=$RANDOM 'BEGIN{srand(seed+1); printf "%.2f", 1.2+rand()*2}')
    local iz=$(awk -v seed=$RANDOM 'BEGIN{srand(seed+2); printf "%.2f", 2.0+rand()*1.5}')
    local imag=$(awk -v x="$ix" -v y="$iy" -v z="$iz" 'BEGIN{printf "%.2f", sqrt(x*x+y*y+z*z)}')

    local impact="{\"x\":$ix,\"y\":$iy,\"z\":$iz,\"magnitude\":$imag,\"device\":\"$DEVICE\"}"
    publish "safeguard/sensores/aceleracao" "$impact"
    echo -e "  ${RED}  [IMPACTO]  magnitude=$imag${NC}"

    sleep 0.3

    # Fase 2: Alerta ON
    publish "safeguard/queda/alerta" "ON"
    echo -e "  ${RED}  [ALERTA]   ON${NC}"

    sleep 0.5

    # Fase 3: Imobilidade pos-impacto (magnitude < 0.5g)
    local rest="{\"x\":0.05,\"y\":0.08,\"z\":0.15,\"magnitude\":0.18,\"device\":\"$DEVICE\"}"
    publish "safeguard/sensores/aceleracao" "$rest"
    echo -e "  ${RED}  [IMOBIL]   magnitude=0.18${NC}"

    publish "safeguard/sensores/velocidade" "{\"velocidade\":0.0,\"device\":\"$DEVICE\"}"

    sleep 3

    # Fase 4: Retorno ao normal
    publish "safeguard/queda/alerta" "OFF"
    echo -e "  ${GREEN}  [ALERTA]   OFF - Retornou ao normal${NC}\n"
}

# ── Cores ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Header ────────────────────────────────────────────────
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SafeGuard - Simulador de Dispositivo${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "  Device      : ${BOLD}$DEVICE${NC}"
echo -e "  Broker      : ${BOLD}$BROKER:$PORT${NC}"
echo -e "  Intervalo   : ${BOLD}${INTERVAL}s${NC}"
echo -e "  Chance queda: ${BOLD}${FALL_CHANCE}%${NC}"
[ "$DURATION" -gt 0 ] && echo -e "  Duracao     : ${BOLD}${DURATION}s${NC}" || echo -e "  Duracao     : ${BOLD}infinita${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "Pressione ${BOLD}Ctrl+C${NC} para parar, ${BOLD}f + Enter${NC} para forcar queda\n"

COUNT=0
START_TIME=$(date +%s)

# Forcar queda se pedido
if [ "$FORCE_FALL" = true ]; then
    simulate_fall
fi

trap 'echo -e "\n${YELLOW}Simulacao encerrada. $COUNT amostras enviadas.${NC}"; exit 0' INT

# ── Loop principal ────────────────────────────────────────
while true; do
    # Checar duracao
    if [ "$DURATION" -gt 0 ]; then
        ELAPSED=$(( $(date +%s) - START_TIME ))
        if [ "$ELAPSED" -ge "$DURATION" ]; then
            echo -e "\n${GREEN}Duracao de ${DURATION}s atingida. $COUNT amostras enviadas.${NC}"
            break
        fi
    fi

    COUNT=$((COUNT + 1))
    ROLL=$(( RANDOM % 100 ))

    if [ "$ROLL" -lt "$FALL_CHANCE" ]; then
        # Queda!
        simulate_fall
        COUNT=$((COUNT + 9))
    elif [ "$ROLL" -lt "$((FALL_CHANCE + 10))" ]; then
        # Movimento brusco sem queda
        DATA=$(bump_acceleration)
        publish "safeguard/sensores/aceleracao" "$DATA"
        VEL=$(normal_velocity)
        publish "safeguard/sensores/velocidade" "$VEL"
        MAG=$(echo "$DATA" | sed 's/.*magnitude"://' | sed 's/,.*//')
        echo -e "  ${YELLOW}[$COUNT] MOVIMENTO BRUSCO  magnitude=$MAG${NC}"
    else
        # Estado normal
        DATA=$(normal_acceleration)
        publish "safeguard/sensores/aceleracao" "$DATA"
        VEL=$(normal_velocity)
        publish "safeguard/sensores/velocidade" "$VEL"
        MAG=$(echo "$DATA" | sed 's/.*magnitude"://' | sed 's/,.*//')
        printf "  ${GREEN}[%5d] Normal  magnitude=%s${NC}\n" "$COUNT" "$MAG"
    fi

    sleep "$INTERVAL"
done
