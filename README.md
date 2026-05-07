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
* external-ingestion
* nginx (웹)

다음 인프라 구성 요소는 관리하지 않는다:

* PostgreSQL
* Redis
* LocalStack
* Exporter (Prometheus exporter 등)

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

| 서비스                | app                | service            |
| ------------------ | ------------------ | ------------------ |
| api-core           | api-core           | api-core           |
| api-public-read    | api-public-read    | api-public-read    |
| external-ingestion | external-ingestion | external-ingestion |
| nginx              | nginx              | nginx              |

---

## 5. 인프라 엔드포인트

아래 인프라 서비스는 이미 클러스터에 구성되어 있다:

### PostgreSQL

| 역할 | 엔드포인트 |
|---|---|
| Primary / Write | `postgres-postgresql-primary.safespot-db.svc.cluster.local:5432` |
| Read-Only | `postgres-postgresql-read.safespot-db.svc.cluster.local:5432` |

### Redis

```
redis.safespot-cache.svc.cluster.local:6379
```

### LocalStack

```
http://localstack.safespot-localstack.svc.cluster.local:4566
```

---

## 6. 네트워크 구성

### 내부 통신

```
Spring Boot → Redis / PostgreSQL / LocalStack
```

### 외부 접근

```
Ingress (nginx) + MetalLB
```

---

## 7. Ingress 라우팅

```
/           → nginx:80
/api/core   → api-core:8080
/api/public → api-public-read:8080
```

---

## 8. 환경 설정

### ConfigMap (서비스별 분리)

ConfigMap은 서비스마다 별도로 생성된다. 공통 변수(Spring, Redis, AWS)는 모든 ConfigMap에 포함되며, `SPRING_DATASOURCE_URL`은 서비스별로 다른 DB 엔드포인트를 가리킨다.

공통 변수 예시:

```env
SPRING_PROFILES_ACTIVE=dev
REDIS_HOST=redis.safespot-cache.svc.cluster.local
REDIS_PORT=6379
AWS_REGION=ap-northeast-2
AWS_ENDPOINT=http://localstack.safespot-localstack.svc.cluster.local:4566
```

서비스별 SPRING_DATASOURCE_URL:

```env
# api-core / external-ingestion (primary)
SPRING_DATASOURCE_URL=jdbc:postgresql://postgres-postgresql-primary.safespot-db.svc.cluster.local:5432/safespot

# api-public-read (read-only)
SPRING_DATASOURCE_URL=jdbc:postgresql://postgres-postgresql-read.safespot-db.svc.cluster.local:5432/safespot
```

### Secret

```env
DB_USER=safespot
DB_PASSWORD=safespot1234
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
JWT_SECRET=<추후 정의>
```

---

## 9. 서비스별 DB 라우팅

각 Spring Boot 서비스는 서비스별 ConfigMap을 통해 서로 다른 DB 엔드포인트에 연결된다. DB 사용자/비밀번호는 동일한 `safespot-secret`에서 주입된다.

| 서비스 | ConfigMap | DB 엔드포인트 |
|---|---|---|
| api-core | safespot-api-core-config | postgres-postgresql-primary.safespot-db.svc.cluster.local |
| api-public-read | safespot-api-public-read-config | postgres-postgresql-read.safespot-db.svc.cluster.local |
| external-ingestion | safespot-external-ingestion-config | postgres-postgresql-primary.safespot-db.svc.cluster.local |

- api-core — 쓰기/읽기 모두 필요하므로 **Primary** 사용
- api-public-read — 읽기 전용 조회 서비스이므로 **Read-Only** 사용
- external-ingestion — 정규화된 외부 데이터를 DB에 쓰므로 **Primary** 사용

---

## 10. 이미지 규칙

### 로컬 개발 (values-local.yaml)

```
safespot/api-core:local
safespot/api-public-read:local
safespot/external-ingestion:local
safespot/nginx:local
```

### CI/CD (values-dev.yaml)

```
ghcr.io/project-safespot/safespot-api-core:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-api-public-read:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-external-ingestion:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-nginx:<IMAGE_TAG>
```

---

## 11. 배포 정책

```yaml
apiCore.enabled=true
apiPublicRead.enabled=true
externalIngestion.enabled=true
nginx.enabled=true
```

---

## 12. Helm Chart 구조

