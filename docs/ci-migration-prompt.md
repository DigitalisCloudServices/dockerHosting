# CI Migration Prompt — Structured Channel Metadata

Use this prompt with AI to migrate site repository CI workflows to the new structured channel metadata format.

---

## Migration Task

**Objective**: Update the GitHub Actions CI workflow to generate channel metadata in the new structured format.

**Context**: The dockerHosting infrastructure has migrated from a simple path-based artifact metadata format to a structured format that explicitly declares storage backend, signing, and encryption for each artifact. This provides better flexibility for multi-cloud deployments and per-artifact security settings.

### Old Format (deprecated)

```json
{
  "infra_artifact": "infra-abc123.tar.gz",
  "infra_hash": "abc123def456...",
  "artifacts": [
    { "name": "frontend", "artifact": "frontend-def456.tar.gz", "git_hash": "def456abc789..." }
  ],
  "lifecycle_hooks": [...],
  "promoted_at": "2026-05-06T14:00:00Z",
  "github_run_id": "12345"
}
```

### New Format (required)

```json
{
  "infra": {
    "git_hash": "abc123def456...",
    "signed": true,
    "encrypted": true,
    "type": "gcs",
    "bucket": "my-bucket-name",
    "path": "prefix/infra/abc123def456.tar.gz"
  },
  "artifacts": [
    {
      "name": "frontend",
      "git_hash": "def456abc789...",
      "signed": true,
      "encrypted": true,
      "type": "gcs",
      "bucket": "my-bucket-name",
      "path": "prefix/frontend/def456abc789.tar.gz"
    }
  ],
  "lifecycle_hooks": [...],
  "promoted_at": "2026-05-06T14:00:00Z",
  "github_run_id": "12345"
}
```

### Field Mapping

| Old Field | New Location | Notes |
|-----------|--------------|-------|
| `infra_artifact` | `infra.path` (basename) | Now includes full path within bucket |
| `infra_hash` | `infra.git_hash` | Renamed for clarity |
| `artifacts[].artifact` | `artifacts[].path` (basename) | Now includes full path |
| `artifacts[].git_hash` | `artifacts[].git_hash` | Unchanged |

### New Fields

- `type`: Storage backend (`gcs`, `http`, `https`, `local`)
- `bucket`: GCS bucket name (without `gs://` prefix) — only for `type: gcs`
- `path`: Full path to a tar.gz file within bucket — only for `type: gcs`
- `url`: Full HTTPS URL — only for `type: http` or `https`
- `directory`: Absolute filesystem path to pre-existing directory — only for `type: local`
- `signed`: Boolean (default `true`) — artifact includes RSA signature (not applicable to `type: local`)
- `encrypted`: Boolean (default `true`) — artifact content is AES-encrypted (not applicable to `type: local`)

**Note**: For `type: local`, the directory must already exist on the server filesystem (e.g., NFS mount, external dependency).

### Storage Type Examples

**GCS with tar.gz file (most common)**:
```json
{
  "type": "gcs",
  "bucket": "my-artifacts-bucket",
  "path": "myproject/frontend/abc123.tar.gz"
}
```

**HTTP (public CDN)**:
```json
{
  "type": "http",
  "url": "https://cdn.example.com/frontend-abc123.tar.gz"
}
```

**Local directory (external dependencies)**:
```json
{
  "type": "local",
  "directory": "/mnt/nfs/wordpress-plugins"
}
```

### When to Use Each Storage Type

- **`type: gcs` with `path`** — Download a tar.gz from GCS (most common, supports signing/encryption)
- **`type: http` with `url`** — Download a tar.gz from a public URL (for CDN-hosted artifacts)
- **`type: local` with `directory`** — Use a pre-existing local directory (NFS mount, external dependency managed outside the release process)

For `type: local`, the artifact is **not downloaded** — it's expected to already exist on the filesystem. This is useful for:
- NFS-mounted shared storage
- Externally managed dependencies (e.g., WordPress plugin directories)
- Static resources that don't change with releases

### Security Defaults

By default, all artifacts are:
- `signed: true` — requires `--artifact-signing-pub-key-file` at deployment
- `encrypted: true` — requires `--artifact-aes-key-file` at deployment

For public artifacts (e.g., hosted on a CDN), set both to `false`:
```json
{
  "name": "frontend",
  "git_hash": "abc123...",
  "signed": false,
  "encrypted": false,
  "type": "http",
  "url": "https://cdn.example.com/frontend-abc123.tar.gz"
}
```

For local directory artifacts, signing and encryption are not applicable (set to `false` or omit):
```json
{
  "name": "plugins",
  "git_hash": "external",
  "signed": false,
  "encrypted": false,
  "type": "local",
  "directory": "/mnt/nfs/wordpress-plugins"
}
```

---

