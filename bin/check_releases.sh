#!/usr/bin/env bash

# Copyright Archive Envoy
# SPDX-License-Identifier: Apache-2.0
# The full text of the Apache license is available in the LICENSE file at
# the root of the repo.

set -ue

# This checks upstream ${sourceGitHubRepository} releases and compares them
# with the released versions on https://archive.tetratelabs.io/envoy/envoy-versions.json.
# When a new version is found and its Docker image is available, it triggers
# the release workflow for both production and debug builds.

# Ensure we have tools we need installed
curl --version >/dev/null
jq --version >/dev/null
gh --version >/dev/null

sourceGitHubRepository=${1?sourceGitHubRepository is required. ex envoyproxy/envoy}
targetGitHubRepository=${2?targetGitHubRepository is required. ex tetratelabs/archive-envoy}
lowestVersion=${3?lowestVersion is required. ex 12.0.0}

curl="curl -fsSL"

# A valid GitHub token to avoid rate limiting.
githubToken=${GITHUB_TOKEN:-}
# Prepare authorization header when performing request to api.github.com to avoid rate limiting, especially when testing locally.
authorizationHeader="Authorization: Bearer ${githubToken}"

# docker_image_exists checks the Docker Hub registry API for a manifest.
# Returns 0 if the image:tag exists, 1 otherwise.
docker_image_exists() {
  local image=$1 tag=$2
  local token
  token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${image}:pull" | jq -r '.token')
  local status
  status=$(curl -fsSL -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://registry-1.docker.io/v2/${image}/manifests/${tag}" 2>/dev/null)
  [ "${status}" = "200" ]
}

# Always use the released versions.
currentVersions=$(${curl} https://archive.tetratelabs.io/envoy/envoy-versions.json)

# Fetch the last page number of releases (example value: 7), so we can get all of the releases.
# To get the last page, we send a HEAD request to "https://api.github.com/repos/${sourceGitHubRepository}/releases",
# then "grep" the "link" header value.
# Reference: https://docs.github.com/en/rest/guides/using-pagination-in-the-rest-api?apiVersion=2022-11-28#using-link-headers.
lastReleasePage=$(${curl}I ${githubToken:+ -H "${authorizationHeader}"} "https://api.github.com/repos/${sourceGitHubRepository}/releases" |
  grep -Eo 'page=[0-9]+' | awk 'NR==2' | cut -d'=' -f2) || exit 1

for ((page = 1; page <= lastReleasePage; page++)); do
  versions=$(${curl} ${githubToken:+ -H "${authorizationHeader}"} "https://api.github.com/repos/${sourceGitHubRepository}/releases?page=${page}" |
    jq -er ".|map(select(.prerelease == false and .draft == false))|.[]|.name" | sort -n) || exit 1

  for version in ${versions}; do
    if [[ $(echo "${currentVersions}" | jq -r --arg ver "${version#v}" '.versions | has($ver)') == "true" ]]; then
      continue
    fi

    if [[ "$(echo -e "${version#v}\n${lowestVersion}" | sort -V | tail -n 1)" != "${version#v}" ]]; then
      continue
    fi

    if ! docker_image_exists envoyproxy/envoy "${version}"; then
      echo "skipping ${version}: Docker image not yet available"
      continue
    fi

    echo "creating release for ${version}"
    ${DRY_RUN:-} gh workflow run release.yaml -f version="${version}"_debug -R "${targetGitHubRepository}"
    ${DRY_RUN:-} gh workflow run release.yaml -f version="${version}" -R "${targetGitHubRepository}"
  done
done
