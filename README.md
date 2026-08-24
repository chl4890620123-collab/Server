# Server Infrastructure

이 저장소는 Windows 미니PC의 중앙 배포/운영 진입점입니다.

## 책임 분리

```text
각 앱 저장소
  = 앱 코드 + Dockerfile + 앱 자체 CI

Server 저장소
  = Self-hosted Runner + 운영 Compose + Caddy + 배포 스크립트

D:\server-data
  = 운영 DB + runtime env + 업로드 + 백업
```

외부 SSH 배포를 기본 경로로 사용하지 않습니다. GitHub Actions의 Windows self-hosted runner가 미니PC에서 직접 Docker 명령을 실행합니다.

## Infrastructure smoke test

기존 smoke test는 그대로 유지합니다.

```text
GitHub Actions
  -> Self-hosted Windows Runner
  -> Docker Compose
  -> Nginx 테스트 화면
  -> HTTP 200
```

기본 포트는 `9010`입니다.

## Restok 배포

Restok은 `chl4890620123-collab/Restok-Rangchain`의 최신 `main`을 Server가 직접 가져와 배포합니다. MOVE-AI나 다른 프로젝트의 Nginx/네트워크/포트에 의존하지 않습니다.

```text
Restok-Rangchain main
   -> Server self-hosted runner
   -> Restok Docker image build
   -> MariaDB 11.4
   -> Spring Boot + FastAPI + React/Nginx
   -> Caddy internal reverse proxy
   -> Cloudflare Quick Tunnel
   -> public HTTPS preview URL
```

운영 파일:

```text
deploy/compose/restok.yml
deploy/caddy/restok.Caddyfile
deploy/scripts/check-restok-legacy-data.ps1
deploy/scripts/deploy-restok.ps1
.github/workflows/deploy-restok.yml
```

### Restok 서버 전용 데이터

```text
D:\server-data\restok\runtime\.env
D:\server-data\restok\mariadb
D:\server-data\restok\uploads
D:\server-data\restok\backups
```

첫 Server-managed 배포에서 runtime `.env`가 없으면 DB 비밀번호, DB root 비밀번호, JWT secret을 서버에서 생성합니다. Gemini와 Google OAuth는 선택 설정이며 실제 키는 Git에 저장하지 않습니다.

기존 Restok DB Docker volume이 감지되는데 새 `D:\server-data\restok\mariadb`가 비어 있으면 배포를 중단합니다. 이전 데이터를 자동으로 버리거나 빈 DB로 대체하지 않습니다.

### Restok 로컬 검증 주소

Restok Caddy는 호스트 80/443을 점유하지 않습니다.

```text
http://127.0.0.1:9050
http://127.0.0.1:9050/api/auth/health
```

9050이 다른 호스트 프로세스에 사용 중이면 기존 서비스를 종료하지 않고 배포를 중단합니다.

### Restok 공개 검수 URL

별도 고정 도메인을 건드리지 않고 Cloudflare Quick Tunnel로 임시 HTTPS URL을 만듭니다.

```text
https://<random>.trycloudflare.com
```

로컬 frontend와 `/api/auth/health`, 공개 frontend와 공개 `/api/auth/health`가 모두 HTTP 200이어야 배포 성공으로 기록합니다.

성공 결과:

```text
deploy/status/restok.txt
```

### Restok 자동 배포

`.github/workflows/deploy-restok.yml`은 다음 경우 실행됩니다.

- Restok 운영 파일이 Server `main`에 변경된 경우
- 수동 `workflow_dispatch`
- 15분 주기 동기화

Restok `main`의 SHA가 기존 배포 SHA와 같고 로컬/공개 health가 모두 정상인 경우에는 다시 빌드하지 않습니다.

새 배포 전에 기존 `restok-db`가 실행 중이면 `mariadb-dump` 백업을 먼저 만듭니다.

```text
D:\server-data\restok\backups\restok_YYYYMMDD_HHMMSS.sql
```

이미지 빌드를 먼저 성공시킨 뒤 컨테이너를 갱신하므로 빌드 실패만으로 실행 중인 Restok 컨테이너를 교체하지 않습니다.

## Maple 배포

Maple은 Server가 최신 `chl4890620123-collab/maple` main을 직접 가져와 배포합니다.

```text
Maple main
   -> Server self-hosted runner
   -> Maple Docker build
   -> MariaDB 11.4
   -> Caddy internal reverse proxy
   -> Cloudflare Quick Tunnel
   -> public HTTPS preview URL
```

운영 Compose:

```text
deploy/compose/maple.yml
```

배포 스크립트:

```text
deploy/scripts/deploy-maple.ps1
```

Caddy 설정:

```text
deploy/caddy/maple.Caddyfile
```

### 서버 전용 데이터

GitHub 저장소에는 실제 운영 비밀번호를 저장하지 않습니다.

```text
D:\server-data\maple\runtime\.env
D:\server-data\maple\mariadb
D:\server-data\maple\backups
```

첫 배포 때 runtime `.env`가 없으면 긴 랜덤 `ADMIN_TOKEN`, DB 비밀번호, DB root 비밀번호를 서버에서 자동 생성합니다.

MariaDB의 `3306` 포트는 호스트나 인터넷에 publish하지 않습니다.

### 로컬 검증 주소

Caddy는 기존 80/443 서비스와 충돌하지 않도록 localhost 전용 포트를 사용합니다.

```text
http://127.0.0.1:9040
```

포트가 이미 다른 서비스에 사용 중이면 배포를 중단합니다. 기존 서비스 포트를 강제로 종료하거나 변경하지 않습니다.

### 공개 검수 URL

별도 도메인 정보가 없는 현재 단계에서는 Cloudflare Quick Tunnel을 사용해 임시 HTTPS URL을 자동 발급합니다.

```text
https://<random>.trycloudflare.com
```

배포 스크립트는 공개 `/api/health`와 실제 Maple 화면의 HTTP 200을 모두 확인한 뒤에만 성공 처리합니다.

성공한 URL은 다음 파일에 기록됩니다.

```text
deploy/status/maple.txt
```

이 Quick Tunnel은 검수/프리뷰용이며 컨테이너를 새로 만들면 URL이 변경될 수 있습니다. 실제 고정 Gabia 도메인이 Server에 등록되면 동일한 Caddy upstream을 고정 도메인으로 교체하면 됩니다.

## 데이터 보호 공통 원칙

- 운영 DB/runtime secret은 앱 저장소에 넣지 않습니다.
- 데이터가 있는 DB를 임의로 초기화하지 않습니다.
- 백업 실패 시 데이터 보호가 우선이며 배포를 중단합니다.
- 전역 `docker system prune`, `docker volume prune`을 배포 스크립트에서 실행하지 않습니다.
- 앱별 컨테이너 이름, 네트워크, localhost 포트를 분리해 한 앱 삭제가 다른 앱의 진입 경로를 끊지 않도록 합니다.
