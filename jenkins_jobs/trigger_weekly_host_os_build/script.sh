set -e

MAIN_REPO_URL_PREFIX="ssh://git@github.com/${GITHUB_ORGANIZATION_NAME}"
PUSH_REPO_URL_PREFIX="ssh://git@github.com/${GITHUB_BOT_USER_NAME}"

BUILDS_WORKSPACE_DIR="/var/lib/host-os"
REPOSITORIES_PATH="${BUILDS_WORKSPACE_DIR}/repositories"

VERSIONS_REPO_NAME="versions"
VERSIONS_MAIN_REPO_URL="${MAIN_REPO_URL_PREFIX}/${VERSIONS_REPO_NAME}.git"
VERSIONS_PUSH_REPO_URL="${PUSH_REPO_URL_PREFIX}/${VERSIONS_REPO_NAME}.git"
UPDATED_VERSIONS_REPO_PATH="${REPOSITORIES_PATH}/${VERSIONS_REPO_NAME}_update-versions"

GITHUB_IO_REPO_NAME="${GITHUB_ORGANIZATION_NAME}.github.io"
GITHUB_IO_MAIN_REPO_URL="${MAIN_REPO_URL_PREFIX}/${GITHUB_IO_REPO_NAME}.git"
GITHUB_IO_PUSH_REPO_URL="${PUSH_REPO_URL_PREFIX}/${GITHUB_IO_REPO_NAME}.git"
GITHUB_IO_REPO_PATH="${REPOSITORIES_PATH}/${GITHUB_IO_REPO_NAME}"

BUILDS_REPO_NAME="builds"
BUILDS_REPO_PATH="."

RELEASE_DATE=$(date +%Y-%m-%d)
COMMIT_BRANCH="weekly-${RELEASE_DATE}"


# the GITHUB_USER_NAME and GITHUB_PASSWORD variables below refer to
# the credentials owner, which is not necessarily the same as the
# source repo owner - GITHUB_BOT_USER_NAME in this case
alias github="github_api $GITHUB_USER_NAME $GITHUB_PASSWORD"

create_pull_request() {
    local dest_repo=$1

    # the 'eval' sets the variable 'pr_number' to the number of the
    # new pull-request
    eval $(github open_pr "Weekly build" "${GITHUB_BOT_USER_NAME}:${COMMIT_BRANCH}" \
          "${GITHUB_ORGANIZATION_NAME}/${dest_repo}" "master" || echo "exit 1")
}

write_comment() {
    local comment_text="$1"

    github write_comment "${GITHUB_ORGANIZATION_NAME}/$VERSIONS_REPO_NAME" \
       "$pr_number" "$comment_text"
}

get_build_state(){
    local target_context="Build Host OS"

    # this will evaluate the queried keys as variables: state=<state>,
    # target_url=<url>
    eval $(github_api "$GITHUB_USER_NAME" "$GITHUB_PASSWORD" \
                      query_status "${GITHUB_ORGANIZATION_NAME}/$VERSIONS_REPO_NAME" \
                      "$VERSIONS_PR_NUMBER" "$target_context" --state \
                      --target-url || echo "exit 1")
}

get_pr_state(){
    local pr_number=$1
    local repo=$2

    # this will evaluate the queried keys as variables: state=<state>,
    # title=<title>
    eval $(github_api "$GITHUB_USER_NAME" "$GITHUB_PASSWORD" \
                      query_pr "${GITHUB_ORGANIZATION_NAME}/$repo" \
                      "$pr_number" --state --title --merged || echo "exit 1")
}

update_versions() {
    python host_os.py \
           --verbose \
           --work-dir $BUILDS_WORKSPACE_DIR \
           update-versions \
               --packages-metadata-repo-url "$VERSIONS_MAIN_REPO_URL" \
               --packages-metadata-repo-branch "$VERSIONS_REPOSITORY_BRANCH" \
               --updater-name "$GITHUB_BOT_NAME" \
               --updater-email "$GITHUB_BOT_EMAIL" \
               --push-repo-url "$VERSIONS_PUSH_REPO_URL" \
               --push-repo-branch "$COMMIT_BRANCH"
}

