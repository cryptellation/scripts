# Cryptellation Scripts

Scripts used to manage Cryptellation system

## Branch Protection Management

This repository contains scripts to manage branch protection rules across all Cryptellation repositories.

### Scripts

- **`check_branch_protection.sh`** - Sets up branch protection rules for all repositories
- **`verify_branch_protection.sh`** - Verifies the current status of branch protection rules

### Usage

From the scripts directory:

```bash
# Check and fix branch protection rules
./check_branch_protection.sh

# Verify current status
./verify_branch_protection.sh
```

### What These Scripts Do

These scripts ensure that all CI jobs defined in `.github/workflows/ci.yaml` files are mandatory for merging pull requests. They:

1. Extract CI job names from workflow files
2. Check current branch protection settings
3. Set required status checks for all relevant CI jobs
4. Enable additional protection features (admin enforcement, PR reviews, etc.)
5. Provide detailed reporting and verification

### Requirements

- GitHub CLI (`gh`) installed and authenticated
- Access to all Cryptellation repositories
- `jq` for JSON parsing
- `curl` for API calls

### Repository Structure

The scripts expect to be run from the `scripts` directory with other Cryptellation repositories in the parent directory.
