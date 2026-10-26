import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / ".github/scripts/update-gitops.sh"
MANIFEST = Path("k8s/overlays/production/kustomization.yaml")
REGISTRY = "042444213801.dkr.ecr.us-east-1.amazonaws.com"


class UpdateGitOpsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.remote = self.directory / "remote.git"
        self.repo = self.directory / "repo"
        self.git = shutil.which("git")
        subprocess.run(
            [self.git, "init", "--bare", str(self.remote)],
            check=True, capture_output=True,
        )
        self.repo.mkdir()
        self.run_git("init", "-b", "main")
        self.run_git("config", "user.name", "Test")
        self.run_git("config", "user.email", "test@example.com")
        shutil.copytree(ROOT / "k8s", self.repo / "k8s")
        self.initial_images = {
            image.rsplit("/", 1)[-1].split(":", 1)[0]: image
            for image in self.render_images()
        }
        self.run_git("add", ".")
        self.run_git("commit", "-m", "Initial manifests")
        self.source = self.run_git("rev-parse", "HEAD").stdout.strip()
        self.tag = f"sha-{self.source}"
        self.run_git("remote", "add", "origin", str(self.remote))
        self.run_git("push", "origin", "main")
        self.environment = {
            **os.environ,
            "ECR_REGISTRY": REGISTRY,
            "IMAGE_TAG": self.tag,
            "SERVICE": "auth-service",
            "SOURCE_SHA": self.source,
            "GITHUB_OUTPUT": str(self.directory / "output"),
        }

    def run_git(self, *arguments):
        return subprocess.run(
            [self.git, *arguments], cwd=self.repo, text=True,
            capture_output=True, check=True,
        )

    def update(self):
        return subprocess.run(
            ["bash", str(SCRIPT)], cwd=self.repo, env=self.environment,
            text=True, capture_output=True,
        )

    def remote_manifest(self):
        return self.run_git("show", f"origin/main:{MANIFEST}").stdout

    def render_images(self):
        rendered = subprocess.run(
            ["kustomize", "build", "k8s/overlays/production"],
            cwd=self.repo, capture_output=True, text=True, check=True,
        ).stdout
        return [
            line.strip().removeprefix("image: ")
            for line in rendered.splitlines()
            if line.strip().startswith("image: ")
        ]

    def test_updates_each_service_and_preserves_other_images(self):
        services = [
            "auth-service", "flag-service", "targeting-service",
            "evaluation-service", "analytics-service",
        ]
        for service in services:
            with self.subTest(service=service):
                self.environment["SERVICE"] = service
                result = self.update()
                self.assertEqual(result.returncode, 0, result.stderr)
                images = self.render_images()
                for candidate in services:
                    expected = (
                        f"{REGISTRY}/{candidate}:{self.tag}"
                        if services.index(candidate) <= services.index(service)
                        else self.initial_images[candidate]
                    )
                    self.assertIn(expected, images)
        message = self.run_git("log", "-1", "--format=%B").stdout
        self.assertIn("Co-authored-by: Copilot", message)
        self.assertEqual(
            self.run_git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.strip(),
            str(MANIFEST),
        )

    def test_noop_does_not_create_another_commit(self):
        first = self.update()
        self.assertEqual(first.returncode, 0, first.stderr)
        before = self.run_git("rev-parse", "HEAD").stdout
        second = self.update()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(before, self.run_git("rev-parse", "HEAD").stdout)
        self.assertIn("already references", second.stdout)

    def test_invalid_manifests_are_not_pushed(self):
        manifest = self.repo / MANIFEST
        manifest.write_text(manifest.read_text().replace("- namespace.yaml", "- missing.yaml"))
        self.run_git("add", ".")
        self.run_git("commit", "-m", "Invalid overlay")
        self.run_git("push", "origin", "main")
        before = self.run_git("rev-parse", "origin/main").stdout
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.run_git("rev-parse", "origin/main").stdout)

    def test_stale_service_build_is_rejected(self):
        source = self.repo / "toggle-master/microsservices/auth-service-main/main.go"
        source.parent.mkdir(parents=True)
        source.write_text("package main\n")
        self.run_git("add", ".")
        self.run_git("commit", "-m", "New service code")
        self.run_git("push", "origin", "main")
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Newer changes exist", result.stdout)
        self.assertNotIn(self.tag, self.remote_manifest())

    def test_source_outside_main_is_rejected(self):
        self.environment["SOURCE_SHA"] = "0" * 40
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not part of main", result.stdout)

    def test_rejected_push_retries_and_preserves_parallel_update(self):
        self.assert_parallel_update_preserved()

    def test_retry_works_without_default_fetch_refspec(self):
        self.run_git("config", "--unset-all", "remote.origin.fetch")
        self.assert_parallel_update_preserved()

    def assert_parallel_update_preserved(self):
        competitor = self.directory / "competitor"
        subprocess.run(
            [self.git, "clone", "--branch", "main", str(self.remote), str(competitor)],
            check=True, capture_output=True,
        )
        for arguments in [
            ["config", "user.name", "Other service"],
            ["config", "user.email", "other@example.com"],
        ]:
            subprocess.run([self.git, *arguments], cwd=competitor, check=True)
        subprocess.run(
            [
                "kustomize", "edit", "set", "image",
                f"auth-service={REGISTRY}/auth-service:parallel",
            ],
            cwd=competitor / MANIFEST.parent, check=True, capture_output=True,
        )
        # The competing push changes a different image.
        self.environment["SERVICE"] = "flag-service"
        subprocess.run([self.git, "add", "."], cwd=competitor, check=True)
        subprocess.run(
            [self.git, "commit", "-m", "Parallel auth image update"],
            cwd=competitor, check=True, capture_output=True,
        )
        shim = self.directory / "bin"
        shim.mkdir()
        marker = self.directory / "pushed"
        wrapper = shim / "git"
        wrapper.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            f'if [ "$1" = push ] && [ ! -f "{marker}" ]; then\n'
            f'  touch "{marker}"\n'
            f'  "{self.git}" -C "{competitor}" push origin main\n'
            'fi\n'
            f'exec "{self.git}" "$@"\n'
        )
        wrapper.chmod(0o755)
        self.environment["PATH"] = f"{shim}{os.pathsep}{os.environ['PATH']}"
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("retrying", result.stdout)
        rendered = subprocess.run(
            ["kustomize", "build", "k8s/overlays/production"],
            cwd=self.repo, check=True, capture_output=True, text=True,
        ).stdout
        self.assertIn(f"image: {REGISTRY}/auth-service:parallel", rendered)
        self.assertIn(f"image: {REGISTRY}/flag-service:{self.tag}", rendered)


if __name__ == "__main__":
    unittest.main()