create_release_notes() {
    python host_os.py \
           --verbose \
           --work-dir $BUILDS_WORKSPACE_DIR \
           build-release-notes \
               --packages-metadata-repo-url "$VERSIONS_MAIN_REPO_URL" \
               --packages-metadata-repo-branch "$VERSIONS_REPO_COMMIT" \
               --release-notes-repo-url "$GITHUB_IO_MAIN_REPO_URL" \
               --updater-name "$GITHUB_BOT_NAME" \
               --updater-email "$GITHUB_BOT_EMAIL" \
               --push-repo-url "$GITHUB_IO_PUSH_REPO_URL" \
               --push-repo-branch "$COMMIT_BRANCH"
}

wait_pull_request_merge() {
    local pr_number=$1
    local repo=$2

    get_pr_state $pr_number $repo
    while [ $state == "open" ]; do
        echo "Waiting for pull-request ${pr_number}: $title to be merged..."
        sleep 1m
        get_pr_state $pr_number $repo
    done

    if [ $merged == "False" ]; then
        echo "Pull-request $pr_number is closed but wasn't merged, aborting..."
        exit 1
    fi
}

fetch_build_info() {
    get_build_state
    local artifacts_src_build_number=$(basename $target_url)
    local artifacts_url=$(basename $JENKINS_URL):${JENKINS_HOME}/jobs/build_host_os/builds/${artifacts_src_build_number}/archive

    rsync -e "ssh -i ${HOME}/.ssh/jenkins_id_rsa" \
              --verbose --compress --stats --times --perms \
              $artifacts_url/BUILD_TIMESTAMP \
              $artifacts_url/BUILDS_REPO_COMMIT \
              $artifacts_url/VERSIONS_REPO_COMMIT .

    BUILD_TIMESTAMP=$(cat BUILD_TIMESTAMP)
    BUILDS_REPO_COMMIT=$(cat BUILDS_REPO_COMMIT)
    VERSIONS_REPO_COMMIT=$(cat VERSIONS_REPO_COMMIT)
}

create_symlinks() {
    local build_dir_path="../to_build/$BUILD_TIMESTAMP"

    ln -s "$build_dir_path" "$RELEASE_DATE"
    ln -s "$RELEASE_DATE" latest

    rsync -e "ssh -i $HOME/.ssh/${UPLOAD_SERVER_USER_NAME}_id_rsa" \
          --verbose --compress --links --times --chmod=a+rwx,g+rwx,o- \
          "$RELEASE_DATE" "latest" \
          "${UPLOAD_SERVER_USER_NAME}@${UPLOAD_SERVER_HOST_NAME}:${UPLOAD_SERVER_WEEKLY_DIR}/"
}

tag_git_repos() {
    local repos_paths=$@
    local version_file="${UPDATED_VERSIONS_REPO_PATH}/VERSION"
    local tag_name="$(cat $version_file | tail -1)-${RELEASE_DATE}"

    for repo_path in ${repos_paths[@]}; do
        pushd $repo_path
        git tag $tag_name
        git push origin $tag_name
        popd
    done
}

update_versions
create_pull_request $VERSIONS_REPO_NAME
VERSIONS_PR_NUMBER=$pr_number

write_comment "$BUILD_ISO_TRIGGER_PHRASE"

wait_pull_request_merge $VERSIONS_PR_NUMBER $VERSIONS_REPO_NAME

fetch_build_info

# checkout the builds repo commit that was used by the build job
# because the branch might have moved during the time it takes to
# generate the build
git checkout $BUILDS_REPO_COMMIT

create_release_notes
create_pull_request $GITHUB_IO_REPO_NAME
GITHUB_IO_PR_NUMBER=$pr_number

wait_pull_request_merge $GITHUB_IO_PR_NUMBER $GITHUB_IO_REPO_NAME

create_symlinks
tag_git_repos $UPDATED_VERSIONS_REPO_PATH $GITHUB_IO_REPO_PATH $BUILDS_REPO_PATH
