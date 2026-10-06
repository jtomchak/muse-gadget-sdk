"""Real local Git remotes verify sync does not discard or rewrite custom work."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "tools/sync-upstream.sh"


class ForkSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.upstream = self.root / "upstream.git"
        self.fork = self.root / "fork.git"
        self.seed = self.root / "seed"
        self.work = self.root / "work"
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.upstream))
        self.git(self.root, "clone", str(self.upstream), str(self.seed))
        self.configure(self.seed)
        (self.seed / "upstream.txt").write_text("base\n")
        self.git(self.seed, "add", ".")
        self.git(self.seed, "commit", "-m", "base")
        self.git(self.seed, "push", "origin", "main")
        self.git(self.root, "clone", "--bare", str(self.upstream), str(self.fork))
        self.git(self.root, "clone", str(self.fork), str(self.work))
        self.configure(self.work)
        self.git(self.work, "remote", "add", "upstream", str(self.upstream))
        self.git(self.work, "switch", "-c", "feature")
        (self.work / "custom.txt").write_text("keep me\n")
        self.git(self.work, "add", ".")
        self.git(self.work, "commit", "-m", "custom")
        self.custom = self.git(self.work, "rev-parse", "HEAD")

    def git(self, cwd, *args):
        return subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True,
                              check=True).stdout.strip()

    def configure(self, path):
        self.git(path, "config", "user.name", "Sync Test")
        self.git(path, "config", "user.email", "sync-test@example.invalid")

    def advance(self, text="upstream update\n"):
        (self.seed / "upstream.txt").write_text(text)
        self.git(self.seed, "commit", "-am", "upstream update")
        self.git(self.seed, "push", "origin", "main")
        return self.git(self.seed, "rev-parse", "HEAD")

    def sync(self):
        return subprocess.run(["bash", str(SCRIPT)], cwd=self.work, text=True,
                              capture_output=True, timeout=20)

    def test_sync_keeps_main_pristine_and_preserves_published_feature_history(self):
        self.git(self.work, "push", "origin", "feature")
        newest = self.advance()
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.fork, "rev-parse", "main"), newest)
        self.assertEqual((self.work / "custom.txt").read_text(), "keep me\n")
        self.git(self.work, "merge-base", "--is-ancestor", self.custom, "HEAD")
        self.git(self.work, "merge-base", "--is-ancestor", newest, "HEAD")
        self.git(self.work, "push", "origin", "feature")  # ordinary push, no force
        self.assertEqual(self.sync().returncode, 0)  # repeat is a no-op

    def test_dirty_worktree_is_rejected_before_remote_mutation(self):
        before = self.git(self.fork, "rev-parse", "main")
        self.advance()
        (self.work / "custom.txt").write_text("unsaved\n")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Commit or stash", result.stderr)
        self.assertEqual(self.git(self.fork, "rev-parse", "main"), before)

    def test_diverged_fork_main_is_never_overwritten(self):
        self.git(self.work, "push", "origin", "HEAD:main")
        self.advance()
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("diverged", result.stderr)
        self.assertEqual(self.git(self.fork, "rev-parse", "main"), self.custom)

    def test_conflicts_remain_reviewable_and_do_not_drop_custom_commit(self):
        (self.work / "upstream.txt").write_text("custom edit\n")
        self.git(self.work, "commit", "-am", "conflicting custom edit")
        before = self.git(self.work, "rev-parse", "HEAD")
        self.advance("different upstream edit\n")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git(self.work, "rev-parse", "HEAD"), before)
        self.assertTrue(self.git(self.work, "ls-files", "-u"))
        self.git(self.work, "merge", "--abort")
