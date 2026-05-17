# SafeSpot Kubernetes Manifest Repository

## 1. 개요

이 저장소는 SafeSpot 서비스 배포를 위한 Kubernetes 매니페스트 및 Helm 차트를 관리한다.

애플리케이션 코드와 Docker 이미지는 별도의 저장소에서 관리된다:

* safespot-application (백엔드)
* safespot-front (프론트엔드)

---

## 2. 관리 범위 (Scope)

이 저장소는 아래 서비스만 관리한다:

* api-core
* api-public-read
* api-public-read-surge (재난 시 선제 확장용 Deployment)
* external-ingestion
* db-migration Job (Flyway, ArgoCD PreSync hook)
* nginx (local only — EKS dev에서는 `nginx.enabled=false`)

다음 인프라 구성 요소는 관리하지 않는다:

* PostgreSQL
* Redis
* LocalStack
* Exporter (Prometheus exporter 등)

> **nginx**: 로컬 개발 환경에서만 사용한다. EKS dev에서는 CloudFront + ALB 구조를 사용하므로 `nginx.enabled=false`다.

---

## 3. Namespace

모든 애플리케이션 워크로드는 아래 namespace에 배포된다:

```text
application
```

---

## 4. Label 규칙 (필수)

모든 Kubernetes 리소스는 반드시 아래 label을 포함해야 한다:

```yaml
metadata:
  labels:
    app: <서비스명>
    service: <서비스명>
    env: dev
```

서비스별 매핑:

| 서비스 | app | service | component |
|---|---|---|---|
| api-core | api-core | api-core | — |
| api-public-read | api-public-read | api-public-read | — |
| api-public-read-surge | api-public-read-surge | api-public-read | surge |
| external-ingestion | external-ingestion | external-ingestion | — |
| nginx | nginx | nginx | — |

**중요 — api-public-read Service selector:**

`api-public-read` Service는 `service: api-public-read` 단일 selector를 사용한다.

```yaml
selector:
  service: api-public-read
```

base pod(`app: api-public-read`)와 surge pod(`app: api-public-read-surge, component: surge`)가 모두 같은 Service endpoint로 합류한다.

---

## 5. 인프라 엔드포인트

### 로컬 (Local)

| 역할 | 엔드포인트 |
|---|---|
| PostgreSQL Primary | `postgres-postgresql-primary.safespot-db.svc.cluster.local:5432` |
| PostgreSQL Read | `postgres-postgresql-read.safespot-db.svc.cluster.local:5432` |
| Redis | `redis.safespot-cache.svc.cluster.local:6379` |
| LocalStack | `http://localstack.safespot-localstack.svc.cluster.local:4566` |

### EKS dev

| 역할 | 엔드포인트 |
|---|---|
| Aurora Writer | SSM `/safespot/dev/data/aurora-cluster-endpoint` → RDS cluster endpoint |
| Aurora Reader | SSM `/safespot/dev/data/aurora-reader-endpoint` → RDS reader endpoint |
| Redis | SSM `/safespot/dev/data/redis-primary-endpoint` → ElastiCache endpoint |
| AWS SQS | 실 AWS SQS 엔드포인트 (LocalStack 불사용) |

> LocalStack은 로컬 전용이다. EKS dev에서는 실 AWS 서비스를 사용한다.

---

## 6. 네트워크 구성

### 로컬

```
Spring Boot → Redis / PostgreSQL / LocalStack
Ingress (nginx) + MetalLB
```

### EKS dev

```
Spring Boot → Redis (ElastiCache) / Aurora / AWS SQS
Ingress (ALB) — AWS Load Balancer Controller
Frontend: CloudFront + S3 (nginx Deployment 불사용)
```

---

## 7. Ingress 라우팅

### 로컬

```
/           → nginx:80
/api/core   → api-core:8080
/api/public → api-public-read:8080
```

### EKS dev (ALB)

```
/api/core   → api-core Service (port 80 → 8080)
/api/public → api-public-read Service (port 80 → 8080)
Frontend    → CloudFront/S3 (ALB 미경유)
```

ExternalDNS가 `api-origin.safespot.site`를 ALB DNS로 연결한다.

---

## 8. 환경 설정

### ConfigMap (서비스별 분리)

ConfigMap은 서비스마다 별도로 생성된다. 공통 변수(Spring, Redis, AWS)는 모든 ConfigMap에 포함되며, `SPRING_DATASOURCE_URL`은 서비스별로 다른 DB 엔드포인트를 가리킨다.

공통 변수 예시:

```env
SPRING_PROFILES_ACTIVE=dev
REDIS_HOST=<endpoint>
REDIS_PORT=6379
AWS_REGION=ap-northeast-2
```

> 로컬에서는 `AWS_ENDPOINT=http://localstack...`, EKS dev에서는 비워둠(실 AWS 사용).

서비스별 SPRING_DATASOURCE_URL:

```env
# api-core / external-ingestion (primary)
SPRING_DATASOURCE_URL=jdbc:postgresql://<writer-endpoint>:5432/safespot

# api-public-read (read-only)
SPRING_DATASOURCE_URL=jdbc:postgresql://<reader-endpoint>:5432/safespot
```

### Secret

EKS dev: External Secrets Operator가 SSM Parameter Store (SecureString)에서 `safespot-secret`을 자동 생성한다.
로컬: `secret.create: true`로 Helm이 직접 생성 (실제 값은 Git 커밋 금지).

---

## 9. 서비스별 DB 라우팅

| 서비스 | ConfigMap | DB 엔드포인트 |
|---|---|---|
| api-core | safespot-api-core-config | Aurora Writer |
| api-public-read | safespot-api-public-read-config | Aurora Reader |
| api-public-read-surge | safespot-api-public-read-config | Aurora Reader (base와 동일) |
| external-ingestion | safespot-external-ingestion-config | Aurora Writer |

- api-core — 쓰기/읽기 모두 필요하므로 Writer 사용
- api-public-read / api-public-read-surge — 읽기 전용 조회 서비스이므로 Reader 사용
- external-ingestion — 정규화된 외부 데이터를 DB에 쓰므로 Writer 사용

