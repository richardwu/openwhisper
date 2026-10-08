#!/usr/bin/env python3
"""Deterministic extraction tests; all fixtures are synthetic and stay in .context."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("discover_vocabulary.py")
sys.dont_write_bytecode = True
CONTEXT = Path(__file__).resolve().parents[2] / ".context"
CONTEXT.mkdir(exist_ok=True)
SPEC = importlib.util.spec_from_file_location("vocabulary_discovery", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vocabulary-discovery-fixture-", dir=CONTEXT)
        self.repo = Path(self.temp.name)
        self.write("project.yml", "name: ExampleProduct\npackages:\n  SwiftWhisper:\n    url: unused\ntargets:\n  ExampleProduct:\n    settings:\n      base:\n        PRODUCT_NAME: ExampleProduct\n")
        self.write("OpenWhisper/Main.swift", "import SwiftUI\nimport Swiftwhisper\nstruct UsefulType {}\nlet a = UsefulType()\n")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def terms(self, **kwargs):
        return [item["term"] for item in MODULE.discover(self.repo, **kwargs)["terms"]]

    def test_scope_skips_non_source_hidden_secrets_tests_and_symlinks(self):
        for path in ("Tests/Test.swift", "docs/Notes.swift", ".context/Scratch.swift", ".env", "OpenWhisper/.env.swift", "OpenWhisper/.build/Generated.swift", "OpenWhisper/Tests/Test.swift", "OpenWhisper/secrets/Secrets.swift", "OpenWhisper/Resources/Assets.swift", "Other/Unrelated.swift"):
            self.write(path, "import SecretFramework\nstruct SecretType {}\n")
        self.write("outside.swift", "import OutsideFramework\n")
        (self.repo / "OpenWhisper" / "Linked.swift").symlink_to(self.repo / "outside.swift")
        (self.repo / "OpenWhisper" / "LinkedDirectory").symlink_to(self.repo / "Other", target_is_directory=True)
        self.write("OpenWhisper/Notes.txt", "import TextFramework\n")
        result = MODULE.discover(self.repo)
        self.assertEqual(result["eligible_paths_read"], ["project.yml", "OpenWhisper/Main.swift"])
        self.assertNotIn("SecretFramework", self.terms())
        self.assertNotIn("OutsideFramework", self.terms())

    def test_metadata_wins_casing_dedup_and_records_provenance(self):
        result = MODULE.discover(self.repo)
        names = [item["term"] for item in result["terms"]]
        self.assertEqual(names.count("SwiftWhisper"), 1)
        self.assertNotIn("Swiftwhisper", names)
        whisper = next(item for item in result["terms"] if item["term"] == "SwiftWhisper")
        self.assertEqual(len(whisper["provenance"]), 2)
        self.assertEqual(names[0], "ExampleProduct")

    def test_rank_and_both_caps(self):
        self.write("OpenWhisper/More.swift", "".join(f"import Framework{index}\n" for index in range(30)))
        result = MODULE.discover(self.repo, max_terms=12, max_chars=200)
        self.assertLessEqual(len(result["terms"]), 12)
        self.assertLessEqual(len(result["initial_prompt"]), 200)
        self.assertEqual(result["terms"][0]["term"], "ExampleProduct")
        self.assertEqual(result["terms"][1]["term"], "SwiftWhisper")
        self.assertLessEqual(len(MODULE.discover(self.repo, max_terms=16, max_chars=12)["initial_prompt"]), 12)
        self.assertEqual(MODULE.discover(self.repo, max_terms=16, max_chars=1)["terms"], [])

    def test_regeneration_updates_names_and_removes_deleted_sources(self):
        self.write("OpenWhisper/New.swift", "import OldFramework\n")
        self.assertIn("OldFramework", self.terms())
        self.write("OpenWhisper/New.swift", "import NewFramework\n")
        self.assertNotIn("OldFramework", self.terms())
        self.assertIn("NewFramework", self.terms())
        (self.repo / "OpenWhisper/New.swift").unlink()
        self.assertNotIn("NewFramework", self.terms())
        self.write("project.yml", "name: RenamedProduct\n")
        self.assertIn("RenamedProduct", self.terms())
        self.assertNotIn("ExampleProduct", self.terms())
        self.assertNotIn("SwiftWhisper", self.terms())

    def test_types_require_references_and_skip_strings_comments_generic_types(self):
        self.write("OpenWhisper/Second.swift", 'let b = UsefulType()\nstruct GenericView {}\nlet a = GenericView()\n// import CommentFramework\nlet name = "import StringFramework"\n')
        self.write("OpenWhisper/Third.swift", "let c = UsefulType()\nlet v = GenericView()\nstruct OnceOnly {}\n")
        names = self.terms()
        self.assertIn("UsefulType", names)
        for unwanted in ("GenericView", "OnceOnly", "CommentFramework", "StringFramework"):
            self.assertNotIn(unwanted, names)

    def test_oversized_source_is_not_read(self):
        self.write("OpenWhisper/Large.swift", "import LargeFramework\n" + " " * MODULE.MAX_FILE_BYTES)
        self.assertNotIn("OpenWhisper/Large.swift", MODULE.discover(self.repo)["eligible_paths_read"])

    def test_nested_block_comments_do_not_leak_identifiers(self):
        self.write("OpenWhisper/Nested.swift", "/* Outer comment\n /* inner comment */\nimport CommentOnlyFramework\nstruct CommentOnlyType {}\n*/\nimport RealFramework\n")
        names = self.terms()
        self.assertIn("RealFramework", names)
        self.assertNotIn("CommentOnlyFramework", names)
        self.assertNotIn("CommentOnlyType", names)

    def test_raw_multiline_strings_do_not_leak_embedded_delimiters(self):
        self.write("OpenWhisper/Raw.swift", 'let note = #"""\nEmbedded triple quote: """\nimport StringOnlyFramework\n"""#\nimport RealFramework\n')
        names = self.terms()
        self.assertIn("RealFramework", names)
        self.assertNotIn("StringOnlyFramework", names)

    def test_comment_markers_and_escaped_quotes_in_strings_preserve_real_import(self):
        self.write("OpenWhisper/Strings.swift", 'let text = "escaped quote: \\\" /* not a comment */"\nlet raw = #"/* not a comment */"#\nimport RealFramework\n')
        self.assertIn("RealFramework", self.terms())


if __name__ == "__main__":
    unittest.main()
