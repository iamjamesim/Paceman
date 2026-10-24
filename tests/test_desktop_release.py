import argparse
from contextlib import chdir, ExitStack
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts import desktop_release as release
from scripts import notarize_release as notary


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.version = "0.1.0-alpha.1"
        self.revision = "a" * 40
        self.artifact_names = [f"Paceman-macos-arm64-{self.version}.dmg",
                               f"Paceman-Omarchy-{self.version}.tar.gz"]
        artifacts = []
        for name in self.artifact_names:
            path = self.directory / name
            path.write_bytes(name.encode())
            artifacts.append({"name": name, "bytes": path.stat().st_size,
                              "sha256": release.sha256(path), "publicDownload": True})
        self.manifest = {"version": self.version, "sourceRevision": self.revision,
                         "mode": "developer-id-notarized", "artifacts": artifacts}
        release.write_json(self.directory / "release-manifest.json", self.manifest)
        (self.directory / "RELEASE-NOTES.md").write_text("First alpha\n")
        self.names = self.artifact_names + ["SHA256SUMS"]
        self.checksums()

    def checksums(self):
        (self.directory / "SHA256SUMS").write_text("".join(
            f"{release.sha256(self.directory / name)}  {name}\n" for name in self.artifact_names))

    def git_output(self, *args):
        if args[1:3] == ("cat-file", "-t"):
            return "tag"
        if args[1:3] == ("status", "--porcelain"):
            return ""
        return self.revision

    def test_verifies_exact_artifacts_and_rejects_modified_bytes(self):
        with patch.object(release, "output", side_effect=self.git_output):
            manifest, names = release.verify(self.directory, platform_checks=False)
            self.assertEqual(manifest, self.manifest)
            self.assertEqual(set(names), set(self.names))
            (self.directory / self.artifact_names[0]).write_bytes(b"different build")
            with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                release.verify(self.directory, platform_checks=False)

    def test_rejects_adhoc_manifest_even_with_matching_checksums(self):
        self.manifest["mode"] = "local-candidate"
        release.write_json(self.directory / "release-manifest.json", self.manifest)
        self.checksums()
        with self.assertRaisesRegex(ValueError, "notarized"):
            release.verify(self.directory, platform_checks=False)

    def test_rejects_checksum_path_traversal_and_duplicates(self):
        for entry in (f"{'a'*64}  ../secret\n", (self.directory / "SHA256SUMS").read_text() * 2):
            (self.directory / "SHA256SUMS").write_text(entry)
            with self.assertRaises(ValueError):
                release.checksum_entries(self.directory)

    def test_qa_survives_description_edits_but_not_package_changes(self):
        release.write_json(self.directory / "qa.json", release.qa_record(self.directory))
        (self.directory / "RELEASE-NOTES.md").write_text("Changed release conditions\n")
        self.checksums()
        release.qa_record(self.directory)
        (self.directory / self.artifact_names[0]).write_bytes(b"different build")
        self.checksums()
        with self.assertRaisesRegex(ValueError, "different artifacts"):
            release.qa_record(self.directory)

    def test_checksums_exclude_internal_manifest_and_notes(self):
        with (self.directory / "SHA256SUMS").open("a") as stream:
            for name in ("release-manifest.json", "RELEASE-NOTES.md"):
                stream.write(f"{release.sha256(self.directory / name)}  {name}\n")
        with self.assertRaisesRegex(ValueError, "exactly the two desktop artifacts"):
            release.verify(self.directory, platform_checks=False)

    def test_package_must_match_local_manifest_even_if_checksums_are_updated(self):
        (self.directory / self.artifact_names[0]).write_bytes(b"different build")
        self.checksums()
        with self.assertRaisesRegex(ValueError, "differs from manifest"):
            release.verify(self.directory, platform_checks=False)

    def test_first_release_may_skip_upgrade_only(self):
        checks = {name: {"result": "passed", "notes": "Observed on test device"}
                  for name in release.QA_CHECKS}
        for name in release.UPGRADE_CHECKS:
            checks[name] = {"result": "not-applicable", "notes": "No prior public desktop build"}
        release.require_qa({"checks": checks}, previous_releases=[])
        with self.assertRaisesRegex(ValueError, "QA incomplete"):
            release.require_qa({"checks": checks}, previous_releases=[{"tagName": "v0.0.1"}])
        checks["mac-fresh"]["result"] = "not-applicable"
        with self.assertRaisesRegex(ValueError, "mac-fresh"):
            release.require_qa({"checks": checks}, previous_releases=[])

    def test_publish_stops_before_edit_when_qa_pending(self):
        with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
             patch.object(release, "github_preflight"), patch.object(release, "remote_tag"), \
             patch.object(release, "releases", return_value=[]), \
             patch.object(release, "download_check") as download, patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "QA incomplete"):
                release.publish(self.directory)
            download.assert_not_called()
            run.assert_not_called()

    def test_conflicting_remote_tag_is_never_overwritten(self):
        tag = f"refs/tags/desktop-v{self.version}"
        def output(*args):
            if args[1] == "ls-remote":
                return f"{'b'*40}\t{tag}\n{'c'*40}\t{tag}^{{}}"
            return "d" * 40
        with patch.object(release, "output", side_effect=output), patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "differs"):
                release.remote_tag(self.version, self.revision, push=True)
            run.assert_not_called()

    def test_stage_resumes_partial_upload_without_replacing_assets(self):
        existing_name = self.artifact_names[0]
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[:3] == ("gh", "release", "download"):
                destination = Path(args[args.index("--dir") + 1]) / existing_name
                destination.write_bytes((self.directory / existing_name).read_bytes())
        with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
             patch.object(release, "github_preflight"), patch.object(release, "remote_tag"), \
             patch.object(release, "releases", return_value=[{"tagName": f"desktop-v{self.version}", "isDraft": True}]), \
             patch.object(release, "release_view", return_value={"assets": [{"name": existing_name}]}), \
             patch.object(release, "run", side_effect=run), patch.object(release, "download_check"):
            release.stage(self.directory)
        uploads = [call for call in calls if call[:3] == ("gh", "release", "upload")]
        self.assertEqual(len(uploads), 1)
        self.assertNotIn(self.directory / existing_name, uploads[0])
        self.assertNotIn("--clobber", uploads[0])
        self.assertFalse(any(call[:3] == ("gh", "release", "edit") for call in calls))

    def test_download_mismatch_blocks_verification(self):
        names = self.names
        def download(*args, **kwargs):
            directory = Path(args[args.index("--dir") + 1])
            for name in names:
                (directory / name).write_bytes((self.directory / name).read_bytes())
            (directory / self.artifact_names[0]).write_bytes(b"replaced remotely")
        with patch.object(release, "release_view", return_value={"assets": [{"name": n} for n in names]}), \
             patch.object(release, "run", side_effect=download):
            with self.assertRaisesRegex(ValueError, "Downloaded release asset differs"):
                release.download_check(self.directory, self.manifest, names)
        self.assertFalse((self.directory / "download-verification.json").exists())

    def test_download_verification_uses_local_manifest_without_uploading_it(self):
        def download(*args, **kwargs):
            if args[:3] == ("gh", "release", "download"):
                directory = Path(args[args.index("--dir") + 1])
                for name in self.names:
                    (directory / name).write_bytes((self.directory / name).read_bytes())
        with patch.object(release, "release_view", return_value={
                "assets": [{"name": name} for name in self.names], "url": "draft"}), \
             patch.object(release, "run", side_effect=download), \
             patch.object(release, "output", side_effect=self.git_output), \
             patch.object(release, "verify_embedded_settings"):
            release.download_check(self.directory, self.manifest, self.names)
        record = json.loads((self.directory / "download-verification.json").read_text())
        downloaded = Path(record["directory"])
        self.assertEqual({path.name for path in downloaded.iterdir()}, set(self.names))
        self.assertEqual(record["checksumsSHA256"], release.sha256(self.directory / "SHA256SUMS"))

    def test_remote_internal_attachment_is_rejected(self):
        with patch.object(release, "release_view", return_value={"assets": [
                {"name": name} for name in self.names + ["release-manifest.json"]]}), \
             patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "expected release set"):
                release.download_check(self.directory, self.manifest, self.names)
            run.assert_not_called()

    def test_prepare_requires_green_ci_before_creating_tag(self):
        args = argparse.Namespace(version=self.version, build_number=1,
                                  notes_file=self.directory / "RELEASE-NOTES.md")
        with patch.object(release.sys, "platform", "darwin"), \
             patch.object(release, "output", side_effect=self.git_output), \
             patch.object(release, "github_preflight"), \
             patch.object(release, "gh", return_value=[{"headSha": self.revision,
                 "status": "completed", "conclusion": "failure"}]), \
             patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "Checks workflow"):
                release.prepare(args)
            run.assert_not_called()

    def test_failed_download_verification_prevents_publish(self):
        record = {"checksumsSHA256": release.sha256(self.directory / "SHA256SUMS"),
                  "checks": {name: {"result": "passed", "notes": "Observed"}
                             for name in release.QA_CHECKS}}
        release.write_json(self.directory / "qa.json", record)
        with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
             patch.object(release, "github_preflight"), patch.object(release, "remote_tag"), \
             patch.object(release, "releases", return_value=[]), \
             patch.object(release, "download_check", side_effect=ValueError("remote changed")), \
             patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "remote changed"):
                release.publish(self.directory)
            run.assert_not_called()

    def test_release_tag_and_classification_follow_version(self):
        for version in ("0.1.0", "0.2.0-beta.1"):
            with self.subTest(version=version):
                manifest = {**self.manifest, "version": version}
                tag = f"desktop-v{version}"
                with patch.object(release, "verify", return_value=(manifest, self.names)), \
                     patch.object(release, "github_preflight"), patch.object(release, "remote_tag"), \
                     patch.object(release, "releases", return_value=[]), \
                     patch.object(release, "download_check"), patch.object(release, "run") as run:
                    release.stage(self.directory)
                    command = run.call_args.args
                    self.assertEqual(command[:4], ("gh", "release", "create", tag))
                    self.assertEqual("--prerelease" in command, "-" in version)
                    self.assertIn(f"Desktop {version}", command)
                    notes_index = command.index("--notes-file")
                    self.assertEqual(command[notes_index + 1], self.directory / "RELEASE-NOTES.md")
                    self.assertEqual(set(command[notes_index + 2:]),
                                     {self.directory / name for name in self.names})
                record = {"checks": {name: {"result": "passed", "notes": "Observed"}
                                     for name in release.QA_CHECKS}}
                for name in release.UPGRADE_CHECKS:
                    record["checks"][name]["result"] = "not-applicable"
                with patch.object(release, "verify", return_value=(manifest, self.names)), \
                     patch.object(release, "github_preflight"), patch.object(release, "remote_tag"), \
                     patch.object(release, "releases", return_value=[{"tagName": "ios-v1.0.0", "isDraft": False}]), \
                     patch.object(release, "qa_record", return_value=record), \
                     patch.object(release, "download_check"), \
                     patch.object(release, "release_view", return_value={"isDraft": True, "url": "draft"}), \
                     patch.object(release, "run") as run:
                    release.publish(self.directory)
                    command = run.call_args.args
                    self.assertEqual(command[:4], ("gh", "release", "edit", tag))
                    self.assertIn(f"--prerelease={str('-' in version).lower()}", command)

    def test_repository_case_change_is_allowed_but_other_repo_is_rejected(self):
        with patch.object(release, "run"), \
             patch.object(release, "gh", return_value={"nameWithOwner": "iamjamesim/Paceman"}), \
             patch.object(release, "output", return_value="https://github.com/iamjamesim/paceman.git"):
            release.github_preflight()
        with patch.object(release, "run"), \
             patch.object(release, "gh", return_value={"nameWithOwner": "other/Paceman"}):
            with self.assertRaisesRegex(ValueError, "Expected GitHub repository"):
                release.github_preflight()

    def test_qa_requires_current_download_verification(self):
        release.write_json(self.directory / "download-verification.json", {"checksumsSHA256": "outdated"})
        args = argparse.Namespace(directory=self.directory, check="mac-fresh",
                                  result="passed", notes="Observed on macOS 26.7")
        with patch.object(release, "verify", return_value=(self.manifest, self.names)):
            with self.assertRaisesRegex(ValueError, "current downloads"):
                release.record_qa(args)
        self.assertFalse((self.directory / "qa.json").exists())

