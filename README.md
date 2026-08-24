# Server Infrastructure

이 저장소는 Windows 미니PC의 중앙 배포/운영 진입점입니다.

## 책임 분리

```text
각 앱 저장소
  = 앱 코드 + Dockerfile + 앱 자체 CI

Server 저장소
  = 운영 Compose + Caddy + 배포/검증 스크립트 + GitHub Actions

D:\server-data
  = 운영 DB + runtime env + 업로드/영상 + 백업
```

현재 운영 배포는 GitHub-hosted Ubuntu runner가 기존 서버 SSH 설정으로 Windows 미니PC에 접속하는 구조입니다. Restok과 Aitm은 Windows의 Docker Desktop credential helper에 빌드가 의존하지 않도록 GitHub runner에서 애플리케이션 이미지를 먼저 빌드하고 Docker image bundle로 전송합니다. Maple은 소스 bind mount 기반이라 서버에서 별도 애플리케이션 이미지 빌드를 하지 않습니다.

## 서비스 분리

| 서비스 | 로컬 Caddy | DB 데이터 | 추가 영속 데이터 |
| --- | --- | --- | --- |
| Maple | `127.0.0.1:9040` | `D:\server-data\maple\mariadb` | runtime / backups |
| Restok | `127.0.0.1:9050` | `D:\server-data\restok\mariadb` | uploads / runtime / backups |
| Aitm | `127.0.0.1:9060` | `D:\server-data\aitm\mariadb` | videos / runtime / backups |

앱별 컨테이너 이름과 Docker network도 각각 `maple-*`, `restok-*`, `aitm-*`로 분리합니다. MariaDB 포트는 호스트에 publish하지 않습니다.

## 공통 배포 흐름

```text
App main
   -> 앱 자체 CI
   -> Server 배포 workflow
   -> 배포 전 DB 백업(기존 DB 실행 중일 때)
   -> Compose 검증
   -> 앱별 localhost Caddy
   -> Cloudflare Quick Tunnel
   -> local/public health + 실제 화면 검증
   -> deploy/status/<app>.txt 기록
```

Quick Tunnel은 검수용 임시 HTTPS 주소입니다. 컨테이너/터널 재생성 시 URL이 바뀔 수 있으며, 고정 Gabia 도메인을 연결할 때는 앱 내부 포트를 외부에 직접 노출하지 않고 Server의 동일한 Caddy upstream을 사용합니다.

## Maple

Maple은 `chl4890620123-collab/maple` 최신 `main`을 서버의 소스 디렉터리에 동기화하고 read-only bind mount로 실행합니다.

```text
Maple main
   -> Server deploy-maple workflow
   -> MariaDB 11.4
   -> FastAPI
   -> Caddy
   -> Quick Tunnel
```

운영 파일:

```text
deploy/compose/maple.yml
deploy/caddy/maple.Caddyfile
deploy/scripts/run-maple-deploy.ps1
deploy/scripts/deploy-maple.ps1
deploy/scripts/verify-maple-rules.py
.github/workflows/deploy-maple-ssh.yml
```

서버 데이터:

```text
D:\server-data\maple\runtime\.env
D:\server-data\maple\mariadb
D:\server-data\maple\backups
```

배포 성공 조건에는 `/api/health`, 화면, 마이스터빌 5개 카테고리, 카탈로그/재료 데이터, 고정 상점가, 길드 할인 ON/OFF 계산 규칙까지 포함됩니다.

성공 상태:

```text
deploy/status/maple.txt
deploy/status/transport.txt
```

## Restok

Restok은 `chl4890620123-collab/Restok-Rangchain` 최신 `main`을 GitHub runner에서 빌드합니다.

```text
Restok main
   -> GitHub runner: AI / Spring Boot / React 이미지 빌드
   -> docker save image bundle
   -> SSH/SCP -> Windows mini PC
   -> docker load
   -> MariaDB 11.4 + prebuilt app images
   -> Caddy
   -> Quick Tunnel
```

운영 파일:

```text
deploy/compose/restok.yml
deploy/caddy/restok.Caddyfile
deploy/scripts/check-restok-legacy-data.ps1
deploy/scripts/deploy-restok.ps1
.github/workflows/deploy-restok.yml
```

서버 데이터:

```text
D:\server-data\restok\runtime\.env
D:\server-data\restok\mariadb
D:\server-data\restok\uploads
D:\server-data\restok\backups
```

기존 Restok DB Docker volume이 감지되는데 새 bind-mount DB 디렉터리가 비어 있으면 배포를 중단합니다. 이전 데이터를 자동으로 버리거나 빈 DB로 대체하지 않습니다. 앱 시작 시 charset 변환은 운영 기본값 `false`입니다.

성공 상태:

```text
deploy/status/restok.txt
deploy/status/restok-transport.txt
```

## Aitm

Aitm은 `chl4890620123-collab/Aitm` 최신 `main`을 Restok과 같은 사전 빌드 방식으로 배포합니다.

```text
Aitm main
   -> GitHub runner: Pose AI / Spring Boot / Frontend 이미지 빌드
   -> docker save image bundle
   -> SSH/SCP -> Windows mini PC
   -> docker load
   -> MariaDB 10.11 + prebuilt app images
   -> Caddy
   -> Quick Tunnel
```

운영 파일:

```text
deploy/compose/aitm.yml
deploy/caddy/aitm.Caddyfile
deploy/runtime/aitm.env.example
deploy/scripts/deploy-aitm.ps1
.github/workflows/deploy-aitm.yml
```

서버 데이터:

```text
D:\server-data\aitm\runtime\.env
D:\server-data\aitm\mariadb
D:\server-data\aitm\videos
D:\server-data\aitm\backups
```

Aitm 프론트의 `/api`와 `/media`는 Compose 서비스명 `backend`로 프록시합니다. 운영에서는 `DB_CHARSET_MIGRATION_ENABLED=false`를 기본값으로 사용해 앱 부팅 중 `ALTER DATABASE/TABLE`을 수행하지 않습니다. 필요할 때만 별도 유지보수 창에서 명시적으로 활성화합니다.

성공 상태:

```text
deploy/status/aitm.txt
deploy/status/aitm-transport.txt
```

## 데이터 보호 공통 원칙

- 운영 DB/runtime secret은 Git 저장소에 넣지 않습니다.
- 데이터가 있는 DB를 임의로 초기화하지 않습니다.
- 기존 DB 컨테이너가 실행 중이면 새 배포 전에 `mariadb-dump --single-transaction` 백업을 만듭니다.
- 백업 실패 시 데이터 보호를 우선해 배포를 중단합니다.
- 전역 `docker system prune`, `docker volume prune`을 실행하지 않습니다.
- 앱별 DB 디렉터리, 네트워크, 컨테이너 이름, localhost 포트를 분리합니다.
- raw SSH/컨테이너 진단 로그를 Git에 커밋하지 않습니다. 수동 probe 로그는 Actions artifact로만 보관하며 retention은 3일입니다.
- 앱 시작 시 대규모 DB charset 변환은 운영 기본값으로 비활성화합니다.

## 진단

Maple/Restok probe workflow는 상세 컨테이너 상태와 로그를 저장소에 남기지 않고 Actions artifact로만 업로드합니다. 상태 파일에는 배포 SHA, 공개 검수 URL, 성공/실패 같은 최소 정보만 기록합니다.
