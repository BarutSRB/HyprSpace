#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


DEFAULT_MAIN_REPO = Path("/Users/barut/OmniWM/OmniWM")
DEFAULT_GITHUB_REPO = "BarutSRB/OmniWM"
SIGNING_IDENTITY = "Developer ID Application: Oliver Nikolic (VF8LDJRGFM)"
NOTARIZE_PROFILE = "OmniWM-Notarize"
MANIFEST_SCHEMA = 3
PUBLIC_STAGES = ("main", "tag", "release")
LEGACY_PUBLIC_STAGES = (*PUBLIC_STAGES, "tap")
DESTINATIONS = ("main_remote", "github_repo")
LEGACY_DESTINATIONS = (*DESTINATIONS, "tap_remote", "tap_github_repo")
LOCAL_RELEASE_STATES = {"preparing", "recovered-local-checkpoint", "prepared"}
SEALED_RELEASE_STATES = {"sealed", "published-main", "published-tag", "published"}
RELEASE_STATES = LOCAL_RELEASE_STATES | SEALED_RELEASE_STATES
MANIFEST_KEYS = {
    "schema",
    "version",
    "tag",
    "previous_tag",
    "previous_version",
    "build",
    "state",
    "sealed",
    "original_main_head",
    "release_commit",
    "embedded_git_hash",
    "signing_identity",
    "notarize_profile",
    "notarization",
    "destinations",
    "assets",
    "notes_sha256",
    "published",
    "release_url",
}
LEGACY_TAP_KEYS = {"original_tap_head", "tap_commit", "cask_sha256"}
LEGACY_MANIFEST_KEYS = {
    1: MANIFEST_KEYS | LEGACY_TAP_KEYS,
    2: MANIFEST_KEYS | LEGACY_TAP_KEYS | {"tap_checkout"},
}


class ReleaseError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    main_repo: Path
    github_repo: str
    signing_identity: str = SIGNING_IDENTITY
    notarize_profile: str = NOTARIZE_PROFILE

    @classmethod
    def from_environment(cls) -> "Config":
        return cls(
            main_repo=Path(os.environ.get("OMNIWM_RELEASE_MAIN_REPO", DEFAULT_MAIN_REPO)),
            github_repo=os.environ.get("OMNIWM_RELEASE_GITHUB_REPO", DEFAULT_GITHUB_REPO),
            signing_identity=os.environ.get("OMNIWM_RELEASE_SIGNING_IDENTITY", SIGNING_IDENTITY),
            notarize_profile=os.environ.get("OMNIWM_RELEASE_NOTARIZE_PROFILE", NOTARIZE_PROFILE),
        )


@dataclass(frozen=True)
class RepoState:
    branch: str
    clean: bool
    status: str
    ahead: int
    behind: int
    head: str