---

## 9-1. api-public-read cache regeneration queue 라우팅

`api-public-read`(와 `api-public-read-surge`)는 cache domain별로 서로 다른 SQS queue에 regeneration event를 발행한다.

### cache domain → queue 매핑

| cache domain | env var | values key | dev queue |
|---|---|---|---|
| shelter, evacuation entry | `SAFESPOT_CACHE_REGENERATION_QUEUES_CACHE_REFRESH_URL` | `configmap.sqs.cacheRefreshQueueUrl` | `safespot-dev-async-worker-sqs-cache-refresh` |
| disaster | `SAFESPOT_CACHE_REGENERATION_QUEUES_READMODEL_REFRESH_URL` | `configmap.sqs.readModelRefreshQueueUrl` | `safespot-dev-async-worker-sqs-readmodel-refresh` |
| weather, air_quality | `SAFESPOT_CACHE_REGENERATION_QUEUES_ENVIRONMENT_CACHE_REFRESH_URL` | `configmap.sqs.environmentCacheRefreshQueueUrl` | `safespot-dev-async-worker-sqs-environment-cache-refresh` |

### env var 전체 목록 (safespot-api-public-read-config)

application 최종 확정 설정(`safespot.aws.sqs.*`) 기준:

```
SAFESPOT_CACHE_REGENERATION_PUBLISHER_MODE=sqs

# application이 실제 읽는 env (safespot.aws.sqs.* Spring relaxed binding)
CACHE_REFRESH_QUEUE_URL=<cache-refresh-queue-url>
READMODEL_REFRESH_QUEUE_URL=<readmodel-refresh-queue-url>
ENVIRONMENT_CACHE_REFRESH_QUEUE_URL=<environment-cache-refresh-queue-url>

# backward compatibility — 구버전 호환. 다중 queue 완전 전환 후 제거 예정.
SAFESPOT_CACHE_REGENERATION_QUEUE_URL=<cache-refresh-queue-url>

# deprecated — 옵션 A 임시 이름. 롤백 안전망용으로 유지 중. 안정화 후 제거.
SAFESPOT_CACHE_REGENERATION_QUEUES_CACHE_REFRESH_URL=<cache-refresh-queue-url>
SAFESPOT_CACHE_REGENERATION_QUEUES_READMODEL_REFRESH_URL=<readmodel-refresh-queue-url>
SAFESPOT_CACHE_REGENERATION_QUEUES_ENVIRONMENT_CACHE_REFRESH_URL=<environment-cache-refresh-queue-url>
```

### api-public-read-surge env 주입 방식

`api-public-read-surge` Deployment는 `api-public-read`와 동일한 ConfigMap(`safespot-api-public-read-config`)을 `envFrom`으로 참조한다. config drift가 없다.

### 후속 작업 필요 사항

| 저장소 | 작업 내용 |
|---|---|
| **k8s-manifest repo** | 배포 안정화 후 deprecated `SAFESPOT_CACHE_REGENERATION_QUEUES_*` env 3개 및 `SAFESPOT_CACHE_REGENERATION_QUEUE_URL` 제거 |
| **terraform repo** | `safespot-dev-async-worker-sqs-readmodel-refresh` queue SSM parameter (`/safespot/dev/async-worker/readmodel-refresh-queue-url`) 실제 URL 확인; IRSA policy에 신규 queue ARN SendMessage 권한 추가 |

---

## 10. 이미지 규칙

### 로컬 개발

```
safespot/api-core:local
safespot/api-public-read:local
safespot/external-ingestion:local
safespot/nginx:local
```

### CI/CD (EKS dev)

```
ghcr.io/project-safespot/safespot-api-core:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-api-public-read:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-external-ingestion:<IMAGE_TAG>
```

> `api-public-read-surge`는 별도 이미지를 관리하지 않는다. `api-public-read`와 동일한 이미지를 사용한다.

---

## 11. 배포 정책

```yaml
apiCore.enabled=true
apiPublicRead.enabled=true
apiPublicReadSurge.enabled=true   # EKS dev; local은 false
externalIngestion.enabled=true
nginx.enabled=false               # EKS dev; local은 true
```

---

## 12. Helm Chart 구조

```
charts/safespot/
├── Chart.yaml
├── values.yaml                     # 공통 기본값 (tag: latest, pullPolicy: Always)
├── values-local.yaml               # 로컬 오버라이드 (tag: local, pullPolicy: IfNotPresent)
├── values-dev.infra.template.yaml  # EKS dev 인프라 템플릿. ${VAR} 구문. 사람이 편집
├── values-dev.infra.generated.yaml # 자동 생성 인프라 값. ArgoCD가 읽음. 직접 수정 금지
├── values-dev.images.yaml          # 애플리케이션 이미지 태그. image-update CI 소유
└── templates/
    ├── namespace.yaml
    ├── configmap-api-core.yaml
    ├── configmap-api-public-read.yaml
    ├── configmap-external-ingestion.yaml
    ├── configmap-migration.yaml
    ├── secret.yaml
    ├── externalsecret.yaml
    ├── serviceaccount.yaml
    ├── deployment-api-core.yaml
    ├── deployment-api-public-read.yaml
    ├── deployment-api-public-read-surge.yaml   # 신규: 재난 선제 확장용
    ├── deployment-external-ingestion.yaml
    ├── deployment-nginx.yaml
    ├── service-api-core.yaml
    ├── service-api-public-read.yaml
    ├── service-external-ingestion.yaml
    ├── service-nginx.yaml
    ├── ingress.yaml
    ├── ingress-api-public-read.yaml
    ├── hpa-api-core.yaml
    ├── hpa-api-public-read.yaml
    ├── hpa-api-public-read-surge.yaml          # 신규: surge Deployment 전용 HPA
    ├── hpa-external-ingestion.yaml
    └── job-db-migration.yaml
```

### values 파일 분리 전략