```
charts/safespot/
├── Chart.yaml
├── values.yaml                    # 공통 기본값 (tag: latest, pullPolicy: Always)
├── values-local.yaml              # 로컬 오버라이드 (tag: local, pullPolicy: IfNotPresent)
├── values-dev.infra.template.yaml  # EKS dev 인프라 템플릿. ${VAR} 구문, SSM String 치환 대상. 사람이 편집
├── values-dev.infra.generated.yaml # 자동 생성 인프라 값. render workflow 소유. 직접 수정 금지
├── values-dev.images.yaml          # 애플리케이션 이미지 태그. image-update CI 소유
└── templates/
    ├── namespace.yaml
    ├── configmap-api-core.yaml
    ├── configmap-api-public-read.yaml
    ├── configmap-external-ingestion.yaml
    ├── secret.yaml
    ├── deployment-api-core.yaml
    ├── deployment-api-public-read.yaml
    ├── deployment-external-ingestion.yaml
    ├── deployment-nginx.yaml
    ├── service-api-core.yaml
    ├── service-api-public-read.yaml
    ├── service-external-ingestion.yaml
    ├── service-nginx.yaml
    ├── ingress.yaml
    ├── hpa-api-core.yaml
    ├── hpa-api-public-read.yaml
    └── hpa-external-ingestion.yaml
```

### values 파일 분리 전략

| 파일 | 용도 | 사용 주체 |
| --- | --- | --- |
| `values.yaml` | 공통 기본값. 모든 환경의 베이스 | 직접 사용하지 않음 |
| `values-local.yaml` | 로컬 개발용. `tag: local`, `pullPolicy: IfNotPresent` | 개발자 로컬 |
| `values-dev.infra.template.yaml` | EKS dev 인프라 템플릿. `${VAR}` 구문. SecureString·이미지 태그 미포함 | 개발자 / PR |
| `values-dev.infra.generated.yaml` | 자동 생성 인프라 값. ArgoCD가 읽음. **직접 수정 금지** | render-dev-values 워크플로 |
| `values-dev.images.yaml` | 애플리케이션 이미지 repository/tag만 포함. 인프라 값 미포함 | image-update CI |

---

## 13. 배포 명령어

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

## 14. CI/CD and Argo CD Workflow

### 배포 흐름

**인프라 값 생성 흐름 (비민감 String 파라미터)**

```
Terraform → SSM Parameter Store (String)
  → render-dev-values 워크플로 (GitHub Actions)
      scripts/render-dev-values.sh 실행
      values-dev.infra.template.yaml의 ${VAR} 치환 (allowlist 적용)
  → values-dev.infra.generated.yaml 커밋 (main 브랜치)
  → Argo CD가 변경 감지
  → Kubernetes 자동 배포 (selfHeal + prune)
```

**이미지 배포 흐름**

```
GitHub Actions (safespot-application)
  → Docker 이미지 빌드 및 GHCR 푸시
  → k8s-manifest 저장소의 values-dev.images.yaml 이미지 태그 업데이트
  → Git push (main 브랜치)
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

> ⚠️ **배포 차단 조건**: `validate-dev-values` CI가 `PENDING_` / `PLACEHOLDER` / `CHANGE_ME` / `${VAR}` 패턴을 감지하면 Argo CD source로의 merge를 차단한다. render 워크플로 실행 전까지 `values-dev.infra.generated.yaml`에 PENDING_ 값이 남아 있으므로, 최초 배포 전 반드시 render 워크플로를 실행한다.

### feature branch 테스트 방법

`application-safespot-dev.yaml`의 `targetRevision: main`은 main에 merge된 변경사항만 추적한다.  
feature branch를 테스트할 때는 ArgoCD Application에서 임시로 변경한다:

```bash
# 임시 적용 (Git에 커밋하지 않음)
kubectl patch application safespot-dev -n argocd \
  --type=merge \
  -p '{"spec":{"source":{"targetRevision":"feat/aws-gitops-cleanup"}}}'
