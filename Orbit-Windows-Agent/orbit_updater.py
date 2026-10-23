"""GitHub release and repository update checker & self-updater for Orbit PC Companion."""
import io
import json
import logging
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import webbrowser
import zipfile

LOGGER = logging.getLogger("orbit.updater")

GITHUB_OWNER = os.getenv("ORBIT_GITHUB_OWNER", "AceDimi2005")
GITHUB_REPO = os.getenv("ORBIT_GITHUB_REPO", "Orbit")
GITHUB_RELEASES_PAGE = f"https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}/releases"
GITHUB_REPO_PAGE = f"https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}"
TRUSTED_GITHUB_HOSTS = {
    "github.com",
    "api.github.com",
    "raw.githubusercontent.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    " release-assets.githubusercontent.com".strip(),
}
UPDATABLE_EXTENSIONS = {".py", ".bat", ".ps1", ".txt", ".md", ".ico", ".json", ".cs"}
PRESERVED_FILENAMES = {".orbit-token", ".orbit-widget-token", ".orbit-sunshine-login"}
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024

_VERSION_RE = re.compile(r"(\d+(?:\.\d+)+)")
_AGENT_VERSION_ASSIGN_RE = re.compile(r'^\s*AGENT_VERSION\s*=\s*["\']([^"\']+)["\']', re.MULTILINE)


