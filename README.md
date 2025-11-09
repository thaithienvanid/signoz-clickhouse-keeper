# Self-Hosting & Operations Guide for SigNoz with ClickHouse Keeper

## Overview

This is a **complete, production-ready guide** for self-hosting SigNoz using Docker Compose with **ClickHouse Keeper** (replacing the traditional ZooKeeper dependency). Whether you're running a development environment on a laptop or deploying a fault-tolerant production cluster, this guide provides everything you need.

### What You'll Learn
- Deploy SigNoz in **standalone mode** (single server) or **high-availability mode** (multi-node cluster)
- Implement **layered security** (Basic Auth, API Keys, TLS, mTLS)
- Manage **operations** (backups, monitoring, scaling, troubleshooting)
- Connect **application agents** to your SigNoz gateway

### Why ClickHouse Keeper?
ClickHouse Keeper is a native coordination service that replaces ZooKeeper. It offers:
- **Better integration**: Built specifically for ClickHouse
- **Simpler deployment**: Fewer dependencies and containers
- **Improved performance**: Lower latency for coordination tasks
- **Raft consensus**: Proven distributed consensus algorithm

---

## Table of Contents

### Part 1: Standalone Deployment (Single Server)
1.  [Architecture Overview](#11-architecture-overview)
2.  [Prerequisites](#12-prerequisites)
3.  [Quick Start (No Security)](#13-quick-start-no-security)
4.  [Configuration Files Deep Dive](#14-configuration-files-deep-dive)
5.  [Adding Security Layers](#15-adding-security-layers)
    - [Option A: Basic Authentication](#option-a-basic-authentication)
    - [Option B: API Key Authentication](#option-b-api-key-bearer-token-authentication)
    - [Option C: TLS Encryption](#option-c-tls-encryption)
    - [Option D: Mutual TLS (mTLS)](#option-d-mutual-tls-mtls)
6.  [Connecting Application Agents](#16-connecting-application-agents)

### Part 2: High Availability Production Deployment
1.  [HA Architecture Overview](#21-ha-architecture-overview)
2.  [Prerequisites for HA](#22-prerequisites-for-ha)
3.  [HA Configuration Files](#23-ha-configuration-files-single-host-simulation)
4.  [Deploy and Verify HA Cluster](#24-deploy-and-verify-ha-cluster)
5.  [Testing Fault Tolerance](#25-testing-fault-tolerance)
6.  [Load Balancer Configuration](#26-load-balancer-configuration)

### Part 3: Operations & Maintenance
1.  [Monitoring & Health Checks](#31-monitoring--health-checks)
2.  [Backup & Restore Strategies](#32-backup--restore-strategies)
3.  [Scaling Guidelines](#33-scaling-guidelines)
4.  [Troubleshooting Common Issues](#34-troubleshooting-common-issues)
5.  [Performance Tuning](#35-performance-tuning)
6.  [Security Best Practices](#36-security-best-practices)

### Document Structure

```mermaid
graph TD
    A[SigNoz Operations Guide] --> B[Part 1: Standalone]
    A --> C[Part 2: HA Production]
    A --> D[Part 3: Operations]
    
    B --> B1[Quick Start<br/>Basic Setup]
    B --> B2[Security Options<br/>Auth/TLS]
    B --> B3[Agent Config<br/>Connect Apps]
    
    C --> C1[HA Architecture<br/>Multi-node]
    C --> C2[Keeper Quorum<br/>3 nodes]
    C --> C3[Load Balancers<br/>Redundancy]
    
    D --> D1[Monitoring<br/>Health Checks]
    D --> D2[Backup/Restore<br/>Data Safety]
    D --> D3[Troubleshooting<br/>Common Issues]
    
    style A fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style B fill:#e8f5e9,stroke:#2e7d32
    style C fill:#fff3e0,stroke:#ef6c00
    style D fill:#f3e5f5,stroke:#6a1b9a
```

---

# Part 1: Standalone Deployment (Single Server)

## 1.1: Architecture Overview

The standalone deployment runs all SigNoz components on a single Docker host. This is ideal for:
- **Development environments** (local testing)
- **Small teams** (<50 services, <100GB/day telemetry)
- **Proof-of-concept** deployments
- **Internal monitoring** (trusted network)

### Architecture Diagram

<details>
<summary><b>ASCII Diagram (Click to expand)</b></summary>

```
┌─────────────────────────────────────────────────────────────────┐
│                    Single Docker Host                            │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                  Docker Network (signoz-net)              │   │
│  │                                                            │   │
│  │  ┌─────────────┐        ┌──────────────┐                 │   │
│  │  │  SigNoz     │        │  ClickHouse  │                 │   │
│  │  │  Backend    │◄───────┤  Keeper      │                 │   │
│  │  │  (UI:8080)  │        │  (Port:9181) │                 │   │
│  │  └──────┬──────┘        └──────────────┘                 │   │
│  │         │                                                  │   │
│  │         │ Queries                                         │   │
│  │         ▼                                                  │   │
│  │  ┌─────────────────────────────────┐                     │   │
│  │  │   ClickHouse Server             │                     │   │
│  │  │   (Stores: Traces/Metrics/Logs) │                     │   │
│  │  └─────────────▲───────────────────┘                     │   │
│  │                │                                          │   │
│  │                │ Writes                                   │   │
│  │         ┌──────┴─────────┐                               │   │
│  │         │ OTel Collector │                               │   │
│  │         │ (Gateway Mode) │◄──────────────────────┐       │   │
│  │         │  gRPC: 4317    │                       │       │   │
│  │         │  HTTP: 4318    │                       │       │   │
│  │         └────────────────┘                       │       │   │
│  │                                                    │       │   │
│  └────────────────────────────────────────────────────┼──────┘   │
│                                                        │          │
└────────────────────────────────────────────────────────┼──────────┘
                                                         │
                                                         │ Telemetry
                                        ┌────────────────┴──────────┐
                                        │  Application Hosts        │
                                        │  (with OTel Agents)       │
                                        └───────────────────────────┘
```
</details>

<details>
<summary><b>Mermaid Diagram (Click to expand)</b></summary>

```mermaid
graph TB
    subgraph "Application Hosts"
        Apps[Applications with OTel SDKs]
    end
    
    subgraph "Single Docker Host"
        subgraph "Docker Network: signoz-net"
            Collector["OTel Collector<br/>(Gateway Mode)<br/>gRPC: 4317<br/>HTTP: 4318"]
            Backend["SigNoz Backend<br/>(UI & Query Service)<br/>Port: 8080"]
            ClickHouse["ClickHouse Server<br/>(Data Storage)<br/>Traces, Metrics, Logs"]
            Keeper["ClickHouse Keeper<br/>(Coordination)<br/>Port: 9181"]
        end
    end
    
    Apps -->|Send Telemetry| Collector
    Collector -->|Write Data| ClickHouse
    Backend -->|Query Data| ClickHouse
    Keeper -.->|Coordinates| ClickHouse
    
    style Apps fill:#e1f5ff
    style Collector fill:#fff4e6
    style Backend fill:#e8f5e9
    style ClickHouse fill:#f3e5f5
    style Keeper fill:#fce4ec
```
</details>

### Component Roles

| Component | Purpose | Critical? |
|-----------|---------|-----------|
| **SigNoz Backend** | Query service, UI, alerting | Yes - UI unavailable if down |
| **OTel Collector** | Gateway for all telemetry ingestion | Yes - data loss if down |
| **ClickHouse Server** | Primary data store (traces, metrics, logs) | Yes - no data storage if down |
| **ClickHouse Keeper** | Coordination for ClickHouse (replicas, distributed ops) | Yes - ClickHouse unstable if down |
| **Schema Migrator** | Database schema initialization/updates | No - runs once at startup |

---

## 1.2: Prerequisites

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| **CPU** | 4 cores | 8+ cores |
| **RAM** | 8 GB | 16+ GB |
| **Storage** | 50 GB SSD | 200+ GB NVMe SSD |
| **Network** | 100 Mbps | 1 Gbps |

### Software Requirements

- **Docker**: 20.10.0+ ([Install Guide](https://docs.docker.com/engine/install/))
- **Docker Compose**: 2.0.0+ (usually bundled with Docker Desktop)
- **Operating System**: Linux (Ubuntu 20.04+, Debian 11+, RHEL 8+) or macOS

### Network Ports

| Port | Service | Protocol | Expose Publicly? |
|------|---------|----------|------------------|
| **8080** | SigNoz UI/API | HTTP | Optional (with auth) |
| **4317** | OTLP gRPC | gRPC | No (internal agents only) |
| **4318** | OTLP HTTP | HTTP | Optional (for browsers) |
| **9000** | ClickHouse Native | TCP | No (internal only) |
| **9181** | Keeper Client | TCP | No (internal only) |

---

## 1.3: Quick Start (No Security)

This section gets you up and running in **under 10 minutes** with a basic, unsecured deployment.

### Step 1: Create Project Directory

```bash
mkdir signoz-standalone && cd signoz-standalone
```

### Step 2: Create Configuration Files

You need **6 configuration files**. Copy and paste each one exactly as shown.

#### File 1: `.env` - Version Management

```env
# SigNoz Component Versions
# Update these to change versions across all services

# ClickHouse versions (server and keeper must be compatible)
CLICKHOUSE_VERSION=25.5.6
CLICKHOUSE_KEEPER_VERSION=25.5.6-alpine

# SigNoz versions (use 'latest' for testing, pin versions for production)
SIGNOZ_VERSION=latest
OTELCOL_VERSION=latest
SCHEMA_MIGRATOR_VERSION=latest
```

#### File 2: `docker-compose.yml` - Service Orchestration

```yaml
version: "3.8"
x-common: &common
  networks:
    - signoz-net
  restart: unless-stopped
services:
  init-clickhouse:
    <<: *common
    image: clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}
    container_name: signoz-init-clickhouse
    command: >
      bash -c "
      version=\"v0.0.1\";
      node_os=$$(uname -s | tr '[:upper:]' '[:lower:]');
      node_arch=$$(uname -m | sed s/aarch64/arm64/ | sed s/x86_64/amd64/);
      wget -O /tmp/histogram-quantile.tar.gz https://github.com/SigNoz/signoz/releases/download/histogram-quantile%2F$${version}/histogram-quantile_$${node_os}_$${node_arch}.tar.gz;
      tar -C /var/lib/clickhouse/user_scripts -xzf /tmp/histogram-quantile.tar.gz;
      "
    restart: on-failure
    volumes:
      - ./clickhouse/user_scripts:/var/lib/clickhouse/user_scripts/
  clickhouse-keeper:
    <<: *common
    image: clickhouse/clickhouse-keeper:${CLICKHOUSE_KEEPER_VERSION}
    container_name: signoz-clickhouse-keeper
    hostname: clickhouse-keeper
    volumes:
      - ./clickhouse-keeper-config.xml:/etc/clickhouse-keeper/keeper_config.xml
      - clickhouse-keeper-data:/var/lib/clickhouse-keeper
    healthcheck:
      test: ["CMD-SHELL", "clickhouse-keeper-client -h localhost -p 9181 -q ruok | grep -q imok"]
      interval: 30s; timeout: 5s; retries: 3
  clickhouse:
    <<: *common
    image: clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}
    container_name: signoz-clickhouse
    depends_on:
      init-clickhouse: { condition: service_completed_successfully }
      clickhouse-keeper: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8123/ping"]
      interval: 30s; timeout: 5s; retries: 3
    volumes:
      - ./clickhouse/config.xml:/etc/clickhouse-server/config.xml
      - ./clickhouse/users.xml:/etc/clickhouse-server/users.xml
      - ./clickhouse/user_scripts:/var/lib/clickhouse/user_scripts/
      - ./cluster-keeper.xml:/etc/clickhouse-server/config.d/cluster.xml
      - clickhouse-data:/var/lib/clickhouse/
  signoz:
    <<: *common
    image: signoz/signoz:${SIGNOZ_BACKEND_VERSION}
    container_name: signoz-backend
    command: ["--config=/root/config/prometheus.yml"]
    ports: ["8080:8080"]
    depends_on:
      clickhouse: { condition: service_healthy }
      schema-migrator-sync: { condition: service_completed_successfully }
    volumes:
      - ./signoz/prometheus.yml:/root/config/prometheus.yml
      - sqlite-data:/var/lib/signoz/
    environment:
      - SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN=tcp://clickhouse:9000
      - SIGNOZ_SQLSTORE_SQLITE_PATH=/var/lib/signoz/signoz.db
      - SIGNOZ_SERVER_ALLOWED_ORIGINS=*
  otel-collector:
    <<: *common
    image: signoz/signoz-otel-collector:${SIGNOZ_OTEL_COLLECTOR_VERSION}
    container_name: signoz-otel-collector
    command: ["--config=/etc/otel-collector-config.yaml"]
    ports: ["4317:4317", "4318:4318"]
    volumes: ["./otel-collector-config.yaml:/etc/otel-collector-config.yaml"]
    depends_on:
      signoz: { condition: service_healthy }
  schema-migrator-sync:
    <<: *common
    image: signoz/signoz-schema-migrator:${SIGNOZ_SCHEMA_MIGRATOR_VERSION}
    container_name: schema-migrator-sync
    command: ["sync", "--dsn=tcp://clickhouse:9000"]
    depends_on:
      clickhouse: { condition: service_healthy }
    restart: on-failure
networks:
  signoz-net:
    name: signoz-net
volumes:
  clickhouse-data:
  sqlite-data:
  clickhouse-keeper-data:
```

#### File 3: `otel-collector-config.yaml` - Telemetry Gateway Configuration

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
        cors:
          allowed_origins:
            - "*"
          allowed_headers:
            - "*"

processors:
  batch:
    send_batch_size: 10000
    send_batch_max_size: 11000
    timeout: 10s

  resourcedetection:
    detectors: [env, system, docker]
    timeout: 2s

  signozspanmetrics/prometheus:
    metrics_exporter: prometheus
    latency_histogram_buckets: [100us, 1ms, 2ms, 6ms, 10ms, 50ms, 100ms, 250ms, 500ms, 1000ms, 1400ms, 2000ms, 5s, 10s, 20s, 40s, 60s]
    dimensions_cache_size: 10000

exporters:
  clickhousetraces:
    datasource: tcp://clickhouse:9000/?database=signoz_traces
    low_cardinal_exception_grouping: true

  clickhousemetricswrite:
    endpoint: tcp://clickhouse:9000/?database=signoz_metrics
    resource_to_telemetry_conversion:
      enabled: true

  clickhouselogsexporter:
    dsn: tcp://clickhouse:9000/?database=signoz_logs

  prometheus:
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [signozspanmetrics/prometheus, batch, resourcedetection]
      exporters: [clickhousetraces]
    
    metrics:
      receivers: [otlp]
      processors: [batch, resourcedetection]
      exporters: [clickhousemetricswrite]
    
    logs:
      receivers: [otlp]
      processors: [batch, resourcedetection]
      exporters: [clickhouselogsexporter]
```

#### File 4: `clickhouse-keeper-config.xml` - Coordination Service

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <console>true</console>
    </logger>

    <listen_host>0.0.0.0</listen_host>

    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
        </coordination_settings>

        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>clickhouse-keeper</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
```

#### File 5: `cluster-keeper.xml` - ClickHouse Cluster Configuration

```xml
<clickhouse>
    <zookeeper>
        <node>
            <host>clickhouse-keeper</host>
            <port>9181</port>
        </node>
        <session_timeout_ms>30000</session_timeout_ms>
        <operation_timeout_ms>10000</operation_timeout_ms>
    </zookeeper>

    <distributed_ddl>
        <path>/clickhouse/task_queue/ddl</path>
    </distributed_ddl>

    <remote_servers>
        <cluster_1S_1R>
            <shard>
                <replica>
                    <host>clickhouse</host>
                    <port>9000</port>
                </replica>
            </shard>
        </cluster_1S_1R>
    </remote_servers>
</clickhouse>
```

#### File 6: `signoz-prometheus.yml` - SigNoz Backend Configuration

```yaml
# Minimal configuration for SigNoz backend
# Additional settings can be configured via environment variables

global:
  scrape_interval: 60s
  evaluation_interval: 60s

scrape_configs:
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector:8889']
```

</details>

### Step 3: Start the Stack

```bash
docker-compose up -d
```

### Step 4: Verify Deployment

**Check all services are healthy:**
```bash
docker-compose ps
```

Expected output - all services should show "Up" and "healthy":
```
NAME                       STATUS
signoz-backend             Up (healthy)
signoz-clickhouse          Up (healthy)
signoz-clickhouse-keeper   Up (healthy)
signoz-init-clickhouse     Exited (0)
signoz-otel-collector      Up
schema-migrator-sync       Exited (0)
```

**Access the UI:**
Open your browser to `http://localhost:8080`

**Test telemetry ingestion:**
```bash
# Send a test trace
curl -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{
    "resourceSpans": [{
      "resource": {
        "attributes": [{
          "key": "service.name",
          "value": {"stringValue": "test-service"}
        }]
      },
      "scopeSpans": [{
        "spans": [{
          "traceId": "5B8EFFF798038103D269B633813FC60C",
          "spanId": "EEE19B7EC3C1B174",
          "name": "test-span",
          "startTimeUnixNano": "1544712660000000000",
          "endTimeUnixNano": "1544712661000000000",
          "kind": 1
        }]
      }]
    }]
  }'
```

### Step 5: View Logs (Troubleshooting)

```bash
# View all logs
docker-compose logs -f

# View specific service logs
docker-compose logs -f signoz
docker-compose logs -f otel-collector
docker-compose logs -f clickhouse
```

### Step 6: Stop the Stack

```bash
# Stop (preserves data)
docker-compose down

# Stop and remove volumes (clean slate)
docker-compose down -v
```

---

## 1.4: Configuration Files Deep Dive

### Understanding Docker Compose Patterns

**YAML Anchors (`x-common`):**
```yaml
x-common: &common
  networks:
    - signoz-net
  restart: unless-stopped
```
This defines reusable configuration that's applied to all services via `<<: *common`, following DRY principles.

**Service Dependencies:**
```yaml
depends_on:
  clickhouse-keeper: { condition: service_healthy }
  clickhouse: { condition: service_healthy }
```
Ensures services start in the correct order and wait for dependencies to be ready.

**Health Checks:**
```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8123/ping"]
  interval: 30s
  timeout: 5s
  retries: 3
```
Docker continuously monitors service health, enabling automatic restarts and proper startup ordering.

### Startup Sequence

<details>
<summary><b>ASCII Diagram (Click to expand)</b></summary>

```
1. init-clickhouse (downloads histogram UDF)
   ↓
2. clickhouse-keeper (starts coordination)
   ↓  (wait for healthy)
3. clickhouse (starts database)
   ↓  (wait for healthy)
4. schema-migrator (creates tables)
   ↓  (wait for complete)
5. signoz (starts backend & UI)
   ↓  (wait for healthy)
6. otel-collector (starts gateway)
```
</details>

<details>
<summary><b>Mermaid Diagram (Click to expand)</b></summary>

```mermaid
graph TD
    A[init-clickhouse<br/>Download UDF] --> B[clickhouse-keeper<br/>Start Coordination]
    B --> C[clickhouse<br/>Start Database]
    C --> D[schema-migrator<br/>Create Schema]
    D --> E[signoz<br/>Start Backend/UI]
    E --> F[otel-collector<br/>Start Gateway]
    
    style A fill:#e8f5e9
    style B fill:#fff3e0
    style C fill:#e1f5fe
    style D fill:#f3e5f5
    style E fill:#fce4ec
    style F fill:#fff9c4
```
</details>

### OTel Collector Pipeline

<details>
<summary><b>ASCII Diagram (Click to expand)</b></summary>

```
Receivers → Processors → Exporters
 (Input)    (Transform)    (Output)
```
</details>

<details>
<summary><b>Mermaid Diagram (Click to expand)</b></summary>

```mermaid
graph LR
    A[Receivers<br/>OTLP gRPC/HTTP] --> B[Processors<br/>Batch, Transform]
    B --> C[Exporters<br/>ClickHouse]
    
    style A fill:#e3f2fd
    style B fill:#fff3e0
    style C fill:#f3e5f5
```
</details>

**Key Components:**

- **`receivers.otlp`**: Accept telemetry via gRPC (4317) and HTTP (4318)
- **`processors.batch`**: Batch data for efficient writes (10k spans/batch)
- **`processors.resourcedetection`**: Add host metadata automatically
- **`processors.signozspanmetrics`**: Generate RED metrics from spans
- **`exporters.clickhouse*`**: Write to ClickHouse databases

**CORS Configuration:**
```yaml
cors:
  allowed_origins: ["*"]  # Allow browser requests
  allowed_headers: ["*"]  # Allow auth headers
```

### ClickHouse Keeper vs ZooKeeper

| Feature | ClickHouse Keeper | ZooKeeper |
|---------|-------------------|-----------|
| **Language** | C++ (native) | Java (JVM) |
| **Memory** | ~50-100MB | ~500MB-1GB |
| **Latency** | <5ms | ~10-20ms |
| **Protocol** | Raft | ZAB |
| **Integration** | Built for ClickHouse | Generic |
| **Dependencies** | None | Requires JVM |

---

## 1.5: Adding Security Layers

**Security is optional but highly recommended for production.** You can mix and match these options.

### Authentication Flow Diagram

<details>
<summary><b>ASCII Diagram (Click to expand)</b></summary>

```
┌─────────────┐           ┌─────────────────────────┐           ┌───────────────┐
│   Client    │           │   OTel Collector        │           │  ClickHouse   │
│  (Agent)    │           │   (Gateway)             │           │               │
└──────┬──────┘           └──────────┬──────────────┘           └───────┬───────┘
       │                             │                                  │
       │  1. Send Telemetry          │                                  │
       │    + Credentials            │                                  │
       ├────────────────────────────>│                                  │
       │                             │                                  │
       │                             │  2. Authenticate                 │
       │                             │     (Basic Auth/API Key/mTLS)    │
       │                             ├──┐                               │
       │                             │  │ Validate                      │
       │                             │<─┘                               │
       │                             │                                  │
       │  3a. REJECT (401)           │                                  │
       │<────────────────────────────┤  (if auth fails)                 │
       │                             │                                  │
       │                             │  3b. ACCEPT & Process            │
       │                             │     (if auth succeeds)           │
       │                             ├─────────────────────────────────>│
       │                             │  4. Write Data                   │
       │                             │                                  │
```
</details>

<details>
<summary><b>Mermaid Diagram (Click to expand)</b></summary>

```mermaid
sequenceDiagram
    participant Client as Client/Agent
    participant Gateway as OTel Collector<br/>(Gateway)
    participant DB as ClickHouse
    
    Client->>Gateway: 1. Send Telemetry + Credentials
    Gateway->>Gateway: 2. Authenticate<br/>(Basic Auth/API Key/mTLS)
    
    alt Authentication Failed
        Gateway-->>Client: 3a. REJECT (401 Unauthorized)
    else Authentication Successful
        Gateway->>Gateway: 3b. Process & Transform
        Gateway->>DB: 4. Write Data
        Gateway-->>Client: 200 OK
    end
    
    Note over Client,DB: Security Layer Protects Gateway
```
</details>

### Option A: Basic Authentication

**Use Case:** Simple username/password protection. Good for internal networks.

**Step 1: Generate Credentials**

```bash
# Replace 'admin' and 'SecurePassword123!' with your own
docker run --rm httpd:2.4-alpine htpasswd -nbB admin "SecurePassword123!"

# Output example:
# admin:$2y$05$xyz...
```

**Step 2: Create `.htpasswd` File**

```bash
# Save the output to a file
echo "admin:\$2y\$05\$xyz..." > .htpasswd
```

**Step 3: Update `otel-collector-config.yaml`**

Add the `basicauth/server` extension:

```yaml
extensions:
  basicauth/server:
    htpasswd:
      file: /etc/.htpasswd
      inline: |
        admin:$2y$05$xyz...

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        auth:
          authenticator: basicauth/server
      http:
        endpoint: 0.0.0.0:4318
        auth:
          authenticator: basicauth/server
        cors:
          allowed_origins: ["*"]
          allowed_headers: ["*"]

# ... rest of config stays the same ...

service:
  extensions: [basicauth/server]
  pipelines:
    # ... pipelines stay the same ...
```

**Step 4: Mount `.htpasswd` in Docker Compose**

```yaml
otel-collector:
  volumes:
    - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml
    - ./.htpasswd:/etc/.htpasswd:ro  # Add this line
```

**Step 5: Restart Services**

```bash
docker-compose restart otel-collector
```

**Step 6: Test Authentication**

```bash
# Without credentials (should fail)
curl -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{}'
# Returns: 401 Unauthorized

# With credentials (should succeed)
curl -X POST http://localhost:4318/v1/traces \
  -u admin:SecurePassword123! \
  -H 'Content-Type: application/json' \
  -d '{}'
# Returns: 200 OK
```

---

### Option B: API Key (Bearer Token) Authentication

**Use Case:** Modern token-based auth. Good for programmatic access.

**Step 1: Generate API Key**

```bash
# Generate a secure random key
openssl rand -hex 32
# Output: a1b2c3d4e5f6...
```

**Step 2: Update `otel-collector-config.yaml`**

```yaml
extensions:
  bearertokenauth/server:
    tokens:
      - "a1b2c3d4e5f6..."  # Your generated token

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        auth:
          authenticator: bearertokenauth/server
      http:
        endpoint: 0.0.0.0:4318
        auth:
          authenticator: bearertokenauth/server
        cors:
          allowed_origins: ["*"]
          allowed_headers: ["*"]

# ... rest of config ...

service:
  extensions: [bearertokenauth/server]
  pipelines:
    # ... same as before ...
```

**Step 3: Restart Services**

```bash
docker-compose restart otel-collector
```

**Step 4: Test Authentication**

```bash
# Without token (should fail)
curl -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{}'
# Returns: 401 Unauthorized

# With token (should succeed)
curl -X POST http://localhost:4318/v1/traces \
  -H 'Authorization: Bearer a1b2c3d4e5f6...' \
  -H 'Content-Type: application/json' \
  -d '{}'
# Returns: 200 OK
```

---

### Option C: TLS Encryption

**Use Case:** Encrypt data in transit. Required for production over public networks.

**Step 1: Generate Self-Signed Certificates**

```bash
# Create certs directory
mkdir -p certs && cd certs

# Generate CA private key
openssl genrsa -out ca-key.pem 4096

# Generate CA certificate
openssl req -new -x509 -days 3650 -key ca-key.pem -out ca-cert.pem \
  -subj "/CN=SigNoz CA"

# Generate server private key
openssl genrsa -out server-key.pem 4096

# Generate server CSR
openssl req -new -key server-key.pem -out server-csr.pem \
  -subj "/CN=localhost"

# Sign server certificate
openssl x509 -req -days 3650 -in server-csr.pem \
  -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out server-cert.pem

cd ..
```

**Step 2: Update `otel-collector-config.yaml`**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        tls:
          cert_file: /etc/certs/server-cert.pem
          key_file: /etc/certs/server-key.pem
      http:
        endpoint: 0.0.0.0:4318
        tls:
          cert_file: /etc/certs/server-cert.pem
          key_file: /etc/certs/server-key.pem
        cors:
          allowed_origins: ["*"]
          allowed_headers: ["*"]

# ... rest of config ...
```

**Step 3: Update `docker-compose.yml`**

```yaml
otel-collector:
  volumes:
    - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml
    - ./certs:/etc/certs:ro  # Mount certificates
```

**Step 4: Restart Services**

```bash
docker-compose restart otel-collector
```

**Step 5: Test TLS Connection**

```bash
# Test with curl (accepts self-signed cert)
curl -k -X POST https://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{}'
```

---

### Option D: Mutual TLS (mTLS)

**Use Case:** Strongest security - both client and server authenticate. Required for zero-trust environments.

**Step 1: Generate Client Certificates**

```bash
cd certs

# Generate client private key
openssl genrsa -out client-key.pem 4096

# Generate client CSR
openssl req -new -key client-key.pem -out client-csr.pem \
  -subj "/CN=signoz-client"

# Sign client certificate
openssl x509 -req -days 3650 -in client-csr.pem \
  -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out client-cert.pem

cd ..
```

**Step 2: Update `otel-collector-config.yaml`**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        tls:
          cert_file: /etc/certs/server-cert.pem
          key_file: /etc/certs/server-key.pem
          client_ca_file: /etc/certs/ca-cert.pem
          client_ca_file_reload: true
      http:
        endpoint: 0.0.0.0:4318
        tls:
          cert_file: /etc/certs/server-cert.pem
          key_file: /etc/certs/server-key.pem
          client_ca_file: /etc/certs/ca-cert.pem
          client_ca_file_reload: true
        cors:
          allowed_origins: ["*"]
          allowed_headers: ["*"]

# ... rest of config ...
```

**Step 3: Test mTLS Connection**

```bash
# Test with client certificate
curl -k -X POST https://localhost:4318/v1/traces \
  --cert certs/client-cert.pem \
  --key certs/client-key.pem \
  -H 'Content-Type: application/json' \
  -d '{}'
```

---

## 1.6: Connecting Application Agents

Once security is enabled, you need to configure your application agents to authenticate.

### Example: Node.js Application with Basic Auth

```javascript
const opentelemetry = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');

const sdk = new opentelemetry.NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: 'http://localhost:4318/v1/traces',
    headers: {
      // Basic Auth
      'Authorization': 'Basic ' + Buffer.from('admin:SecurePassword123!').toString('base64'),
      
      // OR API Key
      // 'Authorization': 'Bearer a1b2c3d4e5f6...',
    },
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();
```

### Example: Python Application with API Key

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

# Set up tracer
trace.set_tracer_provider(TracerProvider())
tracer = trace.get_tracer(__name__)

# Configure exporter with authentication
exporter = OTLPSpanExporter(
    endpoint="http://localhost:4318/v1/traces",
    headers={
        "Authorization": "Bearer a1b2c3d4e5f6..."
    }
)

# Add exporter to tracer
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(exporter)
)
```

### Example: Java Application with mTLS

```java
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.exporter.otlp.http.trace.OtlpHttpSpanExporter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.BatchSpanProcessor;

import javax.net.ssl.*;
import java.io.FileInputStream;
import java.security.KeyStore;

public class TelemetryConfig {
    public static OpenTelemetry initOpenTelemetry() throws Exception {
        // Load client certificate
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        keyStore.load(new FileInputStream("client-cert.p12"), "password".toCharArray());
        
        KeyManagerFactory kmf = KeyManagerFactory.getInstance("SunX509");
        kmf.init(keyStore, "password".toCharArray());
        
        // Load CA certificate
        KeyStore trustStore = KeyStore.getInstance("JKS");
        trustStore.load(new FileInputStream("ca-cert.jks"), "password".toCharArray());
        
        TrustManagerFactory tmf = TrustManagerFactory.getInstance("SunX509");
        tmf.init(trustStore);
        
        // Create SSL context
        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);
        
        // Configure exporter
        OtlpHttpSpanExporter exporter = OtlpHttpSpanExporter.builder()
            .setEndpoint("https://localhost:4318/v1/traces")
            .setSslContext(sslContext)
            .build();
        
        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
            .addSpanProcessor(BatchSpanProcessor.builder(exporter).build())
            .build();
        
        return OpenTelemetrySdk.builder()
            .setTracerProvider(tracerProvider)
            .buildAndRegisterGlobal();
    }
}
```

### Environment Variable Configuration

Most OTel SDKs support environment variables:

```bash
# Basic Auth
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic YWRtaW46U2VjdXJlUGFzc3dvcmQxMjMh"

# API Key
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer a1b2c3d4e5f6..."

# TLS
export OTEL_EXPORTER_OTLP_ENDPOINT="https://localhost:4318"
export OTEL_EXPORTER_OTLP_CERTIFICATE="/path/to/ca-cert.pem"

# mTLS
export OTEL_EXPORTER_OTLP_ENDPOINT="https://localhost:4318"
export OTEL_EXPORTER_OTLP_CERTIFICATE="/path/to/ca-cert.pem"
export OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE="/path/to/client-cert.pem"
export OTEL_EXPORTER_OTLP_CLIENT_KEY="/path/to/client-key.pem"
```

---

---

# Part 2: High Availability (HA) Production Deployment

## 2.1: HA Architecture Overview

High availability ensures your observability platform remains operational even when individual components fail. A production HA deployment distributes SigNoz across multiple nodes with redundancy at every layer.

### Key HA Components

| Component | Minimum HA Setup | Why? |
|-----------|------------------|------|
| **ClickHouse Keeper** | 3 nodes | Raft consensus requires quorum (2 of 3) |
| **ClickHouse Server** | 3 nodes | Data replication + failover |
| **OTel Collector** | 2+ nodes | Load distribution + redundancy |
| **SigNoz Backend** | 2+ nodes | UI/API availability |
| **Load Balancer** | 2+ nodes | Traffic distribution |

### HA Architecture Diagram

<details>
<summary><b>ASCII Diagram - 3-Node HA Cluster (Click to expand)</b></summary>

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Load Balancer Layer                             │
│                    (HAProxy/Nginx - Health Checks)                           │
│                                                                               │
│    ┌──────────────────────┐              ┌──────────────────────┐            │
│    │  LB for OTel         │              │  LB for SigNoz UI    │            │
│    │  :4317 (gRPC)        │              │  :8080 (HTTP)        │            │
│    │  :4318 (HTTP)        │              │                      │            │
│    └──────────┬───────────┘              └──────────┬───────────┘            │
└───────────────┼──────────────────────────────────────┼────────────────────────┘
                │                                      │
    ┌───────────┴─────────┐                 ┌──────────┴─────────┐
    │                     │                 │                    │
    ▼                     ▼                 ▼                    ▼
┌─────────────┐     ┌─────────────┐   ┌──────────┐       ┌──────────┐
│ OTel        │     │ OTel        │   │ SigNoz   │       │ SigNoz   │
│ Collector 1 │     │ Collector 2 │   │ Backend1 │       │ Backend2 │
└──────┬──────┘     └──────┬──────┘   └────┬─────┘       └────┬─────┘
       │                   │               │                   │
       └────────┬──────────┘               └─────────┬─────────┘
                │                                    │
                │ Write Data                         │ Query Data
                ▼                                    ▼
    ┌───────────────────────────────────────────────────────────┐
    │           ClickHouse Cluster (3 Nodes)                    │
    │                                                            │
    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
    │  │ ClickHouse 1 │◄─┤ ClickHouse 2 │◄─┤ ClickHouse 3 │    │
    │  │  Shard 1     │  │  Shard 2     │  │  Shard 3     │    │
    │  │  Replica     │  │  Replica     │  │  Replica     │    │
    │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘    │
    │         │                 │                 │             │
    │         └─────────────────┴─────────────────┘             │
    │                           │                               │
    │                Coordinated via Keeper                     │
    └───────────────────────────┼───────────────────────────────┘
                                ▼
    ┌───────────────────────────────────────────────────────────┐
    │        ClickHouse Keeper Quorum (3 Nodes)                 │
    │                                                            │
    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
    │  │  Keeper 1    │◄─┤  Keeper 2    │◄─┤  Keeper 3    │    │
    │  │  (Leader)    │  │  (Follower)  │  │  (Follower)  │    │
    │  └──────────────┘  └──────────────┘  └──────────────┘    │
    │           Raft Consensus (Quorum: 2 of 3)                 │
    └───────────────────────────────────────────────────────────┘
```
</details>

<details>
<summary><b>Mermaid Diagram - HA Topology (Click to expand)</b></summary>

```mermaid
graph TB
    subgraph "Client Applications"
        Apps[OTel SDKs]
    end
    
    subgraph "Load Balancer Layer"
        LB_OTEL[Load Balancer<br/>OTel Ingestion<br/>:4317/:4318]
        LB_UI[Load Balancer<br/>SigNoz UI<br/>:8080]
    end
    
    subgraph "Application Layer"
        OTC1[OTel Collector 1]
        OTC2[OTel Collector 2]
        OTC3[OTel Collector 3]
        
        SN1[SigNoz Backend 1]
        SN2[SigNoz Backend 2]
    end
    
    subgraph "Data Layer - ClickHouse Cluster"
        CH1[ClickHouse 1<br/>Shard 1]
        CH2[ClickHouse 2<br/>Shard 2]
        CH3[ClickHouse 3<br/>Shard 3]
    end
    
    subgraph "Coordination Layer - Keeper Quorum"
        K1[Keeper 1<br/>Leader]
        K2[Keeper 2<br/>Follower]
        K3[Keeper 3<br/>Follower]
    end
    
    Apps -->|Send Telemetry| LB_OTEL
    Apps -->|Access UI| LB_UI
    
    LB_OTEL --> OTC1
    LB_OTEL --> OTC2
    LB_OTEL --> OTC3
    
    LB_UI --> SN1
    LB_UI --> SN2
    
    OTC1 --> CH1
    OTC1 --> CH2
    OTC1 --> CH3
    OTC2 --> CH1
    OTC2 --> CH2
    OTC2 --> CH3
    OTC3 --> CH1
    OTC3 --> CH2
    OTC3 --> CH3
    
    SN1 --> CH1
    SN1 --> CH2
    SN1 --> CH3
    SN2 --> CH1
    SN2 --> CH2
    SN2 --> CH3
    
    CH1 <-.Replication.-> CH2
    CH2 <-.Replication.-> CH3
    CH3 <-.Replication.-> CH1
    
    K1 <-.Raft Consensus.-> K2
    K2 <-.Raft Consensus.-> K3
    K3 <-.Raft Consensus.-> K1
    
    CH1 -.->|Coordination| K1
    CH2 -.->|Coordination| K2
    CH3 -.->|Coordination| K3
    
    style Apps fill:#e1f5ff
    style LB_OTEL fill:#fff4e6
    style LB_UI fill:#fff4e6
    style OTC1 fill:#e8f5e9
    style OTC2 fill:#e8f5e9
    style OTC3 fill:#e8f5e9
    style SN1 fill:#fce4ec
    style SN2 fill:#fce4ec
    style CH1 fill:#f3e5f5
    style CH2 fill:#f3e5f5
    style CH3 fill:#f3e5f5
    style K1 fill:#fff9c4
    style K2 fill:#fff9c4
    style K3 fill:#fff9c4
```
</details>

### Failover Scenarios

<details>
<summary><b>Scenario 1: Keeper Node Failure (Click to expand)</b></summary>

```mermaid
sequenceDiagram
    participant K1 as Keeper 1 (Leader)
    participant K2 as Keeper 2
    participant K3 as Keeper 3
    participant CH as ClickHouse Cluster
    
    Note over K1,K3: Normal Operation (3/3 healthy)
    K1->>CH: Coordination OK
    
    Note over K1: ❌ Keeper 1 Fails
    K2->>K3: Election Started
    K3->>K2: Vote Exchange
    
    Note over K2: ✅ K2 Elected Leader
    K2->>CH: Coordination Restored
    
    Note over K1,K3: Quorum Maintained (2/3)
    Note over K1,K3: ⚠️ Can tolerate 1 more failure
```
</details>

<details>
<summary><b>Scenario 2: ClickHouse Node Failure (Click to expand)</b></summary>

```mermaid
sequenceDiagram
    participant Apps as Applications
    participant OTC as OTel Collector
    participant CH1 as ClickHouse 1
    participant CH2 as ClickHouse 2
    participant CH3 as ClickHouse 3
    
    Note over CH1,CH3: All nodes healthy, data replicated
    Apps->>OTC: Send Telemetry
    OTC->>CH1: Write Data
    CH1->>CH2: Replicate
    CH1->>CH3: Replicate
    
    Note over CH2: ❌ CH2 Fails
    Apps->>OTC: Send Telemetry
    OTC->>CH1: Write Data (CH2 skipped)
    OTC->>CH3: Write Data
    CH1->>CH3: Continue Replication
    
    Note over CH1,CH3: ✅ Cluster Still Operational
    Note over CH1,CH3: Data on CH1 & CH3, will sync to CH2 when restored
```
</details>

---

## 2.2: Prerequisites for HA

### Hardware Requirements (Per Node)

| Node Type | CPU | RAM | Storage | Network |
|-----------|-----|-----|---------|---------|
| **ClickHouse** | 8+ cores | 32+ GB | 500+ GB NVMe | 10 Gbps |
| **Keeper** | 2 cores | 4 GB | 50 GB SSD | 1 Gbps |
| **OTel Collector** | 4 cores | 8 GB | 50 GB SSD | 10 Gbps |
| **SigNoz Backend** | 4 cores | 8 GB | 50 GB SSD | 1 Gbps |
| **Load Balancer** | 2 cores | 4 GB | 20 GB SSD | 10 Gbps |

### Network Requirements

- **Low latency** between nodes (<5ms RTT ideal for Keeper consensus)
- **High bandwidth** for ClickHouse replication (1+ Gbps)
- **Stable connections** (avoid packet loss)

---

## 2.3: HA Configuration Files (Single-Host Simulation)

For testing HA behavior, we can simulate a multi-node cluster on a single Docker host. This is ideal for development and testing before production deployment.

This setup runs a 3-node ClickHouse Keeper quorum and a 3-node replicated ClickHouse cluster on a single Docker host.

#### Step 1: Create Your Configuration Files

Create a new directory (e.g., `signoz-ha`) and place the following files inside it. We will use the same `.env` file approach for easy version management.

<details>
<summary><b>File 1: `.env` (Image Versions)</b></summary>

```env
# .env
#
# Define the image versions for the SigNoz Docker Compose setup.
# It's recommended to use specific, stable versions for production.

# ClickHouse and ClickHouse Keeper versions
CLICKHOUSE_VERSION=25.5.6
CLICKHOUSE_KEEPER_VERSION=25.5.6-alpine

# SigNoz component versions
SIGNOZ_BACKEND_VERSION=latest
SIGNOZ_OTEL_COLLECTOR_VERSION=latest
SIGNOZ_SCHEMA_MIGRATOR_VERSION=latest
```
</details>

<details>
<summary><b>File 2: `docker-compose.ha.yml` (IMPROVED)</b></summary>

```yaml
version: "3.8"

services:
  clickhouse-keeper-1:
    image: clickhouse/clickhouse-keeper:${CLICKHOUSE_KEEPER_VERSION}
    container_name: signoz-keeper-1
    hostname: clickhouse-keeper-1
    restart: unless-stopped
    volumes:
      - ./keeper-1.xml:/etc/clickhouse-keeper/keeper_config.xml
      - keeper-data-1:/var/lib/clickhouse-keeper
    healthcheck:
      test: ["CMD-SHELL", "clickhouse-keeper-client -h localhost -p 9181 -q ruok | grep -q imok"]
      interval: 10s; timeout: 5s; retries: 3
    networks:
      - signoz-net

  clickhouse-keeper-2:
    image: clickhouse/clickhouse-keeper:${CLICKHOUSE_KEEPER_VERSION}
    container_name: signoz-keeper-2
    hostname: clickhouse-keeper-2
    restart: unless-stopped
    volumes:
      - ./keeper-2.xml:/etc/clickhouse-keeper/keeper_config.xml
      - keeper-data-2:/var/lib/clickhouse-keeper
    healthcheck:
      test: ["CMD-SHELL", "clickhouse-keeper-client -h localhost -p 9181 -q ruok | grep -q imok"]
      interval: 10s; timeout: 5s; retries: 3
    networks:
      - signoz-net

  clickhouse-keeper-3:
    image: clickhouse/clickhouse-keeper:${CLICKHOUSE_KEEPER_VERSION}
    container_name: signoz-keeper-3
    hostname: clickhouse-keeper-3
    restart: unless-stopped
    volumes:
      - ./keeper-3.xml:/etc/clickhouse-keeper/keeper_config.xml
      - keeper-data-3:/var/lib/clickhouse-keeper
    healthcheck:
      test: ["CMD-SHELL", "clickhouse-keeper-client -h localhost -p 9181 -q ruok | grep -q imok"]
      interval: 10s; timeout: 5s; retries: 3
    networks:
      - signoz-net

  clickhouse-1:
    image: clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}
    container_name: signoz-clickhouse-1
    hostname: clickhouse-1
    restart: unless-stopped
    depends_on:
      clickhouse-keeper-1: { condition: service_healthy }
      clickhouse-keeper-2: { condition: service_healthy }
      clickhouse-keeper-3: { condition: service_healthy }
    volumes:
      - ./cluster-ha.xml:/etc/clickhouse-server/config.d/cluster.xml
      - clickhouse-data-1:/var/lib/clickhouse/
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8123/ping"]
      interval: 30s; timeout: 5s; retries: 3
    networks:
      - signoz-net

  clickhouse-2:
    image: clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}
    container_name: signoz-clickhouse-2
    hostname: clickhouse-2
    restart: unless-stopped
    depends_on:
      clickhouse-keeper-1: { condition: service_healthy }
      clickhouse-keeper-2: { condition: service_healthy }
      clickhouse-keeper-3: { condition: service_healthy }
    volumes:
      - ./cluster-ha.xml:/etc/clickhouse-server/config.d/cluster.xml
      - clickhouse-data-2:/var/lib/clickhouse/
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8123/ping"]
      interval: 30s; timeout: 5s; retries: 3
    networks:
      - signoz-net

  clickhouse-3:
    image: clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}
    container_name: signoz-clickhouse-3
    hostname: clickhouse-3
    restart: unless-stopped
    depends_on:
      clickhouse-keeper-1: { condition: service_healthy }
      clickhouse-keeper-2: { condition: service_healthy }
      clickhouse-keeper-3: { condition: service_healthy }
    volumes:
      - ./cluster-ha.xml:/etc/clickhouse-server/config.d/cluster.xml
      - clickhouse-data-3:/var/lib/clickhouse/
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "0.0.0.0:8123/ping"]
      interval: 30s; timeout: 5s; retries: 3
    networks:
      - signoz-net

  schema-migrator:
    image: signoz/signoz-schema-migrator:${SIGNOZ_SCHEMA_MIGRATOR_VERSION}
    container_name: schema-migrator-sync
    command: ["sync", "--dsn=tcp://clickhouse-1:9000"] # Point to any CH node
    depends_on:
      clickhouse-1: { condition: service_healthy }
      clickhouse-2: { condition: service_healthy }
      clickhouse-3: { condition: service_healthy }
    restart: on-failure
    networks:
      - signoz-net

  signoz:
    image: signoz/signoz:${SIGNOZ_BACKEND_VERSION}
    container_name: signoz-backend
    ports: ["8080:8080"]
    depends_on:
      schema-migrator: { condition: service_completed_successfully }
    volumes:
      - sqlite-data:/var/lib/signoz/
    environment:
      - SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN=tcp://clickhouse-1:9000,tcp://clickhouse-2:9000,tcp://clickhouse-3:9000
      - SIGNOZ_SQLSTORE_SQLITE_PATH=/var/lib/signoz/signoz.db
    networks:
      - signoz-net

  otel-collector:
    image: signoz/signoz-otel-collector:${SIGNOZ_OTEL_COLLECTOR_VERSION}
    container_name: signoz-otel-collector
    command: ["--config=/etc/otel-collector-config.yaml"]
    ports: ["4317:4317", "4318:4318"]
    volumes:
      - ./otel-collector-ha.yaml:/etc/otel-collector-config.yaml
    depends_on:
      signoz: { condition: service_started }
    networks:
      - signoz-net

networks:
  signoz-net:
    name: signoz-net

volumes:
  keeper-data-1:
  keeper-data-2:
  keeper-data-3:
  clickhouse-data-1:
  clickhouse-data-2:
  clickhouse-data-3:
  sqlite-data:
```
</details>

#### File 3: `keeper-1.xml` - First Keeper Node

<details>
<summary><b>Click to expand keeper-1.xml</b></summary>

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <console>true</console>
    </logger>

    <listen_host>0.0.0.0</listen_host>

    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
        </coordination_settings>

        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>clickhouse-keeper-1</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>2</id>
                <hostname>clickhouse-keeper-2</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>3</id>
                <hostname>clickhouse-keeper-3</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
```
</details>

#### File 4: `keeper-2.xml` - Second Keeper Node

<details>
<summary><b>Click to expand keeper-2.xml</b></summary>

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <console>true</console>
    </logger>

    <listen_host>0.0.0.0</listen_host>

    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>2</server_id>
        
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
        </coordination_settings>

        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>clickhouse-keeper-1</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>2</id>
                <hostname>clickhouse-keeper-2</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>3</id>
                <hostname>clickhouse-keeper-3</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
```
</details>

#### File 5: `keeper-3.xml` - Third Keeper Node

<details>
<summary><b>Click to expand keeper-3.xml</b></summary>

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <console>true</console>
    </logger>

    <listen_host>0.0.0.0</listen_host>

    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>3</server_id>
        
        <log_storage_path>/var/lib/clickhouse-keeper/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/coordination/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>information</raft_logs_level>
        </coordination_settings>

        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>clickhouse-keeper-1</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>2</id>
                <hostname>clickhouse-keeper-2</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>3</id>
                <hostname>clickhouse-keeper-3</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
```
</details>

#### File 6: `cluster-ha.xml` - HA Cluster Configuration

<details>
<summary><b>Click to expand cluster-ha.xml</b></summary>

```xml
<clickhouse>
    <!-- ClickHouse Keeper (ZooKeeper replacement) Configuration -->
    <zookeeper>
        <node>
            <host>clickhouse-keeper-1</host>
            <port>9181</port>
        </node>
        <node>
            <host>clickhouse-keeper-2</host>
            <port>9181</port>
        </node>
        <node>
            <host>clickhouse-keeper-3</host>
            <port>9181</port>
        </node>
        <session_timeout_ms>30000</session_timeout_ms>
        <operation_timeout_ms>10000</operation_timeout_ms>
    </zookeeper>

    <!-- Distributed DDL Configuration -->
    <distributed_ddl>
        <path>/clickhouse/task_queue/ddl</path>
    </distributed_ddl>

    <!-- Remote Servers (Cluster Topology) -->
    <remote_servers>
        <!-- 3 shards, 2 replicas each for high availability -->
        <cluster_3S_2R>
            <shard>
                <replica>
                    <host>clickhouse-1</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-2</host>
                    <port>9000</port>
                </replica>
            </shard>
            <shard>
                <replica>
                    <host>clickhouse-2</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-3</host>
                    <port>9000</port>
                </replica>
            </shard>
            <shard>
                <replica>
                    <host>clickhouse-3</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-1</host>
                    <port>9000</port>
                </replica>
            </shard>
        </cluster_3S_2R>

        <!-- Single shard with 3 replicas (simpler HA) -->
        <cluster_1S_3R>
            <shard>
                <replica>
                    <host>clickhouse-1</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-2</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-3</host>
                    <port>9000</port>
                </replica>
            </shard>
        </cluster_1S_3R>
    </remote_servers>

    <!-- Macros for replica identification -->
    <macros>
        <shard>01</shard>
        <replica>replica_1</replica>
    </macros>
</clickhouse>
```
</details>

#### File 7: `otel-collector-ha.yaml` - HA Collector Configuration

<details>
<summary><b>Click to expand otel-collector-ha.yaml</b></summary>

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
        cors:
          allowed_origins: ["*"]
          allowed_headers: ["*"]

processors:
  batch:
    send_batch_size: 10000
    send_batch_max_size: 11000
    timeout: 10s

  resourcedetection:
    detectors: [env, system, docker]
    timeout: 2s

  signozspanmetrics/prometheus:
    metrics_exporter: prometheus
    latency_histogram_buckets: [100us, 1ms, 2ms, 6ms, 10ms, 50ms, 100ms, 250ms, 500ms, 1000ms, 1400ms, 2000ms, 5s, 10s, 20s, 40s, 60s]
    dimensions_cache_size: 10000

exporters:
  # Write to all ClickHouse nodes for redundancy
  clickhousetraces:
    datasource: tcp://clickhouse-1:9000,clickhouse-2:9000,clickhouse-3:9000/?database=signoz_traces
    low_cardinal_exception_grouping: true

  clickhousemetricswrite:
    endpoint: tcp://clickhouse-1:9000,clickhouse-2:9000,clickhouse-3:9000/?database=signoz_metrics
    resource_to_telemetry_conversion:
      enabled: true

  clickhouselogsexporter:
    dsn: tcp://clickhouse-1:9000,clickhouse-2:9000,clickhouse-3:9000/?database=signoz_logs

  prometheus:
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [signozspanmetrics/prometheus, batch, resourcedetection]
      exporters: [clickhousetraces]
    
    metrics:
      receivers: [otlp]
      processors: [batch, resourcedetection]
      exporters: [clickhousemetricswrite]
    
    logs:
      receivers: [otlp]
      processors: [batch, resourcedetection]
      exporters: [clickhouselogsexporter]
```
</details>

---

## 2.4: Deploy and Verify HA Cluster

**Step 1: Start all services**

```bash
docker-compose -f docker-compose.ha.yml up -d
```

**Step 2: Check service health**

```bash
docker-compose -f docker-compose.ha.yml ps
```

Expected output - all services should be "Up" and healthy:
```
NAME                       STATUS
signoz-backend             Up
signoz-clickhouse-1        Up (healthy)
signoz-clickhouse-2        Up (healthy)
signoz-clickhouse-3        Up (healthy)
signoz-keeper-1            Up (healthy)
signoz-keeper-2            Up (healthy)
signoz-keeper-3            Up (healthy)
signoz-otel-collector      Up
schema-migrator-sync       Exited (0)
```

**Step 3: Verify ClickHouse Keeper quorum**

```bash
# Check keeper status on node 1
docker exec signoz-keeper-1 clickhouse-keeper-client -h localhost -p 9181 -q "get /clickhouse/task_queue/ddl"

# Check if all keepers see each other
docker logs signoz-keeper-1 2>&1 | grep -i "raft"
```

**Step 4: Verify ClickHouse cluster**

```bash
# Connect to ClickHouse and check cluster
docker exec signoz-clickhouse-1 clickhouse-client --query="SELECT * FROM system.clusters"
```

---

## 2.5: Testing Fault Tolerance

**Test 1: Keeper Node Failure**

```bash
# Stop one keeper node
docker-compose -f docker-compose.ha.yml stop clickhouse-keeper-2

# Verify cluster still works (needs 2 out of 3)
docker exec signoz-clickhouse-1 clickhouse-client --query="SELECT 1"

# Restore keeper
docker-compose -f docker-compose.ha.yml start clickhouse-keeper-2
```

**Test 2: ClickHouse Node Failure**

```bash
# Stop one ClickHouse node
docker-compose -f docker-compose.ha.yml stop clickhouse-2

# Verify UI still accessible
curl http://localhost:8080/api/v1/version

# Send test telemetry
curl -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[]}'

# Restore ClickHouse
docker-compose -f docker-compose.ha.yml start clickhouse-2
```

**Test 3: Split Brain Prevention**

```bash
# Stop 2 out of 3 keepers (quorum lost)
docker-compose -f docker-compose.ha.yml stop clickhouse-keeper-2 clickhouse-keeper-3

# Cluster should be read-only now
docker exec signoz-clickhouse-1 clickhouse-client --query="CREATE TABLE test (id Int32) ENGINE=Memory"
# Should fail: "Coordination::Exception: Session expired"

# Restore quorum
docker-compose -f docker-compose.ha.yml start clickhouse-keeper-2 clickhouse-keeper-3
```

---

## 2.6: Load Balancer Configuration

For production HA, you should place a load balancer in front of:
1. **OTel Collector** (ports 4317, 4318) - for telemetry ingestion
2. **SigNoz UI** (port 8080) - for user access

#### Example: Nginx Load Balancer

Create `nginx.conf`:

```nginx
upstream otel_grpc {
    least_conn;
    server otel-collector-1:4317 max_fails=3 fail_timeout=30s;
    server otel-collector-2:4317 max_fails=3 fail_timeout=30s;
    server otel-collector-3:4317 max_fails=3 fail_timeout=30s;
}

upstream otel_http {
    least_conn;
    server otel-collector-1:4318 max_fails=3 fail_timeout=30s;
    server otel-collector-2:4318 max_fails=3 fail_timeout=30s;
    server otel-collector-3:4318 max_fails=3 fail_timeout=30s;
}

upstream signoz_ui {
    least_conn;
    server signoz-1:8080 max_fails=3 fail_timeout=30s;
    server signoz-2:8080 max_fails=3 fail_timeout=30s;
}

server {
    listen 4317 http2;
    location / {
        grpc_pass grpc://otel_grpc;
    }
}

server {
    listen 4318;
    location / {
        proxy_pass http://otel_http;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}

server {
    listen 8080;
    location / {
        proxy_pass http://signoz_ui;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

#### Example: HAProxy Configuration

Create `haproxy.cfg`:

```haproxy
global
    maxconn 4096

defaults
    mode http
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend otel_http_frontend
    bind *:4318
    default_backend otel_http_backend

backend otel_http_backend
    balance roundrobin
    option httpchk GET /
    server collector1 otel-collector-1:4318 check
    server collector2 otel-collector-2:4318 check
    server collector3 otel-collector-3:4318 check

frontend signoz_ui_frontend
    bind *:8080
    default_backend signoz_ui_backend

backend signoz_ui_backend
    balance roundrobin
    option httpchk GET /api/v1/version
    server ui1 signoz-1:8080 check
    server ui2 signoz-2:8080 check
```

---

# Part 3: Operations & Maintenance

This section covers day-to-day operations, maintenance procedures, and troubleshooting for your SigNoz deployment.

## 3.1: Monitoring & Health Checks

**Docker-level Monitoring:**

```bash
# Check service status
docker-compose ps

# Monitor resource usage
docker stats

# Check individual service health
docker inspect signoz-clickhouse --format='{{.State.Health.Status}}'
```

**ClickHouse Monitoring Queries:**

```sql
-- Database sizes
SELECT
    database,
    formatReadableSize(sum(bytes)) AS size
FROM system.parts
WHERE active
GROUP BY database
ORDER BY sum(bytes) DESC;

-- Query performance
SELECT
    query_duration_ms,
    query,
    user,
    client_name
FROM system.query_log
WHERE type = 'QueryFinish'
ORDER BY query_duration_ms DESC
LIMIT 10;

-- Replication status (HA only)
SELECT
    database,
    table,
    is_leader,
    total_replicas,
    active_replicas
FROM system.replicas;
```

**OTel Collector Metrics:**

The collector exposes Prometheus metrics on port 8889:

```bash
curl http://localhost:8889/metrics | grep otelcol
```

Key metrics to monitor:
- `otelcol_receiver_accepted_spans` - Spans received
- `otelcol_receiver_refused_spans` - Spans rejected
- `otelcol_exporter_sent_spans` - Spans exported
- `otelcol_processor_batch_batch_send_size` - Batch sizes

---

## 3.2: Backup & Restore Strategies

#### Configuration Backup

```bash
# Backup all configuration files
tar -czf signoz-config-$(date +%Y%m%d).tar.gz \
  docker-compose.yml \
  .env \
  otel-collector-config.yaml \
  clickhouse-keeper-config.xml \
  cluster-keeper.xml \
  signoz-prometheus.yml

# Store in version control
git add *.yml *.xml *.yaml .env
git commit -m "Backup configuration"
git push
```

#### Data Backup (Standalone)

**Method 1: Volume Backup (Offline)**

```bash
# Stop services
docker-compose down

# Backup volumes
docker run --rm \
  -v signoz-standalone_clickhouse-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/clickhouse-backup-$(date +%Y%m%d).tar.gz -C /data .

# Restart services
docker-compose up -d
```

**Method 2: ClickHouse Native Backup (Online)**

```bash
# Backup database
docker exec signoz-clickhouse clickhouse-client --query="BACKUP DATABASE signoz_traces TO Disk('backups', 'traces-$(date +%Y%m%d).zip')"
docker exec signoz-clickhouse clickhouse-client --query="BACKUP DATABASE signoz_metrics TO Disk('backups', 'metrics-$(date +%Y%m%d).zip')"
docker exec signoz-clickhouse clickhouse-client --query="BACKUP DATABASE signoz_logs TO Disk('backups', 'logs-$(date +%Y%m%d).zip')"
```

#### Data Backup (HA with clickhouse-backup)

Install `clickhouse-backup` tool:

```bash
# Create backup configuration
cat > clickhouse-backup-config.yml <<EOF
general:
  remote_storage: s3
  backups_to_keep_local: 3
  backups_to_keep_remote: 10

clickhouse:
  host: clickhouse-1
  port: 9000
  username: default
  password: ""

s3:
  endpoint: https://s3.amazonaws.com
  region: us-east-1
  bucket: signoz-backups
  access_key: YOUR_ACCESS_KEY
  secret_key: YOUR_SECRET_KEY
EOF

# Create backup
clickhouse-backup create backup-$(date +%Y%m%d-%H%M%S)

# Upload to S3
clickhouse-backup upload backup-$(date +%Y%m%d-%H%M%S)
```

#### Data Restore

**Restore from volume backup:**

```bash
# Stop services
docker-compose down

# Remove old data
docker volume rm signoz-standalone_clickhouse-data

# Create new volume
docker volume create signoz-standalone_clickhouse-data

# Restore data
docker run --rm \
  -v signoz-standalone_clickhouse-data:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/clickhouse-backup-20250109.tar.gz -C /data

# Restart services
docker-compose up -d
```

**Restore from ClickHouse backup:**

```bash
docker exec signoz-clickhouse clickhouse-client --query="RESTORE DATABASE signoz_traces FROM Disk('backups', 'traces-20250109.zip')"
```

---

## 3.3: Scaling Guidelines

#### Vertical Scaling (Increase Resources)

**ClickHouse:**
- **CPU**: 8+ cores recommended for production
- **RAM**: 16GB minimum, 64GB+ for large deployments
- **Disk**: NVMe SSD, 500GB+ with RAID 10

Update `docker-compose.yml`:

```yaml
clickhouse:
  deploy:
    resources:
      limits:
        cpus: '8'
        memory: 32G
      reservations:
        cpus: '4'
        memory: 16G
```

**OTel Collector:**
- **CPU**: 2-4 cores
- **RAM**: 4-8GB
- **Network**: High throughput (10Gbps+)

#### Horizontal Scaling (Add More Nodes)

**Add more OTel Collectors:**

```yaml
otel-collector-2:
  image: signoz/signoz-otel-collector:${SIGNOZ_OTEL_COLLECTOR_VERSION}
  container_name: signoz-otel-collector-2
  command: ["--config=/etc/otel-collector-config.yaml"]
  ports: ["4319:4317", "4320:4318"]  # Different ports
  volumes: ["./otel-collector-config.yaml:/etc/otel-collector-config.yaml"]
```

Place a load balancer (Nginx/HAProxy) in front of multiple collectors.

**Add more ClickHouse nodes:**

Update `cluster-ha.xml` to include additional shards/replicas, then add services to `docker-compose.ha.yml`.

---

## 3.4: Troubleshooting Common Issues

**Issue 1: Services Won't Start**

```bash
# Check logs
docker-compose logs clickhouse
docker-compose logs otel-collector

# Common causes:
# - Port conflicts (already in use)
# - Insufficient memory
# - Misconfigured volumes
```

**Issue 2: High Memory Usage**

```bash
# Check ClickHouse memory
docker exec signoz-clickhouse clickhouse-client --query="
  SELECT
    formatReadableSize(value) AS memory
  FROM system.asynchronous_metrics
  WHERE metric = 'MemoryTracking'
"

# Tune ClickHouse settings in config.xml:
# <max_memory_usage>10000000000</max_memory_usage>  # 10GB
```

**Issue 3: Slow Queries**

```bash
# Find slow queries
docker exec signoz-clickhouse clickhouse-client --query="
  SELECT
    query_duration_ms,
    query
  FROM system.query_log
  WHERE type = 'QueryFinish'
    AND query_duration_ms > 5000
  ORDER BY query_duration_ms DESC
  LIMIT 10
"

# Add indexes or optimize table structure
```

**Issue 4: Data Not Appearing in UI**

```bash
# Check OTel Collector is receiving data
curl http://localhost:8889/metrics | grep accepted_spans

# Check ClickHouse has data
docker exec signoz-clickhouse clickhouse-client --query="
  SELECT count(*) FROM signoz_traces.signoz_index_v2
"

# Check SigNoz backend logs
docker-compose logs signoz | tail -100
```

**Issue 5: Keeper Quorum Lost**

```bash
# Check keeper status
docker exec signoz-keeper-1 clickhouse-keeper-client -h localhost -p 9181 -q "ruok"

# If quorum lost, restart all keeper nodes simultaneously
docker-compose -f docker-compose.ha.yml restart clickhouse-keeper-1 clickhouse-keeper-2 clickhouse-keeper-3
```

---

## 3.5: Performance Tuning

#### ClickHouse Tuning

**Optimize merge settings:**

```xml
<!-- Add to clickhouse config.xml -->
<merge_tree>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
    <max_bytes_to_merge_at_min_space_in_pool>1048576</max_bytes_to_merge_at_min_space_in_pool>
</merge_tree>
```

**Enable query cache:**

```xml
<query_cache>
    <max_size_in_bytes>1073741824</max_size_in_bytes>  <!-- 1GB -->
    <max_entries>1024</max_entries>
</query_cache>
```

#### OTel Collector Tuning

**Increase batch size for high throughput:**

```yaml
processors:
  batch:
    send_batch_size: 50000      # Increase from 10000
    send_batch_max_size: 55000
    timeout: 5s                 # Decrease from 10s
```

**Add memory limiter:**

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 4096
    spike_limit_mib: 512

service:
  pipelines:
    traces:
      processors: [memory_limiter, batch, resourcedetection]
```

---

## 3.6: Security Best Practices

1. **Enable Authentication** - Always use Basic Auth, API Keys, or mTLS in production
2. **Use TLS** - Encrypt all traffic over public networks
3. **Network Isolation** - Use Docker networks, don't expose ClickHouse ports publicly
4. **Regular Updates** - Pin versions in `.env` and update regularly
5. **Backup Encryption** - Encrypt backups at rest and in transit
6. **Access Control** - Limit who can access SigNoz UI and APIs
7. **Secrets Management** - Use Docker secrets or external secret managers
8. **Audit Logging** - Enable ClickHouse query logging for compliance
9. **Rate Limiting** - Implement rate limits on ingestion endpoints
10. **Monitoring** - Set up alerts for security events (failed auth, unusual traffic)

---

## Conclusion

This guide covered:
- ✅ Standalone deployment (development/small teams)
- ✅ Multiple security options (Basic Auth, API Keys, TLS, mTLS)
- ✅ HA deployment (production-grade fault tolerance)
- ✅ Operations (monitoring, backup, scaling, troubleshooting)

For additional help:
- [SigNoz Documentation](https://signoz.io/docs/)
- [SigNoz Community Slack](https://signoz.io/slack)
- [GitHub Issues](https://github.com/SigNoz/signoz/issues)

---

**Document Version:** 2.0  
**Last Updated:** November 9, 2025  
**Maintained By:** SigNoz Community
