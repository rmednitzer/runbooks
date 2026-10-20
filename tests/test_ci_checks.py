"""Run the CI snapshot checker with synthetic API responses and no credentials."""

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40


def check(name="lint", ident=1, app=15368, sha=SHA, status="completed", conclusion="success"):
    return {
        "name": name,
        "id": ident,
        "app": {"id": app},
        "head_sha": sha,
        "status": status,
        "conclusion": conclusion,
    }


class SnapshotChecks(unittest.TestCase):
    def evaluate(self, pages, required="lint", allowed=""):
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/check_ci_checks.py")],
            input=json.dumps(pages),
            text=True,
            capture_output=True,
            timeout=5,
            env={"TARGET_SHA": SHA, "REQUIRED_CHECKS": required, "ALLOWED_SKIPPED_CHECKS": allowed},
        ).returncode

    def test_all_paginated_dependencies_must_pass(self):
        self.assertEqual(
            self.evaluate(
                [{"check_runs": [check()]}, {"check_runs": [check("security", 2)]}],
                required="lint\nsecurity",
            ),
            0,
        )
        self.assertEqual(self.evaluate([{"check_runs": [check()]}], required="lint\nsecurity"), 2)

    def test_foreign_app_or_revision_is_not_evidence(self):
        for item in (check(app=999), check(sha="b" * 40)):
            with self.subTest(item=item):
                self.assertEqual(self.evaluate([{"check_runs": [item]}]), 2)

    def test_new_attempt_supersedes_older_success_across_pages(self):
        for status, conclusion, expected in (("queued", None, 2), ("completed", "failure", 1)):
            with self.subTest(status=status):
                self.assertEqual(
                    self.evaluate(
                        [
                            {"check_runs": [check(ident=2, status=status, conclusion=conclusion)]},
                            {"check_runs": [check(ident=1)]},
                        ]
                    ),
                    expected,
                )

    def test_skips_require_an_exact_explicit_exception(self):
        pages = [{"check_runs": [check(conclusion="skipped")]}]
        self.assertEqual(self.evaluate(pages), 1)
        self.assertEqual(self.evaluate(pages, allowed="lint-other"), 1)
        self.assertEqual(self.evaluate(pages, allowed="lint"), 0)

    def test_malformed_or_missing_policy_fails_closed(self):
        for pages in ({}, [{"check_runs": None}], [{"check_runs": [{}]}]):
            with self.subTest(pages=pages):
                self.assertEqual(self.evaluate(pages), 1)
        self.assertEqual(self.evaluate([{"check_runs": [check()]}], required=""), 1)


if __name__ == "__main__":
    unittest.main()
