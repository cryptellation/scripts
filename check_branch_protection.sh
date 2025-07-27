#!/bin/bash

# Script to check and fix branch protection rules for all cryptellation repositories
# This ensures all CI jobs in .github/workflows/ci.yaml are mandatory for merging

set -e

GITHUB_TOKEN=$(gh auth token)
ORG="cryptellation"
DEFAULT_BRANCH="main"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to get repositories with CI workflows from workspace
get_repos_with_ci() {
    local workspace_dir="../"
    local repos=()
    
    # Find all directories in the workspace that have CI workflows
    for dir in "$workspace_dir"*/; do
        if [[ -d "$dir" ]]; then
            local repo_name=$(basename "$dir")
            local ci_file="$dir/.github/workflows/ci.yaml"
            
            # Check if this directory has a CI workflow
            if [[ -f "$ci_file" ]]; then
                repos+=("$repo_name")
            fi
        fi
    done
    
    echo "${repos[@]}"
}

# Get repositories with CI workflows
REPOS=($(get_repos_with_ci))

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get CI job names from a repository's ci.yaml
get_ci_jobs() {
    local repo=$1
    local ci_file="../$repo/.github/workflows/ci.yaml"
    
    if [[ ! -f "$ci_file" ]]; then
        log_warning "CI file not found for $repo"
        return 1
    fi
    
    # Extract job names that run on pull requests (look for name: field under jobs)
    awk '/^  [a-zA-Z0-9_-]+:$/ { job_key=$1; gsub(/:/, "", job_key) } /^    name:/ { if (job_key != "") { gsub(/^[[:space:]]*name:[[:space:]]*/, ""); print } }' "$ci_file" | grep -v "publish" | grep -v "Publish" || true
}

# Function to get actual job names from recent workflow runs
get_actual_job_names() {
    local repo=$1
    
    # Get the most recent workflow run
    local run_id=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$ORG/$repo/actions/runs?per_page=1" | \
        jq -r '.workflow_runs[0].id' 2>/dev/null)
    
    if [[ "$run_id" == "null" || -z "$run_id" ]]; then
        return 1
    fi
    
    # Get job names from that run
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$ORG/$repo/actions/runs/$run_id/jobs" | \
        jq -r '.jobs[].name' 2>/dev/null | grep -v "publish" | grep -v "Publish" || true
}

# Function to check current branch protection rules
check_branch_protection() {
    local repo=$1
    local response
    
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$ORG/$repo/branches/$DEFAULT_BRANCH/protection" 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to check branch protection for $repo"
        return 1
    fi
    
    # Check if branch protection exists
    if echo "$response" | grep -q '"message":"Not Found"'; then
        echo "none"
        return 0
    fi
    
    # Extract required status checks
    echo "$response" | jq -r '.required_status_checks.contexts[]?' 2>/dev/null || echo ""
}

# Function to set branch protection rules
set_branch_protection() {
    local repo=$1
    local jobs_json=$2
    
    local protection_data=$(cat <<EOF
{
  "required_status_checks": {
    "strict": false,
    "contexts": $jobs_json
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0
  },
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
)

    local response=$(curl -s -X PUT \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$protection_data" \
        "https://api.github.com/repos/$ORG/$repo/branches/$DEFAULT_BRANCH/protection")
    
    if echo "$response" | grep -q '"message":"Not Found"'; then
        log_error "Repository $repo not found or no access"
        return 1
    fi
    
    if echo "$response" | grep -q '"message":"Bad credentials"'; then
        log_error "Bad credentials for $repo"
        return 1
    fi
    
    log_success "Branch protection updated for $repo"
    return 0
}

# Main execution
main() {
    log_info "Checking branch protection rules for all repositories..."
    echo
    
    local total_repos=${#REPOS[@]}
    local fixed_count=0
    local already_ok_count=0
    local error_count=0
    
    for repo in "${REPOS[@]}"; do
        log_info "Checking $repo..."
        
        # Get CI jobs for this repository
        local ci_jobs=($(get_ci_jobs "$repo"))
        
        if [[ ${#ci_jobs[@]} -eq 0 ]]; then
            log_warning "No CI jobs found for $repo, skipping..."
            continue
        fi
        
        # Get actual job names from recent workflow runs
        local actual_jobs=($(get_actual_job_names "$repo"))
        
        if [[ ${#actual_jobs[@]} -eq 0 ]]; then
            log_warning "No recent workflow runs found for $repo, using expected jobs"
            actual_jobs=("${ci_jobs[@]}")
        fi
        
        # Check current branch protection
        local current_checks=($(check_branch_protection "$repo"))
        
        if [[ "$current_checks" == "none" ]]; then
            log_warning "No branch protection found for $repo"
        else
            log_info "Current required checks: ${current_checks[*]}"
        fi
        
        # Convert actual jobs to JSON array
        local jobs_json=$(printf '%s\n' "${actual_jobs[@]}" | jq -R . | jq -s .)
        
        # Check if all actual jobs are required
        local missing_jobs=()
        for job in "${actual_jobs[@]}"; do
            if [[ ! " ${current_checks[*]} " =~ " ${job} " ]]; then
                missing_jobs+=("$job")
            fi
        done
        
        if [[ ${#missing_jobs[@]} -gt 0 ]]; then
            log_warning "Missing required checks for $repo: ${missing_jobs[*]}"
            log_info "Setting branch protection for $repo..."
            
            if set_branch_protection "$repo" "$jobs_json"; then
                ((fixed_count++))
            else
                ((error_count++))
            fi
        else
            log_success "Branch protection already correctly configured for $repo"
            ((already_ok_count++))
        fi
        
        echo
    done
    
    # Summary
    echo "=========================================="
    log_info "Summary:"
    log_success "Already correctly configured: $already_ok_count"
    log_success "Fixed: $fixed_count"
    log_error "Errors: $error_count"
    log_info "Total repositories checked: $total_repos"
    echo "=========================================="
}

# Run the script
main "$@" 