| 파일 | 용도 | 사용 주체 |
|---|---|---|
| `values.yaml` | 공통 기본값. 모든 환경의 베이스 | 직접 사용하지 않음 |
| `values-local.yaml` | 로컬 개발용. `tag: local`, `pullPolicy: IfNotPresent` | 개발자 로컬 |
| `values-dev.infra.template.yaml` | EKS dev 인프라 템플릿. `${VAR}` 구문. SecureString·이미지 태그 미포함 | 개발자 / PR |
| `values-dev.infra.generated.yaml` | 자동 생성 인프라 값. ArgoCD가 읽음. **직접 수정 금지** | render-dev-values 워크플로 |
| `values-dev.images.yaml` | 애플리케이션 이미지 repository/tag만 포함. 인프라 값 미포함 | image-update CI |

### 주요 values 키

| values 키 | 설명 |
|---|---|
| `apiPublicReadSurge.enabled` | surge Deployment 생성 여부 |
| `scheduling.apiCore` / `.apiPublicRead` / `.externalIngestion` / `.dbMigration` | nodeSelector / tolerations / affinity |
| `scheduling.apiPublicReadSurge` | surge Deployment용 nodeSelector / tolerations |
| `autoscaling.apiPublicReadSurge` | surge HPA 설정 (enabled / minReplicas / maxReplicas / metric) |

---

## 13. Scheduling / Node Placement

### EKS dev node placement

| 워크로드 | nodeSelector | MNG / NodePool |
|---|---|---|
| api-core | `safespot.io/workload-class=app` | app MNG |
| api-public-read | `safespot.io/workload-class=app` | app MNG |
| external-ingestion | `safespot.io/workload-class=app` | app MNG |
| db-migration | `safespot.io/workload-class=app` | app MNG |
| api-public-read-surge | `safespot.io/workload-class=public` | Karpenter public-surge NodePool |

### api-public-read-surge toleration

```yaml
tolerations:
  - key: safespot.io/dedicated
    operator: Equal
    value: public-surge
    effect: NoSchedule
```

> app MNG에는 taint가 없으므로 api-core / api-public-read / external-ingestion / db-migration은 toleration 없이 배치된다.

---

## 14. api-public-read-surge / pre-scaling

### 설계 의도

`api-public-read-surge`는 재난 발생 시 선제 확장을 위한 별도 Deployment다.
- 기존 `api-public-read` base Deployment는 app MNG에서 HPA가 관리
- surge Deployment는 Karpenter public-surge NodePool에서 별도 HPA가 관리
- 두 Deployment의 pod는 모두 `api-public-read` Service로 합류

### HPA 구조

| HPA | target | minReplicas | maxReplicas | metric |
|---|---|---|---|---|
| `api-public-read` | Deployment/api-public-read | 1 | 5 | CPU 70% |
| `api-public-read-surge` | Deployment/api-public-read-surge | 1 | 10 | External metric |

surge HPA metric:

```yaml
metrics:
  - type: External
    external:
      metric:
        name: api_public_read_requests_per_second
      target:
        type: AverageValue
        averageValue: "5"
```

**External metric 의존성:** surge HPA가 실제로 동작하려면 `external.metrics.k8s.io` API provider(Prometheus Adapter 또는 동등한 구현)가 필요하다. 이 구성은 safespot-ops repo 후속 작업이다.

```bash
# External metrics API 확인
kubectl get apiservice | grep external.metrics
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1"
kubectl -n application describe hpa api-public-read-surge
```

### 운영 흐름

**평상시:**
- `HPA/api-public-read-surge minReplicas=1`
- surge pod 최소 1개 상시 존재
- public-surge Karpenter node가 생성될 수 있음

**재난 발생:**
- pre-scaling controller가 `HPA/api-public-read-surge` `spec.minReplicas`를 `1 → N`으로 patch
- HPA가 External metric 기준으로 replicas를 `N~10` 사이에서 조정
- Pending surge pod가 생기면 Karpenter가 public-surge NodePool을 확장

**재난 해소:**
- pre-scaling controller가 `spec.minReplicas`를 `N → 1`로 patch
- HPA가 surge replicas를 1까지 축소
- 빈 Karpenter node는 consolidation으로 정리

### EKS HPAScaleToZero 제약

현재 EKS 클러스터에서 HPA `minReplicas: 0`이 API server validation에서 거부된다.

```
spec.minReplicas: Invalid value: 0: must be greater than or equal to 1
```

따라서 surge HPA는 `minReplicas: 1` fallback으로 운영한다. scale-to-zero는 후속 과제다.

**후속 대안:**
- KEDA 도입
- pre-scaling controller가 HPA 생성/삭제 방식으로 전환
- EKS 클러스터 `HPAScaleToZero` feature gate 활성화 확인

### ArgoCD ignoreDifferences

pre-scaling controller가 `HPA/api-public-read-surge`의 `spec.minReplicas`를 runtime patch하면
ArgoCD selfHeal이 GitOps desired state로 되돌릴 수 있다.

이를 방지하기 위해 `application-safespot-dev.yaml`에 아래 ignoreDifferences가 설정되어 있다:

```yaml
ignoreDifferences:
  - group: autoscaling
    kind: HorizontalPodAutoscaler
    name: api-public-read-surge
    namespace: application
    jsonPointers:
      - /spec/minReplicas
```

`/spec/maxReplicas`, `/spec/metrics`, `/spec/scaleTargetRef`는 GitOps가 계속 관리한다.

---

## 15. 배포 명령어

### 로컬 검증

```bash
helm lint charts/safespot

helm template safespot charts/safespot \
  -f charts/safespot/values-local.yaml
```

### 로컬 설치 / 업그레이드

```bash
helm upgrade --install safespot charts/safespot \
  -f charts/safespot/values-local.yaml \
  --namespace application \
  --create-namespace
```

### 삭제

```bash
helm uninstall safespot --namespace application
```

---

## 16. EKS dev 렌더링 / server dry-run 검증

### 렌더링

```bash
helm template safespot charts/safespot \
  -f charts/safespot/values-dev.infra.generated.yaml \
  -f charts/safespot/values-dev.images.yaml \
  > /tmp/safespot-dev-rendered.yaml
```

### server dry-run

