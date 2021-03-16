#!/usr/bin/env bash

# based on: https://github.com/cameronbraid/jx3-kind/blob/master/jx3-kind.sh

{
set -euo pipefail

COMMAND=${1:-'help'}

DIR=${NAME:-"$(pwd)"}

NAME=${NAME:-"gke-gitea"}
TOKEN=${TOKEN:-}

BOT_USER="${BOT_USER:-jenkins-x-test-bot}"
BOT_PASS="${BOT_PASS:-jenkins-x-test-bot}"

export DEVELOPER_USER="developer"
export DEVELOPER_PASS="developer"

ORG="${ORG:-coders}"
#TEST_NAME="${TEST_NAME:-test-create-spring}"
TEST_NAME="${TEST_NAME:-test-quickstart-node-http}"

DEV_CLUSTER_REPOSITORY="${DEV_CLUSTER_REPOSITORY:-https://github.com/jx3-gitops-repositories/jx3-gke-gsm-gitea}"

# versions
KIND_VERSION=${KIND_VERSION:-"0.10.0"}
JX_VERSION=${JX_VERSION:-"3.1.306"}
KUBECTL_VERSION=${KUBECTL_VERSION:-"1.20.0"}
YQ_VERSION=${YQ_VERSION:-"4.2.0"}

LOG_TIMESTAMPS=${LOG_TIMESTAMPS:-"true"}
LOG_FILE=${LOG_FILE:-"log"}
LOG=${LOG:-"console"} #or file

GITEA_ADMIN_PASSWORD=${GITEA_ADMIN_PASSWORD:-"abcdEFGH"}

export GIT_SCHEME="http"
export GIT_KIND="gitea"

# lets setup git
git config --global --add user.name JenkinsXBot
git config --global --add user.email jenkins-x@googlegroups.com


# write message to console and log
info() {
  prefix=""
  if [[ "${LOG_TIMESTAMPS}" == "true" ]]; then
    prefix="$(date '+%Y-%m-%d %H:%M:%S') "
  fi
  if [[ "${LOG}" == "file" ]]; then
    echo -e "${prefix}$@" >&3
    echo -e "${prefix}$@"
  else
    echo -e "${prefix}$@"
  fi
}

# write to console and store some information for error reporting
STEP=""
SUB_STEP=""
step() {
  STEP="$@"
  SUB_STEP=""
  info
  info "[$STEP]"
}

# store some additional information for error reporting
substep() {
  SUB_STEP="$@"
  info " - $SUB_STEP"
}

err() {
  if [[ "$STEP" == "" ]]; then
      echo "Failed running: ${BASH_COMMAND}"
      exit 1
  else
    if [[ "$SUB_STEP" != "" ]]; then
      echo "Failed at [$STEP / $SUB_STEP] running : ${BASH_COMMAND}"
      exit 1
    else
      echo "Failed at [$STEP] running : ${BASH_COMMAND}"
      exit 1
    fi
  fi
}

FILE_NGINX_VALUES=`cat << EOF
controller:
  hostPort:
    enabled: true
  replicaCount: 1
  config:
    # since the docker registry is being used via ingress
    # an alternative to making this global is to convigure the docker-registry ingress to use an annotation
    proxy-body-size: 1g
EOF
`

installNginxIngress() {

  step "Installing nginx ingress"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

  echo "${FILE_NGINX_VALUES}" | helm upgrade --install nginx --namespace nginx --create-namespace --values - ingress-nginx/ingress-nginx

  substep "Waiting for nginx to start"

  sleep 2

  kubectl wait --namespace nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=100m

  IP=""
  while [ -z $IP ]; do
    IP=$(kubectl get service -n nginx nginx-ingress-nginx-controller -o=jsonpath="{.status.loadBalancer.ingress[0].ip}")

    if [[ "$IP" == "" ]]; then
      echo "Waiting for nginx LoadBalancer External IP to be resolved..."
      sleep 10
    fi
  done

 export GIT_HOST=${GIT_HOST:-"gitea.${IP}.nip.io"}
 export GIT_URL="${GIT_SCHEME}://${GIT_HOST}"

 echo "using GIT_URL ${GIT_URL}"
}


installGitea() {
  step "Installing Gitea at $GIT_HOST"

FILE_GITEA_VALUES_YAML=`cat <<EOF
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: nginx
  hosts:
    - ${GIT_HOST}
gitea:
  admin:
    password: ${GITEA_ADMIN_PASSWORD}
  config:
    server:
      DOMAIN: ${GIT_HOST}
      PROTOCOL: ${GIT_SCHEME}
      ROOT_URL: ${GIT_SCHEME}://${GIT_HOST}
      SSH_DOMAIN: ${GIT_HOST}
    database:
      DB_TYPE: sqlite3
      ## Note that the intit script checks to see if the IP & port of the database service is accessible, so make sure you set those to something that resolves as successful (since sqlite uses files on disk setting the port & ip won't affect the running of gitea).
      HOST: ${IP}:80 # point to the nginx ingress
    service:
      DISABLE_REGISTRATION: true
  database:
    builtIn:
      postgresql:
        enabled: false
image:
  version: 1.13.0
EOF
`

  helm repo add gitea-charts https://dl.gitea.io/charts/

  echo "${FILE_GITEA_VALUES_YAML}" | helm upgrade --install --namespace gitea --create-namespace -f - gitea gitea-charts/gitea

  sleep 2

  substep "Waiting for Gitea to start"

  kubectl wait --namespace gitea \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=gitea \
    --timeout=100m

  echo "gitea is running at ${GIT_URL}"

  sleep 2

  echo "running curl -LI -o /dev/null  -s ${GIT_URL}/api/v1/admin/users -H '${CURL_AUTH_HEADER}'"

  # Verify that gitea is serving
  for i in {1..20}; do
    echo "curling..."

    http_output=`curl -v -LI -H "${CURL_AUTH_HEADER}" -s "${GIT_URL}/api/v1/admin/users" || true`
    echo "output of curl ${http_output}"

    echo curl -v -LI -s "${GIT_URL}/api/v1/admin/users" "${CURL_GIT_ADMIN_AUTH[@]}"
    http_code=`curl -LI -o /dev/null -w '%{http_code}' -H "${CURL_AUTH_HEADER}" -s "${GIT_URL}/api/v1/admin/users" || true`
    echo "got response code ${http_code}"

    if [[ "${http_code}" = "200" ]]; then
      break
    fi
    sleep 1
  done

  echo "stopped polling"

  if [[ "${http_code}" != "200" ]]; then
    info "Gitea didn't startup"
    return 1
  fi

  info "Gitea is up at ${GIT_URL}"
  info "Login with username: gitea_admin password: ${GITEA_ADMIN_PASSWORD}"
}


FILE_USER_JSON=`cat << 'EOF'
{
  "admin": true,
  "email": "developer@example.com",
  "full_name": "full_name",
  "login_name": "login_name",
  "must_change_password": false,
  "password": "password",
  "send_notify": false,
  "source_id": 0,
  "username": "username"
}
EOF
`

CURL_AUTH_HEADER=""
declare -a CURL_AUTH=()
curlBasicAuth() {
  username=$1
  password=$2
  basic=`echo -n "${username}:${password}" | base64`
  CURL_AUTH=("-H" "Authorization: Basic $basic")

  CURL_AUTH_HEADER="Authorization: Basic $basic"
}
curlTokenAuth() {
  token=$1
  CURL_AUTH=("-H" "Authorization: token ${token}")
}

curlBasicAuth "gitea_admin" "${GITEA_ADMIN_PASSWORD}"
CURL_GIT_ADMIN_AUTH=("${CURL_AUTH[@]}")
declare -a CURL_TYPE_JSON=("-H" "Accept: application/json" "-H" "Content-Type: application/json")
# "${GIT_SCHEME}://gitea_admin:${GITEA_ADMIN_PASSWORD}@${GIT_HOST}"

giteaCreateUserAndToken() {
  username=$1
  password=$2

  request=`echo "${FILE_USER_JSON}" \
    | yq e '.email="'${username}@example.com'"' - \
    | yq e '.full_name="'${username}'"' - \
    | yq e '.login_name="'${username}'"' - \
    | yq e '.username="'${username}'"' - \
    | yq e '.password="'${password}'"' -`

  substep "creating ${username} user"
  response=`echo "${request}" | curl -s -X POST "${GIT_URL}/api/v1/admin/users" "${CURL_GIT_ADMIN_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-`
  # info $request
  # info $response

  substep "updating ${username} user"
  response=`echo "${request}" | curl -s -X PATCH "${GIT_URL}/api/v1/admin/users/${username}" "${CURL_GIT_ADMIN_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data @-`
  # info $response

  substep "creating ${username} token"
  curlBasicAuth "${username}" "${password}"
  response=`curl -s -X POST "${GIT_URL}/api/v1/users/${username}/tokens" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data '{"name":"jx3"}'`
  # info $response
  token=`echo "${response}" | yq eval '.sha1' -`
  if [[ "$token" == "null" ]]; then
    info "Failed to create token for ${username}, json response: \n${response}"
    return 1
  fi
  TOKEN="${token}"
}


configureGiteaOrgAndUsers() {
  step "Setting up gitea organisation and users"

ENV_VARS=`cat << 'EOF'
export GIT_SERVER_URL="${GIT_URL}"
export GIT_SERVER_HOST="${GIT_HOST}"
export GIT_USER="${DEVELOPER_USER}"
EOF
`
  cat ${ENV_VARS} > "${DIR}/variables.sh"


  giteaCreateUserAndToken "${BOT_USER}" "${BOT_PASS}"
  botToken="${TOKEN}"
  echo "${botToken}" > "${DIR}/.bot.token"

  giteaCreateUserAndToken "${DEVELOPER_USER}" "${DEVELOPER_PASS}"
  developerToken="${TOKEN}"
  echo "${developerToken}" > "${DIR}/.developer.token"
  substep "creating ${ORG} organisation"

  curlTokenAuth "${developerToken}"
  json=`curl -s -X POST "${GIT_URL}/api/v1/orgs" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}" --data '{"repo_admin_change_team_access": true, "username": "'${ORG}'", "visibility": "private"}'`
  # info "${json}"

  substep "add ${BOT_USER} an owner of ${ORG} organisation"

  substep "find owners team for ${ORG}"
  curlTokenAuth "${developerToken}"
  json=`curl -s "${GIT_URL}/api/v1/orgs/${ORG}/teams/search?q=owners" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}"`
  id=`echo "${json}" | yq eval '.data[0].id' -`
  if [[ "${id}" == "null" ]]; then
    info "Unable to find owners team, json response :\n${json}"
    return 1
  fi

  substep "add ${BOT_USER} as member of owners team (#${id}) for ${ORG}"
  curlTokenAuth "${developerToken}"
  response=`curl -s -X PUT "${GIT_URL}/api/v1/teams/${id}/members/${BOT_USER}" "${CURL_AUTH[@]}" "${CURL_TYPE_JSON[@]}"`

}

loadGitUserTokens() {
  botToken=`cat "${DIR}/.bot.token"`
  developerToken=`cat "${DIR}/.developer.token"`
}




# resetGitea() {
#   #
#   #
#   # DANGER : THIS WILL REMOVE ALL GITEA DATA
#   #
#   #
#   step "Resetting Gitea"
#   substep "Clar gitea data folder which includes the sqlite database and repositories"
#   kubectl -n gitea exec gitea-0 -- rm -rf "/data/*"


#   substep "Restart gitea pod"
#   kubectl -n gitea delete pod gitea-0
#   sleep 5
#   expectPodsReadyByLabel gitea app.kubernetes.io/name=gitea

# }



help() {
  # TODO
  info "run 'kind.sh create' or 'kind.sh destroy'"
}

createBootRepo() {
  step "creating the dev cluster git repo: ${GIT_URL}/${ORG}/cluster-$NAME-dev from template: ${DEV_CLUSTER_REPOSITORY}"

  rm -rf "cluster-$NAME-dev"

  export GIT_USERNAME="${BOT_USER}"
  export GIT_TOKEN="${TOKEN}"

  echo "user $GIT_USERNAME"
  echo "token $GIT_TOKEN"

  # lets make it public for now since its on a laptop
  # --private
  jx scm repo create ${GIT_URL}/${ORG}/cluster-$NAME-dev --template ${DEV_CLUSTER_REPOSITORY}  --confirm --push-host ${GIT_HOST}
  sleep 2

  git clone ${GIT_SCHEME}://${DEVELOPER_USER}:${DEVELOPER_PASS}@${GIT_HOST}/${ORG}/cluster-$NAME-dev

  cd cluster-$NAME-dev
  jx gitops requirements edit --domain "${IP}.nip.io" --git-server ${GIT_URL}
  git commit -a -m "fix: upgrade domain and git server"
  git push
  cd ..
}

installGitOperator() {
  step "installing the git operator at url: ${GIT_URL}/${ORG}/cluster-$NAME-dev with user: ${BOT_USER} token: ${BOT_PASS}"

  #jx admin operator --url "${GIT_URL}/${ORG}/cluster-$NAME-dev" --username ${BOT_USER} --token ${TOKEN}

FILE_JXGO_VALUES_YAML=`cat <<EOF
bootServiceAccount:
  enabled: true
  annotations:
    iam.gke.io/gcp-service-account: "${TF_VAR_cluster_name}-boot@${TF_VAR_gcp_project}.iam.gserviceaccount.com"
env:
  NO_RESOURCE_APPLY: "true"
url: "${GIT_URL}/${ORG}/cluster-$NAME-dev"
username: "${BOT_USER}"
password: "${TOKEN}"
EOF
`

  helm repo add jx3 https://storage.googleapis.com/jenkinsxio/charts

  echo "${FILE_JXGO_VALUES_YAML}" | helm upgrade --install --namespace jx-git-operator --create-namespace -f - jxgo jx3/jx-git-operator

  # lets tail the boot log
  jx admin log -w
}

runBDD() {
    step "running the BDD tests $TEST_NAME on git server $GIT_URL"

    echo "user: ${BOT_USER} token: ${TOKEN}"

    helm upgrade --install bdd jx3/jx-bdd  --namespace jx --create-namespace --set bdd.approverSecret="bdd-git-approver",bdd.kind="$GIT_KIND",bdd.owner="$ORG",bdd.gitServerHost="gitea-http.gitea",bdd.gitServerURL="$GIT_URL",command.test="make $TEST_NAME",jxgoTag="$JX_VERSION",bdd.user="${BOT_USER}",bdd.token="${TOKEN}"

    echo "about to wait for the BDD test to run"

    sleep 20

    kubectl describe nodes
    kubectl get event -n jx -w &

    # lets avoid the jx commands thinking we are outside of kubernetes due to $GITHUB-ACTIONS maybe being set..
    export JX_KUBERNETES="true"
    jx verify job --name jx-bdd -n jx
}






create() {
  installNginxIngress
  
  installGitea
  configureGiteaOrgAndUsers

  createBootRepo
  installGitOperator
}


function_exists() {
  declare -f -F $1 > /dev/null
  return $?
}

if [[ "${COMMAND}" == "ciLoop" ]]; then
  ciLoop
elif [[ "${COMMAND}" == "env" ]]; then
  :
else
  if `function_exists "${COMMAND}"`; then
    shift
    #initLog

    "${COMMAND}" "$@"
  else
    info "Unknown command : ${COMMAND}"
    exit 1
  fi
fi

exit 0
}
