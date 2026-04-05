# SafeGuard - Diagramas de Arquitetura

## 1. Arquitetura Geral do Sistema

```mermaid
graph LR
    subgraph Devices["Dispositivos IoT"]
        D1["ESP32 #001<br/>(Pulseira)"]
        D2["ESP32 #002<br/>(Pulseira)"]
        D3["ESP32 #N<br/>(Pulseira)"]
    end

    subgraph EC2["Servidor AWS EC2"]
        MQ["Mosquitto<br/>MQTT Broker<br/>:1883"]
        NR["Node-RED<br/>Motor de Logica<br/>:1880"]
        IDB["InfluxDB<br/>Time Series DB<br/>:8086"]
        GF["Grafana<br/>Dashboards<br/>:3000"]
    end

    subgraph Users["Usuarios"]
        CARE["Cuidador<br/>(Notificacao)"]
        DOC["Medico<br/>(Dashboard)"]
    end

    D1 & D2 & D3 -->|"MQTT pub<br/>safeguard/*"| MQ
    MQ -->|"MQTT sub"| NR
    NR -->|"HTTP API<br/>Line Protocol"| IDB
    NR -->|"Alerta<br/>Debug/Email"| CARE
    IDB -->|"Flux Query"| GF
    GF -->|"Visualizacao"| DOC
```

## 2. Fluxo de Dados Detalhado

```mermaid
sequenceDiagram
    participant ESP as ESP32 (Wokwi)
    participant MQ as Mosquitto
    participant NR as Node-RED
    participant DB as InfluxDB
    participant GF as Grafana

    loop A cada 500ms
        ESP->>MQ: safeguard/sensores/aceleracao<br/>{"x":0.1, "y":0.2, "z":0.98, "magnitude":1.01}
        MQ->>NR: MQTT message (subscribe)
        NR->>DB: POST /api/v2/write<br/>aceleracao,device=esp32-001 x=0.1,y=0.2,...
    end

    Note over ESP: magnitude > 3g detectado!

    ESP->>MQ: safeguard/sensores/aceleracao<br/>{"magnitude": 3.7}
    MQ->>NR: Aceleracao recebida
    NR->>DB: Grava leitura

    ESP->>MQ: safeguard/queda/alerta → "ON"
    MQ->>NR: Alerta recebido
    NR->>DB: alerta,device=esp32-001 status="ON"
    NR-->>NR: Debug: "QUEDA DETECTADA!"

    Note over NR: Ponto de expansao:<br/>Email, SMS, Push

    loop Monitoramento continuo
        GF->>DB: SELECT magnitude FROM aceleracao
        DB-->>GF: Time series data
        GF->>GF: Renderiza graficos
    end

    ESP->>MQ: safeguard/queda/alerta → "OFF"
    MQ->>NR: Status normal
    NR->>DB: alerta,device=esp32-001 status="OFF"
    NR-->>NR: Debug: "Status Normal"
```

## 3. Logica de Deteccao de Queda (Firmware ESP32)

```mermaid
flowchart TD
    A[Inicio Loop] --> B[Ler eixos X, Y, Z simulados]
    B --> C["Calcular magnitude<br/>A = sqrt(x² + y² + z²)"]
    C --> D{"A > LIMITE_ALTO<br/>(3g)?"}

    D -->|Nao| E{"A < LIMITE_BAIXO<br/>(0.5g) por 3s?"}
    E -->|Nao| F[Publicar dados sensor<br/>safeguard/sensores/aceleracao]
    E -->|Sim| G[Estado: Imobilidade<br/>Incrementar contador]
    F --> A
    G --> A

    D -->|Sim| H[Estado: Impacto Detectado]
    H --> I[Aguardar 3 segundos]
    I --> J{"Magnitude atual<br/>< 0.5g?"}

    J -->|Nao| K[Impacto isolado<br/>Publicar dados<br/>sem alerta]
    J -->|Sim| L["Publicar QUEDA<br/>safeguard/queda/alerta → ON"]

    K --> F
    L --> M[Publicar dados do sensor]
    M --> N[Aguardar reset manual<br/>ou timeout 30s]
    N --> O["Publicar NORMAL<br/>safeguard/queda/alerta → OFF"]
    O --> A
```

## 4. Pipeline Node-RED (3 Pipelines Paralelas)

