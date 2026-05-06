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
├── values-dev.template.yaml       # EKS dev 템플릿. ${VAR} 구문으로 SSM 치환 대상 표시
├── values-dev.generated.yaml      # 자동 생성 파일 (ArgoCD가 읽음). 직접 수정 금지
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
| `values-dev.template.yaml` | EKS dev 템플릿. `${VAR}` 구문, 사람이 편집하는 파일 | 개발자 / PR |
| `values-dev.generated.yaml` | 자동 생성 파일. ArgoCD가 읽음. **직접 수정 금지** | render-dev-values 워크플로 |

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
      values-dev.template.yaml의 ${VAR} 치환
  → values-dev.generated.yaml 커밋 (main 브랜치)
  → Argo CD가 변경 감지
  → Kubernetes 자동 배포 (selfHeal + prune)
```

**이미지 배포 흐름**

```
GitHub Actions (safespot-application)
  → Docker 이미지 빌드 및 GHCR 푸시
  → k8s-manifest 저장소의 values-dev.generated.yaml 이미지 태그 업데이트
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
| `argocd/application-safespot-dev.yaml` | **EKS dev (canonical)** | `values-dev.generated.yaml` |
| `argocd/application-safespot-local.yaml` | 로컬 전용 | `values-local.yaml` |

**EKS dev 등록 명령어:**

```bash
kubectl apply -f argocd/application-safespot-dev.yaml
```

> ⚠️ `application-safespot-local.yaml`은 로컬 클러스터 전용이다. EKS에 절대 적용하지 말 것.

**배포 전 필수 확인:**

`values-dev.generated.yaml`은 `render-dev-values` 워크플로가 자동 생성한다. 배포 전에 아래 SSM 파라미터가 존재하는지 확인한다:

| SSM 경로 | 설명 |
|---|---|
| `/safespot/dev/rds/writer-endpoint` | RDS 클러스터 writer 엔드포인트 |
| `/safespot/dev/rds/reader-endpoint` | RDS 클러스터 reader 엔드포인트 |
| `/safespot/dev/elasticache/endpoint` | ElastiCache Redis 엔드포인트 |
| `/safespot/dev/sqs/core-events-url` | SQS URL (core-events) |
| `/safespot/dev/sqs/cache-regeneration-url` | SQS URL (cache-regeneration) |
| `/safespot/dev/sqs/disaster-events-url` | SQS URL (disaster-events) |
| `/safespot/dev/sqs/environment-events-url` | SQS URL (environment-events) |
| `/safespot/dev/domain/api-host` | Ingress 호스트 (e.g. `api.safespot.site`) |
| `/safespot/dev/acm/certificate-arn` | ACM 인증서 ARN (HTTPS 전환 시) |
| `CHANGE_ME_EKS_API_SERVER_URL` | `argocd/application-safespot-dev.yaml`의 EKS API server URL (수동 입력) |

SSM 파라미터 생성 후 `render-dev-values` 워크플로를 수동으로 실행하면 `values-dev.generated.yaml`이 갱신된다.

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

```bash
helm upgrade --install safespot charts/safespot \
  -f charts/safespot/values-dev.generated.yaml \
  --set apiCore.image.tag=<IMAGE_TAG> \
  --set apiPublicRead.image.tag=<IMAGE_TAG> \
  --set externalIngestion.image.tag=<IMAGE_TAG>
```

### 환경별 values 파일 사용 원칙

* `values-local.yaml` — 개발자 로컬 환경 전용. `docker build`로 생성한 로컬 이미지를 사용한다.
* `values-dev.template.yaml` — EKS dev 템플릿. `${VAR}` 구문으로 SSM 치환 대상을 표시한다. 사람이 편집하는 파일이다.
* `values-dev.generated.yaml` — `render-dev-values` 워크플로가 자동 생성한다. 직접 편집하지 않는다.
* **Argo CD(EKS)는 반드시 `values-dev.generated.yaml`만 사용한다.**

---

## 15. Secret 관리

### 원칙

Git 저장소에 실제 시크릿 값을 커밋하지 않는다.

**EKS (dev):** `ExternalSecret` 리소스가 SSM Parameter Store의 SecureString 값을 읽어 `safespot-secret`을 자동 생성한다 (`secret.externalSecret.enabled: true`). Helm/ArgoCD는 Secret을 직접 생성하지 않는다 (`secret.create: false`).

**로컬:** `secret.create: true`로 설정하면 Helm이 Secret을 렌더링한다. 로컬 전용이며 Git에 실제 값을 커밋하지 않는다.

### 필수 키 목록

| 키 | 설명 |
|---|---|
| `DB_USER` | 데이터베이스 사용자 |
| `DB_PASSWORD` | 데이터베이스 비밀번호 |
| `SPRING_DATASOURCE_USERNAME` | Spring DataSource 사용자 |
| `SPRING_DATASOURCE_PASSWORD` | Spring DataSource 비밀번호 |
| `AWS_ACCESS_KEY_ID` | AWS / LocalStack 액세스 키 |
| `AWS_SECRET_ACCESS_KEY` | AWS / LocalStack 시크릿 키 |
| `JWT_SECRET` | JWT 서명 키 |
| `SAFESPOT_JWT_SECRET` | api-core 필수. `safespot.jwt.secret` 프로퍼티에 매핑됨 |
| `SAFESPOT_JWT_EXPIRATION` | JWT 만료 시간(초). 기본값 `1800` |

`JWT_SECRET`과 `SAFESPOT_JWT_SECRET`은 동일한 값을 사용한다.

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

## 16. 주의사항

* 이 저장소에서 인프라 리소스를 생성하지 않는다.
* 환경별 설정은 반드시 values 파일로 관리한다.
* 민감 정보는 Secret, 일반 설정은 ConfigMap을 사용한다.
* `values-dev.generated.yaml`은 자동 생성 파일이다. 직접 수정하지 않는다. 인프라 값은 `render-dev-values` 워크플로, 이미지 태그는 애플리케이션 CI 파이프라인이 갱신한다.
