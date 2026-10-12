// Jenkinsfile - Parameterized Pipeline (repo jenkins-lab-infra)
// Credential: dockerhub-credentials, ssh-deploy-key, resend-api-key, contact-to-email, discord-webhook
// Parameter didefinisikan di sini (Pipeline as Code). Setelah build pertama, tombol "Build with Parameters" muncul.

def notifyDiscord(String status) {
    try {
        node {
            withCredentials([string(credentialsId: 'discord-webhook', variable: 'WEBHOOK')]) {
                discordSend(
                    webhookURL: WEBHOOK,
                    title: "${env.JOB_NAME} #${env.BUILD_NUMBER}",
                    description: "Status: ${status}\nImage: ${env.IMAGE_REPO ?: '-'}:${env.DEPLOY_TAG ?: '-'}\nAksi: ${params.ACTION}",
                    link: env.BUILD_URL,
                    result: status,
                    footer: 'Jenkins Lab'
                )
            }
        }
    } catch (err) {
        echo "Notifikasi Discord gagal: ${err.message}"
    }
}

pipeline {
    agent none

    parameters {
        string(name: 'GIT_URL', defaultValue: 'https://github.com/kanjeeng/portofolio-tailwind-css', description: 'Repositori aplikasi (hanya https://github.com/USER/REPO)')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch yang di-build')
        string(name: 'DOCKERHUB_NAMESPACE', defaultValue: 'kanjeeng', description: 'Username Docker Hub (GANTI sesuai akun Anda)')
        string(name: 'IMAGE_NAME', defaultValue: 'portofolio-jenkins', description: 'Nama image (huruf kecil)')
        string(name: 'CONTAINER_NAME', defaultValue: 'portofolio', description: 'Nama kontainer di Server 2')
        string(name: 'HOST_PORT', defaultValue: '3000', description: 'Port host Server 2')
        string(name: 'APP_SERVER_HOST', defaultValue: '10.2.1.20', description: 'IP privat Server 2 (harus 10.2.1.x)')
        choice(name: 'ACTION', choices: ['build-and-deploy', 'deploy-existing-tag'], description: 'deploy-existing-tag dipakai untuk rollback manual')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Wajib diisi bila ACTION = deploy-existing-tag, contoh 12-a1b2c3d')
        booleanParam(name: 'REQUIRE_APPROVAL', defaultValue: true, description: 'Minta persetujuan admin atau devops sebelum deploy')
        booleanParam(name: 'TRIVY_FAIL_ON_VULN', defaultValue: false, description: 'Gagalkan build bila ada kerentanan HIGH atau CRITICAL')
        booleanParam(name: 'LINT_STRICT', defaultValue: false, description: 'Gagalkan build bila lint gagal (default: hanya tandai UNSTABLE)')
    }

    options {
        timestamps()
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
        skipDefaultCheckout(true)
    }

    environment {
        DOCKER_BUILDKIT = '1'
        CONTAINER_PORT  = '3000'
        DEPLOY_USER     = 'deploy'
        SSH_OPTS        = '-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10'
        TRIVY_EXIT      = "${params.TRIVY_FAIL_ON_VULN ? 1 : 0}"
    }

    stages {

        stage('Prepare') {
            steps {
                script {
                    if (!(params.GIT_URL ==~ '^https://github[.]com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'))
                        error('GIT_URL harus berformat https://github.com/USER/REPO')
                    if (!(params.GIT_BRANCH ==~ '^[A-Za-z0-9._/-]{1,100}$'))
                        error('GIT_BRANCH tidak valid')
                    if (!(params.DOCKERHUB_NAMESPACE ==~ '^[a-z0-9][a-z0-9_-]{2,40}$'))
                        error('DOCKERHUB_NAMESPACE tidak valid')
                    if (!(params.IMAGE_NAME ==~ '^[a-z0-9][a-z0-9._-]{0,60}$'))
                        error('IMAGE_NAME tidak valid')
                    if (!(params.CONTAINER_NAME ==~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'))
                        error('CONTAINER_NAME tidak valid')
                    if (!(params.HOST_PORT ==~ '^[0-9]{2,5}$'))
                        error('HOST_PORT tidak valid')
                    if (!(params.APP_SERVER_HOST ==~ '^10[.]2[.]1[.][0-9]{1,3}$'))
                        error('APP_SERVER_HOST harus berada di subnet 10.2.1.0/24')
                    if (params.ACTION == 'deploy-existing-tag' && !(params.IMAGE_TAG ==~ '^[A-Za-z0-9_.-]{1,100}$'))
                        error('IMAGE_TAG wajib diisi untuk deploy-existing-tag')

                    env.IMAGE_REPO = "${params.DOCKERHUB_NAMESPACE}/${params.IMAGE_NAME}"
                    env.DEPLOY_TAG = (params.ACTION == 'deploy-existing-tag') ? params.IMAGE_TAG : 'pending'
                    currentBuild.description = "${params.ACTION} ${env.IMAGE_REPO}"
                }
            }
        }

        stage('Build and Push') {
            when { expression { params.ACTION == 'build-and-deploy' } }
            agent any
            stages {

                stage('1. Checkout') {
                    steps {
                        checkout([
                            $class: 'GitSCM',
                            branches: [[name: "*/${params.GIT_BRANCH}"]],
                            userRemoteConfigs: [[url: params.GIT_URL]],
                            extensions: [
                                [$class: 'RelativeTargetDirectory', relativeTargetDir: 'app'],
                                [$class: 'CleanBeforeCheckout']
                            ]
                        ])
                        script {
                            env.SHORT_SHA  = sh(returnStdout: true, script: 'git -C app rev-parse --short=7 HEAD').trim()
                            env.DEPLOY_TAG = "${env.BUILD_NUMBER}-${env.SHORT_SHA}"
                            currentBuild.description = "${params.ACTION} ${env.IMAGE_REPO}:${env.DEPLOY_TAG}"
                        }
                    }
                }

                stage('2. Install and Lint') {
                    steps {
                        dir('app') {
                            script {
                                docker.image('node:20-alpine').inside('-e HOME=/tmp -e npm_config_cache=/tmp/.npm') {
                                    sh 'npm ci --no-audit --no-fund'
                                    catchError(buildResult: params.LINT_STRICT ? 'FAILURE' : 'UNSTABLE', stageResult: 'UNSTABLE') {
                                        sh 'npm run lint'
                                    }
                                }
                            }
                        }
                    }
                }

                stage('3. Build Image') {
                    steps {
                        dir('app') {
                            withCredentials([
                                string(credentialsId: 'resend-api-key', variable: 'RESEND_API_KEY'),
                                string(credentialsId: 'contact-to-email', variable: 'CONTACT_TO_EMAIL')
                            ]) {
                                sh '''
                                    set +x
                                    docker build \
                                      --build-arg RESEND_API_KEY="$RESEND_API_KEY" \
                                      --build-arg CONTACT_TO_EMAIL="$CONTACT_TO_EMAIL" \
                                      --build-arg APP_VERSION="$DEPLOY_TAG" \
                                      --label org.opencontainers.image.revision="$SHORT_SHA" \
                                      --label org.opencontainers.image.source="$GIT_URL" \
                                      -t "$IMAGE_REPO:$DEPLOY_TAG" -t "$IMAGE_REPO:jenkins" .
                                '''
                            }
                        }
                    }
                }

                stage('4. Scan Image (Trivy)') {
                    steps {
                        sh '''
                            trivy image --severity HIGH,CRITICAL --ignore-unfixed --no-progress --timeout 10m \
                              --format json --output trivy-report.json "$IMAGE_REPO:$DEPLOY_TAG" || true
                            trivy image --severity HIGH,CRITICAL --ignore-unfixed --no-progress --timeout 10m \
                              --exit-code "$TRIVY_EXIT" "$IMAGE_REPO:$DEPLOY_TAG"
                        '''
                    }
                    post {
                        always { archiveArtifacts artifacts: 'trivy-report.json', allowEmptyArchive: true }
                    }
                }

                stage('5. Push to Docker Hub') {
                    steps {
                        withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials',
                                                          usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
                            sh '''
                                set +x
                                export DOCKER_CONFIG="$(mktemp -d)"
                                trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                                echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
                                docker push "$IMAGE_REPO:$DEPLOY_TAG"
                                docker push "$IMAGE_REPO:jenkins"
                            '''
                        }
                    }
                }
            }
            post {
                always {
                    sh 'docker rmi "$IMAGE_REPO:$DEPLOY_TAG" "$IMAGE_REPO:jenkins" || true'
                    sh 'docker image prune -f || true'
                    cleanWs()
                }
            }
        }

        stage('6. Approval') {
            when { expression { params.REQUIRE_APPROVAL } }
            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    input message: "Deploy ${env.IMAGE_REPO}:${env.DEPLOY_TAG} ke ${params.APP_SERVER_HOST}?",
                          ok: 'Deploy',
                          submitter: 'admin,devops'
                }
            }
        }

        stage('Release') {
            agent any
            stages {

                stage('7. Deploy') {
                    steps {
                        sshagent(credentials: ['ssh-deploy-key']) {
                            withCredentials([
                                string(credentialsId: 'resend-api-key', variable: 'RESEND_API_KEY'),
                                string(credentialsId: 'contact-to-email', variable: 'CONTACT_TO_EMAIL')
                            ]) {
                                sh '''
                                    set +x
                                    printf 'NODE_ENV=production\\nPORT=%s\\nHOSTNAME=0.0.0.0\\nRESEND_API_KEY=%s\\nCONTACT_TO_EMAIL=%s\\n' \
                                      "$CONTAINER_PORT" "$RESEND_API_KEY" "$CONTACT_TO_EMAIL" \
                                      | ssh $SSH_OPTS "$DEPLOY_USER@$APP_SERVER_HOST" 'umask 077; cat > ~/portofolio.env'
                                '''
                                sh '''
                                    ssh $SSH_OPTS "$DEPLOY_USER@$APP_SERVER_HOST" "bash -s -- $IMAGE_REPO:$DEPLOY_TAG $CONTAINER_NAME $HOST_PORT $CONTAINER_PORT" <<'REMOTE'
set -euo pipefail
IMAGE="$1"; NAME="$2"; HPORT="$3"; CPORT="$4"
PREV="$(docker inspect -f '{{.Config.Image}}' "$NAME" 2> /dev/null || true)"
if [ -n "$PREV" ]; then echo "$PREV" > ~/"$NAME".prev; fi
docker pull "$IMAGE"
docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped --env-file ~/portofolio.env \
  -p "$HPORT:$CPORT" --cap-drop ALL --security-opt no-new-privileges:true "$IMAGE" > /dev/null
REMOTE
                                '''
                            }
                        }
                    }
                }

                stage('8. Health Check') {
                    steps {
                        sshagent(credentials: ['ssh-deploy-key']) {
                            script {
                                int rc = sh(returnStatus: true, script: '''
                                    ssh $SSH_OPTS "$DEPLOY_USER@$APP_SERVER_HOST" "bash -s -- $HOST_PORT" <<'REMOTE'
PORT="$1"
for i in $(seq 1 15); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/"; then echo "OK (percobaan $i)"; exit 0; fi
  echo "belum siap ($i/15)"; sleep 4
done
exit 1
REMOTE
                                ''')
                                if (rc != 0) {
                                    echo 'Health check gagal. Menjalankan rollback ke image sebelumnya.'
                                    sh '''
                                        ssh $SSH_OPTS "$DEPLOY_USER@$APP_SERVER_HOST" "bash -s -- $CONTAINER_NAME $HOST_PORT $CONTAINER_PORT" <<'REMOTE' || true
NAME="$1"; HPORT="$2"; CPORT="$3"
PREV="$(cat ~/"$NAME".prev 2> /dev/null || true)"
if [ -z "$PREV" ]; then echo "tidak ada image sebelumnya"; exit 1; fi
docker rm -f "$NAME" > /dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped --env-file ~/portofolio.env \
  -p "$HPORT:$CPORT" --cap-drop ALL --security-opt no-new-privileges:true "$PREV" > /dev/null
REMOTE
                                    '''
                                    error('Health check gagal, rollback dijalankan')
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    post {
        success  { script { notifyDiscord('SUCCESS') } }
        unstable { script { notifyDiscord('UNSTABLE') } }
        failure  { script { notifyDiscord('FAILURE') } }
        aborted  { script { notifyDiscord('ABORTED') } }
    }
}