## Instructions for AI

1. **Locate the workflow file** (likely `.github/workflows/deploy.yml` or similar)
2. **Find the channel metadata generation step** — look for where `infra-latest.json`, `prod-latest.json`, or similar is created
3. **Update the JSON structure** to match the new format:
   - Nest `infra_artifact` and `infra_hash` under `infra` object
   - Add `signed`, `encrypted`, `type`, `bucket`, `path` to `infra`
   - Add `signed`, `encrypted`, `type`, `bucket`, `path` to each artifact in `artifacts` array
4. **Set bucket and path** based on current GCS upload configuration
   - Extract bucket name from current `gsutil cp` or `gcloud storage cp` commands
   - Include any prefix (e.g., `myproject/`) in the `path` field
5. **Set security flags** based on current artifact processing:
   - If artifacts are encrypted and signed: `"signed": true, "encrypted": true`
   - If artifacts are public/unencrypted: `"signed": false, "encrypted": false`
6. **Preserve lifecycle_hooks** — this array should remain unchanged
7. **Test the changes** — ensure the generated JSON validates and all fields are present

### Example Transformation

If the current workflow has:
```yaml
- name: Promote channel metadata
  run: |
    jq -n \
      --arg infra_artifact "infra-${GIT_HASH}.tar.gz" \
      --arg infra_hash "${GIT_HASH}" \
      '{
        infra_artifact: $infra_artifact,
        infra_hash: $infra_hash,
        artifacts: [],
        lifecycle_hooks: [],
        promoted_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        github_run_id: env.GITHUB_RUN_ID
      }' > channel.json
    gsutil cp channel.json gs://my-bucket/channels/prod-latest.json
```

Transform it to:
```yaml
- name: Promote channel metadata
  run: |
    jq -n \
      --arg git_hash "${GIT_HASH}" \
      --arg bucket "my-bucket" \
      --arg path "infra/${GIT_HASH}.tar.gz" \
      '{
        infra: {
          git_hash: $git_hash,
          signed: true,
          encrypted: true,
          type: "gcs",
          bucket: $bucket,
          path: $path
        },
        artifacts: [],
        lifecycle_hooks: [],
        promoted_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        github_run_id: env.GITHUB_RUN_ID
      }' > channel.json
    gsutil cp channel.json gs://my-bucket/channels/prod-latest.json
```

### If Using Python for Metadata Generation

```python
import json
import datetime

metadata = {
    "infra": {
        "git_hash": git_hash,
        "signed": True,
        "encrypted": True,
        "type": "gcs",
        "bucket": "my-artifacts-bucket",
        "path": f"myproject/infra/{git_hash}.tar.gz"
    },
    "artifacts": [
        {
            "name": "frontend",
            "git_hash": frontend_hash,
            "signed": True,
            "encrypted": True,
            "type": "gcs",
            "bucket": "my-artifacts-bucket",
            "path": f"myproject/frontend/{frontend_hash}.tar.gz"
        },
        # Optional: local directory for external dependencies
        # {
        #     "name": "plugins",
        #     "git_hash": "external",
        #     "signed": False,
        #     "encrypted": False,
        #     "type": "local",
        #     "directory": "/mnt/nfs/wordpress-plugins"
        # }
    ],
    "lifecycle_hooks": lifecycle_hooks,  # From infra/lifecycle-hooks.json
    "promoted_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "github_run_id": os.environ["GITHUB_RUN_ID"]
}

with open("channel.json", "w") as f:
    json.dump(metadata, f, indent=2)
```

---

## Verification

After migration, verify the channel metadata contains:

1. ✅ `infra` object with: `git_hash`, `signed`, `encrypted`, `type`, `bucket`, `path`
2. ✅ Each artifact in `artifacts` array has: `name`, `git_hash`, `signed`, `encrypted`, `type`, `bucket`, `path`
3. ✅ `lifecycle_hooks` array preserved (if it existed)
4. ✅ `promoted_at` and `github_run_id` fields present

Test deployment with:
```bash
sudo /opt/dockerHosting/deploy-site.sh \
  --site-name test-site \
  --gcs-bucket gs://my-bucket \
  --gcs-key-file /path/to/gcs-key.json \
  --channel prod-latest
```

---

## Common Issues

**Issue**: Deployment fails with "channel metadata is missing infra"
**Solution**: Ensure `infra` is a top-level object, not `infra_artifact` string

**Issue**: "Unsupported storage type" error
**Solution**: Ensure `type` field is exactly `"gcs"`, `"http"`, or `"https"` (lowercase)

**Issue**: 404 when downloading artifacts
**Solution**: Verify `bucket` and `path` match the actual GCS upload location

**Issue**: "AES key required" error but artifact is unencrypted
**Solution**: Set `"encrypted": false` in the channel metadata
