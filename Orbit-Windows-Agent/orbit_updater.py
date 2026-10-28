"""GitHub release and repository update checker & self-updater for Orbit PC Companion.

Versions (PEP 440, a small subset): `4.6.0` is a stable build; `4.6.0a1`, `4.6.0b1` and `4.6.0rc1`
are the first alpha, beta and release candidate of 4.6.0, shown as "4.6.0 alpha 1", "4.6.0 beta 1"
and "4.6.0 RC 1". For the same number a stable build is newer than its release candidates, which
are newer than its betas, which are newer than its alphas:
4.5.2 < 4.6.0a1 < 4.6.0b1 < 4.6.0b2 < 4.6.0rc1 < 4.6.0 < 4.6.1b1. Tags may also spell them
`pc-v4.6.0-beta.1` or `4.6.0 beta 1`; `normalize_version_string` turns those into `4.6.0b1`.

Update channels, saved per PC in `%LOCALAPPDATA%\\Orbit\\settings.json` → "updates" → "channel"
(the tray's "Beta updates" item):
- "stable" (default): GitHub releases that are not pre-releases, and AGENT_VERSION on `main`.
  Pre-release versions are ignored even if one reaches `main` by mistake.
- "beta": also GitHub pre-releases and AGENT_VERSION on the `beta` branch, downloaded from
  `refs/heads/beta`.
The newest version wins (a stable source wins a tie). An update is offered only when it is newer
than the running build, so turning beta off never downgrades: a PC on 4.6.0b2 keeps it until a
stable 4.6.0 or later is out.
"""
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

CHANNEL_STABLE = "stable"
CHANNEL_BETA = "beta"
CHANNELS = (CHANNEL_STABLE, CHANNEL_BETA)
CHANNEL_BRANCHES = {CHANNEL_STABLE: "main", CHANNEL_BETA: "beta"}
SETTINGS_SECTION = "updates"

# "4.6.0", "4.6.0b1", "v4.6.0-beta.1", "4.6.0 RC 2". Words (alpha, beta, pre, preview) may leave the
# number out ("4.6.0-beta" is beta 0) but must not run into more letters; the short forms a, b and
# rc need their number, so "4.3.0 and more" or "4.3.0 a new tray" stay 4.3.0.
_VERSION_RE = re.compile(
    r"(\d+(?:\.\d+)+)"
    r"(?:[-_.\s]?(?:(alpha|beta|preview|pre)(?![A-Za-z])(?:[-_.\s]?(\d+))?|(a|b|rc)[-_.\s]?(\d+)))?",
    re.IGNORECASE,
)
_STAGES = {"a": "a", "alpha": "a", "b": "b", "beta": "b", "rc": "rc", "pre": "rc", "preview": "rc"}
_STAGE_RANKS = {"a": 0, "b": 1, "rc": 2}
_STAGE_NAMES = {"a": "alpha", "b": "beta", "rc": "RC"}
_STABLE_RANK = 3
_AGENT_VERSION_ASSIGN_RE = re.compile(r'^\s*AGENT_VERSION\s*=\s*["\']([^"\']+)["\']', re.MULTILINE)


def _version_parts(value):
    """(release "4.6.0", stage "a" | "b" | "rc" | None, number) or None when there is no version."""
    if not isinstance(value, str):
        return None
    match = _VERSION_RE.search(value.strip())
    if not match:
        return None
    stage = _STAGES.get((match.group(2) or match.group(4) or "").lower())
    number = int(match.group(3) or match.group(5) or 0) if stage else 0
    return match.group(1), stage, number


def parse_version(value):
    """Sort key for a version: ((4, 6), rank, number), rank alpha 0, beta 1, RC 2, stable 3.

    Trailing zeros of the number do not count (4.6 == 4.6.0). Text without a version sorts as
    the lowest stable version."""
    parts = _version_parts(value)
    if parts is None:
        return ((0,), _STABLE_RANK, 0)
    release, stage, number = parts
    numbers = [int(part) for part in release.split(".")]
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers.pop()
    if stage is None:
        return (tuple(numbers), _STABLE_RANK, 0)
    return (tuple(numbers), _STAGE_RANKS[stage], number)