```bash
kubectl get namespace application || kubectl create namespace application
kubectl apply --dry-run=server -f /tmp/safespot-dev-rendered.yaml
```

> **주의:** AWS Load Balancer Controller 또는 External Secrets Operator webhook이 비정상인 경우,
> Ingress/ExternalSecret dry-run에서 webhook 오류가 발생할 수 있다.
> 이 경우 아래 명령으로 platform addon 상태를 먼저 확인한다.

```bash
kubectl -n kube-system get endpoints aws-load-balancer-webhook-service
kubectl -n external-secrets get svc external-secrets-operator-webhook
kubectl -n argocd get applications -o wide
```

### 주요 확인 항목

```bash
# nodeSelector 확인
grep -n "nodeSelector:" -A3 /tmp/safespot-dev-rendered.yaml
grep -n "safespot.io/workload-class" /tmp/safespot-dev-rendered.yaml

# surge HPA 확인
grep -n "name: api-public-read-surge" -A60 /tmp/safespot-dev-rendered.yaml

# Service selector 확인
grep -n "kind: Service" -A20 /tmp/safespot-dev-rendered.yaml | grep -A5 "selector:"

# HPA target 확인
grep -n "kind: HorizontalPodAutoscaler" -A20 /tmp/safespot-dev-rendered.yaml | grep -A5 "scaleTargetRef"
```

---

## 17. CI/CD and Argo CD Workflow

### 배포 흐름

**인프라 값 생성 흐름 (비민감 String 파라미터)**

```
Terraform → SSM Parameter Store (String)
  → render-dev-values 워크플로 (GitHub Actions)
      scripts/render-dev-values.sh 실행
      values-dev.infra.template.yaml의 ${VAR} 치환 (allowlist 적용)
  → values-dev.infra.generated.yaml 커밋 (feat/aws-gitops-cleanup 브랜치)
  → Argo CD가 변경 감지
  → Kubernetes 자동 배포 (selfHeal + prune)
```

**이미지 배포 흐름**

```
GitHub Actions (safespot-application)
  → Docker 이미지 빌드 및 GHCR 푸시
  → k8s-manifest 저장소의 values-dev.images.yaml 이미지 태그 업데이트
  → Git push
  → Argo CD가 변경 감지
  → Kubernetes 자동 배포 (selfHeal + prune)
```

**Secret 흐름 (민감 SecureString 파라미터)**

```
Terraform → SSM Parameter Store (SecureString)
  → External Secrets Operator (ExternalSecret 리소스, Sync wave -2)
  → Kubernetes Secret (safespot-secret) 자동 생성
  → Spring Boot Pod에서 envFrom 주입
```

> ArgoCD는 Terraform 상태 파일이나 S3를 직접 읽지 않는다. Git이 유일한 소스이다.

### Argo CD Application

ArgoCD Application은 환경별로 분리되어 있다:

| 파일 | 대상 | values 파일 |
|---|---|---|
| `argocd/application-safespot-dev.yaml` | **EKS dev (canonical)** | `values-dev.infra.generated.yaml` + `values-dev.images.yaml` |
| `argocd/application-safespot-local.yaml` | 로컬 전용 | `values-local.yaml` |

**EKS dev Application 주요 설정:**

```yaml
spec:
  project: default   # AppProject는 default 유지

  source:
    targetRevision: feat/aws-gitops-cleanup  # main 병합 후 main으로 전환

  ignoreDifferences:
    - group: autoscaling
      kind: HorizontalPodAutoscaler
      name: api-public-read-surge
      namespace: application
      jsonPointers:
        - /spec/minReplicas   # pre-scaling controller가 patch하는 필드만 ignore

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - RespectIgnoreDifferences=true   # ignoreDifferences를 sync 시에도 존중
```

> AppProject는 별도 분리하지 않고 `default`를 사용한다.

**현재 dev EKS 배포 브랜치:** `feat/aws-gitops-cleanup`
**main 병합 이후:** `application-safespot-dev.yaml`의 `targetRevision`을 `main`으로 전환한다.

**EKS dev 등록 명령어:**

```bash
kubectl apply -f argocd/application-safespot-dev.yaml
```

> ⚠️ `application-safespot-local.yaml`은 로컬 클러스터 전용이다. EKS에 절대 적용하지 말 것.

**배포 전 필수 확인:**

`values-dev.infra.generated.yaml`은 `render-dev-values` 워크플로가 자동 생성한다. 배포 전에 아래 SSM String 파라미터가 존재하는지 확인한다:

| SSM 경로 | render 변수 | 설명 |
|---|---|---|
| `/safespot/dev/app/profile` | `SPRING_PROFILE` | Spring 프로파일 |
| `/safespot/dev/data/aurora-cluster-endpoint` | `RDS_WRITER_ENDPOINT` | Aurora writer 엔드포인트 |
| `/safespot/dev/data/aurora-reader-endpoint` | `RDS_READER_ENDPOINT` | Aurora reader 엔드포인트 |
| `/safespot/dev/data/aurora-db-name` | `DB_NAME` | 데이터베이스 이름 |
| `/safespot/dev/data/aurora-port` | `DB_PORT` | 데이터베이스 포트 |
| `/safespot/dev/data/redis-primary-endpoint` | `REDIS_ENDPOINT` | Redis 엔드포인트 |
| `/safespot/dev/data/redis-port` | `REDIS_PORT` | Redis 포트 |
| `/safespot/dev/async-worker/event-queue-url` | `READMODEL_QUEUE_URL` | SQS core event 큐 |
| `/safespot/dev/async-worker/cache-refresh-queue-url` | `CACHE_REFRESH_QUEUE_URL` | SQS cache refresh 큐 |
| `/safespot/dev/async-worker/environment-cache-refresh-queue-url` | `ENV_CACHE_QUEUE_URL` | SQS env-cache 큐 |
| `/safespot/dev/async-worker/readmodel-refresh-queue-url` | `READMODEL_REFRESH_QUEUE_URL` | SQS readmodel refresh 큐 |
| `/safespot/dev/api/core/context-path` | `API_CORE_CONTEXT_PATH` | api-core context path |
| `/safespot/dev/api/public/context-path` | `API_PUBLIC_CONTEXT_PATH` | api-public-read context path |
| `/safespot/dev/front-edge/api-origin-domain-name` | `API_HOST` | Ingress host (`api-origin.safespot.site`) |
| `/safespot/dev/front-edge/alb-certificate-arn` | `ALB_CERTIFICATE_ARN` | ALB HTTPS 리스너용 ACM ARN (ap-northeast-2) |

