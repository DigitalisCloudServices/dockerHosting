# Known Complexity Issues

The following functions currently exceed complexity limits and should be refactored:

## Functions >30 lines (max 30)

- `setup.sh:92` - `setup_sudo_user` (36 lines)
- `deploy-site.sh:181` - `decrypt_artifact` (39 lines)
- `scripts/install-traefik.sh:77` - `_migrate_one_site` (36 lines)
- `scripts/setup-secret-scan.sh:41` - `install_gitleaks` (43 lines)
- `lib/gcs.sh:15` - `_gcs_access_token_uncached` (47 lines)
- `lib/update-site.sh:308` - `_download_artifact` (163 lines) ⚠️ **Priority**

## Refactoring Recommendations

### High Priority

**`_download_artifact` (163 lines)** - This function handles multiple storage types (GCS, HTTP, local) and should be split into:
- `_download_gcs_artifact`
- `_download_http_artifact`
- `_setup_local_artifact`

### Medium Priority

**`_gcs_access_token_uncached` (47 lines)** - Split JWT generation and token exchange into separate functions.

**`install_gitleaks` (43 lines)** - Extract architecture detection and checksum verification into helper functions.

**`decrypt_artifact` (39 lines)** - Extract signature verification and decryption into separate functions.

### Low Priority

Functions 31-36 lines are borderline and can be addressed as part of natural maintenance.

## Running Quality Checks

```bash
# Run all quality checks (will fail on these known issues)
make test-all

# Run just required tests (passes)
make test

# Run individual quality checks
make test-complexity
make test-unused
make test-docs
```
