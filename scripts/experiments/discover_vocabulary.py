#!/usr/bin/env python3
"""Discover bounded vocabulary from explicit project metadata and Swift source.

No network access, installed dependencies, persistent cache, or user-directory scan.
The project.yml parser accepts only the tiny scalar subset needed here.
"""

import argparse
import json
import re
from collections import Counter
from pathlib import Path


IDENTIFIER = re.compile(r"[A-Z][A-Za-z0-9]{2,47}\Z")
IMPORT = re.compile(r"^\s*(?:@preconcurrency\s+)?import\s+([A-Za-z][A-Za-z0-9]*)", re.M)
TYPE = re.compile(r"^\s*(?:(?:public|private|internal|fileprivate|final|indirect|open)\s+)*(?:struct|class|enum|protocol|actor)\s+([A-Z][A-Za-z0-9]*)", re.M)
GENERIC_SUFFIXES = ("View", "Controller", "Panel", "Service", "Delegate", "Manager", "Store", "Error", "Modifier", "Configuration", "Entry", "App")
SKIP_DIRS = {"tests", "docs", "resources", "build", "deriveddata", "secrets"}
MAX_FILE_BYTES = 1_000_000
STRING_START = re.compile(r'(#+)?("""|")')


def strip_swift_comments_and_strings(text):
    """Keep code and line breaks; skip nested comments and quoted literals.

    This is still a lexical heuristic: Swift regex literals and interpolated
    expressions are not parsed.
    """
    output = []
    index = 0
    while index < len(text):
        start = index
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = len(text) if newline < 0 else newline
        elif text.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            literal = STRING_START.match(text, index) if text[index] in '#"' else None
            if not literal:
                output.append(text[index])
                index += 1
                continue
            hashes = literal[1] or ""
            closing = literal[2] + hashes
            escape = "\\" + hashes
            index = literal.end()
            while index < len(text):
                if text.startswith(escape, index):
                    index = min(len(text), index + len(escape) + 1)
                elif text.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
        output.append(" " + "\n" * text[start:index].count("\n"))
    return "".join(output)


def eligible_sources(repo):
    """Return explicit files only; never follow a symlink or hidden directory."""
    metadata = repo / "project.yml"
    paths = [metadata] if metadata.is_file() and not metadata.is_symlink() else []
    source = repo / "OpenWhisper"
    if not source.is_dir() or source.is_symlink():
        return paths

    def visit(directory):
        for path in sorted(directory.iterdir()):
            if path.is_symlink() or path.name.startswith("."):
                continue
            if path.is_dir():
                if path.name.casefold() not in SKIP_DIRS:
                    visit(path)
            elif path.suffix == ".swift" and path.is_file():
                paths.append(path)

    visit(source)
    return paths


def discover(repo, max_terms=16, max_chars=1000):
    repo = Path(repo).resolve()
    candidates = {}
    code = {}
    read_paths = []

    def add(name, score, provenance):
        if not IDENTIFIER.fullmatch(name):
            return
        key = name.casefold()
        item = candidates.setdefault(key, {"term": name, "score": score, "provenance": []})
        if score > item["score"]:
            item["term"], item["score"] = name, score
        if provenance not in item["provenance"]:
            item["provenance"].append(provenance)

    for path in eligible_sources(repo):
        if path.stat().st_size > MAX_FILE_BYTES:
            continue
        text = path.read_text(encoding="utf-8")
        relative = str(path.relative_to(repo))
        read_paths.append(relative)
        if relative == "project.yml":
            in_packages = False
            for line_number, line in enumerate(text.splitlines(), 1):
                name = re.fullmatch(r"name:\s*([A-Z][A-Za-z0-9]*)\s*", line)
                if name:
                    add(name[1], 100, f"{relative}:{line_number}:project name")
                if line and not line[0].isspace():
                    in_packages = line == "packages:"
                package = re.fullmatch(r"  ([A-Z][A-Za-z0-9]*):\s*", line) if in_packages else None
                if package:
                    add(package[1], 85, f"{relative}:{line_number}:package")
                product = re.fullmatch(r"\s+PRODUCT_NAME:\s*[\"']?([A-Z][A-Za-z0-9]*)[\"']?\s*", line)
                if product:
                    add(product[1], 95, f"{relative}:{line_number}:product name")
        else:
            text = strip_swift_comments_and_strings(text)
            code[relative] = text

    imports = {}
    declarations = {}
    for relative, text in code.items():
        for match in IMPORT.finditer(text):
            imports.setdefault(match[1], set()).add(relative)
        for match in TYPE.finditer(text):
            declarations.setdefault(match[1], set()).add(relative)
    for name, paths in imports.items():
        for relative in sorted(paths):
            add(name, 65 + min(len(paths), 15), f"{relative}:import")

    occurrences = Counter()
    for text in code.values():
        occurrences.update(set(re.findall(r"\b[A-Z][A-Za-z0-9]*\b", text)))
    for name, paths in declarations.items():
        if name.endswith(GENERIC_SUFFIXES) or occurrences[name] < 3 or sum(character.isupper() for character in name) < 2:
            continue
        for relative in sorted(paths):
            add(name, 20 + min(occurrences[name], 15), f"{relative}:type ({occurrences[name]} files)")

    ranked = sorted(candidates.values(), key=lambda item: (-item["score"], item["term"].casefold()))
    selected = []
    for item in ranked:
        proposed = ", ".join([entry["term"] for entry in selected] + [item["term"]]) + "."
        if len(selected) >= max_terms:
            break
        if len(proposed) <= max_chars:
            selected.append(item)
    prompt = ", ".join(item["term"] for item in selected) + ("." if selected else "")
    return {"language": "en", "terms": selected, "initial_prompt": prompt,
            "eligible_paths_read": read_paths, "prompt_characters": len(prompt),
            "scope": "project.yml and non-hidden, non-symlink Swift source under OpenWhisper/"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--max-terms", type=int, default=16)
    parser.add_argument("--max-chars", type=int, default=1000)
    parser.add_argument("--prompt-only", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.max_terms <= 20 or not 1 <= args.max_chars <= 1000:
        parser.error("max-terms must be 1..20; max-chars must be 1..1000")
    result = discover(args.repo, args.max_terms, args.max_chars)
    print(result["initial_prompt"] if args.prompt_only else json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