> **ACM 인증서 구분**
> - **ALB 용 (ap-northeast-2)**: `/safespot/dev/front-edge/alb-certificate-arn` — Ingress annotation에 사용
> - **CloudFront 용 (us-east-1)**: `/safespot/dev/front-edge/certificate-arn` — Ingress에 사용 금지. CloudFront distribution에만 연결

SSM 파라미터 생성 후 `render-dev-values` 워크플로를 수동으로 실행하면 `values-dev.infra.generated.yaml`이 갱신된다.

> ⚠️ **배포 차단 조건**: `validate-dev-values` CI가 `PENDING_` / `PLACEHOLDER` / `CHANGE_ME` / `${VAR}` 패턴을 감지하면 ArgoCD source로의 merge를 차단한다.

### feature branch 테스트 방법

현재 `application-safespot-dev.yaml`의 `targetRevision`은 `feat/aws-gitops-cleanup`이다.
다른 feature branch를 테스트할 때는 ArgoCD Application에서 임시로 변경한다:

```bash
kubectl patch application safespot-dev -n argocd \
  --type=merge \
  -p '{"spec":{"source":{"targetRevision":"<branch-name>"}}}'
```

또는 `application-safespot-dev.yaml`을 로컬에서 직접 수정 후 `kubectl apply`:

```yaml
targetRevision: <branch-name>  # 테스트 후 되돌릴 것
```

### 최초 EKS 배포 순서

> ⚠️ ExternalSecret이 생성하는 Secret(safespot-secret)은 ArgoCD Sync 중 생성되므로, 최초 배포 시 아래 순서를 지켜야 한다.

```
1. platform addon 배포 확인 (External Secrets Operator, ClusterSecretStore: ssm-parameter-store)
2. SSM Parameter Store에 /safespot/dev/... 경로 파라미터 생성 확인
3. ArgoCD에 EKS 클러스터 등록 (argocd cluster add)
4. application-safespot-dev.yaml 적용 (kubectl apply)
5. ArgoCD Sync 실행
6. ExternalSecret이 safespot-secret 생성 완료 확인
   kubectl get externalsecret -n application -w
7. db-migration Job 수동 실행 또는 두 번째 Sync 실행
```

> **첫 번째 Sync에서 db-migration Job(PreSync hook)이 실패할 수 있다.**
> ExternalSecret은 일반 Sync 리소스(wave -2)이므로 PreSync hook보다 나중에 실행된다.
> Secret 미존재 → Job pod 생성 실패 → Sync 실패는 예상된 동작이다.
> 두 번째 Sync부터는 Secret이 이미 존재하므로 정상 동작한다.

### CI에서 이미지 태그 주입 예시

image-update CI는 `values-dev.images.yaml`의 태그를 직접 수정하고 커밋한다:

```yaml
apiCore:
  image:
    tag: <IMAGE_TAG>
apiPublicRead:
  image:
    tag: <IMAGE_TAG>
externalIngestion:
  image:
    tag: <IMAGE_TAG>
```

> `api-public-read-surge`는 `apiPublicRead.image`를 공유하므로 별도 이미지 태그를 관리하지 않는다.

### 환경별 values 파일 사용 원칙

* `values-local.yaml` — 개발자 로컬 환경 전용. `docker build`로 생성한 로컬 이미지를 사용한다.
* `values-dev.infra.template.yaml` — EKS dev 인프라 템플릿. `${VAR}` 구문. **이미지 태그 포함 금지. SecureString 포함 금지.**
* `values-dev.infra.generated.yaml` — `render-dev-values` 워크플로가 자동 생성. 직접 편집 금지. **이미지 태그 포함 금지.**
* `values-dev.images.yaml` — image-update CI 소유. **인프라 엔드포인트/ARN 포함 금지.**
* **Argo CD(EKS)는 반드시 `values-dev.infra.generated.yaml` + `values-dev.images.yaml` 두 파일을 순서대로 적용한다.**

---

## 18. Secret 관리

### 원칙

Git 저장소에 실제 시크릿 값을 커밋하지 않는다.

**EKS (dev):** `ExternalSecret` 리소스가 SSM Parameter Store의 SecureString 값을 읽어 `safespot-secret`을 자동 생성한다 (`secret.externalSecret.enabled: true`). Helm/ArgoCD는 Secret을 직접 생성하지 않는다 (`secret.create: false`).

**로컬:** `secret.create: true`로 설정하면 Helm이 Secret을 렌더링한다. 로컬 전용이며 Git에 실제 값을 커밋하지 않는다.

### 필수 키 목록

| 키 | SSM canonical path | 설명 |
|---|---|---|
| `DB_USER` | `/safespot/dev/secret/rds/username` | 데이터베이스 사용자 |
| `DB_PASSWORD` | `/safespot/dev/secret/rds/password` | 데이터베이스 비밀번호 |
| `SPRING_DATASOURCE_USERNAME` | `/safespot/dev/secret/rds/username` | Spring DataSource 사용자 (alias) |
| `SPRING_DATASOURCE_PASSWORD` | `/safespot/dev/secret/rds/password` | Spring DataSource 비밀번호 (alias) |
| `SAFESPOT_JWT_SECRET` | `/safespot/dev/secret/jwt/access-token-key` | api-core JWT 서명 키 |
| `JWT_REFRESH_TOKEN_KEY` | `/safespot/dev/secret/jwt/refresh-token-key` | JWT 리프레시 토큰 키 |
| `SEOUL_API_KEY` | `/safespot/dev/secret/seoul/service-key` | 서울 열린데이터광장 API 키 |
| `MOIS_API_KEY` | `/safespot/dev/secret/mois/api-key` | 행정안전부 API 키 |
| `SAFETY_DATA_ALERT_API_KEY` | `/safespot/dev/secret/mois/api-key` | SafetyDataAlertHandler compat alias |
| `DATA_GO_KR_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | data.go.kr 공통 API 키 |
| `KMA_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | KmaWeather/KmaEarthquake compat alias |
| `AIR_KOREA_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | AirKoreaAirQuality compat alias |
| `FORESTRY_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | ForestryLandslide compat alias |