class FeedTests(unittest.TestCase):
    setUp = ReleaseTests.setUp
    checksums = ReleaseTests.checksums

    def configure(self):
        self.manifest.update(updater={
            "feedURL": release.FEED_BASE_URL + "/macos/stable/appcast.xml",
            "publicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        }, buildNumber=42, sparkleLockSHA256=release.sha256(release.ROOT / "macos/sparkle.json"))
        self.pages = (self.directory / "pages").resolve()
        self.pages.mkdir()
        (self.pages / ".nojekyll").touch()
        (self.pages / "CNAME").write_text("updates.paceman.ai\n")
        self.target = self.pages / "macos/test/appcast.xml"
        self.options = dict(feed_channel="test", pages_dir=self.pages,
                            sparkle_archive=self.directory / "Sparkle.tar.xz",
                            keychain_account="paceman-release", approve_feed_signing=True)
        self.prefix = f"https://github.com/{release.REPOSITORY}/releases/download/desktop-v{self.version}/"
        self.events = []

    def preflight(self, **overrides):
        args = dict(channel="test", pages_dir=self.pages,
                    sparkle_archive=self.directory / "Sparkle.tar.xz", account="paceman-release", approved=True)
        args.update(overrides)
        return release.feed_preflight(self.manifest, **args)

    def pages_output(self, *args):
        if "--show-toplevel" in args:
            return str(self.pages)
        if "--show-current" in args:
            return "gh-pages"
        if "get-url" in args:
            return f"https://github.com/{release.REPOSITORY}.git"
        return ""

    def signed_output(self, *args):
        self.events.append((Path(args[0]).name, *args[1:]))
        if Path(args[0]).name == "generate_keys":
            return self.manifest["updater"]["publicEDKey"]
        return "MOCK_SIGNATURE_NO_CRYPTO_EXECUTED"

    def signed_run(self, *args, **kwargs):
        self.events.append((Path(args[0]).name, *args[1:]))
        if Path(args[0]).name == "generate_appcast":
            path = Path(args[args.index("-o") + 1])
            root = release.ET.parse(path).getroot() if path.exists() else release.ET.fromstring("<rss><channel/></rss>")
            item = release.ET.Element("item")
            release.ET.SubElement(item, f"{{{release.SPARKLE_NS}}}version").text = str(self.manifest["buildNumber"])
            release.ET.SubElement(item, f"{{{release.SPARKLE_NS}}}shortVersionString").text = self.version.split("-")[0]
            notes = next(path.parent.glob("*.md")).read_text()
            release.ET.SubElement(item, "description").text = notes
            mac = next(path.parent.glob("*.dmg"))
            release.ET.SubElement(item, "enclosure", {"url": self.prefix + mac.name,
                "length": str(mac.stat().st_size), f"{{{release.SPARKLE_NS}}}edSignature": "MOCK_SIGNATURE"})
            root.find("channel").insert(0, item)
            release.ET.ElementTree(root).write(path, encoding="utf-8")

    def verified_feed(self, path, *args):
        # Signature execution is mocked; content and publication guards run normally.
        return release.ET.parse(path).getroot()

    def stage(self):
        with patch.object(release, "public_download_check", return_value=self.prefix), \
             patch.object(release.sparkle_dependency, "framework", return_value=Path("/mock/Sparkle.framework")), \
             patch.object(release, "verify_signed_feed", side_effect=self.verified_feed), \
             patch.object(release, "output", side_effect=self.signed_output), \
             patch.object(release, "run", side_effect=self.signed_run):
            release.stage_feed(self.directory, self.manifest, self.names, channel="test",
                               pages_dir=self.pages, sparkle_archive=Path("/mock/archive"), account="paceman-release")

    def qa(self, *, updater=True):
        return {"checksumsSHA256": release.sha256(self.directory / "SHA256SUMS"),
                "checks": {name: {"result": "passed", "notes": "Observed in isolated signed trial"}
                           for name in release.QA_CHECKS | (release.UPDATER_QA_CHECKS if updater else {})}}

    def test_configured_release_requires_explicit_signing_opt_in_before_any_live_work(self):
        self.configure()
        with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
             patch.object(release, "github_preflight") as github, patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "guarded feed"):
                release.publish(self.directory)
            with self.assertRaisesRegex(ValueError, "approve-feed-signing"):
                release.publish(self.directory, **{**self.options, "approve_feed_signing": False})
            github.assert_not_called()
            run.assert_not_called()

    def test_pages_preflight_rejects_wrong_repo_branch_unrelated_changes_and_channel(self):
        self.configure()
        with patch.object(release, "output", side_effect=self.pages_output):
            self.preflight()  # Stable candidate can be trialed through the isolated test feed.
            with self.assertRaisesRegex(ValueError, "Prereleases"):
                self.preflight(channel="stable")
        for replaced in ("other/marketing.git", "main", "unrelated.txt"):
            def wrong(*args):
                if replaced == "other/marketing.git" and "get-url" in args:
                    return "https://github.com/other/marketing.git"
                if replaced == "main" and "--show-current" in args:
                    return "main"
                if replaced == "unrelated.txt" and "diff" in args:
                    return replaced
                return self.pages_output(*args)
            with patch.object(release, "output", side_effect=wrong), self.assertRaises(ValueError):
                self.preflight()
        self.manifest["version"] = "0.1.0"
        self.manifest["updater"]["feedURL"] = release.FEED_BASE_URL + "/macos/test/appcast.xml"
        with self.assertRaisesRegex(ValueError, "channel differs"):
            self.preflight(channel="stable")

    def test_updater_provenance_requires_current_lock_and_public_only_config(self):
        self.configure()
        release.write_json(self.directory / "release-manifest.json", self.manifest)
        with patch.object(release, "output", side_effect=ReleaseTests.git_output.__get__(self)):
            release.verify(self.directory, platform_checks=False)
            self.manifest["updater"]["privateKey"] = "must never be accepted"
            release.write_json(self.directory / "release-manifest.json", self.manifest)
            with self.assertRaisesRegex(ValueError, "never a private key"):
                release.verify(self.directory, platform_checks=False)
            del self.manifest["updater"]["privateKey"]
            self.manifest["sparkleLockSHA256"] = "outdated"
            release.write_json(self.directory / "release-manifest.json", self.manifest)
            with self.assertRaisesRegex(ValueError, "provenance"):
                release.verify(self.directory, platform_checks=False)

    def test_feed_preflight_requires_exact_custom_domain_and_root_feed_changes(self):
        self.configure()
        def changed_feed(*args):
            if "diff" in args:
                return "macos/test/appcast.xml"
            return self.pages_output(*args)
        with patch.object(release, "output", side_effect=changed_feed):
            self.preflight()
            cname = self.pages / "CNAME"
            for value in ("paceman.ai", "other.example", ""):
                cname.write_text(value + "\n")
                with self.assertRaisesRegex(ValueError, "custom domain"):
                    self.preflight()
            cname.unlink()
            with self.assertRaisesRegex(ValueError, "custom domain"):
                self.preflight()
            marker = self.directory / "domain-marker"
            marker.write_text("updates.paceman.ai\n")
            cname.symlink_to(marker)
            with self.assertRaisesRegex(ValueError, "custom domain"):
                self.preflight()
            cname.unlink()
            cname.write_text("updates.paceman.ai\n")
            (self.pages / ".nojekyll").unlink()
            with self.assertRaisesRegex(ValueError, "nojekyll"):
                self.preflight()

    def test_feed_preflight_rejects_old_nested_path_and_symlinked_macos_directory(self):
        self.configure()
        def nested(*args):
            if "diff" in args:
                return "updates/macos/test/appcast.xml"
            return self.pages_output(*args)
        with patch.object(release, "output", side_effect=nested), self.assertRaisesRegex(ValueError, "unrelated changes"):
            self.preflight()
        elsewhere = self.directory / "elsewhere"
        elsewhere.mkdir()
        (self.pages / "macos").symlink_to(elsewhere, target_is_directory=True)
        with patch.object(release, "output", side_effect=self.pages_output), self.assertRaisesRegex(ValueError, "symlinks"):
            self.preflight()

    def test_stable_requires_signed_qa_while_test_feed_bootstraps_trial(self):
        self.configure()
        release.require_qa(self.qa(updater=False), previous_releases=[], updater=False)
        with self.assertRaisesRegex(ValueError, "mac-signed-update"):
            release.require_qa(self.qa(updater=False), previous_releases=[], updater=True)
        release.require_qa(self.qa(), previous_releases=[], updater=True)

    def test_incomplete_qa_and_failed_downloads_block_all_signing_and_release_mutation(self):
        self.configure()
        for complete in (False, True):
            with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
                 patch.object(release, "feed_preflight"), patch.object(release, "github_preflight"), \
                 patch.object(release, "remote_tag"), patch.object(release, "releases", return_value=[]), \
                 patch.object(release, "qa_record", return_value=self.qa() if complete else {}), \
                 patch.object(release, "download_check", side_effect=ValueError("download mismatch")), \
                 patch.object(release, "stage_feed") as signing, patch.object(release, "run") as run:
                with self.assertRaises(ValueError):
                    release.publish(self.directory, **self.options)
                signing.assert_not_called()
                run.assert_not_called()

    def test_publish_orders_assets_before_feed_and_retries_feed_without_replacing_packages(self):
        self.configure()
        events = []
        public = [False]
        def view(*args):
            return {"isDraft": not public[0], "isPrerelease": True, "url": "public-release"}
        def run(*args, **kwargs):
            events.append("publish-assets")
            self.assertEqual(args[:3], ("gh", "release", "edit"))
            public[0] = True
        attempts = [0]
        def feed(*args, **kwargs):
            events.append("sign-feed")
            attempts[0] += 1
            if attempts[0] == 1:
                raise ValueError("signing failed; no feed")
        with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
             patch.object(release, "feed_preflight"), patch.object(release, "github_preflight"), \
             patch.object(release, "remote_tag"), patch.object(release, "releases", return_value=[]), \
             patch.object(release, "qa_record", return_value=self.qa()), \
             patch.object(release, "download_check", side_effect=lambda *args: events.append("check-assets")), \
             patch.object(release, "release_view", side_effect=view), \
             patch.object(release, "run", side_effect=run), patch.object(release, "stage_feed", side_effect=feed):
            with self.assertRaisesRegex(ValueError, "signing failed"):
                release.publish(self.directory, **self.options)
            release.publish(self.directory, **self.options)
        self.assertEqual(events, ["check-assets", "publish-assets", "check-assets", "sign-feed",
                                  "check-assets", "check-assets", "sign-feed"])

    def test_public_mismatch_blocks_key_lookup_and_preserves_feed(self):
        self.configure()
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"previous signed feed")
        with patch.object(release, "public_download_check", side_effect=ValueError("public bytes differ")), \
             patch.object(release.sparkle_dependency, "framework") as framework:
            with self.assertRaisesRegex(ValueError, "public bytes differ"):
                release.stage_feed(self.directory, self.manifest, self.names, channel="test",
                                   pages_dir=self.pages, sparkle_archive=Path("/mock/archive"), account="release")
            framework.assert_not_called()
        self.assertEqual(self.target.read_bytes(), b"previous signed feed")

    def test_relative_pages_checkout_from_external_cwd_survives_existing_feed_retry(self):
        self.configure()
        def signing(*args, **kwargs):
            if Path(args[0]).name == "sign_update" and Path(args[-1]).suffix == ".xml":
                effective = release.ROOT / Path(args[-1])
                self.assertTrue(Path(args[-1]).is_absolute())
                self.assertTrue(effective.is_file(), f"Real signer cwd cannot read {effective}")
            self.signed_run(*args, **kwargs)
        with chdir(self.directory), \
             patch.object(release, "public_download_check", return_value=self.prefix), \
             patch.object(release.sparkle_dependency, "framework", return_value=Path("/mock/Sparkle.framework")), \
             patch.object(release, "output", side_effect=self.signed_output), \
             patch.object(release, "run", side_effect=signing), \
             patch.object(release, "verify_signed_feed", side_effect=self.verified_feed):
            for _ in range(2):
                release.stage_feed(self.directory.resolve(), self.manifest, self.names, channel="test",
                                   pages_dir=Path("pages"), sparkle_archive=Path("/mock/archive"), account="release")
        self.assertTrue(self.target.is_file())

    def test_failed_postpublication_download_check_blocks_feed(self):
        self.configure()
        with patch.object(release, "verify", return_value=(self.manifest, self.names)), \
             patch.object(release, "feed_preflight"), patch.object(release, "github_preflight"), \
             patch.object(release, "remote_tag"), patch.object(release, "releases", return_value=[]), \
             patch.object(release, "qa_record", return_value=self.qa()), \
             patch.object(release, "download_check", side_effect=[None, ValueError("post-publication mismatch")]), \
             patch.object(release, "release_view", return_value={"isDraft": True}), \
             patch.object(release, "run") as run, patch.object(release, "stage_feed") as feed:
            with self.assertRaisesRegex(ValueError, "post-publication mismatch"):
                release.publish(self.directory, **self.options)
            self.assertEqual(run.call_count, 1)  # Assets became public; feed remains untouched.
            feed.assert_not_called()

    def test_wrong_archive_hash_stops_before_any_keychain_lookup(self):
        self.configure()
        archive = self.directory / "wrong-sparkle.tar.xz"
        archive.write_bytes(b"not the pinned archive")
        with patch.object(release, "public_download_check", return_value=self.prefix), \
             patch.object(release, "output") as output:
            with self.assertRaisesRegex(ValueError, "does not match"):
                release.stage_feed(self.directory, self.manifest, self.names, channel="test",
                                   pages_dir=self.pages, sparkle_archive=archive, account="release")
            output.assert_not_called()

    def test_public_downloads_use_anonymous_https_and_exact_bytes(self):
        self.configure()
        def curl(*args, **kwargs):
            self.assertEqual(args[0], "curl")
            self.assertIn("--proto-redir", args)
            self.assertTrue(args[-1].startswith(self.prefix))
            target = Path(args[args.index("--output") + 1])
            target.write_bytes((self.directory / target.name).read_bytes())
        with patch.object(release, "run", side_effect=curl):
            self.assertEqual(release.public_download_check(self.directory, self.manifest, self.names), self.prefix)
        def bad(*args, **kwargs):
            curl(*args, **kwargs)
            Path(args[args.index("--output") + 1]).write_bytes(b"changed remotely")
        with patch.object(release, "run", side_effect=bad), self.assertRaisesRegex(ValueError, "Public release asset differs"):
            release.public_download_check(self.directory, self.manifest, self.names)

    def test_signing_uses_pinned_tools_keychain_only_and_embeds_notes(self):
        self.configure()
        self.stage()
        root = release.ET.parse(self.target).getroot()
        item = root.find("channel/item")
        self.assertEqual(item.findtext(f"{{{release.SPARKLE_NS}}}version"), "42")
        self.assertIn("First alpha", item.findtext("description"))
        self.assertEqual(item.find("enclosure").get("url"), self.prefix + self.artifact_names[0])
        self.assertEqual(sum(event[0] == "generate_appcast" for event in self.events), 1)
        self.assertFalse(any(event[0] in ("generate_keys", "sign_update") for event in self.events))
        self.assertFalse(any("--ed-key-file" in event or "-s" in event or "git" == event[0] for event in self.events))
        evidence = json.loads((self.directory / "feed-staging.json").read_text())
        self.assertFalse(evidence["published"])
        self.assertEqual(evidence["feedSHA256"], release.sha256(self.target))
        self.assertEqual(evidence["feedURL"], "https://updates.paceman.ai/macos/test/appcast.xml")

    def test_repeated_staging_is_byte_identical_and_changed_notes_same_build_are_rejected(self):
        self.configure()
        self.stage()
        original = self.target.read_bytes()
        (self.directory / "feed-staging.json").unlink()
        self.stage()
        self.assertEqual(self.target.read_bytes(), original)
        self.assertTrue((self.directory / "feed-staging.json").is_file())
        (self.directory / "RELEASE-NOTES.md").write_text("Changed same build")
        with self.assertRaisesRegex(ValueError, "Existing feed build differs"):
            self.stage()
        self.assertEqual(self.target.read_bytes(), original)

    def test_equivalent_signed_semantics_survive_formatting_without_resigning(self):
        self.configure()
        self.stage()
        tree = release.ET.parse(self.target)
        release.ET.indent(tree)
        tree.write(self.target, encoding="utf-8", xml_declaration=True)
        original = self.target.read_bytes()
        self.stage()
        self.assertEqual(self.target.read_bytes(), original)

    def test_semantic_digest_preserves_markdown_whitespace(self):
        original = release.ET.fromstring("<item><description>release notes</description></item>")
        changed = release.ET.fromstring("<item><description>    release notes</description></item>")
        self.assertNotEqual(release.semantic_digest(original), release.semantic_digest(changed))

    def test_interrupted_evidence_write_recovers_reviewed_signed_feed_without_resigning(self):
        self.configure()
        with patch.object(release, "record_feed_staging", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.stage()
        original = self.target.read_bytes()
        self.assertFalse((self.directory / "feed-test-staging.json").exists())
        self.assertTrue((self.directory / "feed-test-intent.json").exists())
        self.stage()
        self.assertEqual(self.target.read_bytes(), original)
        self.assertEqual(sum(event[0] == "generate_appcast" for event in self.events), 1)
        record = json.loads((self.directory / "feed-test-staging.json").read_text())
        self.assertEqual(record["feedSHA256"], release.sha256(self.target))

    def test_interrupted_evidence_cannot_adopt_conflicting_signed_metadata_or_notes(self):
        self.configure()
        with patch.object(release, "record_feed_staging", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.stage()
        original = self.target.read_bytes()
        for field in ("description", f"{{{release.SPARKLE_NS}}}minimumSystemVersion"):
            root = release.ET.fromstring(original)
            item = root.find("channel/item")
            node = item.find(field)
            if node is None:
                node = release.ET.SubElement(item, field)
            node.text = "conflicting signed value"
            self.target.write_bytes(release.ET.tostring(root))
            changed = self.target.read_bytes()
            with self.assertRaisesRegex(ValueError, "Existing feed build differs"):
                self.stage()
            self.assertEqual(self.target.read_bytes(), changed)
        self.target.write_bytes(original)
        self.stage()
        self.assertEqual(sum(event[0] == "generate_appcast" for event in self.events), 1)

    def test_new_feed_keeps_old_items_and_rejects_downgrade(self):
        self.configure()
        self.stage()
        self.manifest["buildNumber"] += 1
        self.stage()
        items = release.ET.parse(self.target).findall("channel/item")
        self.assertEqual([item.findtext(f"{{{release.SPARKLE_NS}}}version") for item in items], ["43", "42"])
        original = self.target.read_bytes()
        self.manifest["buildNumber"] = 41
        with self.assertRaisesRegex(ValueError, "lower build"):
            self.stage()
        self.assertEqual(self.target.read_bytes(), original)

    def test_wrong_key_failed_signing_or_verification_never_replace_current_feed(self):
        self.configure()
        self.stage()
        original = self.target.read_bytes()
        self.manifest["buildNumber"] += 1
        for failure in ("wrong-key", "sign", "verify-existing", "verify-new"):
            def run(*args, **kwargs):
                if failure == "sign" and Path(args[0]).name == "generate_appcast":
                    raise ValueError("sign failed")
                return self.signed_run(*args, **kwargs)
            def verify(path, *args):
                existing = path == self.target
                if (failure == "wrong-key" or (failure == "verify-existing" and existing)
                        or (failure == "verify-new" and not existing)):
                    raise ValueError("public signature mismatch")
                return self.verified_feed(path, *args)
            with patch.object(release, "public_download_check", return_value=self.prefix), \
                 patch.object(release.sparkle_dependency, "framework", return_value=Path("/mock/Sparkle.framework")), \
                 patch.object(release, "verify_signed_feed", side_effect=verify), \
                 patch.object(release, "run", side_effect=run):
                with self.assertRaises(ValueError):
                    release.stage_feed(self.directory, self.manifest, self.names, channel="test",
                                       pages_dir=self.pages, sparkle_archive=Path("/mock/archive"), account="release")
            self.assertEqual(self.target.read_bytes(), original)


class NotarizationTests(unittest.TestCase):
    def test_timeout_resumes_same_submission_and_staples_original_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            dmg = Path(temporary) / "Paceman.dmg"
            dmg.write_bytes(b"signed original")
            context = {"sourceRevision": "a" * 40, "version": "0.1.0-alpha.1"}
            submission = "00000000-0000-4000-8000-000000000001"
            calls = []
            status = ["In Progress"]
            def apple(profile, *args, **kwargs):
                calls.append(args[0])
                value = {"id": submission} if args[0] == "submit" else {"status": status[0]}
                if args[0] == "log":
                    Path(args[2]).write_text('{"issues":null}')
                return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
            def command(args, **kwargs):
                if args[1:3] == ["stapler", "staple"]:
                    self.assertEqual(dmg.read_bytes(), b"signed original")
                    dmg.write_bytes(b"signed original plus ticket")
            with patch.object(notary, "apple", side_effect=apple), \
                 patch.object(notary.subprocess, "run", side_effect=command):
                with self.assertRaisesRegex(ValueError, "still processing"):
                    notary.notarize(dmg, "test-profile", context)
                status[0] = "Accepted"
                dmg.write_bytes(b"interrupted previous stapling")
                notary.notarize(dmg, "test-profile", context, resume=True)
            self.assertEqual(calls.count("submit"), 1)
            state = json.loads((dmg.parent / ".notarization/submission.json").read_text())
            self.assertEqual(state["id"], submission)
            self.assertEqual(state["status"], "Accepted")
            self.assertEqual(state["stapledSHA256"], notary.digest(dmg))

    def test_resume_rejects_changed_build_or_unknown_upload_outcome(self):
        with tempfile.TemporaryDirectory() as temporary:
            dmg = Path(temporary) / "Paceman.dmg"
            evidence = dmg.parent / ".notarization"
            evidence.mkdir()
            original = evidence / "submitted.dmg"
            original.write_bytes(b"original")
            notary.save(evidence / "submission.json", {
                "context": {"version": "1"}, "submittedSHA256": notary.digest(original),
            })
            with patch.object(notary, "apple") as apple:
                with self.assertRaisesRegex(ValueError, "does not match"):
                    notary.notarize(dmg, "profile", {"version": "2"}, resume=True)
                with self.assertRaisesRegex(ValueError, "outcome is unknown"):
                    notary.notarize(dmg, "profile", {"version": "1"}, resume=True)
                apple.assert_not_called()


if __name__ == "__main__":
    unittest.main()
class CandidateTests(unittest.TestCase):
    setUp_artifacts = ReleaseTests.setUp
    checksums = ReleaseTests.checksums
    configure = FeedTests.configure
    pages_output = FeedTests.pages_output
    signed_run = FeedTests.signed_run
    verified_feed = FeedTests.verified_feed
    qa = FeedTests.qa

    def setUp(self):
        self.setUp_artifacts()
        self.configure()
        old_version = self.version
        self.version = "0.9.0"
        for asset in self.manifest["artifacts"]:
            old_name = asset["name"]
            asset["name"] = old_name.replace(old_version, self.version)
            (self.directory / old_name).rename(self.directory / asset["name"])
        self.manifest["version"] = self.version
        self.artifact_names = [asset["name"] for asset in self.manifest["artifacts"]]
        self.names = self.artifact_names + ["SHA256SUMS"]
        self.checksums()
        release.write_json(self.directory / "release-manifest.json", self.manifest)
        self.prefix = f"https://github.com/{release.REPOSITORY}/releases/download/desktop-v{self.version}/"
        self.remote = None
        self.tag_object = "b" * 40
        self.live_feeds = {}
        self.calls = []
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for name, kwargs in {
            "verify": {"return_value": (self.manifest, self.names)},
            "github_preflight": {}, "remote_tag": {}, "download_check": {},
            "releases": {"side_effect": lambda: [self.remote] if self.remote else []},
            "release_view": {"side_effect": lambda _version: self.remote},
            "output": {"side_effect": self.candidate_output},
            "run": {"side_effect": self.command},
            "public_download_check": {"return_value": self.prefix},
            "fetch_public_feed": {"side_effect": self.fetch},
            "verify_signed_feed": {"side_effect": self.verified_feed},
        }.items():
            self.stack.enter_context(patch.object(release, name, **kwargs))
        self.stack.enter_context(patch.object(release.sparkle_dependency, "framework", return_value=Path("/mock/Sparkle.framework")))
        release.write_json(self.directory / "qa.json", self.qa(updater=False))
        release.write_json(self.directory / "download-verification.json", {"checksumsSHA256": release.sha256(self.directory / "SHA256SUMS")})

    def candidate_output(self, *args):
        if args[:2] == ("git", "rev-parse"):
            return self.tag_object
        return self.pages_output(*args)

    def command(self, *args, **kwargs):
        self.calls.append(args)
        if args[:3] == ("gh", "release", "create"):
            self.remote = {"tagName": f"desktop-v{self.version}", "databaseId": 99,
                "isDraft": True, "isPrerelease": "--prerelease" in args, "url": "fixture",
                "assets": [{"name": name, "size": (self.directory / name).stat().st_size,
                            "apiUrl": f"https://api.github.com/repos/{release.REPOSITORY}/releases/assets/{i}"}
                           for i, name in enumerate(self.names, 1)]}
        elif args[:3] == ("gh", "release", "edit"):
            if "--draft=false" in args:
                self.remote["isDraft"] = False
            self.remote["isPrerelease"] = "--prerelease=true" in args
        elif Path(args[0]).name == "generate_appcast":
            self.signed_run(*args, **kwargs)
        else:
            raise AssertionError(f"Unexpected live operation: {args}")

    def fetch(self, channel, destination, *, allow_missing=False):
        if channel not in self.live_feeds:
            if allow_missing:
                return False
            raise ValueError("Public test feed not yet published")
        destination.write_bytes(self.live_feeds[channel])
        return True

    def test_stage_test_and_promote_keep_exact_assets_and_feed(self):
        self.publish_and_qa()
        original = self.target.read_bytes()
        identity = release.checked_candidate(self.directory, self.manifest)["identity"]
        release.promote(self.directory, pages_dir=self.pages)
        stable = self.pages / "macos/stable/appcast.xml"
        self.assertEqual(stable.read_bytes(), original)
        self.assertEqual(release.checked_candidate(self.directory, self.manifest)["identity"], identity)
        self.assertFalse(self.remote["isPrerelease"])
        self.assertTrue(any("--latest=false" in call for call in self.calls))
        self.assertIn("--latest=true", self.calls[-1])
        self.assertEqual(sum(Path(call[0]).name == "generate_appcast" for call in self.calls), 1)
        self.assertFalse(any("upload" in call or "build" in call or "push" in call for call in self.calls))
        release.promote(self.directory, pages_dir=self.pages)  # Metadata/feed retry, no re-signing.
        self.assertEqual(stable.read_bytes(), original)

    def publish_and_qa(self):
        release.stage(self.directory, candidate=True)
        self.assertTrue(self.remote["isPrerelease"])
        release.publish_test(self.directory, **{key: value for key, value in self.options.items() if key != "feed_channel"})
        self.assertFalse(self.remote["isDraft"])
        self.assertTrue(self.remote["isPrerelease"])
        self.live_feeds["test"] = self.target.read_bytes()  # Model the separately approved Pages push.
        for name in release.UPDATER_QA_CHECKS:
            release.record_qa(argparse.Namespace(directory=self.directory, check=name, result="passed",
                                                 notes="Observed exact candidate on physical test Mac"))

    def test_candidate_cannot_use_legacy_publish_to_bypass_promotion(self):
        release.stage(self.directory, candidate=True)
        count = len(self.calls)
        with self.assertRaisesRegex(ValueError, "publish-test then promote"):
            release.publish(self.directory, **self.options)
        self.assertEqual(len(self.calls), count)

    def test_failed_package_qa_and_postpublish_anonymous_download_stop_test_feed(self):
        release.stage(self.directory, candidate=True)
        record = self.qa(updater=False)
        record["checks"]["mac-upgrade"]["result"] = "failed"
        release.write_json(self.directory / "qa.json", record)
        count = len(self.calls)
        options = {key: value for key, value in self.options.items() if key != "feed_channel"}
        with self.assertRaisesRegex(ValueError, "QA incomplete"):
            release.publish_test(self.directory, **options)
        self.assertEqual(len(self.calls), count)
        release.write_json(self.directory / "qa.json", self.qa(updater=False))
        with patch.object(release, "public_download_check", side_effect=ValueError("anonymous mismatch")):
            with self.assertRaisesRegex(ValueError, "anonymous mismatch"):
                release.publish_test(self.directory, **options)
        self.assertTrue(self.remote["isPrerelease"])
        self.assertFalse(self.target.exists())
        self.assertFalse((self.pages / "macos/stable/appcast.xml").exists())

    def test_test_feed_retry_reuses_signed_bytes_without_signing_again(self):
        self.publish_and_qa()
        original = self.target.read_bytes()
        self.target.unlink()
        with patch.object(release, "stage_feed") as signer:
            release.publish_test(self.directory, **{key: value for key, value in self.options.items() if key != "feed_channel"})
            signer.assert_not_called()
        self.assertEqual(self.target.read_bytes(), original)

    def test_alpha_and_test_embedded_settings_cannot_be_promoted(self):
        for version, feed in (("0.9.0-alpha.1", "stable"), ("0.9.0", "test")):
            with self.subTest(version=version, feed=feed):
                self.manifest["version"] = version
                self.manifest["updater"]["feedURL"] = f"{release.FEED_BASE_URL}/macos/{feed}/appcast.xml"
                with self.assertRaisesRegex(ValueError, "final numeric"):
                    release.stage(self.directory, candidate=True)
        self.assertEqual(self.calls, [])

    def test_asset_replacement_manifest_notes_and_tag_changes_stop_before_mutation(self):
        release.stage(self.directory, candidate=True)
        for kind in ("asset", "release", "tag", "tag-object", "manifest", "notes"):
            with self.subTest(kind=kind):
                before = json.loads(json.dumps(self.remote))
                path = self.directory / ("RELEASE-NOTES.md" if kind == "notes" else "release-manifest.json")
                original = path.read_bytes()
                if kind == "asset": self.remote["assets"][0]["apiUrl"] += "-replacement"
                elif kind == "release": self.remote["databaseId"] += 1
                elif kind == "tag": self.remote["tagName"] += "-other"
                elif kind == "tag-object": self.tag_object = "c" * 40
                else: path.write_bytes(original + b"\n")
                count = len(self.calls)
                with self.assertRaisesRegex(ValueError, "identity changed|tag differs"):
                    release.publish_test(self.directory, **{key: value for key, value in self.options.items() if key != "feed_channel"})
                self.assertEqual(len(self.calls), count)
                self.remote = before
                self.tag_object = "b" * 40
                path.write_bytes(original)

    def test_signing_failure_retry_reuses_public_release_assets(self):
        release.stage(self.directory, candidate=True)
        with patch.object(release, "stage_feed", side_effect=ValueError("signing failed")):
            with self.assertRaisesRegex(ValueError, "signing failed"):
                release.publish_test(self.directory, **{key: value for key, value in self.options.items() if key != "feed_channel"})
        self.assertFalse(self.remote["isDraft"])
        self.assertTrue(self.remote["isPrerelease"])
        self.assertFalse(self.target.exists())
        release.publish_test(self.directory, **{key: value for key, value in self.options.items() if key != "feed_channel"})
        self.assertEqual(sum(call[:3] == ("gh", "release", "create") for call in self.calls), 1)
        self.assertEqual(sum(Path(call[0]).name == "generate_appcast" for call in self.calls), 1)

    def test_public_feed_and_qa_binding_block_promotion_and_leave_stable_intact(self):
        self.publish_and_qa()
        stable = self.pages / "macos/stable/appcast.xml"
        stable.parent.mkdir(parents=True)
        stable.write_bytes(b"original stable bytes")
        for failure in ("failed-qa", "unbound-qa", "changed-public-feed", "changed-assets"):
            with self.subTest(failure=failure):
                qa = release.qa_record(self.directory)
                original = json.loads(json.dumps(qa))
                feed = self.live_feeds["test"]
                if failure == "failed-qa": qa["checks"]["mac-signed-recovery"]["result"] = "failed"
                if failure == "unbound-qa": qa["checks"]["mac-signed-update"].pop("candidateIdentity")
                if failure == "changed-public-feed": self.live_feeds["test"] += b"\n"
                if failure == "changed-assets": self.remote["assets"][0]["apiUrl"] += "other"
                release.write_json(self.directory / "qa.json", qa)
                count = len(self.calls)
                with self.assertRaises(ValueError):
                    release.promote(self.directory, pages_dir=self.pages)
                self.assertEqual(len(self.calls), count)
                self.assertEqual(stable.read_bytes(), b"original stable bytes")
                release.write_json(self.directory / "qa.json", original)
                self.live_feeds["test"] = feed
                if failure == "changed-assets": self.remote["assets"][0]["apiUrl"] = self.remote["assets"][0]["apiUrl"][:-5]

    def test_unpublished_trial_cannot_be_recorded_as_passed(self):
        release.stage(self.directory, candidate=True)
        with self.assertRaises((ValueError, KeyError)):
            release.record_qa(argparse.Namespace(directory=self.directory, check="mac-signed-update",
                                                 result="passed", notes="Not really observed"))
        self.assertNotIn("mac-signed-update", release.qa_record(self.directory)["checks"])

    def test_same_build_conflicting_signed_item_cannot_be_promoted(self):
        self.publish_and_qa()
        original = self.target.read_bytes()
        stable = self.pages / "macos/stable/appcast.xml"
        stable.parent.mkdir(parents=True)
        for field in ("description", f"{{{release.SPARKLE_NS}}}minimumSystemVersion",
                      f"{{{release.SPARKLE_NS}}}hardwareRequirements", f"{{{release.SPARKLE_NS}}}channel"):
            root = release.ET.fromstring(original)
            item = root.find("channel/item")
            node = item.find(field)
            if node is None:
                node = release.ET.SubElement(item, field)
            node.text = "different signed semantics"
            conflicting = release.ET.tostring(root)
            for location in ("public", "local"):
                with self.subTest(field=field, location=location):
                    stable.write_bytes(conflicting if location == "local" else original)
                    self.live_feeds["stable"] = conflicting if location == "public" else original
                    count = len(self.calls)
                    with self.assertRaisesRegex(ValueError, "signed item semantics"):
                        release.promote(self.directory, pages_dir=self.pages)
                    self.assertEqual(len(self.calls), count)
                    self.assertEqual(stable.read_bytes(), conflicting if location == "local" else original)
        stable.write_bytes(original)
        self.live_feeds["stable"] = original
        release.promote(self.directory, pages_dir=self.pages)
        self.assertEqual(stable.read_bytes(), original)

    def test_postpromotion_failure_is_retryable_without_activating_stable(self):
        self.publish_and_qa()
        with patch.object(release, "public_download_check", side_effect=[self.prefix, ValueError("anonymous download failed")]):
            with self.assertRaisesRegex(ValueError, "anonymous download failed"):
                release.promote(self.directory, pages_dir=self.pages)
        self.assertFalse(self.remote["isPrerelease"])
        self.assertFalse((self.pages / "macos/stable/appcast.xml").exists())
        release.promote(self.directory, pages_dir=self.pages)
        self.assertEqual((self.pages / "macos/stable/appcast.xml").read_bytes(), self.target.read_bytes())

    def test_newer_public_build_prevents_candidate_publication(self):
        self.publish_and_qa()
        newer = release.ET.fromstring(self.live_feeds["test"])
        newer.find(f"channel/item/{{{release.SPARKLE_NS}}}version").text = "43"
        self.live_feeds["test"] = release.ET.tostring(newer)
        count = len(self.calls)
        with self.assertRaisesRegex(ValueError, "lower build"):
            release.publish_test(self.directory, **{key: value for key, value in self.options.items() if key != "feed_channel"})
        self.assertEqual(len(self.calls), count)


class EmbeddedSettingsTests(unittest.TestCase):
    def test_actual_bundle_settings_build_source_and_signature_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = {"version": "0.9.0", "buildNumber": 43, "sourceRevision": "a" * 40,
                        "updater": {"feedURL": release.FEED_BASE_URL + "/macos/stable/appcast.xml",
                                    "publicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}
            mismatch = [None]
            calls = []
            def run(*args, **_kwargs):
                calls.append(args)
                if args[:2] != ("/usr/bin/hdiutil", "attach"):
                    return
                app = Path(args[args.index("-mountpoint") + 1]) / "Paceman.app"
                library = app / "Contents/Resources/lib"
                library.mkdir(parents=True)
                info = {"CFBundleIdentifier": "ai.paceman.macos", "CFBundleShortVersionString": "0.9.0",
                        "CFBundleVersion": "43", **release.sparkle_dependency.public_update_settings(manifest["updater"])}
                if mismatch[0] and mismatch[0] != "sourceRevision": info[mismatch[0]] = "wrong"
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                (library / "build-info.json").write_text(json.dumps({"sourceRevision": "bad" if mismatch[0] == "sourceRevision" else "a" * 40, "release": "0.9.0"}))
            with patch.object(release, "run", side_effect=run):
                release.verify_embedded_settings(directory, manifest)
                self.assertTrue(any(call[0] == "/usr/bin/codesign" for call in calls))
                for key in ("SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "CFBundleVersion", "sourceRevision"):
                    mismatch[0] = key
                    with self.assertRaisesRegex(ValueError, "embedded"):
                        release.verify_embedded_settings(directory, manifest)
                    self.assertEqual(calls[-1][:2], ("/usr/bin/hdiutil", "detach"))

class PublicFeedVerificationTests(unittest.TestCase):
    def test_http_errors_are_not_treated_as_empty_channels(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "feed.xml"
            for status in ("404", "500", "403", "000"):
                with patch.object(release, "run", return_value=subprocess.CompletedProcess([], 0, status, "")) as command:
                    if status == "404":
                        self.assertFalse(release.fetch_public_feed("stable", path, allow_missing=True))
                    else:
                        with self.assertRaisesRegex(ValueError, "returned HTTP"):
                            release.fetch_public_feed("stable", path, allow_missing=True)
                    self.assertIn("--disable", command.call_args.args)
                    self.assertIn("=https", command.call_args.args)
                    self.assertNotIn("--insecure", command.call_args.args)

    def test_malformed_signature_footer_stops_before_crypto_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "feed.xml"
            for content in (b"<rss/>", b"<rss/><!-- sparkle-signatures:\nedSignature: AAAA\nlength: 1\n-->\n"):
                path.write_bytes(content)
                with patch.object(release, "run") as command, self.assertRaisesRegex(ValueError, "footer"):
                    release.verify_signed_feed(path, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
                command.assert_not_called()

    @unittest.skipUnless(release.sys.platform == "darwin", "CryptoKit verification requires the release Mac")
    def test_public_signed_fixture_verifies_and_tampered_bytes_fail(self):
        # Public alpha.6 feed from the completed trial, used only as a signature-format fixture.
        # No signing tool, keychain, private key, network access or installed app is involved.
        fixture = release.ROOT / "tests/fixtures/sparkle/signed-appcast.xml"
        key = "owgq9+CVp60Ka1ml4tbGep5Hl8QdtDNerMcVm6+0E/s="
        release.verify_signed_feed(fixture, key)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "feed.xml"
            path.write_bytes(fixture.read_bytes().replace(b"<title>Paceman", b"<title>Xaceman", 1))
            with self.assertRaises(subprocess.CalledProcessError):
                release.verify_signed_feed(path, key)
