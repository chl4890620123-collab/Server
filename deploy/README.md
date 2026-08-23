# Central deployment

이 저장소는 Windows 미니PC의 중앙 운영/배포 진입점입니다.

## 책임 분리

- 각 앱 저장소: 소스코드, Dockerfile, 앱 자체 CI
- Server 저장소: production Compose, 서버 runtime env, SSH 배포, 포트, Caddy 라우팅
- 미니PC D 드라이브: 영구 DB 데이터와 서버 전용 secret/runtime 설정

기존 `server-web`은 루트 `docker-compose.yml`로 계속 운영합니다. 프로젝트 서비스는 별도 Compose project를 사용하므로 서로의 `--remove-orphans`에 영향을 받지 않습니다.

## Maple

중앙 workflow:

```text
.github/workflows/deploy-maple.yml
```

동작:

```text
Maple main 최신 소스
  -> Server Actions가 checkout
  -> linux/amd64 Docker image build
  -> GHCR: server-maple:<Maple commit SHA>
  -> 기존 Server SSH secret으로 미니PC 접속
  -> deploy/scripts/deploy-maple.ps1
  -> deploy/compose/maple.yml
  -> maple-app + maple-db
  -> /api/health 확인
```

Maple 저장소에는 미니PC SSH Secret을 중복 등록하지 않습니다.

### 자동 동기화

Server workflow는 수동 실행 외에 15분 간격으로 Maple `main` 최신 커밋을 확인합니다. 동일한 SHA의 GHCR 이미지가 이미 존재하면 이미지 재빌드는 건너뛰고 exact SHA 이미지를 배포합니다.

### Server Secrets

기존 Server 배포에서 사용 중인 아래 값만 그대로 사용합니다.

```text
SERVER_HOST
SERVER_USER
SERVER_PORT
SERVER_SSH_KEY
SERVER_PASSWORD
```

`GITHUB_TOKEN`은 Actions가 자동 제공합니다.

### Maple runtime

실제 운영 환경값은 GitHub 저장소에 저장하지 않습니다.

```text
D:\server-data\maple\runtime\.env
```

첫 중앙 배포 때 파일이 없으면 `deploy-maple.ps1`이 안전한 랜덤 `ADMIN_TOKEN`, DB 사용자 비밀번호, DB root 비밀번호를 생성해 서버에만 저장합니다.

예시 형식은 다음 파일에 있습니다.

```text
deploy/runtime/maple.env.example
```

### 영구 데이터

MariaDB 데이터는 다음 위치에 bind mount 됩니다.

```text
D:\server-data\maple\mariadb
```

컨테이너/이미지를 교체해도 이 경로는 삭제하지 않습니다. 전역 `docker system prune`, `docker volume prune`은 이 배포 스크립트에서 실행하지 않습니다.

### 포트

기본값:

```text
Server status page : 9010
Maple              : 9040
Maple MariaDB       : Docker 내부 3306 only
```

Maple DB는 호스트에 3306을 publish하지 않습니다.

### Caddy

`deploy/caddy/maple.Caddyfile.example`은 기존 public Caddy에 추가할 라우팅 예시입니다. 기존 80/443 Caddy 컨테이너를 대체하거나 두 번째 Caddy를 실행하지 않습니다.

실제 도메인이 정해진 뒤 `maple.example.com`만 실제 호스트명으로 바꾸고 기존 Caddy 설정에 추가합니다.