---

## 19. ALB Ingress 배포 후 검증

ArgoCD sync 후 아래 명령으로 정상 여부를 확인한다.

```bash
# Ingress 리소스 확인
kubectl get ingress -n application

# ALB IngressGroup 및 TargetGroupBinding 확인
kubectl describe ingress -n application
kubectl get targetgroupbinding -n application

# ExternalDNS가 api-origin.safespot.site를 ALB에 연결했는지 확인 (TTL 반영 후)
nslookup api-origin.safespot.site

# HTTP → HTTPS redirect 확인
curl -I http://api-origin.safespot.site/api/core/actuator/health

# HTTPS 헬스체크 확인
curl -I https://api-origin.safespot.site/api/core/actuator/health
curl -I https://api-origin.safespot.site/api/public/actuator/health

# CloudFront 경유 확인
curl -I https://safespot.site/api/public/actuator/health
```

---

## 20. scenario-simulator (dev/test 전용)

`scenario-simulator`는 재난 시나리오 부하 테스트 전용 서비스다. 운영 노출 없이 cluster 내부에서만 접근한다.

### 접근 방법

```bash
kubectl -n application port-forward svc/scenario-simulator 18080:8080
```

### 호출 예시

```bash
curl -X POST http://localhost:18080/internal/test/scenarios/run \
  -H "Content-Type: application/json" \
  -d '{
    "scenarioName": "SEOUL_HIGH_EARTHQUAKE_LOAD",
    "disaster": {
      "disasterType": "EARTHQUAKE",
      "region": "SEOUL",
      "level": "HIGH"
    },
    "residents": {
      "count": 1000,
      "distribution": "WEIGHTED_BY_CAPACITY"
    },
    "cache": {
      "triggerRegeneration": true
    },
    "scale": {
      "triggerProactiveScale": true
    }
  }'
```

### 배포 정책

| 항목 | 값 |
|---|---|
| `scenarioSimulator.enabled` 기본값 | `false` |
| dev EKS 활성화 | `values-dev.infra.generated.yaml` (`enabled: true`) |
| prod 활성화 | 금지 |
| Ingress / ALB 라우팅 | 없음 (ClusterIP only) |
| CloudFront 노출 | 없음 |
| IRSA 구성 | 아래 ServiceAccount 절 참고 |

### ServiceAccount (IRSA) 구성

**AWS dev 임시 구성**: scenario-simulator는 전용 IRSA role 없이 기존 `api-core` ServiceAccount를 재사용한다.

```yaml
scenarioSimulator:
  serviceAccount:
    create: false
    name: api-core  # api-core IRSA SA 재사용
```

**재사용 이유**:
- scenario-simulator는 api-core와 동일한 SQS core-event 큐에 메시지를 발행한다.
- Terraform 변경 없이 기존 SQS SendMessage 권한을 즉시 활용할 수 있다.

**추후 분리 권장**: 서비스별 최소 권한 원칙에 따라 scenario-simulator 전용 IRSA role을 생성하고 `serviceAccount.create: true`, `serviceAccount.roleArn`을 설정하는 것이 권장된다.

> prod에서는 `scenarioSimulator.enabled: false` 유지 — ServiceAccount 공유 여부와 무관하게 prod 노출은 금지한다.

### 이미지 태그 관리

`values-dev.images.yaml`의 `scenarioSimulator.image.tag`를 image-update CI가 다른 서비스와 동일하게 관리한다.

```yaml
scenarioSimulator:
  image:
    repository: ghcr.io/project-safespot/safespot-scenario-simulator
    tag: <IMAGE_TAG>
    pullPolicy: Always
```

---

## 21. Load test mode (부하테스트 모드)

### 왜 kubectl scale/patch를 쓰지 않는가

`kubectl scale` 또는 `kubectl patch`로 runtime에 replicas를 올려도 ArgoCD selfHeal 또는 pre-scaling-controller가 곧바로 Git desired state(values.yaml 기본값)로 되돌린다.

- **ArgoCD selfHeal**: Deployment `spec.replicas`가 Git과 다르면 sync 시 덮어씀.
- **pre-scaling-controller**: 재난 해소/cooldown 정책에 따라 HPA `spec.minReplicas`를 `normalMinReplicas=1`로 patch.
- 결과: 추가 pod가 Created 직후 Terminating → 부하테스트 capacity가 올라가지 않음.

따라서 부하테스트는 Git/Helm overlay를 통해 desired state 자체를 변경해야 한다.

---

### Loadtest overlay 의도 (`values-loadtest.yaml`)

| 워크로드 | 항목 | loadtest 값 | 운영 기본값 |
|---|---|---|---|
| api-public-read normal | HPA min/max | **1/1** | 1/5 |
| api-public-read-surge | replicas | **6** | 1 |
| api-public-read-surge | HPA min/max | **6/6** | 1/20 |
| pre-scaling-controller | enabled | **false** | true |

**normal api-public-read를 1/1로 고정하는 이유:**

직전 1500 TPS 테스트에서 normal HPA가 5 replicas까지 scale-out을 시도하면서 3개가 Pending 상태로 남았다. Pending pod의 node provisioning 시도가 surge node pool 기준 측정에 노이즈를 추가한다. 이번 테스트 목표는 `api-public-read-surge 6 replicas + c5a.xlarge surge node pool` 조합의 성능 검증이므로, normal scale-out을 완전히 차단해 테스트 변수를 제거한다.

**Deployment의 `spec.replicas` 동작 주의:**

