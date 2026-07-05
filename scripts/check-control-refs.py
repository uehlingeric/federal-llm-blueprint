#!/usr/bin/env python3
"""
Control-mapping consistency checker.

Validates that docs/controls.yaml, CONTROLS.md, and the Terraform code stay
synchronized:

  (a) every control id annotated in Terraform code ("Aligns to NIST 800-53
      <ids>" descriptions and controls = [...] lists feeding the
      Nist80053Controls tag) exists in docs/controls.yaml;
  (b) the control ids in docs/controls.yaml exactly match the "### <ID> —"
      heading ids in CONTROLS.md (both directions);
  (c) every resources[].path in docs/controls.yaml exists on disk;
  (d) every resources[].resource ("aws_type.name", optionally with an
      instance key like aws_kms_key.this["logs"]) is declared in the cited
      path as: resource "aws_type" "name".

Exits nonzero with a readable diff on any failure. Run from the repo root
(make check-controls). Requires PyYAML (stdlib otherwise).
"""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("[check-controls] ERROR: PyYAML required (pip install pyyaml)")
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTROLS_YAML = REPO_ROOT / "docs" / "controls.yaml"
CONTROLS_MD = REPO_ROOT / "CONTROLS.md"
MODULES_DIR = REPO_ROOT / "modules"

# Control ids like AC-2, SC-28, and enhancements like SC-28(1)
CONTROL_ID = r"[A-Z]{2}-\d+(?:\(\d+\))?"
ALIGNS_RE = re.compile(r"Aligns to NIST 800-53 ((?:%s(?:,\s*)?)+)" % CONTROL_ID)
CONTROLS_LIST_RE = re.compile(r"controls\s*=\s*\[([^\]]*)\]")
MD_HEADING_RE = re.compile(r"^### (%s) — " % CONTROL_ID, re.MULTILINE)
ID_RE = re.compile(CONTROL_ID)


def code_control_ids() -> dict[str, list[str]]:
    """Control ids annotated in modules/**/*.tf, mapped to citing files."""
    found: dict[str, list[str]] = {}
    for tf_path in sorted(MODULES_DIR.rglob("*.tf")):
        text = tf_path.read_text()
        ids: set[str] = set()
        for match in ALIGNS_RE.finditer(text):
            ids.update(ID_RE.findall(match.group(1)))
        for match in CONTROLS_LIST_RE.finditer(text):
            ids.update(ID_RE.findall(match.group(1)))
        for control_id in ids:
            found.setdefault(control_id, []).append(
                str(tf_path.relative_to(REPO_ROOT))
            )
    return found


def main() -> int:
    errors: list[str] = []

    data = yaml.safe_load(CONTROLS_YAML.read_text())
    yaml_controls = data.get("controls", [])
    yaml_ids = {c["id"] for c in yaml_controls}

    # (a) code annotations must exist in the yaml
    for control_id, files in sorted(code_control_ids().items()):
        if control_id not in yaml_ids:
            errors.append(
                f"(a) {control_id} annotated in code ({', '.join(sorted(set(files)))}) "
                f"but missing from docs/controls.yaml"
            )

    # (b) yaml ids == CONTROLS.md heading ids, both directions
    md_ids = set(MD_HEADING_RE.findall(CONTROLS_MD.read_text()))
    for control_id in sorted(yaml_ids - md_ids):
        errors.append(f"(b) {control_id} in docs/controls.yaml but no '### {control_id} —' heading in CONTROLS.md")
    for control_id in sorted(md_ids - yaml_ids):
        errors.append(f"(b) {control_id} heading in CONTROLS.md but missing from docs/controls.yaml")

    # (c) cited paths exist; (d) cited resources are declared in them
    for control in yaml_controls:
        for ref in control.get("resources", []):
            rel_path = ref["path"]
            path = REPO_ROOT / rel_path
            if not path.exists():
                errors.append(f"(c) {control['id']}: cited path does not exist: {rel_path}")
                continue
            resource = ref.get("resource")
            if not resource:
                continue
            if not path.is_file():
                errors.append(
                    f"(d) {control['id']}: resource '{resource}' cited against a directory: {rel_path}"
                )
                continue
            # Strip instance keys: aws_kms_key.this["logs"] -> aws_kms_key.this
            bare = re.sub(r'\[".*"\]$', "", resource)
            try:
                res_type, res_name = bare.split(".", 1)
            except ValueError:
                errors.append(f"(d) {control['id']}: malformed resource reference: {resource}")
                continue
            declaration = f'resource "{res_type}" "{res_name}"'
            if declaration not in path.read_text():
                errors.append(
                    f"(d) {control['id']}: '{declaration}' not found in {rel_path} (cited as {resource})"
                )

    if errors:
        print(f"[check-controls] FAIL: {len(errors)} inconsistencies between code, CONTROLS.md, and docs/controls.yaml\n")
        for err in errors:
            print(f"  {err}")
        return 1

    print(
        f"[check-controls] OK: {len(yaml_ids)} controls consistent across code annotations, "
        f"CONTROLS.md, and docs/controls.yaml"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