class Runner:
    def run(self, args, cwd=None, check=True, capture=True, quiet=False, env=None):
        command = [str(arg) for arg in args]
        if not quiet:
            where = f" ({cwd})" if cwd else ""
            print(f"$ {' '.join(command)}{where}")
        kwargs = {
            "cwd": cwd,
            "text": True,
            "check": False,
            "env": env,
        }
        if capture:
            kwargs["stdout"] = subprocess.PIPE
            kwargs["stderr"] = subprocess.PIPE
        try:
            result = subprocess.run(command, **kwargs)
        except FileNotFoundError as error:
            raise ReleaseError(f"missing command: {command[0]}") from error
        if check and result.returncode != 0:
            stdout = result.stdout.strip() if result.stdout else ""
            stderr = result.stderr.strip() if result.stderr else ""
            detail = "\n".join(part for part in (stdout, stderr) if part)
            raise ReleaseError(
                f"command failed with exit {result.returncode}: {' '.join(command)}"
                + (f"\n{detail}" if detail else "")
            )
        return result

    def output(self, args, cwd=None, check=True):
        return self.run(args, cwd=cwd, check=check, quiet=True).stdout.strip()

    def popen(self, args, cwd=None):
        return subprocess.Popen(
            [str(arg) for arg in args],
            cwd=cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def validate_version(version):
    require(re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", version) is not None, "version must look like 0.5.7")


def github_slug(remote):
    value = remote.strip()
    match = re.fullmatch(
        r"(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?",
        value,
        re.IGNORECASE,
    )
    return match.group(1) if match else None


def parse_version(version):
    return tuple(int(part) for part in version.split("."))


def manifest_stages(manifest):
    return PUBLIC_STAGES if manifest["schema"] == MANIFEST_SCHEMA else LEGACY_PUBLIC_STAGES


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw_temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = Path(raw_temp)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


class ReleaseManager:
    def __init__(self, config=None, runner=None):
        self.config = config or Config.from_environment()
        self.runner = runner or Runner()

    @property
    def main(self):
        return self.config.main_repo

    @property
    def info_plist(self):
        return self.main / "Info.plist"

    @property
    def website_version_file(self):
        return self.main / "website" / "src" / "data" / "site.ts"

    def git(self, repo, *args, check=True):
        return self.runner.output(["git", *args], cwd=repo, check=check)

    def run_git(self, repo, *args):
        return self.runner.run(["git", *args], cwd=repo)

    def fetch(self):
        self.runner.run(["git", "fetch", "origin", "--tags", "--prune"], cwd=self.main, capture=False)

    def repo_state(self, repo):
        branch = self.git(repo, "branch", "--show-current")
        status = self.git(repo, "status", "--porcelain=v1")
        head = self.git(repo, "rev-parse", "HEAD")
        upstream = self.runner.run(
            ["git", "rev-parse", "--verify", "origin/main"],
            cwd=repo,
            check=False,
            quiet=True,
        )
        ahead = 0
        behind = 0
        if upstream.returncode == 0:
            left, right = self.git(repo, "rev-list", "--left-right", "--count", "origin/main...HEAD").split()
            behind = int(left)
            ahead = int(right)
        return RepoState(branch, not status, status, ahead, behind, head)

    def require_clean_worktree(self, repo, message):
        status = self.git(repo, "status", "--porcelain=v1")
        require(not status, f"{message}:\n{status}")

    def plist(self):
        with self.info_plist.open("rb") as handle:
            return plistlib.load(handle)

    def write_plist_version(self, version, build):
        value = self.plist()
        value["CFBundleShortVersionString"] = version
        value["CFBundleVersion"] = str(build)
        with self.info_plist.open("wb") as handle:
            plistlib.dump(value, handle, sort_keys=False)

    def website_version(self):
        text = self.website_version_file.read_text(encoding="utf-8")
        match = re.fullmatch(r"export const version = '([^']+)';\n?", text)
        require(match is not None, "website version file has an unsupported format")
        return match.group(1)

    def write_website_version(self, version):
        self.website_version_file.write_text(f"export const version = '{version}';\n", encoding="utf-8")

    def tag(self, version):
        return f"v{version}"

    def manifest_path(self, version):
        validate_version(version)
        return self.main / "dist" / f"release-v{version}.json"

    def asset_paths(self, version):
        validate_version(version)
        dist = self.main / "dist"
        return {
            "app": dist / f"OmniWM-v{version}.zip",
            "ghostty": dist / f"GhosttyKit.xcframework-v{version}.zip",
            "notes": dist / f"release-notes-v{version}.md",
            "source": dist / f"release-source-v{version}.txt",
        }

    def load_manifest(self, version):
        path = self.manifest_path(version)
        require(path.exists(), f"missing release manifest: {path}")
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise ReleaseError(f"invalid release manifest: {error}") from error
        self.validate_manifest_data(value, version)
        return value

    def validate_manifest_data(self, value, version):
        require(isinstance(value, dict), "release manifest root must be an object")
        require(isinstance(version, str), "manifest version must be a string")
        validate_version(version)
        schema = value.get("schema")
        require(
            type(schema) is int and (schema == MANIFEST_SCHEMA or schema in LEGACY_MANIFEST_KEYS),
            "unsupported release manifest schema",
        )
        legacy = schema != MANIFEST_SCHEMA
        expected_keys = LEGACY_MANIFEST_KEYS[schema] if legacy else MANIFEST_KEYS
        require(set(value) == expected_keys, "release manifest fields are incomplete or unsupported")
        require(value.get("version") == version, "manifest version mismatch")
        require(value["tag"] == self.tag(version), "manifest tag does not match version")
        for field in ("previous_tag", "previous_version", "signing_identity", "notarize_profile"):
            require(isinstance(value[field], str) and value[field], f"manifest {field} is invalid")
        validate_version(value["previous_version"])
        require(
            value["previous_tag"] == self.tag(value["previous_version"]),
            "manifest previous tag does not match previous version",
        )
        require(
            parse_version(value["previous_version"]) < parse_version(version),
            "manifest previous version must be older than the release version",
        )
        require(
            isinstance(value["state"], str) and value["state"] in RELEASE_STATES,
            "manifest state is invalid",
        )
        require(
            isinstance(value["original_main_head"], str)
            and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value["original_main_head"]) is not None,
            "manifest original_main_head is not a full Git object ID",
        )
        for field in ("release_commit", "release_url"):
            require(
                value[field] is None or isinstance(value[field], str),
                f"manifest {field} must be a string or null",
            )
        require(
            value["release_commit"] is None
            or re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value["release_commit"]) is not None,
            "manifest release_commit is not a full Git object ID",
        )
        require(
            value["embedded_git_hash"] is None
            or (
                isinstance(value["embedded_git_hash"], str)
                and re.fullmatch(r"[0-9a-f]{4,64}", value["embedded_git_hash"]) is not None
            ),
            "manifest embedded_git_hash is invalid",
        )
        require(
            value["notes_sha256"] is None
            or (
                isinstance(value["notes_sha256"], str)
                and re.fullmatch(r"[0-9a-f]{64}", value["notes_sha256"]) is not None
            ),
            "manifest notes_sha256 is not a SHA-256 digest",
        )
        require(isinstance(value["sealed"], bool), "manifest sealed must be boolean")
        require(
            type(value["build"]) is int and value["build"] > 0,
            "manifest build must be a positive integer",
        )
        require(
            isinstance(value["notarization"], dict)
            and set(value["notarization"]) == {"status", "stapled"}
            and isinstance(value["notarization"]["status"], str)
            and isinstance(value["notarization"]["stapled"], bool),
            "manifest notarization state is invalid",
        )
        require(
            isinstance(value["destinations"], dict)
            and set(value["destinations"]) == set(LEGACY_DESTINATIONS if legacy else DESTINATIONS)
            and all(
                isinstance(destination, str) and destination
                for destination in value["destinations"].values()
            ),
            "manifest destinations are invalid",
        )
        require(
            isinstance(value["published"], dict)
            and set(value["published"]) == set(manifest_stages(value))
            and all(isinstance(flag, bool) for flag in value["published"].values()),
            "manifest published state is invalid",
        )
        require(isinstance(value["assets"], dict), "manifest assets must be an object")
        for name, asset in value["assets"].items():
            require(name in {"app", "ghostty"}, f"manifest has unsupported asset {name}")
            require(
                isinstance(asset, dict)
                and set(asset) == {"path", "sha256"}
                and isinstance(asset["path"], str)
                and asset["path"]
                and isinstance(asset["sha256"], str)
                and re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]) is not None,
                f"manifest asset {name} is invalid",
            )
        if legacy:
            return
        state = value["state"]
        published_prefix = {
            "preparing": 0,
            "recovered-local-checkpoint": 0,
            "prepared": 0,
            "sealed": 0,
            "published-main": 1,
            "published-tag": 2,
            "published": 3,
        }[state]
        expected_published = {
            stage: index < published_prefix
            for index, stage in enumerate(PUBLIC_STAGES)
        }
        require(
            value["published"] == expected_published,
            "manifest published flags do not match its state",
        )
        if state in {"preparing", "recovered-local-checkpoint"}:
            require(not value["sealed"], "incomplete release manifest cannot be sealed")
            require(value["assets"] == {}, "incomplete release manifest cannot contain assets")
            require(value["embedded_git_hash"] is None, "incomplete release manifest has an embedded hash")
            require(value["notes_sha256"] is None, "incomplete release manifest has a notes hash")
            require(value["release_url"] is None, "incomplete release manifest has a release URL")
            require(
                value["notarization"] == {"status": "pending", "stapled": False},
                "incomplete release manifest has inconsistent notarization state",
            )
            return
        require(
            set(value["assets"]) == {"app", "ghostty"},
            "prepared release manifest must contain exactly app and ghostty assets",
        )
        expected_paths = self.asset_paths(version)
        for name in ("app", "ghostty"):
            require(
                value["assets"][name]["path"] == str(expected_paths[name]),
                f"manifest {name} asset path is not canonical",
            )
        require(value["release_commit"] is not None, "prepared release manifest lacks release commit")
        require(value["embedded_git_hash"] is not None, "prepared release manifest lacks embedded hash")
        require(
            value["notarization"] == {"status": "verified", "stapled": True},
            "prepared release manifest has inconsistent notarization state",
        )
        if state == "prepared":
            require(not value["sealed"], "prepared release manifest cannot already be sealed")
            require(value["notes_sha256"] is None, "unsealed release manifest has a notes hash")
        else:
            require(value["sealed"], "published release manifest must be sealed")
            require(value["notes_sha256"] is not None, "sealed release manifest lacks notes hash")
        if published_prefix < len(PUBLIC_STAGES):
            require(value["release_url"] is None, "release URL exists before GitHub publication")
        else:
            expected_url = (
                f"https://github.com/{value['destinations']['github_repo']}"
                f"/releases/tag/{value['tag']}"
            )
            require(value["release_url"] == expected_url, "manifest release URL is not canonical")

    def save_manifest(self, manifest):
        self.require_current_schema(manifest, "manifest update")
        self.validate_manifest_data(manifest, manifest.get("version"))
        atomic_json(self.manifest_path(manifest["version"]), manifest)

    def require_current_schema(self, manifest, operation):
        require(
            manifest.get("schema") == MANIFEST_SCHEMA,
            f"{operation} requires a schema {MANIFEST_SCHEMA} manifest; historical manifests are read-only",
        )

    def owned_commit_after(self, repo, original_head, expected_subject):
        head = self.git(repo, "rev-parse", "HEAD")
        if head == original_head:
            return None
        parent = self.git(repo, "rev-parse", "HEAD^", check=False)
        subject = self.git(repo, "log", "-1", "--pretty=%s", check=False)
        require(
            parent == original_head and subject == expected_subject,
            f"{repo} advanced beyond the recoverable release checkpoint",
        )
        return head

    def recover_local_checkpoints(self, manifest):
        if not manifest.get("release_commit"):
            release_commit = self.owned_commit_after(
                self.main,
                manifest["original_main_head"],
                f"Release {manifest['version']}",
            )
            if release_commit:
                manifest["release_commit"] = release_commit
                manifest["state"] = "recovered-local-checkpoint"
        return manifest

    def local_tag_commit(self, tag):
        result = self.runner.run(
            ["git", "rev-list", "-n", "1", tag],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        return result.stdout.strip() if result.returncode == 0 else None

    def remote_tag_commit(self, tag):
        result = self.runner.run(
            ["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}^{{}}"],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        if result.returncode != 0:
            raise ReleaseError(f"unable to query remote tag {tag}: {result.stderr.strip()}")
        if result.stdout.strip():
            return result.stdout.split()[0]
        direct = self.runner.run(
            ["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}"],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        if direct.returncode != 0:
            raise ReleaseError(f"unable to query remote tag {tag}: {direct.stderr.strip()}")
        return direct.stdout.split()[0] if direct.stdout.strip() else None

    def github_release(self, tag):
        result = self.runner.run(
            [
                "gh",
                "release",
                "view",
                tag,
                "--repo",
                self.config.github_repo,
                "--json",
                "tagName,name,body,url,isDraft,isPrerelease,assets",
            ],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        if result.returncode == 0:
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise ReleaseError(f"invalid GitHub release response: {error}") from error
        detail = f"{result.stdout}\n{result.stderr}".lower()
        if "not found" in detail or "http 404" in detail or "release does not exist" in detail:
            return None
        raise ReleaseError(f"unable to query GitHub release {tag}: {result.stderr.strip()}")

    def latest_github_release_tag(self):
        result = self.runner.run(
            [
                "gh",
                "release",
                "view",
                "--repo",
                self.config.github_repo,
                "--json",
                "tagName",
                "--jq",
                ".tagName",
            ],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        if result.returncode != 0:
            raise ReleaseError(f"unable to query latest GitHub release: {result.stderr.strip()}")
        return result.stdout.strip()

    def all_release_tags(self):
        raw = self.git(self.main, "tag", "--list", "v[0-9]*")
        values = []
        for tag in raw.splitlines():
            version = tag.removeprefix("v")
            if re.fullmatch(r"\d+(?:\.\d+)+", version):
                values.append((parse_version(version), tag))
        return sorted(values)

    def previous_release(self, version):
        candidates = [entry for entry in self.all_release_tags() if entry[0] < parse_version(version)]
        require(candidates, f"no previous release before v{version}")
        parts, tag = candidates[-1]
        return tag, ".".join(str(part) for part in parts)

    def commits_since(self, tag, end="HEAD"):
        raw = self.git(self.main, "log", "--pretty=format:%h %s", "--no-merges", f"{tag}..{end}")
        return [
            line
            for line in raw.splitlines()
            if line and not re.search(r"\bRelease \d", line)
        ]

    def required_tools(self):
        names = [
            "git",
            "gh",
            "swift",
            "make",
            "lipo",
            "codesign",
            "xcrun",
            "spctl",
            "syspolicy_check",
            "ditto",
            "xattr",
            "security",
        ]
        return [name for name in names if shutil.which(name) is None]

    def signing_identity_found(self):
        result = self.runner.run(
            ["security", "find-identity", "-v", "-p", "codesigning"],
            check=False,
            quiet=True,
        )
        if result.returncode != 0:
            raise ReleaseError(f"unable to query signing identities: {result.stderr.strip()}")
        return self.config.signing_identity in f"{result.stdout}\n{result.stderr}"

    def github_write_access(self, repository):
        result = self.runner.run(
            [
                "gh",
                "api",
                f"repos/{repository}",
                "--jq",
                ".permissions.push",
            ],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        return {
            "ok": result.returncode == 0 and result.stdout.strip() == "true",
            "detail": (result.stderr or result.stdout).strip(),
        }

    def notary_profile_access(self):
        result = self.runner.run(
            [
                "xcrun",
                "notarytool",
                "history",
                "--keychain-profile",
                self.config.notarize_profile,
                "--output-format",
                "json",
            ],
            cwd=self.main,
            check=False,
            quiet=True,
        )
        return {
            "ok": result.returncode == 0,
            "detail": (result.stderr or result.stdout).strip(),
        }

    def remote_url(self, repo):
        return self.git(repo, "remote", "get-url", "origin")

    def verify_remote_identity(self, remote, expected, label):
        actual_slug = github_slug(remote)
        require(actual_slug is not None, f"{label} origin is not a GitHub repository: {remote}")
        require(
            actual_slug.casefold() == expected.casefold(),
            f"{label} origin {actual_slug} does not match {expected}",
        )

    def verify_destinations(self, manifest):
        destinations = manifest.get("destinations")
        require(isinstance(destinations, dict), "manifest is missing sealed publish destinations")
        expected = {
            "main_remote": self.remote_url(self.main),
            "github_repo": self.config.github_repo,
        }
        require(destinations == expected, "current publish destinations differ from the sealed manifest")
        self.verify_remote_identity(destinations["main_remote"], destinations["github_repo"], "main")

    def plan_data(self, version):
        validate_version(version)
        self.fetch()
        previous_tag, previous_version = self.previous_release(version)
        plist = self.plist()
        main_state = self.repo_state(self.main)
        tag = self.tag(version)
        missing_tools = self.required_tools()
        main_remote = self.remote_url(self.main)
        return {
            "version": version,
            "tag": tag,
            "previous_tag": previous_tag,
            "previous_version": previous_version,
            "current_version": str(plist["CFBundleShortVersionString"]),
            "website_version": self.website_version(),
            "current_build": int(plist["CFBundleVersion"]),
            "next_build": int(plist["CFBundleVersion"]) + 1,
            "main": main_state,
            "local_tag": self.local_tag_commit(tag),
            "remote_tag": self.remote_tag_commit(tag),
            "github_release": self.github_release(tag),
            "commits": self.commits_since(previous_tag),
            "missing_tools": missing_tools,
            "signing_identity_found": False if "security" in missing_tools else self.signing_identity_found(),
            "github_write_access": (
                {"ok": False, "detail": "gh is missing"}
                if "gh" in missing_tools
                else self.github_write_access(self.config.github_repo)
            ),
            "notary_profile_access": (
                {"ok": False, "detail": "xcrun is missing"}
                if "xcrun" in missing_tools
                else self.notary_profile_access()
            ),
            "main_remote": main_remote,
        }

    def print_plan(self, plan):
        print(f"Version: {plan['version']}")
        print(f"Tag: {plan['tag']}")
        print(f"Previous release: {plan['previous_tag']}")
        print(
            f"Info.plist: {plan['current_version']} build {plan['current_build']} "
            f"-> {plan['version']} build {plan['next_build']}"
        )
        print(f"Website: {plan['website_version']} -> {plan['version']}")
        state = plan["main"]
        print(
            f"main: branch={state.branch} clean={state.clean} "
            f"ahead={state.ahead} behind={state.behind} head={state.head[:12]}"
        )
        print(f"Local tag: {plan['local_tag'] or 'absent'}")
        print(f"Remote tag: {plan['remote_tag'] or 'absent'}")
        print(f"GitHub release: {'present' if plan['github_release'] else 'absent'}")
        print(f"Signing identity: {'found' if plan['signing_identity_found'] else 'missing'}")
        print(f"GitHub write access: {'ok' if plan['github_write_access']['ok'] else 'failed'}")
        print(f"Notary profile access: {'ok' if plan['notary_profile_access']['ok'] else 'failed'}")
        print(f"Main origin: {plan['main_remote']}")
        print("Missing tools: " + (", ".join(plan["missing_tools"]) if plan["missing_tools"] else "none"))
        print("Commits:")
        for commit in plan["commits"] or ["none"]:
            print(f"- {commit}")

    def enforce_new_release_plan(self, plan):
        require(
            plan["website_version"] == plan["current_version"],
            "website version differs from Info.plist",
        )
        require(not plan["missing_tools"], f"missing tools: {', '.join(plan['missing_tools'])}")
        require(plan["signing_identity_found"], f"missing signing identity: {self.config.signing_identity}")
        require(
            plan["github_write_access"]["ok"],
            "GitHub authentication lacks push/release access: "
            + plan["github_write_access"]["detail"],
        )
        require(
            plan["notary_profile_access"]["ok"],
            "notary profile is unavailable: " + plan["notary_profile_access"]["detail"],
        )
        self.verify_remote_identity(plan["main_remote"], self.config.github_repo, "main")
        require(plan["main"].branch == "main", "main repo must be on main")
        require(plan["main"].clean, f"main repo is dirty:\n{plan['main'].status}")
        require(plan["main"].behind == 0, "main repo is behind origin/main")
        require(plan["local_tag"] is None, f"local tag already exists: {plan['tag']}")
        require(plan["remote_tag"] is None, f"remote tag already exists: {plan['tag']}")
        require(plan["github_release"] is None, f"GitHub release already exists: {plan['tag']}")
        require(
            parse_version(plan["version"]) > parse_version(plan["current_version"]),
            "target version must be newer than Info.plist",
        )
        require(plan["commits"], f"no unreleased commits after {plan['previous_tag']}")

    def release_bullets(self, commits):
        verbs = {
            "Add": "Added",
            "Align": "Aligned",
            "Fix": "Fixed",
            "Harden": "Hardened",
            "Improve": "Improved",
            "Introduce": "Introduced",
            "Move": "Moved",
            "Refine": "Refined",
            "Remove": "Removed",
            "Replace": "Replaced",
            "Stabilize": "Stabilized",
            "Update": "Updated",
        }
        bullets = []
        for commit in commits:
            subject = commit.split(" ", 1)[1] if " " in commit else commit
            subject = re.sub(r"\s+\(#\d+\)$", "", subject).strip()
            first, separator, rest = subject.partition(" ")
            text = f"{verbs.get(first, first)}{separator}{rest}".strip()
            if text and text[-1] not in ".!?":
                text += "."
            bullets.append(f"- {text}")
        return bullets

    def create_release_text(self, version, previous_version, previous_tag, commits):
        paths = self.asset_paths(version)
        notes = "\n".join(
            [
                f"## What's New Since {previous_version}",
                "",
                *self.release_bullets(commits),
                "",
                "Official website and documentation: https://omniwm.app",
                "Installation guide: https://omniwm.app/guides/install/",
                "",
                "## Release Integrity",
                "",
                "Asset hashes are sealed by the release manifest after final note review.",
                "",
            ]
        )
        source = "\n".join(
            [
                f"version: {version}",
                f"tag: {self.tag(version)}",
                f"previous_tag: {previous_tag}",
                "",
                "commits:",
                *[f"- {commit}" for commit in commits],
                "",
            ]
        )
        paths["notes"].write_text(notes, encoding="utf-8")
        paths["source"].write_text(source, encoding="utf-8")

    def create_zip(self, source, destination):
        destination.unlink(missing_ok=True)
        self.runner.run(["ditto", "-c", "-k", "--keepParent", source, destination], cwd=self.main)

    def app_embedded_hash(self, app_path):
        plist_path = app_path / "Contents" / "Info.plist"
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
        return str(plist.get("OMNIWMGitHash", ""))

    def check_distribution(self, app_path, verbose=False):
        command = ["syspolicy_check", "distribution", app_path]
        if verbose:
            command.append("--verbose")
        self.runner.run(command, cwd=self.main, capture=False)
        self.runner.run(["spctl", "--assess", "--type", "execute", "--verbose=4", app_path], cwd=self.main, capture=False)
        self.runner.run(["xcrun", "stapler", "validate", app_path], cwd=self.main, capture=False)
        self.runner.run(["codesign", "--verify", "--deep", "--strict", "--verbose=4", app_path], cwd=self.main, capture=False)

    def smoke_test(self, app_path, seconds=2):
        executable = app_path / "Contents" / "MacOS" / "OmniWM"
        require(executable.exists(), f"missing app executable: {executable}")
        process = self.runner.popen([executable], cwd=self.main)
        try:
            time.sleep(seconds)
            require(process.poll() is None, f"OmniWM exited during smoke test with {process.returncode}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def verify_app_zip(
        self,
        zip_path,
        *,
        version,
        build,
        embedded_hash,
        signing_identity,
    ):
        with tempfile.TemporaryDirectory(prefix="omniwm-release-") as raw:
            destination = Path(raw)
            self.runner.run(["ditto", "-x", "-k", zip_path, destination], cwd=self.main)
            app = destination / "OmniWM.app"
            require(app.exists(), f"{zip_path} does not contain OmniWM.app")
            with (app / "Contents" / "Info.plist").open("rb") as handle:
                plist = plistlib.load(handle)
            require(
                str(plist.get("CFBundleShortVersionString")) == version,
                "ZIP app version does not match manifest",
            )
            require(
                str(plist.get("CFBundleVersion")) == str(build),
                "ZIP app build does not match manifest",
            )
            require(
                str(plist.get("OMNIWMGitHash")) == embedded_hash,
                "ZIP app embedded Git hash does not match manifest",
            )
            self.check_distribution(app)
            signature = self.runner.run(
                ["codesign", "-dv", "--verbose=4", app],
                cwd=self.main,
                check=False,
                quiet=True,
            )
            require(signature.returncode == 0, "unable to inspect ZIP app signature")
            signature_text = f"{signature.stdout}\n{signature.stderr}"
            require(
                f"Authority={signing_identity}" in signature_text,
                "ZIP app signing identity does not match manifest",
            )
            quarantine = f"0181;{int(time.time()):x};Homebrew Cask;"
            self.runner.run(["xattr", "-w", "com.apple.quarantine", quarantine, app], cwd=self.main)
            self.check_distribution(app, verbose=True)
            self.smoke_test(app)

    def prepare(self, version):
        require(not self.manifest_path(version).exists(), "release manifest already exists; use status or abort")
        plan = self.plan_data(version)
        self.print_plan(plan)
        self.enforce_new_release_plan(plan)
        manifest = {
            "schema": MANIFEST_SCHEMA,
            "version": version,
            "tag": plan["tag"],
            "previous_tag": plan["previous_tag"],
            "previous_version": plan["previous_version"],
            "build": plan["next_build"],
            "state": "preparing",
            "sealed": False,
            "original_main_head": plan["main"].head,
            "release_commit": None,
            "embedded_git_hash": None,
            "signing_identity": self.config.signing_identity,
            "notarize_profile": self.config.notarize_profile,
            "notarization": {"status": "pending", "stapled": False},
            "destinations": {
                "main_remote": plan["main_remote"],
                "github_repo": self.config.github_repo,
            },
            "assets": {},
            "notes_sha256": None,
            "published": {stage: False for stage in PUBLIC_STAGES},
            "release_url": None,
        }
        self.save_manifest(manifest)
        self.write_plist_version(version, plan["next_build"])
        self.write_website_version(version)
        self.runner.run(["make", "verify"], cwd=self.main, capture=False)
        self.runner.run(["swift", "test"], cwd=self.main, capture=False)
        self.runner.run(["swift", "test", "--parallel"], cwd=self.main, capture=False)
        self.run_git(self.main, "add", "Info.plist", "website/src/data/site.ts")
        self.run_git(self.main, "commit", "-m", f"Release {version}")
        release_commit = self.git(self.main, "rev-parse", "HEAD")
        self.require_clean_worktree(
            self.main,
            "main worktree changed immediately after the release commit",
        )
        manifest["release_commit"] = release_commit
        self.save_manifest(manifest)
        package_environment = {
            **os.environ,
            "OMNIWM_SIGNING_IDENTITY": self.config.signing_identity,
            "OMNIWM_NOTARIZE_PROFILE": self.config.notarize_profile,
        }
        self.runner.run(
            ["Scripts/package-app.sh", "release", "true"],
            cwd=self.main,
            capture=False,
            env=package_environment,
        )
        app = self.main / "dist" / "OmniWM.app"
        expected_embedded = self.git(self.main, "rev-parse", "--short", release_commit)
        embedded = self.app_embedded_hash(app)
        require(embedded == expected_embedded, f"embedded Git hash {embedded} does not match release commit {expected_embedded}")
        paths = self.asset_paths(version)
        self.create_zip(app, paths["app"])
        self.verify_app_zip(
            paths["app"],
            version=version,
            build=plan["next_build"],
            embedded_hash=embedded,
            signing_identity=self.config.signing_identity,
        )
        self.create_zip(self.main / "Frameworks" / "GhosttyKit.xcframework", paths["ghostty"])
        self.create_release_text(
            version,
            plan["previous_version"],
            plan["previous_tag"],
            plan["commits"],
        )
        self.require_clean_worktree(
            self.main,
            "main worktree changed during release packaging",
        )
        self.run_git(self.main, "tag", "-a", plan["tag"], "-m", f"OmniWM v{version}")
        app_sha = sha256_file(paths["app"])
        ghostty_sha = sha256_file(paths["ghostty"])
        manifest.update(
            {
                "state": "prepared",
                "release_commit": release_commit,
                "embedded_git_hash": embedded,
                "notarization": {"status": "verified", "stapled": True},
                "assets": {
                    "app": {"path": str(paths["app"]), "sha256": app_sha},
                    "ghostty": {"path": str(paths["ghostty"]), "sha256": ghostty_sha},
                },
            }
        )
        self.save_manifest(manifest)
        self.print_status(manifest)

    def verify_manifest(self, manifest, seal):
        require(isinstance(manifest, dict), "release manifest root must be an object")
        self.validate_manifest_data(manifest, manifest.get("version"))
        version = manifest["version"]
        self.verify_destinations(manifest)
        paths = self.asset_paths(version)
        require(self.repo_state(self.main).branch == "main", "main repo must remain on main")
        require(self.git(self.main, "rev-parse", "HEAD") == manifest["release_commit"], "main HEAD differs from release commit")
        require(self.local_tag_commit(manifest["tag"]) == manifest["release_commit"], "local tag does not match release commit")
        expected_embedded = self.git(
            self.main,
            "rev-parse",
            "--short",
            manifest["release_commit"],
        )
        require(
            manifest["embedded_git_hash"] == expected_embedded,
            "manifest embedded Git hash does not derive from the release commit",
        )
        for key in ("app", "ghostty"):
            path = Path(manifest["assets"][key]["path"])
            require(path.exists(), f"missing {key} asset: {path}")
            require(sha256_file(path) == manifest["assets"][key]["sha256"], f"{key} asset hash drift")
        require(paths["notes"].exists(), f"missing notes: {paths['notes']}")
        self.verify_app_zip(
            Path(manifest["assets"]["app"]["path"]),
            version=version,
            build=manifest["build"],
            embedded_hash=manifest["embedded_git_hash"],
            signing_identity=manifest["signing_identity"],
        )
        notes_sha = sha256_file(paths["notes"])
        if seal:
            manifest["notes_sha256"] = notes_sha
            manifest["sealed"] = True
            manifest["state"] = "sealed"
            self.save_manifest(manifest)
        else:
            require(manifest["sealed"], "manifest is not sealed; run verify")
            require(manifest["notes_sha256"] == notes_sha, "release notes changed after sealing")
        return manifest

    def verify(self, version):
        manifest = self.load_manifest(version)
        self.require_current_schema(manifest, "verify")
        require(manifest["state"] in {"prepared", "sealed"}, "release is not ready for verification")
        self.verify_destinations(manifest)
        self.fetch()
        self.verify_manifest(manifest, seal=True)
        self.print_status(manifest)

    def ensure_main_published(self, manifest):
        remote = self.git(self.main, "rev-parse", "origin/main")
        if remote == manifest["release_commit"]:
            return
        if self.runner.run(
            ["git", "merge-base", "--is-ancestor", manifest["release_commit"], remote],
            cwd=self.main,
            check=False,
            quiet=True,
        ).returncode == 0:
            raise ReleaseError("origin/main advanced beyond the sealed release commit")
        require(
            self.runner.run(
                ["git", "merge-base", "--is-ancestor", remote, manifest["release_commit"]],
                cwd=self.main,
                check=False,
                quiet=True,
            ).returncode
            == 0,
            "origin/main has diverged from the prepared release commit",
        )
        self.runner.run(["git", "push", "origin", "main"], cwd=self.main, capture=False)
        self.runner.run(["git", "fetch", "origin"], cwd=self.main)
        require(self.git(self.main, "rev-parse", "origin/main") == manifest["release_commit"], "main push did not publish sealed commit")

    def ensure_tag_published(self, manifest):
        remote = self.remote_tag_commit(manifest["tag"])
        if remote is None:
            self.runner.run(["git", "push", "origin", manifest["tag"]], cwd=self.main, capture=False)
            remote = self.remote_tag_commit(manifest["tag"])
        require(remote == manifest["release_commit"], "remote tag does not match sealed release commit")

    def verify_existing_release_assets(self, manifest):
        with tempfile.TemporaryDirectory(prefix="omniwm-release-download-") as raw:
            destination = Path(raw)
            self.runner.run(
                [
                    "gh",
                    "release",
                    "download",
                    manifest["tag"],
                    "--repo",
                    self.config.github_repo,
                    "--dir",
                    destination,
                ],
                cwd=self.main,
            )
            for data in manifest["assets"].values():
                local = Path(data["path"])
                downloaded = destination / local.name
                require(downloaded.exists(), f"GitHub release is missing {local.name}")
                require(sha256_file(downloaded) == data["sha256"], f"GitHub asset hash mismatch: {local.name}")

    def ensure_release_published(self, manifest):
        notes = self.asset_paths(manifest["version"])["notes"].read_text(encoding="utf-8").rstrip()
        release = self.github_release(manifest["tag"])
        if release is None:
            self.runner.run(
                [
                    "gh",
                    "release",
                    "create",
                    manifest["tag"],
                    manifest["assets"]["app"]["path"],
                    manifest["assets"]["ghostty"]["path"],
                    "--repo",
                    self.config.github_repo,
                    "--title",
                    f"OmniWM v{manifest['version']}",
                    "--notes-file",
                    self.asset_paths(manifest["version"])["notes"],
                    "--verify-tag",
                    "--latest",
                ],
                cwd=self.main,
                capture=False,
            )
            release = self.github_release(manifest["tag"])
        require(release is not None, "GitHub release was not created")
        require(release["tagName"] == manifest["tag"], "GitHub release tag mismatch")
        require(release["name"] == f"OmniWM v{manifest['version']}", "GitHub release title mismatch")
        require(str(release["body"]).rstrip() == notes, "GitHub release notes mismatch")
        require(not release["isDraft"], "GitHub release is still a draft")
        require(not release["isPrerelease"], "GitHub release is marked as a prerelease")
        require(
            self.latest_github_release_tag() == manifest["tag"],
            "GitHub release is not the latest release",
        )
        expected_assets = {
            Path(data["path"]).name
            for data in manifest["assets"].values()
        }
        actual_assets = {
            asset["name"]
            for asset in release["assets"]
            if isinstance(asset, dict) and isinstance(asset.get("name"), str)
        }
        require(actual_assets == expected_assets, "GitHub release asset set does not exactly match manifest")
        self.verify_existing_release_assets(manifest)
        manifest["release_url"] = release["url"]

    def publish(self, version, yes):
        require(yes, "publishing requires --yes after explicit user confirmation")
        manifest = self.load_manifest(version)
        self.require_current_schema(manifest, "publish")
        self.verify_destinations(manifest)
        self.fetch()
        self.verify_manifest(manifest, seal=False)
        handlers = {
            "main": self.ensure_main_published,
            "tag": self.ensure_tag_published,
            "release": self.ensure_release_published,
        }
        for stage in PUBLIC_STAGES:
            handlers[stage](manifest)
            manifest["published"][stage] = True
            published_count = sum(
                1 for published_stage in PUBLIC_STAGES if manifest["published"][published_stage]
            )
            manifest["state"] = (
                "published"
                if published_count == len(PUBLIC_STAGES)
                else f"published-{PUBLIC_STAGES[published_count - 1]}"
            )
            self.save_manifest(manifest)
        manifest["state"] = "published"
        self.save_manifest(manifest)
        self.print_status(manifest)
        print("Homebrew: the official homebrew/cask omniwm cask is updated by autobump from this GitHub release")

    def print_status(self, manifest):
        print(f"Release {manifest['version']}: {manifest['state']}")
        print(f"- manifest: {self.manifest_path(manifest['version'])}")
        print(f"- release commit: {manifest.get('release_commit') or 'pending'}")
        print(f"- tag: {manifest['tag']}")
        print(f"- sealed: {manifest.get('sealed', False)}")
        for name, data in manifest.get("assets", {}).items():
            print(f"- {name}: {data['path']} ({data['sha256']})")
        for stage in manifest_stages(manifest):
            print(f"- published {stage}: {manifest['published'].get(stage, False)}")
        if manifest.get("release_url"):
            print(f"- release URL: {manifest['release_url']}")

    def public_presence(self, manifest):
        main_remote = self.git(self.main, "rev-parse", "origin/main")
        main_present = main_remote == manifest.get("release_commit")
        if (
            manifest.get("release_commit")
            and not main_present
            and self.runner.run(
                ["git", "merge-base", "--is-ancestor", manifest["release_commit"], main_remote],
                cwd=self.main,
                check=False,
                quiet=True,
            ).returncode
            == 0
        ):
            raise ReleaseError("public main branch advanced beyond the sealed release commit")
        remote_tag = self.remote_tag_commit(manifest["tag"])
        if remote_tag is not None and remote_tag != manifest.get("release_commit"):
            raise ReleaseError("public tag exists but does not match the prepared release commit")
        release = self.github_release(manifest["tag"])
        if release is not None and release.get("tagName") != manifest["tag"]:
            raise ReleaseError("GitHub release exists with an unexpected tag")
        return {
            "main": main_present,
            "tag": remote_tag is not None,
            "release": release is not None,
        }

    def status(self, version):
        manifest = self.load_manifest(version)
        if manifest["schema"] != MANIFEST_SCHEMA:
            self.print_status(manifest)
            complete = manifest["state"] == "published" and all(manifest["published"].values())
            if complete:
                print(f"- live status: unavailable for historical schema {manifest['schema']} manifest")
            else:
                print("- live status unavailable: incomplete historical manifests are unsupported")
            return complete
        try:
            self.verify_destinations(manifest)
            recovered = self.recover_local_checkpoints(manifest.copy())
            self.fetch()
            actual = self.public_presence(recovered)
            manifest = recovered
        except (OSError, ReleaseError, ValueError) as error:
            self.print_status(manifest)
            print(f"- live status unavailable: {error}")
            return False
        self.print_status(manifest)
        for stage in PUBLIC_STAGES:
            print(f"- observed public {stage}: {actual[stage]}")
        return True

    def abort(self, version):
        manifest = self.load_manifest(version)
        self.require_current_schema(manifest, "abort")
        self.verify_destinations(manifest)
        manifest = self.recover_local_checkpoints(manifest)
        self.fetch()
        actual = self.public_presence(manifest)
        require(
            not any(manifest["published"].values()) and not any(actual.values()),
            "cannot abort after any public stage",
        )
        tag = manifest["tag"]
        local_tag = self.local_tag_commit(tag)
        require(
            local_tag is None
            or (
                manifest.get("release_commit") is not None
                and local_tag == manifest["release_commit"]
            ),
            "local release tag does not match the prepared release commit",
        )
        main_branch = self.git(self.main, "branch", "--show-current")
        require(
            main_branch == "main",
            "main repo must be on main before abort",
        )
        main_head = self.git(self.main, "rev-parse", "HEAD")
        require(
            main_head in {manifest["original_main_head"], manifest.get("release_commit")},
            "main HEAD moved after preparation; abort refuses to rewrite it",
        )
        if local_tag:
            self.run_git(self.main, "tag", "-d", tag)
        if manifest.get("release_commit") and main_head == manifest["release_commit"]:
            self.run_git(self.main, "reset", "--mixed", manifest["original_main_head"])
        self.run_git(
            self.main,
            "restore",
            "--staged",
            "--worktree",
            "Info.plist",
            "website/src/data/site.ts",
        )
        for path in self.asset_paths(version).values():
            path.unlink(missing_ok=True)
        self.manifest_path(version).unlink(missing_ok=True)
        print(f"Aborted local release {version}; no public state was changed")


def build_parser():
    parser = argparse.ArgumentParser(description="Prepare and publish sealed OmniWM releases.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "prepare", "verify", "status", "abort"):
        child = subparsers.add_parser(name)
        child.add_argument("version")
    for name in ("publish", "resume"):
        child = subparsers.add_parser(name)
        child.add_argument("version")
        child.add_argument("--yes", action="store_true")
    return parser


def main():
    args = build_parser().parse_args()
    manager = ReleaseManager()
    try:
        if args.command == "plan":
            plan = manager.plan_data(args.version)
            manager.print_plan(plan)
            manager.enforce_new_release_plan(plan)
        elif args.command == "prepare":
            manager.prepare(args.version)
        elif args.command == "verify":
            manager.verify(args.version)
        elif args.command in {"publish", "resume"}:
            manager.publish(args.version, args.yes)
        elif args.command == "status":
            return 0 if manager.status(args.version) else 1
        elif args.command == "abort":
            manager.abort(args.version)
        return 0
    except (OSError, ReleaseError, ValueError) as error:
        print(f"release error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