def parse_version(value):
    """Parse a semantic version string such as 'v4.1.0' into a tuple of ints."""
    if not isinstance(value, str):
        return (0,)
    match = _VERSION_RE.search(value.strip())
    if not match:
        return (0,)
    parts = [int(part) for part in match.group(1).split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def normalize_version_string(value):
    """Extract a clean version string like '4.1.0' from a tag or release name."""
    if not isinstance(value, str):
        return ""
    match = _VERSION_RE.search(value.strip())
    return match.group(1) if match else value.strip().lstrip("vV")


def is_newer_version(candidate, current):
    """Return True if candidate version is strictly newer than current version."""
    return parse_version(candidate) > parse_version(current)


def validate_github_url(url):
    """Ensure a URL uses HTTPS and points to an official GitHub host."""
    parsed = urlparse(str(url or ""))
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or (host not in TRUSTED_GITHUB_HOSTS and not host.endswith(".githubusercontent.com")):
        raise ValueError(f"Untrusted update URL: {url}")
    return url


def _fetch_bytes(url, opener=None, timeout=6.0, accept="application/vnd.github+json"):
    validate_github_url(url)
    request = Request(
        url,
        headers={
            "Accept": accept,
            "User-Agent": "OrbitPCCompanion-Updater/4.1",
        },
    )
    open_func = opener or urlopen
    with open_func(request, timeout=timeout) as response:
        return response.read(MAX_ARCHIVE_BYTES + 1)


def _select_release_download_url(release_payload, owner=GITHUB_OWNER, repo=GITHUB_REPO):
    assets = release_payload.get("assets") or []
    if isinstance(assets, list):
        # Prefer a zip asset containing Windows Agent / Companion files.
        for asset in assets:
            if not isinstance(asset, dict):
                continue
            name = str(asset.get("name") or "").lower()
            download_url = asset.get("browser_download_url")
            if download_url and name.endswith(".zip") and ("orbit" in name or "windows" in name or "companion" in name or "agent" in name):
                return download_url
        for asset in assets:
            if not isinstance(asset, dict):
                continue
            name = str(asset.get("name") or "").lower()
            download_url = asset.get("browser_download_url")
            if download_url and name.endswith(".zip"):
                return download_url
    zipball = release_payload.get("zipball_url")
    if isinstance(zipball, str) and zipball.startswith("https://"):
        return zipball
    return f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/main"


def _is_pc_companion_release(release_payload):
    """Return True if a GitHub release targets the Windows PC Companion (not iOS-only)."""
    if not isinstance(release_payload, dict) or release_payload.get("draft"):
        return False
    tag = str(release_payload.get("tag_name") or "").strip().lower()
    title = str(release_payload.get("name") or "").strip().lower()
    if tag.startswith(("ios-", "ios_", "iphone-", "ipad-")):
        return False
    if tag.startswith(("pc-", "pc_", "windows-", "companion-", "agent-")):
        return True
    assets = release_payload.get("assets") or []
    for asset in assets:
        if isinstance(asset, dict):
            asset_name = str(asset.get("name") or "").lower()
            if "windows" in asset_name or "agent" in asset_name or "companion" in asset_name:
                return True
    if ("ios" in title or "iphone" in title or "testflight" in title) and not any(
        kw in title for kw in ("windows", "pc", "companion", "agent")
    ):
        return False
    return True


def _release_dict_to_candidate(data, owner, repo):
    tag_name = str(data.get("tag_name") or data.get("name") or "").strip()
    latest_version = normalize_version_string(tag_name)
    if not latest_version:
        return None
    return {
        "latestVersion": latest_version,
        "releaseTitle": str(data.get("name") or f"Orbit PC Companion {latest_version}").strip(),
        "releaseNotes": str(data.get("body") or "").strip(),
        "releaseUrl": str(data.get("html_url") or f"https://github.com/{owner}/{repo}/releases").strip(),
        "downloadUrl": _select_release_download_url(data, owner=owner, repo=repo),
        "publishedAt": data.get("published_at"),
        "source": "github_release",
    }


def _check_latest_release(owner, repo, opener=None, timeout=6.0):
    releases_url = f"https://api.github.com/repos/{owner}/{repo}/releases?per_page=20"
    try:
        raw = _fetch_bytes(releases_url, opener=opener, timeout=timeout)
        payload = json.loads(raw.decode("utf-8"))
    except Exception:
        api_url = f"https://api.github.com/repos/{owner}/{repo}/releases/latest"
        raw = _fetch_bytes(api_url, opener=opener, timeout=timeout)
        payload = json.loads(raw.decode("utf-8"))

    releases = payload if isinstance(payload, list) else ([payload] if isinstance(payload, dict) else [])
    best_candidate = None
    for item in releases:
        if not _is_pc_companion_release(item):
            continue
        candidate = _release_dict_to_candidate(item, owner, repo)
        if candidate is None:
            continue
        if best_candidate is None or is_newer_version(candidate["latestVersion"], best_candidate["latestVersion"]):
            best_candidate = candidate
    return best_candidate


def _check_main_branch_version(owner, repo, opener=None, timeout=6.0):
    raw_url = f"https://raw.githubusercontent.com/{owner}/{repo}/main/Orbit-Windows-Agent/orbit_agent.py"
    raw = _fetch_bytes(raw_url, opener=opener, timeout=timeout, accept="text/plain")
    source_text = raw.decode("utf-8", errors="replace")
    match = _AGENT_VERSION_ASSIGN_RE.search(source_text)
    if not match:
        return None
    latest_version = normalize_version_string(match.group(1))
    if not latest_version:
        return None
    return {
        "latestVersion": latest_version,
        "releaseTitle": f"Orbit PC Companion {latest_version}",
        "releaseNotes": "Latest public version on GitHub main branch.",
        "releaseUrl": f"https://github.com/{owner}/{repo}/releases",
        "downloadUrl": f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/main",
        "publishedAt": None,
        "source": "github_main",
    }


def check_for_updates(current_version, owner=GITHUB_OWNER, repo=GITHUB_REPO, opener=None, timeout=6.0):
    """Check GitHub Releases (and main branch fallback) for a newer public PC companion."""
    clean_current = normalize_version_string(current_version) or str(current_version)
    release_candidate = None
    main_candidate = None
    last_error = None

    try:
        release_candidate = _check_latest_release(owner, repo, opener=opener, timeout=timeout)
    except HTTPError as http_err:
        if http_err.code != 404:
            last_error = http_err
    except (URLError, ValueError, OSError) as err:
        last_error = err

    try:
        main_candidate = _check_main_branch_version(owner, repo, opener=opener, timeout=timeout)
    except (HTTPError, URLError, ValueError, OSError) as err:
        if last_error is None:
            last_error = err

    chosen = release_candidate
    if main_candidate is not None:
        if chosen is None or is_newer_version(main_candidate["latestVersion"], chosen["latestVersion"]):
            chosen = main_candidate

    if chosen is None:
        if last_error is not None:
            raise RuntimeError(f"Could not reach GitHub ({owner}/{repo}): {last_error}") from last_error
        raise RuntimeError(f"No public version information found on GitHub ({owner}/{repo}).")

    latest_version = chosen["latestVersion"]
    return {
        "currentVersion": clean_current,
        "latestVersion": latest_version,
        "updateAvailable": is_newer_version(latest_version, clean_current),
        "releaseTitle": chosen["releaseTitle"],
        "releaseNotes": chosen["releaseNotes"],
        "releaseUrl": chosen["releaseUrl"],
        "downloadUrl": chosen["downloadUrl"],
        "publishedAt": chosen["publishedAt"],
        "source": chosen["source"],
        "repository": f"{owner}/{repo}",
    }


def _find_agent_root_in_zip(namelist):
    """Locate the directory prefix inside a zip archive that contains orbit_agent.py."""
    for name in namelist:
        normalized = name.replace("\\", "/")
        if normalized == "orbit_agent.py":
            return ""
        if normalized.endswith("/orbit_agent.py"):
            return normalized[: -len("orbit_agent.py")]
    raise ValueError("Archive does not contain Orbit-Windows-Agent/orbit_agent.py")


def apply_update_archive(zip_bytes, target_dir=None):
    """Safely extract updated Orbit-Windows-Agent files into target_dir while preserving secrets."""
    if len(zip_bytes) > MAX_ARCHIVE_BYTES:
        raise ValueError("Update archive exceeds maximum permitted size.")
    destination = Path(target_dir).resolve() if target_dir is not None else Path(__file__).resolve().parent
    destination.mkdir(parents=True, exist_ok=True)

    updated_files = []
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        prefix = _find_agent_root_in_zip(archive.namelist())
        with tempfile.TemporaryDirectory(prefix="orbit_update_") as staging_raw:
            staging = Path(staging_raw)
            for member in archive.infolist():
                if member.is_dir():
                    continue
                normalized = member.filename.replace("\\", "/")
                if prefix and not normalized.startswith(prefix):
                    continue
                relative_str = normalized[len(prefix):] if prefix else normalized
                if not relative_str or "/" in relative_str:
                    # Only update top-level files inside Orbit-Windows-Agent
                    continue
                if relative_str in PRESERVED_FILENAMES:
                    continue
                rel_path = Path(relative_str)
                if rel_path.suffix.lower() not in UPDATABLE_EXTENSIONS:
                    continue
                staged_file = staging / rel_path.name
                staged_file.write_bytes(archive.read(member.filename))
                updated_files.append(rel_path.name)

            if "orbit_agent.py" not in updated_files:
                raise ValueError("Update archive did not include orbit_agent.py")

            for filename in updated_files:
                shutil.copy2(staging / filename, destination / filename)

    return updated_files


def download_and_apply_update(download_url, target_dir=None, opener=None, timeout=15.0):
    """Download a GitHub zip archive and apply updated companion files."""
    zip_bytes = _fetch_bytes(download_url, opener=opener, timeout=timeout, accept="application/octet-stream")
    return apply_update_archive(zip_bytes, target_dir=target_dir)


def open_releases_page(url=GITHUB_RELEASES_PAGE):
    """Open the GitHub releases page in the user's browser."""
    validate_github_url(url)
    return webbrowser.open(url)