def normalize_version_string(value):
    """The canonical version in a tag or title: 'pc-v4.6.0-beta.1' → '4.6.0b1', 'v4.1.0' → '4.1.0'."""
    if not isinstance(value, str):
        return ""
    parts = _version_parts(value)
    if parts is None:
        return value.strip().lstrip("vV")
    release, stage, number = parts
    return f"{release}{stage}{number}" if stage else release


def is_prerelease(value):
    """True for alpha, beta and release-candidate versions such as 4.6.0b1."""
    parts = _version_parts(value)
    return parts is not None and parts[1] is not None


def display_version(value):
    """How people read a version: '4.6.0b1' → '4.6.0 beta 1', '4.6.0rc2' → '4.6.0 RC 2'."""
    parts = _version_parts(value)
    if parts is None:
        return value.strip() if isinstance(value, str) else ""
    release, stage, number = parts
    return f"{release} {_STAGE_NAMES[stage]} {number}" if stage else release


def is_newer_version(candidate, current):
    """Return True if candidate version is strictly newer than current version."""
    return parse_version(candidate) > parse_version(current)


# Channel -------------------------------------------------------------------------------------

def normalize_channel(value):
    """"beta" (any case) is the beta channel; anything else, including nothing, is stable."""
    return CHANNEL_BETA if str(value or "").strip().lower() == CHANNEL_BETA else CHANNEL_STABLE


def _settings_store(store):
    if store is not None:
        return store
    import orbit_settings
    return orbit_settings.shared_store()


def _updates_section(store):
    try:
        section = _settings_store(store).get(SETTINGS_SECTION, {})
    except Exception:
        LOGGER.warning("Could not read the update channel; using stable", exc_info=True)
        return {}
    return section if isinstance(section, dict) else {}


def current_channel(store=None):
    """This PC's update channel from the agent settings; "stable" when unset or unreadable."""
    return normalize_channel(_updates_section(store).get("channel"))


def set_channel(channel, store=None):
    """Saves the update channel ("stable" or "beta") and returns it."""
    if channel not in CHANNELS:
        raise ValueError(f"Unknown update channel: {channel!r}")
    saved = _settings_store(store).update(SETTINGS_SECTION, {"channel": channel})
    return normalize_channel(saved.get("channel"))


def beta_notice_shown(store=None):
    """True once the PC owner has read the beta explanation (it is shown only the first time)."""
    return _updates_section(store).get("betaNoticeShown") is True


def mark_beta_notice_shown(store=None):
    _settings_store(store).update(SETTINGS_SECTION, {"betaNoticeShown": True})


def branch_download_url(branch, owner=GITHUB_OWNER, repo=GITHUB_REPO):
    """The zip of a branch, e.g. https://codeload.github.com/AceDimi2005/Orbit/zip/refs/heads/beta."""
    if branch not in CHANNEL_BRANCHES.values():
        raise ValueError(f"Unknown update branch: {branch!r}")
    return f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/{branch}"


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


def _select_release_download_url(release_payload, owner=GITHUB_OWNER, repo=GITHUB_REPO, branch="main"):
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
    return branch_download_url(branch, owner=owner, repo=repo)


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
    # GitHub's "pre-release" box or a pre-release version number: only for the beta channel.
    prerelease = bool(data.get("prerelease")) or is_prerelease(latest_version)
    return {
        "latestVersion": latest_version,
        "releaseTitle": str(data.get("name") or f"Orbit PC Companion {display_version(latest_version)}").strip(),
        "releaseNotes": str(data.get("body") or "").strip(),
        "releaseUrl": str(data.get("html_url") or f"https://github.com/{owner}/{repo}/releases").strip(),
        "downloadUrl": _select_release_download_url(data, owner=owner, repo=repo,
                                                    branch="beta" if prerelease else "main"),
        "publishedAt": data.get("published_at"),
        "source": "github_prerelease" if prerelease else "github_release",
        "branch": None,
        "prerelease": prerelease,
    }


