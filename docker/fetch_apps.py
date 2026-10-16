#!/usr/bin/env python3
"""
Automated Frappe Apps Fetcher & Cloner
Supports public & private repositories via:
  1. Docker BuildKit SSH Agent Forwarding (--ssh default)
  2. BuildKit Secret Mount (--secret id=git_token)
  3. Build Args (GITHUB_TOKEN / GIT_TOKEN)
  4. apps.json file or APPS_JSON_BASE64 / APPS_JSON environment variables
"""

import base64
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


def run_cmd(cmd, env=None, check=True):
    print(f"[fetch_apps] Running: {cmd}")
    result = subprocess.run(cmd, shell=True, env=env, capture_output=True, text=True)
    if result.returncode != 0 and check:
        print(f"[fetch_apps] ERROR: Command failed with code {result.returncode}", file=sys.stderr)
        if result.stdout:
            print(f"[fetch_apps] stdout: {result.stdout}", file=sys.stderr)
        if result.stderr:
            print(f"[fetch_apps] stderr: {result.stderr}", file=sys.stderr)
        sys.exit(result.returncode)
    return result


def setup_ssh():
    ssh_dir = Path.home() / ".ssh"
    ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    # Disable strict host key checking prompt for common git providers
    known_hosts = ssh_dir / "known_hosts"
    print("[fetch_apps] Populating SSH known_hosts for GitHub, GitLab, and Bitbucket...")
    run_cmd(
        "ssh-keyscan -t ed25519,rsa github.com gitlab.com bitbucket.org >> " + str(known_hosts),
        check=False,
    )

    # Configure git to use SSH with non-interactive batch mode
    run_cmd('git config --global core.sshCommand "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"')


def get_git_token():
    # 1. Check BuildKit secret mounts
    for secret_path in [
        Path("/run/secrets/git_token"),
        Path("/run/secrets/github_token"),
        Path("/run/secrets/token"),
    ]:
        if secret_path.is_file():
            token = secret_path.read_text().strip()
            if token:
                print(f"[fetch_apps] Loaded git token from secret mount: {secret_path}")
                return token

    # 2. Check environment variables
    for env_var in ["GIT_TOKEN", "GITHUB_TOKEN", "GITLAB_TOKEN"]:
        token = os.environ.get(env_var, "").strip()
        if token:
            print(f"[fetch_apps] Loaded git token from environment variable: {env_var}")
            return token

    return None


def setup_git_credentials(token):
    if not token:
        return

    print("[fetch_apps] Configuring Git credential rewriting for private HTTPS repositories...")
    # Rewrite https://github.com/ to include token
    run_cmd(f'git config --global url."https://x-access-token:{token}@github.com/".insteadOf "https://github.com/"')
    run_cmd(f'git config --global url."https://oauth2:{token}@gitlab.com/".insteadOf "https://gitlab.com/"')


def load_apps_list():
    # 1. Check base64-encoded environment variable (common in CI/CD)
    b64_apps = os.environ.get("APPS_JSON_BASE64", "").strip()
    if b64_apps:
        try:
            decoded = base64.b64decode(b64_apps).decode("utf-8")
            print("[fetch_apps] Loaded apps specification from APPS_JSON_BASE64")
            return json.loads(decoded)
        except Exception as e:
            print(f"[fetch_apps] Failed to decode APPS_JSON_BASE64: {e}", file=sys.stderr)
            sys.exit(1)

    # 2. Check raw JSON environment variable
    raw_json = os.environ.get("APPS_JSON", "").strip()
    if raw_json:
        try:
            print("[fetch_apps] Loaded apps specification from APPS_JSON")
            return json.loads(raw_json)
        except Exception as e:
            print(f"[fetch_apps] Failed to parse APPS_JSON: {e}", file=sys.stderr)
            sys.exit(1)

    # 3. Check apps.json file paths
    for file_path in [
        Path("/opt/apps.json"),
        Path("/home/frappe/frappe-bench/apps.json"),
        Path("apps.json"),
    ]:
        if file_path.is_file():
            print(f"[fetch_apps] Loaded apps specification from {file_path}")
            with open(file_path, "r", encoding="utf-8") as f:
                return json.load(f)

    print("[fetch_apps] WARNING: No apps.json found and no APPS_JSON variables provided.")
    return []


def get_app_name(app):
    if "name" in app and app["name"]:
        return app["name"]

    url = app.get("url", "")
    # Parse repo name from git url (e.g. https://github.com/frappe/frappe.git -> frappe)
    # or git@github.com:frappe/erpnext.git -> erpnext
    cleaned = url.rstrip("/").split("/")[-1]
    if cleaned.endswith(".git"):
        cleaned = cleaned[:-4]
    return cleaned


def main():
    target_apps_dir = Path("/home/frappe/frappe-bench/apps")
    target_apps_dir.mkdir(parents=True, exist_ok=True)

    setup_ssh()
    token = get_git_token()
    setup_git_credentials(token)

    apps = load_apps_list()
    if not apps:
        print("[fetch_apps] No apps to fetch. Checking if local apps exist...")
        existing_apps = [p.name for p in target_apps_dir.iterdir() if p.is_dir()]
        print(f"[fetch_apps] Existing apps found: {existing_apps}")
        return

    print(f"[fetch_apps] Processing {len(apps)} applications...")

    for app in apps:
        url = app.get("url")
        branch = app.get("branch", "main")
        name = get_app_name(app)

        if not url:
            print(f"[fetch_apps] Skipping invalid entry without url: {app}")
            continue

        dest_dir = target_apps_dir / name

        # Check if directory already has files (e.g. from local COPY or mount)
        if dest_dir.is_dir() and any(dest_dir.iterdir()):
            print(f"[fetch_apps] App '{name}' already present at {dest_dir}. Skipping clone.")
            continue

        print(f"\n[fetch_apps] Fetching '{name}' from {url} (branch: {branch})...")
        clone_cmd = f"git clone --depth 1 -b '{branch}' '{url}' '{dest_dir}'"

        result = run_cmd(clone_cmd, check=False)
        if result.returncode != 0:
            print(
                f"\n[fetch_apps] FAILED to clone '{name}' from '{url}'.\n"
                "If this is a PRIVATE repository, ensure you have provided credentials:\n"
                "  - For SSH (git@github.com:...): use BuildKit SSH forwarding -> docker build --ssh default ...\n"
                "  - For HTTPS (https://...): pass secret/token -> docker build --secret id=git_token,src=token.txt ...\n"
                "    or -> docker build --build-arg GITHUB_TOKEN=your_token ...\n",
                file=sys.stderr,
            )
            if result.stderr:
                print(f"[fetch_apps] Git Error details: {result.stderr}", file=sys.stderr)
            sys.exit(1)

        print(f"[fetch_apps] Successfully cloned '{name}'.")

    print("\n[fetch_apps] All applications fetched successfully.")


if __name__ == "__main__":
    main()
