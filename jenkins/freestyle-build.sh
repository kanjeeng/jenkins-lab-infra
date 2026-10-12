#!/bin/bash
# Skrip "Execute shell" untuk job portofolio-freestyle.
# Variabel dari Credentials Binding: DOCKERHUB_USER, DOCKERHUB_PASS, RESEND_API_KEY,
# CONTACT_TO_EMAIL, DISCORD_WEBHOOK. Kunci SSH disuntik oleh plugin SSH Agent.
# Job dijalankan di workspace hasil clone repo aplikasi (Dockerfile ada di direktori kerja).
set -euo pipefail
set +x

APP_HOST="10.2.1.20"
CONTAINER="portofolio"
PORT="3000"
IMAGE_REPO="$DOCKERHUB_USER/portofolio-jenkins"
SHORT_SHA="$(git rev-parse --short=7 HEAD)"
TAG="$BUILD_NUMBER-$SHORT_SHA"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10"

notify() {
  jq -n --arg c "$1" '{content: $c}' \
    | curl -sS -m 10 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK" > /dev/null || true
}

# Konfigurasi Docker sementara agar kredensial tidak tersimpan di home user jenkins
export DOCKER_CONFIG="$(mktemp -d)"
cleanup() {
  rc=$?
  rm -rf "$DOCKER_CONFIG"
  if [ "$rc" -ne 0 ]; then notify "[GAGAL] portofolio-freestyle #$BUILD_NUMBER $BUILD_URL"; fi
}
trap cleanup EXIT

echo "== 1. Build image $IMAGE_REPO:$TAG =="
docker build \
  --build-arg RESEND_API_KEY="$RESEND_API_KEY" \
  --build-arg CONTACT_TO_EMAIL="$CONTACT_TO_EMAIL" \
  --build-arg APP_VERSION="$TAG" \
  -t "$IMAGE_REPO:$TAG" -t "$IMAGE_REPO:freestyle" .

echo "== 2. Scan Trivy (mode peringatan) =="
trivy image --severity HIGH,CRITICAL --ignore-unfixed --no-progress --timeout 10m --exit-code 0 "$IMAGE_REPO:$TAG"

echo "== 3. Push ke Docker Hub =="
echo "$DOCKERHUB_PASS" | docker login -u "$DOCKERHUB_USER" --password-stdin
docker push "$IMAGE_REPO:$TAG"
docker push "$IMAGE_REPO:freestyle"

echo "== 4. Kirim env-file runtime ke Server 2 (lewat stdin, bukan baris perintah) =="
printf 'NODE_ENV=production\nPORT=%s\nHOSTNAME=0.0.0.0\nRESEND_API_KEY=%s\nCONTACT_TO_EMAIL=%s\n' \
  "$PORT" "$RESEND_API_KEY" "$CONTACT_TO_EMAIL" \
  | ssh $SSH_OPTS "deploy@$APP_HOST" 'umask 077; cat > ~/portofolio.env'

echo "== 5. Deploy di Server 2 =="
ssh $SSH_OPTS "deploy@$APP_HOST" "bash -s -- $IMAGE_REPO:$TAG $CONTAINER $PORT" <<'REMOTE'
set -euo pipefail
IMAGE="$1"; NAME="$2"; PORT="$3"
PREV="$(docker inspect -f '{{.Config.Image}}' "$NAME" 2> /dev/null || true)"
if [ -n "$PREV" ]; then echo "$PREV" > ~/"$NAME".prev; fi
docker pull "$IMAGE"
docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped --env-file ~/portofolio.env \
  -p "$PORT:3000" --cap-drop ALL --security-opt no-new-privileges:true "$IMAGE" > /dev/null
REMOTE

echo "== 6. Health check (maks. 15 kali) =="
if ! ssh $SSH_OPTS "deploy@$APP_HOST" "bash -s -- $PORT" <<'REMOTE'
PORT="$1"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/"; then echo "OK (percobaan $i)"; exit 0; fi
  echo "belum siap ($i/15)"; sleep 4
done
exit 1
REMOTE
then
  echo "Health check gagal, rollback ke image sebelumnya"
  ssh $SSH_OPTS "deploy@$APP_HOST" "bash -s -- $CONTAINER $PORT" <<'REMOTE' || true
NAME="$1"; PORT="$2"
PREV="$(cat ~/"$NAME".prev 2> /dev/null || true)"
if [ -z "$PREV" ]; then echo "tidak ada image sebelumnya"; exit 1; fi
docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped --env-file ~/portofolio.env \
  -p "$PORT:3000" --cap-drop ALL --security-opt no-new-privileges:true "$PREV" > /dev/null
REMOTE
  exit 1
fi

notify "[BERHASIL] portofolio-freestyle #$BUILD_NUMBER image $IMAGE_REPO:$TAG"
docker image prune -f > /dev/null || true