def _check_latest_release(owner, repo, opener=None, timeout=6.0, include_prereleases=False):
    """The newest PC Companion release; pre-releases count only with include_prereleases."""
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
        if candidate is None or (candidate["prerelease"] and not include_prereleases):
            continue
        if best_candidate is None or is_newer_version(candidate["latestVersion"], best_candidate["latestVersion"]):
            best_candidate = candidate
    return best_candidate


def _check_branch_version(owner, repo, branch, opener=None, timeout=6.0):
    """AGENT_VERSION in orbit_agent.py on a branch ("main" or "beta"), as an update candidate."""
    raw_url = f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/Orbit-Windows-Agent/orbit_agent.py"
    raw = _fetch_bytes(raw_url, opener=opener, timeout=timeout, accept="text/plain")
    source_text = raw.decode("utf-8", errors="replace")
    match = _AGENT_VERSION_ASSIGN_RE.search(source_text)
    if not match:
        return None
    latest_version = normalize_version_string(match.group(1))
    if not latest_version:
        return None
    beta = branch == CHANNEL_BRANCHES[CHANNEL_BETA]
    return {
        "latestVersion": latest_version,
        "releaseTitle": f"Orbit PC Companion {display_version(latest_version)}",
        "releaseNotes": "Latest beta build on the GitHub beta branch." if beta
        else "Latest public version on GitHub main branch.",
        "releaseUrl": f"https://github.com/{owner}/{repo}/commits/{branch}" if beta
        else f"https://github.com/{owner}/{repo}/releases",
        "downloadUrl": branch_download_url(branch, owner=owner, repo=repo),
        "publishedAt": None,
        "source": f"github_{branch}",
        "branch": branch,
        "prerelease": is_prerelease(latest_version),
    }


def _check_main_branch_version(owner, repo, opener=None, timeout=6.0):
    return _check_branch_version(owner, repo, "main", opener=opener, timeout=timeout)


def check_for_updates(current_version, owner=GITHUB_OWNER, repo=GITHUB_REPO, opener=None, timeout=6.0,
                      channel=None):
    """Check GitHub for a newer PC Companion on this PC's update channel (see the module notes).

    `channel` None reads the saved one. The reply says which channel was checked and how to show
    both versions ("4.6.0 beta 1")."""
    channel = current_channel() if channel is None else normalize_channel(channel)
    beta = channel == CHANNEL_BETA
    clean_current = normalize_version_string(current_version) or str(current_version)
    candidates = []  # stable sources first, so they win a tie
    last_error = None

    try:
        candidates.append(_check_latest_release(owner, repo, opener=opener, timeout=timeout, include_prereleases=beta))
    except HTTPError as http_err:
        if http_err.code != 404:
            last_error = http_err
    except (URLError, ValueError, OSError) as err:
        last_error = err

    for branch in ("main", "beta") if beta else ("main",):
        try:
            candidates.append(_check_branch_version(owner, repo, branch, opener=opener, timeout=timeout))
        except HTTPError as http_err:
            if branch == "beta" and http_err.code == 404:
                LOGGER.info("There is no beta branch on GitHub (%s/%s) yet", owner, repo)
            elif last_error is None:
                last_error = http_err
        except (URLError, ValueError, OSError) as err:
            if last_error is None:
                last_error = err

    chosen = None
    for candidate in candidates:
        if candidate is None or (candidate["prerelease"] and not beta):
            continue  # a pre-release version on main never reaches stable PCs
        if chosen is None or is_newer_version(candidate["latestVersion"], chosen["latestVersion"]):
            chosen = candidate

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
        "channel": channel,
        "currentVersionDisplay": display_version(clean_current),
        "latestVersionDisplay": display_version(latest_version),
        "currentIsPrerelease": is_prerelease(clean_current),
        "latestIsPrerelease": bool(chosen["prerelease"]),
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