```mermaid
graph TD
    subgraph Pipeline1["Pipeline 1: Aceleracao"]
        MA["MQTT In<br/>safeguard/sensores/aceleracao"] --> FA["Function<br/>JSON → Influx Line Protocol"]
        FA --> HA["HTTP POST<br/>InfluxDB Write API"]
        HA --> DA["Debug<br/>Aceleracao OK"]
    end

    subgraph Pipeline2["Pipeline 2: Velocidade"]
        MV["MQTT In<br/>safeguard/sensores/velocidade"] --> FV["Function<br/>JSON → Influx Line Protocol"]
        FV --> HV["HTTP POST<br/>InfluxDB Write API"]
        HV --> DV["Debug<br/>Velocidade OK"]
    end

    subgraph Pipeline3["Pipeline 3: Alerta"]
        MAL["MQTT In<br/>safeguard/queda/alerta"] --> FL["Function<br/>→ Influx Line Protocol"]
        MAL --> SW["Switch<br/>ON / OFF"]
        FL --> HL["HTTP POST<br/>InfluxDB Write API"]
        SW -->|"ON"| DON["Debug<br/>QUEDA DETECTADA!"]
        SW -->|"OFF"| DOFF["Debug<br/>Status Normal"]
    end

    MQ["Mosquitto<br/>:1883"] --> MA
    MQ --> MV
    MQ --> MAL

    HA --> IDB[("InfluxDB<br/>Bucket: sensors")]
    HV --> IDB
    HL --> IDB
```

## 5. Estrutura dos Topicos MQTT

```mermaid
graph TD
    ROOT["safeguard/"] --> SENSORES["sensores/"]
    ROOT --> QUEDA["queda/"]

    SENSORES --> ACEL["aceleracao<br/>JSON - QoS 1"]
    SENSORES --> VEL["velocidade<br/>JSON - QoS 1"]

    QUEDA --> ALERTA["alerta<br/>String ON/OFF - QoS 1"]

    ACEL --> ACEL_P["x: float<br/>y: float<br/>z: float<br/>magnitude: float<br/>device: string"]
    VEL --> VEL_P["velocidade: float<br/>device: string"]
    ALERTA --> ALERTA_P["ON ou OFF"]

    style ROOT fill:#1a1a2e,color:#fff
    style SENSORES fill:#16213e,color:#fff
    style QUEDA fill:#e94560,color:#fff
    style ACEL fill:#0f3460,color:#fff
    style VEL fill:#0f3460,color:#fff
    style ALERTA fill:#c70039,color:#fff
```

## 6. Modelo de Dados InfluxDB

```mermaid
classDiagram
    class sensors {
        +String bucket
        +Int retention 30d
    }

    class aceleracao {
        +String measurement = aceleracao
        +String tag device
        +Float field x
        +Float field y
        +Float field z
        +Float field magnitude
        +Timestamp time
    }

    class velocidade {
        +String measurement = velocidade
        +String tag device
        +Float field valor
        +Timestamp time
    }

    class alerta {
        +String measurement = alerta
        +String tag device
        +String field status
        +Timestamp time
    }

    sensors --> aceleracao : contains
    sensors --> velocidade : contains
    sensors --> alerta : contains
```

## 7. Dashboard Grafana - Layout dos Painéis

```
+--------------------------------------------------+--------------------------------------------------+
|  Linha 1                                         |                                                  |
|  Grafico Temporal: Aceleracao (Magnitude)        |  Grafico Temporal: Aceleracao por Eixo           |
|  Threshold: verde / amarelo / vermelho           |  Linhas X, Y, Z separadas                        |
|  h:8 w:12                                        |  h:8 w:12                                        |
+--------------------------------------------------+------------------------+------------------------+
|  Linha 2                                         |                        |                        |
|  Grafico Temporal: Velocidade                    |  Painel Status Atual   |  Contador              |
|  h:8 w:12                                        |  verde = NORMAL        |  Total de Alertas      |
|                                                  |  vermelho = QUEDA      |  de Queda              |
|                                                  |  h:4 w:6               |  h:4 w:6               |
+--------------------------------------------------+------------------------+------------------------+
|  Linha 3                                         |                                                  |
|  Tabela: Historico de Alertas                    |                                                  |
|  ON = QUEDA / OFF = NORMAL                       |                                                  |
|  h:8 w:12                                        |                                                  |
+--------------------------------------------------+--------------------------------------------------+
```

## 8. Multidevice - Como Funciona

```mermaid
graph LR
    subgraph Devices["N Pulseiras"]
        D1["ESP32 #001<br/>device: esp32-001"]
        D2["ESP32 #002<br/>device: esp32-002"]
        DN["ESP32 #N<br/>device: esp32-NNN"]
    end

    subgraph Broker["Mosquitto"]
        T1["safeguard/sensores/aceleracao"]
    end

    subgraph Influx["InfluxDB - Tags por Device"]
        DB1["device=esp32-001"]
        DB2["device=esp32-002"]
        DBN["device=esp32-NNN"]
    end

    D1 -->|"device: esp32-001"| T1
    D2 -->|"device: esp32-002"| T1
    DN -->|"device: esp32-NNN"| T1

    T1 -->|"Node-RED extrai tag device"| DB1
    T1 --> DB2
    T1 --> DBN

    subgraph Grafana["Filtro por Device"]
        G1["Dashboard #001"]
        G2["Dashboard #002"]
        GALL["Dashboard Todos"]
    end

    DB1 --> G1
    DB2 --> G2
    DB1 & DB2 & DBN --> GALL
```
