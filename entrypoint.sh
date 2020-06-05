#!/bin/sh

set -u
set -e

DEFAULT_POLL_TIMEOUT=10
POLL_TIMEOUT=${POLL_TIMEOUT:-$DEFAULT_POLL_TIMEOUT}

git checkout "${GITHUB_REF:11}"

branch=${GITHUB_REPOSITORY}/$(git symbolic-ref --short HEAD)

sh -c "git config --global credential.username $GITLAB_USERNAME"
sh -c "git config --global core.askPass /cred-helper.sh"
sh -c "git config --global credential.helper cache"
sh -c "git remote add mirror $*"
sh -c "echo pushing to $branch branch at $(git remote get-url --push mirror)"
sh -c "git push -f mirror HEAD:$branch"

sleep $POLL_TIMEOUT

# convert slashes in a HTML-compatible way
branch=${branch//\//%2F}

pipeline_id=$(curl --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/repository/commits/${branch}" | jq '.last_pipeline.id')

echo "Triggered CI for branch ${branch}"
echo "Working with pipeline id #${pipeline_id}"
echo "Poll timeout set to ${POLL_TIMEOUT}"

ci_status="pending"

until [[ "$ci_status" != "pending" && "$ci_status" != "running" ]]
do
   sleep $POLL_TIMEOUT
   ci_output=$(curl --header "PRIVATE-TOKEN: $GITLAB_PASSWORD" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/pipelines/${pipeline_id}")
   ci_status=$(jq -n "$ci_output" | jq -r .status)
   ci_web_url=$(jq -n "$ci_output" | jq -r .web_url)
   
   echo "Current pipeline status: ${ci_status}"
   if [ "$ci_status" = "running" ]
   then
     echo "Checking pipeline status..."
     curl -d '{"state":"pending", "target_url": "'${ci_web_url}'", "context": "gitlab-ci"}' -H "Authorization: token ${GITHUB_TOKEN}"  -H "Accept: application/vnd.github.antiope-preview+json" -X POST --silent "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}"  > /dev/null 
   fi
done

echo "Pipeline finished with status ${ci_status}"
  
if [ "$ci_status" = "success" ]
then 
  curl -d '{"state":"success", "target_url": "'${ci_web_url}'", "context": "gitlab-ci"}' -H "Authorization: token ${GITHUB_TOKEN}"  -H "Accept: application/vnd.github.antiope-preview+json" -X POST --silent "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" 
  job_id=$(curl --header "PRIVATE-TOKEN: ${GITLAB_PASSWORD}" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/pipelines/${pipeline_id}/jobs" | jq .[0].id)
  echo "job_id is ${job_id}"
  results=$(curl --location --header "PRIVATE-TOKEN: ${GITLAB_PASSWORD}" --silent "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/jobs/${job_id}/artifacts/branch_hash")
  echo "results is ${results}"

  exit 0
elif [ "$ci_status" = "failed" ]
then 
  curl -d '{"state":"failure", "target_url": "'${ci_web_url}'", "context": "gitlab-ci"}' -H "Authorization: token ${GITHUB_TOKEN}"  -H "Accept: application/vnd.github.antiope-preview+json" -X POST --silent "https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" 
  exit 1
fi