```

또는 `application-safespot-dev.yaml`을 로컬에서 직접 수정 후 `kubectl apply`:

```yaml
targetRevision: feat/aws-gitops-cleanup  # 테스트 후 main으로 되돌릴 것
```

> PR merge 전에는 main 추적 Application으로 feature branch 변경사항을 테스트할 수 없다.

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

### 환경별 values 파일 사용 원칙

* `values-local.yaml` — 개발자 로컬 환경 전용. `docker build`로 생성한 로컬 이미지를 사용한다.
* `values-dev.infra.template.yaml` — EKS dev 인프라 템플릿. `${VAR}` 구문. **이미지 태그 포함 금지. SecureString 포함 금지.**
* `values-dev.infra.generated.yaml` — `render-dev-values` 워크플로가 자동 생성. 직접 편집 금지. **이미지 태그 포함 금지.**
* `values-dev.images.yaml` — image-update CI 소유. **인프라 엔드포인트/ARN 포함 금지.**
* **Argo CD(EKS)는 반드시 `values-dev.infra.generated.yaml` + `values-dev.images.yaml` 두 파일을 순서대로 적용한다.**

---

## 15. Secret 관리

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
| `SAFESPOT_JWT_SECRET` | `/safespot/dev/secret/jwt/access-token-key` | api-core JWT 서명 키. `safespot.jwt.secret` 매핑 |
| `JWT_REFRESH_TOKEN_KEY` | `/safespot/dev/secret/jwt/refresh-token-key` | JWT 리프레시 토큰 키 (reserved) |
| `SEOUL_API_KEY` | `/safespot/dev/secret/seoul/service-key` | 서울 열린데이터광장 API 키 |
| `MOIS_API_KEY` | `/safespot/dev/secret/mois/api-key` | 행정안전부 API 키 (canonical) |
| `SAFETY_DATA_ALERT_API_KEY` | `/safespot/dev/secret/mois/api-key` | SafetyDataAlertHandler compat alias |
| `DATA_GO_KR_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | data.go.kr 공통 API 키 (canonical) |
| `KMA_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | KmaWeather/KmaEarthquake compat alias |
| `AIR_KOREA_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | AirKoreaAirQuality compat alias |
| `FORESTRY_API_KEY` | `/safespot/dev/secret/data-go-kr/service-key` | ForestryLandslide compat alias |

SSM path는 provider/기관 기준으로 명명한다. backend env 이름은 변경하지 않으며, ExternalSecret이 alias 매핑을 제공한다.

### Secret 생성 방법

환경 파일(`safespot-secret.local.env`)에 키=값 형태로 작성한 후 아래 명령어로 적용한다:

```bash
kubectl create secret generic safespot-secret \
  -n application \
  --from-env-file=safespot-secret.local.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

시크릿 값 생성 예시:

```bash
openssl rand -base64 64
```

### Helm에서 Secret 직접 생성하는 경우 (로컬 테스트 전용)

`values-local.yaml`에서 `secret.create: true`로 설정하면 Helm이 Secret을 렌더링한다. 단, 이 모드는 실제 값을 Git에 커밋하지 않는 로컬 전용으로만 사용한다.

```yaml
secret:
  create: true
  existingName: safespot-secret
  dbUser: "myuser"
  dbPassword: "mypassword"
  ...
```

---

## 16. ALB Ingress 배포 후 검증

ArgoCD sync 후 아래 명령으로 정상 여부를 확인한다.

```bash
# Ingress 리소스 확인 (신규: safespot-api-core-ingress, safespot-api-public-read-ingress)
kubectl get ingress -n application

# ALB IngressGroup 및 TargetGroupBinding 확인
kubectl describe ingress safespot-api-core-ingress -n application
kubectl describe ingress safespot-api-public-read-ingress -n application
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

> **ALB 교체 주의**: `group.name: safespot-dev-api`가 없는 기존 `safespot-ingress`는 prune으로 삭제되며 ALB도 새로 생성된다.  
> 신규 ALB DNS가 ExternalDNS를 통해 Route53에 반영되기까지 DNS TTL(기본 60s) 이내 일시적 접근 불가가 발생할 수 있다.

---

## 17. 주의사항

* 이 저장소에서 인프라 리소스를 생성하지 않는다.
* 환경별 설정은 반드시 values 파일로 관리한다.
* 민감 정보는 Secret, 일반 설정은 ConfigMap을 사용한다.
* `values-dev.infra.generated.yaml`과 `values-dev.images.yaml`은 자동 생성/자동 갱신 파일이다. 직접 수정하지 않는다.
* 두 파일에 `PENDING_` / `PLACEHOLDER` / `CHANGE_ME` / `${VAR}`가 남아 있으면 `validate-dev-values` CI가 실패하고 Argo CD에 도달하지 못한다.
* ALB Ingress에는 반드시 ap-northeast-2 ACM 인증서를 사용한다. CloudFront용 us-east-1 인증서는 Ingress에 사용 금지.
