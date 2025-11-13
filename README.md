# linins
One-file bootstrapper that installs curated package bundles (and optional tooling such as Docker or Tailscale) on Debian/Ubuntu systems using `apt`.

## Repository layout
- `install.sh` – main installer; downloads the bundle lists and installs each package.
- `packages/*.txt` – bundle definitions. Lines starting with `#` are comments; everything else is treated as an `apt` package name.

## Running the installer
### 1. Clone and execute locally
```bash
git clone git@github.com:njinco/linins.git
cd linins
chmod +x install.sh
./install.sh --bundles base,desktop --with-docker
```

### 2. One-liner (remote execution)
```bash
curl -fsSL https://raw.githubusercontent.com/njinco/linins/main/install.sh | bash -s -- \
  --bundles base,server --with-tailscale
```
Set `RAW_BASE_URL` if the package lists live somewhere other than the default (`https://raw.githubusercontent.com/njinco/linins/main`):
```bash
curl -fsSL https://example.com/install.sh | RAW_BASE_URL=https://example.com bash
```

## Running from a private repo
`raw.githubusercontent.com` respects GitHub authentication headers, so you can access the installer without making the repo public.

1. Generate a classic PAT with at least `repo` scope (or run `gh auth token` if you use GitHub CLI).
2. Export the token before curling the script:
   ```bash
   export GITHUB_TOKEN="$(gh auth token)"   # or set your PAT manually
   curl -H "Authorization: Bearer $GITHUB_TOKEN" \
        -fsSL https://raw.githubusercontent.com/njinco/linins/main/install.sh |
        RAW_BASE_URL=https://raw.githubusercontent.com/njinco/linins/main \
        bash -s -- --bundles base,dev
   ```
3. The same header must be used for any subsequent requests (the script automatically pulls each `packages/*.txt` from `RAW_BASE_URL`, so no additional steps are needed once the environment variable is set).

If you prefer SSH access, you can also tunnel the file through `gh`:
```bash
gh api repos/njinco/linins/contents/install.sh --jq '.content' | base64 -d | bash
```

## Configuration knobs
- `--bundles base,desktop` or `BUNDLES="base,desktop"`: comma-separated list of bundle files to install (see `packages/`).
- `--with-docker` or `WITH_DOCKER=1`: installs Docker Engine + Compose plugin.
- `--with-tailscale` or `WITH_TAILSCALE=1`: installs the official Tailscale package.
- `RAW_BASE_URL`: root URL hosting `install.sh` + `packages/`. Override this when mirroring or hosting elsewhere.

The script deduplicates packages across bundles and runs apt in non-interactive mode. You can edit any of the `packages/*.txt` files and rerun the installer to converge on the new state.

## Adding or changing bundles
1. Create/modify the relevant file under `packages/` (e.g., `packages/devops.txt`).
2. Commit/push the change.
3. Re-run the installer with `BUNDLES="base,devops"` (or use `--bundles base,devops`).

Because `install.sh` only relies on static text files, you can fork this repo, adjust package selections, and point `RAW_BASE_URL` to your fork for team-specific setups.
