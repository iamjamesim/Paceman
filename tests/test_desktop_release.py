import argparse
import json
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
        self.names = self.artifact_names + ["release-manifest.json", "RELEASE-NOTES.md"]
        self.checksums()

    def checksums(self):
        (self.directory / "SHA256SUMS").write_text("".join(
            f"{release.sha256(self.directory / name)}  {name}\n" for name in self.names))

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
            self.assertEqual(set(names), set(self.names) | {"SHA256SUMS"})
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

    def test_qa_cannot_be_reused_after_notes_or_artifacts_change(self):
        release.write_json(self.directory / "qa.json", release.qa_record(self.directory))
        (self.directory / "RELEASE-NOTES.md").write_text("Changed release conditions\n")
        self.checksums()
        with self.assertRaisesRegex(ValueError, "different artifacts"):
            release.qa_record(self.directory)

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
        tag = f"refs/tags/v{self.version}"
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
             patch.object(release, "releases", return_value=[{"tagName": f"v{self.version}", "isDraft": True}]), \
             patch.object(release, "release_view", return_value={"assets": [{"name": existing_name}]}), \
             patch.object(release, "run", side_effect=run), patch.object(release, "download_check"):
            release.stage(self.directory)
        uploads = [call for call in calls if call[:3] == ("gh", "release", "upload")]
        self.assertEqual(len(uploads), 1)
        self.assertNotIn(self.directory / existing_name, uploads[0])
        self.assertNotIn("--clobber", uploads[0])
        self.assertFalse(any(call[:3] == ("gh", "release", "edit") for call in calls))

    def test_download_mismatch_blocks_verification(self):
        names = self.names + ["SHA256SUMS"]
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

    def test_qa_requires_current_download_verification(self):
        release.write_json(self.directory / "download-verification.json", {"checksumsSHA256": "outdated"})
        args = argparse.Namespace(directory=self.directory, check="mac-fresh",
                                  result="passed", notes="Observed on macOS 26.7")
        with patch.object(release, "verify"):
            with self.assertRaisesRegex(ValueError, "current downloads"):
                release.record_qa(args)
        self.assertFalse((self.directory / "qa.json").exists())


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