`deployment-api-public-read.yaml`은 `autoscaling.apiPublicRead.enabled: true`인 경우 `spec.replicas`를 렌더링하지 않는다. HPA가 replicas를 관리하기 때문이다. loadtest overlay에서도 HPA를 `enabled: true`, `min/max: 1/1`로 고정하므로 HPA가 1 replica를 유지한다.

---

### 부하테스트 적용 방법

#### 1. 로컬 Helm 렌더링 검증

```bash
helm template safespot charts/safespot \
  -f charts/safespot/values.yaml \
  -f charts/safespot/values-loadtest.yaml \
  > /tmp/safespot-loadtest.yaml

# surge HPA 확인
grep -n "minReplicas: 6" /tmp/safespot-loadtest.yaml
grep -n "maxReplicas: 6" /tmp/safespot-loadtest.yaml

# normal HPA 확인
grep -n "minReplicas: 1" /tmp/safespot-loadtest.yaml
grep -n "maxReplicas: 1" /tmp/safespot-loadtest.yaml

# pre-scaling-controller 없어야 함
grep -n "name: pre-scaling-controller" /tmp/safespot-loadtest.yaml
```

#### 2. ArgoCD Application에 overlay 적용

`argocd/application-safespot-dev.yaml`의 `helm.valueFiles`에 `values-loadtest.yaml`을 임시로 추가한다:

```yaml
helm:
  valueFiles:
    - values-dev.infra.generated.yaml
    - values-dev.images.yaml
    - values-loadtest.yaml          # 부하테스트 시 임시 추가
```

변경 후 kubectl apply 및 ArgoCD sync:

```bash
kubectl apply -f argocd/application-safespot-dev.yaml
kubectl -n argocd wait --for=condition=Synced application/safespot-dev --timeout=120s
```

#### 3. 테스트 전 기대 상태 확인

```bash
kubectl -n application get deploy api-public-read api-public-read-surge
kubectl -n application get hpa api-public-read api-public-read-surge
kubectl -n application get pod -o wide -l 'app in (api-public-read,api-public-read-surge)'
kubectl -n application get deploy pre-scaling-controller
kubectl get nodes -L safespot.io/node-group,node.kubernetes.io/instance-type
kubectl get nodeclaims -o wide
```

**기대값:**

| 항목 | 기대값 |
|---|---|
| api-public-read READY | 1/1 |
| api-public-read HPA MINPODS/MAXPODS | 1/1 |
| api-public-read-surge READY | 6/6 |
| api-public-read-surge HPA MINPODS/MAXPODS | 6/6 |
| Pending pod | 0 |
| surge pod 배치 노드 | c5a.xlarge (api-public-read nodepool) |
| pre-scaling-controller | 없음 (deployment 존재하지 않음) |

---

### 테스트 후 원복 방법

`argocd/application-safespot-dev.yaml`에서 `values-loadtest.yaml` 라인을 제거한다:

```yaml
helm:
  valueFiles:
    - values-dev.infra.generated.yaml
    - values-dev.images.yaml
    # values-loadtest.yaml 제거
```

변경 후 kubectl apply 및 ArgoCD sync (`--prune` 필요 — pre-scaling-controller Deployment 복구):

```bash
kubectl apply -f argocd/application-safespot-dev.yaml
# ArgoCD automated sync에 prune: true가 이미 설정되어 있으므로 자동 처리됨
kubectl -n argocd wait --for=condition=Synced application/safespot-dev --timeout=120s
```

원복 확인:

```bash
kubectl -n application get deploy api-public-read api-public-read-surge
kubectl -n application get hpa api-public-read api-public-read-surge
kubectl -n application get deploy pre-scaling-controller
```

**기대값:**

| 항목 | 기대값 |
|---|---|
| api-public-read HPA MINPODS/MAXPODS | 1/5 |
| api-public-read-surge HPA MINPODS/MAXPODS | 1/20 |
| pre-scaling-controller | Running |

---

### HPA metric 확인 방법

surge HPA metric(`api_public_read_requests_per_second`)이 `<unknown>`으로 표시되는 경우 아래 순서로 점검한다:

```bash
# External metrics API 등록 확인
kubectl get --raw /apis/external.metrics.k8s.io/v1beta1 | jq .

# 특정 metric 값 확인
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/application/api_public_read_requests_per_second" | jq .

# HPA 상태 및 이벤트 확인
kubectl -n application describe hpa api-public-read-surge
```

---

## 22. ALB Access Log 설정

### 개요

AWS Load Balancer Controller가 생성하는 ALB의 access log를 S3에 적재하는 기능이다.
S3 bucket 생성 및 bucket policy는 Terraform 또는 별도 팀 작업에서 관리한다.
이 저장소는 bucket name/prefix를 values로 받아 Ingress annotation에 반영한다.

### 확정된 S3 정책

| 항목 | 값 |
|---|---|
| S3 bucket | `safespot-dev-ops-logs` |
| prefix | `alb` |
| AWS account | `154335823230` |
| bucket policy Resource | `arn:aws:s3:::safespot-dev-ops-logs/alb/AWSLogs/154335823230/*` |

**중요: annotation prefix와 bucket policy Resource 경로가 반드시 일치해야 한다.**

ALB는 `s3://<bucket>/<prefix>/AWSLogs/<account-id>/...` 경로에 로그를 쓴다.
annotation에서 `access_logs.s3.prefix=alb`로 설정하면 실제 S3 object path는 `alb/AWSLogs/154335823230/...`이다.
bucket policy Resource에 `alb/AWSLogs/154335823230/*`가 허용되어 있어야 ALB가 로그를 쓸 수 있다.

prefix를 바꾸면 bucket policy Resource도 반드시 함께 변경해야 한다.

### Terraform 선행 조건

ALB access log를 활성화하기 전에 아래가 완료되어야 한다:

| 리소스 | 내용 |
|---|---|
| `aws_s3_bucket` | `safespot-dev-ops-logs` bucket 생성 |
| `aws_s3_bucket_policy` | ALB delivery principal(`delivery.logs.amazonaws.com`)에 `s3:PutObject` 허용, Resource: `arn:aws:s3:::safespot-dev-ops-logs/alb/AWSLogs/154335823230/*` |

