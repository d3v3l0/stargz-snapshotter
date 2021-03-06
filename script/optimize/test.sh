#!/bin/bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

set -euo pipefail

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
REPO="${CONTEXT}../../"
REGISTRY_HOST=registry-optimize
REPO_PATH=/go/src/github.com/containerd/stargz-snapshotter
DUMMYUSER=dummyuser
DUMMYPASS=dummypass

source "${REPO}/script/util/utils.sh"

DOCKER_COMPOSE_YAML=$(mktemp)
AUTH_DIR=$(mktemp -d)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${DOCKER_COMPOSE_YAML}" || true
    rm -rf "${AUTH_DIR}" || true
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

echo "Preparing creds..."
prepare_creds "${AUTH_DIR}" "${REGISTRY_HOST}" "${DUMMYUSER}" "${DUMMYPASS}"

echo "Preparing docker-compose.yml..."
cat <<EOF > "${DOCKER_COMPOSE_YAML}"
version: "3.3"
services:
  docker_opt:
    image: docker:dind
    container_name: docker
    privileged: true
    environment:
    - DOCKER_TLS_CERTDIR=/certs
    entrypoint:
    - sh
    - -c
    - |
      mkdir -p /etc/docker/certs.d/${REGISTRY_HOST}:5000 && \
      cp /registry/certs/domain.crt /etc/docker/certs.d/${REGISTRY_HOST}:5000 && \
      dockerd-entrypoint.sh
    volumes:
    - docker-client:/certs/client
    - ${AUTH_DIR}:/registry:ro
  testenv_opt:
    build:
      context: "${REPO}/script/optimize/optimize"
      dockerfile: Dockerfile
    container_name: testenv_opt
    privileged: true
    working_dir: ${REPO_PATH}
    entrypoint: ./script/optimize/optimize/entrypoint.sh
    environment:
    - NO_PROXY=127.0.0.1,localhost,${REGISTRY_HOST}:5000
    - DOCKER_HOST=tcp://docker:2376
    - DOCKER_TLS_VERIFY=1
    tmpfs:
    - /tmp:exec,mode=777
    volumes:
    - "${REPO}:${REPO_PATH}:ro"
    - ${AUTH_DIR}:/auth:ro
    - docker-client:/docker/client:ro
    - /dev/fuse:/dev/fuse
  registry:
    image: registry:2
    container_name: ${REGISTRY_HOST}
    environment:
    - REGISTRY_AUTH=htpasswd
    - REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm"
    - REGISTRY_AUTH_HTPASSWD_PATH=/auth/auth/htpasswd
    - REGISTRY_HTTP_TLS_CERTIFICATE=/auth/certs/domain.crt
    - REGISTRY_HTTP_TLS_KEY=/auth/certs/domain.key
    volumes:
    - ${AUTH_DIR}:/auth:ro
volumes:
  docker-client:
EOF

echo "Testing..."
FAIL=
if ! ( cd "${CONTEXT}" && \
           docker-compose -f "${DOCKER_COMPOSE_YAML}" build ${DOCKER_BUILD_ARGS:-} testenv_opt && \
           docker-compose -f "${DOCKER_COMPOSE_YAML}" up --abort-on-container-exit ) ; then
    FAIL=true
fi
docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
if [ "${FAIL}" == "true" ] ; then
    exit 1
fi

exit 0
