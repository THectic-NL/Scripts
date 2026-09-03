# Testing the Enhanced Automated Dependency Management

This document explains how to test the improved automated dependency management system.

## Overview

The enhanced workflow now automatically:
1. Extracts version information from dependency update issues
2. Updates version numbers in installer files
3. Creates and commits changes to a new branch
4. Opens a Pull Request with actual code modifications
5. Links the PR to the original issue

## Testing with Issue #48

Issue #48 is a perfect test case for the Ansible dependency updates:
- **Python**: 3.14.2 → 3.14.3
- **Ansible**: 13.3.0 → 13.5.0

### Method 1: Manually Trigger via GitHub Actions UI

1. Go to the [Actions tab](https://github.com/Thectic-NL/Scripts/actions)
2. Select "Auto-Update Dependencies" workflow
3. Click "Run workflow"
4. Enter issue number: `48`
5. Click "Run workflow" button

### Method 2: Trigger by Editing the Issue

The workflow automatically runs when dependency issues are opened or edited:

1. Go to [Issue #48](https://github.com/Thectic-NL/Scripts/issues/48)
2. Click "Edit" on the issue
3. Add a space or make any minor edit to the description
4. Save the changes

The workflow will automatically trigger.

### Method 3: Using GitHub CLI (with proper authentication)

```bash
gh workflow run auto-update-dependencies.yml -f issue_number=48
```

## Expected Behavior

When the workflow runs successfully:

1. **Version Extraction**: The workflow parses issue #48 and extracts:
   ```
   Python: 3.14.2 → 3.14.3
   Ansible: 13.3.0 → 13.5.0
   ```

2. **File Updates**: Automatically modifies `ansible/ansible_installer.sh`:
   - Updates `BUILD_PYTHON_VERSION:-3.14.2` to `BUILD_PYTHON_VERSION:-3.14.3`
   - Updates `pip install ansible==13.3.0` to `pip install ansible==13.5.0`

3. **Branch Creation**: Creates a new branch like `automated-update/ansible-1743422410`

4. **Commit**: Creates a commit with message:
   ```
   chore: update Ansible dependencies

   - Python: 3.14.2 → 3.14.3
   - Ansible: 13.3.0 → 13.5.0

   Automated update from issue #48
   ```

5. **PR Creation**: Opens a PR with:
   - Title: "🔄 Update Ansible Dependencies"
   - Body containing changelog, files updated, and testing checklist
   - Labels: `dependencies`, `automated`, `ansible`
   - Status: Ready for review (not draft, unlike NGINX PRs)

6. **Issue Comment**: Adds a comment to issue #48:
   ```
   🤖 Automated PR Created

   A pull request has been created with automated dependency updates: #XX

   The changes have been automatically applied. Please review and test before merging.
   ```

7. **PR Closes Issue**: The PR body includes `Closes #48`, so merging the PR will automatically close the issue.

## Verification Steps

After the workflow completes:

1. **Check the PR**: Verify the actual code changes in the Files tab
2. **Review the commit**: Ensure version numbers are correct
3. **Test the installer**: Clone the PR branch and run:
   ```bash
   git fetch origin automated-update/ansible-XXXXX
   git checkout automated-update/ansible-XXXXX
   ./ansible/ansible_installer.sh
   ```
4. **Verify versions**: After installation, check:
   ```bash
   python3 --version  # Should show 3.14.3
   ansible --version  # Should show 13.5.0
   ```

## NGINX Updates (Different Flow)

For NGINX updates, the workflow behavior is different:

1. **Draft PR**: NGINX PRs are marked as draft because they require SHA256 checksum verification
2. **Manual Step Required**: Use the helper script to update checksums:
   ```bash
   ./.github/scripts/update-nginx-checksums.sh
   ```
3. **Review and Mark Ready**: After checksums are updated, mark the PR as ready for review

## Troubleshooting

### Workflow Doesn't Trigger

- Ensure the issue has the `dependencies` label
- Ensure the issue title contains "Update Available"
- Check the workflow runs in the Actions tab for any errors

### PR Not Created

- Check workflow logs in the Actions tab
- Look for errors in the "Parse issue and update dependencies" step
- Verify the issue body format matches expected patterns

### Version Regex Not Matching

The workflow expects version information in this format:
```
- **ComponentName**: current_version → latest_version
```

Examples:
```
- **Python**: 3.14.2 → 3.14.3
- **NGINX**: 1.29.7 → 1.29.8
- **OpenSSL**: 3.6.1 → 3.6.2
```

## Success Criteria

The automated dependency management is working correctly when:

1. ✅ Workflow triggers automatically on issue creation/edit
2. ✅ Version information is correctly extracted from issues
3. ✅ Installer files are modified with correct version numbers
4. ✅ PRs are created with actual code changes (not empty branches)
5. ✅ NGINX PRs are marked as draft
6. ✅ Ansible/Kubernetes PRs are ready to merge
7. ✅ Issues and PRs are properly linked
8. ✅ Comments are added to issues when PRs are created
9. ✅ All files are committed and pushed successfully

## Next Steps

After successful testing with issue #48:

1. Monitor for new dependency updates
2. Review and merge automatically created PRs
3. Verify that merged PRs close their associated issues
4. Watch for the next weekly dependency check (every Monday at 9:00 AM UTC)