> S3 bucket policy 없이 ALB access log를 활성화하면 ALB가 로그를 쓰지 못하고 오류가 발생한다. Ingress annotation을 먼저 적용해도 ALB attribute 설정 자체는 성공하지만 로그가 쌓이지 않는다.

### Values 구조

```yaml
# values.yaml (기본 — 비활성. nginx/local 환경에서 annotation 렌더링 안 됨)
ingress:
  alb:
    loadBalancerAttributes: []   # 추가 ALB attributes (key=value 목록)
    accessLogs:
      enabled: false
      bucket: ""
      # prefix는 bucket policy Resource 경로와 반드시 일치해야 한다.
      # policy Resource: arn:aws:s3:::safespot-dev-ops-logs/alb/AWSLogs/154335823230/*
      prefix: "alb"

# values-dev.infra.template.yaml (EKS dev — bucket 고정값, SSM 불필요)
ingress:
  alb:
    accessLogs:
      enabled: true
      bucket: safespot-dev-ops-logs
      prefix: alb
```

### 렌더링 결과 annotation

```yaml
alb.ingress.kubernetes.io/load-balancer-attributes: "access_logs.s3.enabled=true,access_logs.s3.bucket=safespot-dev-ops-logs,access_logs.s3.prefix=alb"
```

`ingress.className: alb`인 경우에만 이 annotation이 렌더링된다. `className: nginx`(로컬 환경) 에서는 렌더링되지 않는다.

추가 ALB attributes가 필요한 경우 `ingress.alb.loadBalancerAttributes`에 문자열 목록으로 추가한다:

```yaml
ingress:
  alb:
    loadBalancerAttributes:
      - "deletion_protection.enabled=true"
      - "idle_timeout.timeout_seconds=120"
```

`ingress.annotations`에 `alb.ingress.kubernetes.io/load-balancer-attributes` 키를 직접 넣지 않는다. 중복 annotation이 생성되므로 반드시 `ingress.alb.loadBalancerAttributes` / `ingress.alb.accessLogs`로 관리한다.

### Helm 로컬 검증

```bash
# 기본 values(nginx ingress) — annotation 없어야 함
helm template safespot charts/safespot \
  -f charts/safespot/values.yaml \
  > /tmp/safespot-default.yaml
grep "load-balancer-attributes" /tmp/safespot-default.yaml && echo "UNEXPECTED" || echo "OK (expected)"

# EKS dev values — access log annotation 확인
helm template safespot charts/safespot \
  -f charts/safespot/values.yaml \
  -f charts/safespot/values-dev.infra.generated.yaml \
  > /tmp/safespot-dev.yaml

grep -n "load-balancer-attributes" /tmp/safespot-dev.yaml
grep -n "access_logs.s3.enabled=true" /tmp/safespot-dev.yaml
grep -n "access_logs.s3.bucket=safespot-dev-ops-logs" /tmp/safespot-dev.yaml
grep -n "access_logs.s3.prefix=alb" /tmp/safespot-dev.yaml
```

기대 출력 (두 Ingress 리소스에 각 1줄):
```
alb.ingress.kubernetes.io/load-balancer-attributes: "access_logs.s3.enabled=true,access_logs.s3.bucket=safespot-dev-ops-logs,access_logs.s3.prefix=alb"
```

### ArgoCD sync 후 배포 검증

```bash
# Ingress annotation 확인
kubectl -n application get ingress -o yaml | grep -A5 "load-balancer-attributes"

# ALB attribute 확인 (ALB ARN은 kubectl describe ingress에서 확인)
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn <ALB_ARN> \
  --region ap-northeast-2 \
  | jq '.Attributes[] | select(.Key | startswith("access_logs"))'
```

기대 결과:
```json
{"Key": "access_logs.s3.enabled", "Value": "true"}
{"Key": "access_logs.s3.bucket",  "Value": "safespot-dev-ops-logs"}
{"Key": "access_logs.s3.prefix",  "Value": "alb"}
```

### S3 로그 적재 확인

ALB sync 후 약 5분 지연 후 로그가 쌓인다. annotation과 ALB attribute가 먼저 맞는지 확인한 뒤 S3를 확인한다.

```bash
# S3 object 확인
aws s3 ls s3://safespot-dev-ops-logs/alb/AWSLogs/154335823230/ --recursive | head -20

# 오늘 날짜 로그 확인
aws s3 ls "s3://safespot-dev-ops-logs/alb/AWSLogs/154335823230/elasticloadbalancing/ap-northeast-2/$(date +%Y/%m/%d)/"
```

### 비활성화 (rollback)

`values-dev.infra.generated.yaml`에서 `accessLogs.enabled`를 `false`로 변경 후 ArgoCD sync:

```yaml
ingress:
  alb:
    accessLogs:
      enabled: false
```

---

## 23. 주의사항

* 이 저장소에서 인프라 리소스를 생성하지 않는다.
* 환경별 설정은 반드시 values 파일로 관리한다.
* 민감 정보는 Secret, 일반 설정은 ConfigMap을 사용한다.
* `values-dev.infra.generated.yaml`과 `values-dev.images.yaml`은 자동 생성/자동 갱신 파일이다. 직접 수정하지 않는다.
* 두 파일에 `PENDING_` / `PLACEHOLDER` / `CHANGE_ME` / `${VAR}`가 남아 있으면 `validate-dev-values` CI가 실패하고 Argo CD에 도달하지 못한다.
* ALB Ingress에는 반드시 ap-northeast-2 ACM 인증서를 사용한다. CloudFront용 us-east-1 인증서는 Ingress에 사용 금지.
* `api-public-read-surge` HPA는 External metric(`api_public_read_requests_per_second`)을 사용한다. `external.metrics.k8s.io` provider가 없으면 HPA가 metric을 읽지 못한다.
* ArgoCD `ignoreDifferences`는 `HPA/api-public-read-surge`의 `/spec/minReplicas`만 ignore한다. 나머지 HPA 필드는 GitOps가 관리한다.
