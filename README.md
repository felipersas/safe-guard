# SafeGuard

Sistema de Monitoramento e Deteccao de Quedas para Idosos via IoT.

## Arquitetura

```
ESP32 (Wokwi)
   │  MQTT (pub)
   ▼
Mosquitto Broker ◄──── Node-RED (sub)
   │                       │
   │                   InfluxDB (write via HTTP)
   │                       │
   │                   Grafana (read via Flux)
   ▼
safeguard/sensores/aceleracao   → InfluxDB
safeguard/sensores/velocidade   → InfluxDB
safeguard/queda/alerta          → InfluxDB + Notificacao
```

## Stack

| Componente | Tecnologia | Porta |
|---|---|---|
| Broker MQTT | Eclipse Mosquitto 2 | 1883 (TCP) / 9001 (WS) |
| Logica / Alertas | Node-RED | 1880 |
| Banco de Dados | InfluxDB 2.7 | 8086 |
| Dashboard | Grafana | 3000 |

## Topicos MQTT

| Topico | Payload | Descricao |
|---|---|---|
| `safeguard/sensores/aceleracao` | JSON: `{"x","y","z","magnitude","device"}` | Dados do acelerometro |
| `safeguard/sensores/velocidade` | JSON: `{"velocidade","device"}` | Velocidade derivada |
| `safeguard/queda/alerta` | String: `"ON"` ou `"OFF"` | Alerta de queda |

## Quick Start

### 1. Subir os servicos

```bash
docker compose up -d
```

### 2. Verificar status

```bash
docker compose ps
```

Todos os 4 containers devem estar `Up`:
- safeguard-mosquitto
- safeguard-influxdb
- safeguard-nodered
- safeguard-grafana

### 3. Acessar as interfaces

| Servico | URL | Credenciais |
|---|---|---|
| Node-RED | http://localhost:1880 | sem autenticacao |
| Grafana | http://localhost:3000 | admin / safeguard2026 |
| InfluxDB | http://localhost:8086 | admin / safeguard2026 |

## Simular dados (testar sem o ESP32)

### Publicar dados do acelerometro

```bash
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/sensores/aceleracao" \
  -m '{"x":0.1,"y":0.2,"z":0.98,"magnitude":1.01,"device":"esp32-001"}'
```

### Publicar dados de velocidade

```bash
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/sensores/velocidade" \
  -m '{"velocidade":1.5,"device":"esp32-001"}'
```

### Simular uma queda

```bash
# Disparar alerta
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/queda/alerta" \
  -m "ON"

# Voltar ao normal
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/queda/alerta" \
  -m "OFF"
```

### Simular sequencia completa de queda (aceleracao brusca + imobilidade)

```bash
# 1. Impacto (magnitude > 3g)
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/sensores/aceleracao" \
  -m '{"x":2.1,"y":1.8,"z":2.5,"magnitude":3.7,"device":"esp32-001"}'

# 2. Alerta de queda
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/queda/alerta" \
  -m "ON"

# 3. Imobilidade pos-impacto (magnitude < 0.5g)
docker exec safeguard-mosquitto mosquitto_pub \
  -t "safeguard/sensores/aceleracao" \
  -m '{"x":0.05,"y":0.1,"z":0.2,"magnitude":0.23,"device":"esp32-001"}'
```

### Script de teste com dados continuos

```bash
# Publica dados a cada 2 segundos por 30 segundos
for i in $(seq 1 15); do
  MAGNITUDE=$(echo "scale=2; $RANDOM / 32767 * 2" | bc)
  X=$(echo "scale=2; $RANDOM / 32767 * 1.5" | bc)
  Y=$(echo "scale=2; $RANDOM / 32767 * 1.5" | bc)
  Z=$(echo "scale=2; $RANDOM / 32767 * 1.5" | bc)

  docker exec safeguard-mosquitto mosquitto_pub \
    -t "safeguard/sensores/aceleracao" \
    -m "{\"x\":$X,\"y\":$Y,\"z\":$Z,\"magnitude\":$MAGNITUDE,\"device\":\"esp32-001\"}"

  echo "Sample $i: mag=$MAGNITUDE"
  sleep 2
done
```

## Verificar dados no InfluxDB

### Via UI (http://localhost:8086)

1. Logue com admin / safeguard2026
2. Vá em **Data Explorer**
3. Selecione bucket `sensors` e measurement `aceleracao`

### Via CLI

```bash
docker exec safeguard-influxdb influx query \
  'from(bucket: "sensors") |> range(start: -1h) |> filter(fn: (r) => r._measurement == "aceleracao")' \
  --org safeguard \
  --token safeguard-token-2026
```

## Deploy na EC2 (AWS)

### 1. Security Group

Libere as seguintes portas no Security Group da instancia:

| Porta | Origem | Motivo |
|---|---|---|
| 22 | seu IP | SSH |
| 1883 | 0.0.0.0/0 | MQTT (ESP32 Wokwi) |
| 1880 | seu IP | Node-RED (admin) |
| 3000 | seu IP | Grafana (dashboard) |

> **Nao** exponha a porta 8086 (InfluxDB) publicamente.

### 2. Na instancia

```bash
# Instalar Docker
sudo yum update -y
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user

# Instalar Docker Compose
sudo curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Fazer logout e login novamente para o grupo docker
exit

# Clonar/copiar o projeto e subir
cd ~/IOT
docker compose up -d
```

### 3. Configurar o ESP32 no Wokwi

No codigo do ESP32, aponte o MQTT broker para o IP publico da EC2:

```cpp
const char* mqtt_server = "SEU.IP.PUBLICO.AWS";
const int mqtt_port = 1883;
```

## Estrutura do Projeto

```
IOT/
├── docker-compose.yml
├── .env
├── README.md
├── docs/
│   └── safeguard-documento.pdf    # Documentacao tecnica
├── mosquitto/
│   └── config/mosquitto.conf
├── nodered/
│   └── data/flows.json            # Flow pre-configurado
├── influxdb/
│   └── data/
└── grafana/
    └── provisioning/
        ├── datasources/influxdb.yml
        └── dashboards/
            ├── dashboard-provider.yml
            └── json/safeguard-overview.json
```

## Comandos Uteis

```bash
# Subir
docker compose up -d

# Parar
docker compose down

# Ver logs
docker compose logs -f nodered
docker compose logs -f mosquitto

# Reiniciar um servico
docker compose restart nodered

# Limpar tudo (remove dados)
docker compose down -v
```

## Credenciais

Todas as credenciais estao no arquivo `.env`. Altere antes de ir para producao.

| Servico | Usuario | Senha |
|---|---|---|
| InfluxDB | admin | safeguard2026 |
| Grafana | admin | safeguard2026 |
| InfluxDB Token | - | safeguard-token-2026 |
