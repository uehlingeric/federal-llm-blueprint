#!/usr/bin/env python3
"""
OSCAL component-definition generator.

Renders docs/controls.yaml (the machine-readable control mapping) as an OSCAL
1.1.3 component definition at docs/oscal/component-definition.json, so SSP
tooling that consumes OSCAL can ingest the stack's control implementation
statements directly.

Output is deterministic: UUIDs are UUIDv5 hashes of stable identifiers, and
metadata.last-modified is preserved from the existing file when the generated
content is otherwise unchanged, so regeneration never churns the artifact.

Modes:
  generate (default)  Write docs/oscal/component-definition.json.
  --check             Exit nonzero if the committed artifact is stale relative
                      to docs/controls.yaml (run from CI; make oscal-check).
  --schema PATH       Additionally validate the document against a local copy
                      of the NIST OSCAL component-definition JSON schema
                      (requires the jsonschema and regex packages; the NIST
                      schema uses XSD \\p{L} character classes that Python's
                      stdlib re cannot compile). Fetch the schema from
                      github.com/usnistgov/OSCAL/releases (asset
                      oscal_component_schema.json).

Run from the repo root (make oscal / make oscal-check). Requires PyYAML
(stdlib otherwise).
"""

import argparse
import copy
import datetime
import json
import re
import sys
import uuid
from pathlib import Path

try:
    import yaml
except ImportError:
    print("[generate-oscal] ERROR: PyYAML required (pip install pyyaml)")
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTROLS_YAML = REPO_ROOT / "docs" / "controls.yaml"
OUTPUT = REPO_ROOT / "docs" / "oscal" / "component-definition.json"

REPO_URL = "https://github.com/uehlingeric/federal-llm-blueprint"
PROP_NS = REPO_URL
OSCAL_VERSION = "1.1.3"
DOC_VERSION = "0.1.0"
CATALOG_SOURCE = (
    "https://raw.githubusercontent.com/usnistgov/oscal-content/main/"
    "nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json"
)

# Deterministic UUID namespace for this repository's OSCAL artifacts.
UUID_NS = uuid.uuid5(uuid.NAMESPACE_URL, REPO_URL)


def stable_uuid(name: str) -> str:
    return str(uuid.uuid5(UUID_NS, name))


def oscal_control_id(control_id: str) -> str:
    """CONTROLS.md id -> OSCAL catalog id: SC-8(1) -> sc-8.1"""
    return re.sub(r"\((\d+)\)", r".\1", control_id).lower()


def requirement_description(control: dict) -> str:
    """Implementation statement plus resource citations as markdown."""
    parts = [control["statement"].strip()]
    resources = control.get("resources", [])
    if resources:
        bullets = []
        for ref in resources:
            label = f"`{ref['path']}`"
            if ref.get("resource"):
                label += f" — `{ref['resource']}`"
            note = ref.get("note", "").strip()
            bullets.append(f"- {label}" + (f": {note}" if note else ""))
        parts.append("**Implementing resources:**\n\n" + "\n".join(bullets))
    return "\n\n".join(parts)


def build_document() -> dict:
    """Build the component definition; metadata.last-modified left unset."""
    data = yaml.safe_load(CONTROLS_YAML.read_text())
    controls = data["controls"]

    implemented_requirements = []
    for control in controls:
        requirement = {
            "uuid": stable_uuid(f"implemented-requirement:{control['id']}"),
            "control-id": oscal_control_id(control["id"]),
            "description": requirement_description(control),
            "props": [
                {
                    "name": "responsibility",
                    "value": control["responsibility"],
                    "ns": PROP_NS,
                }
            ],
        }
        gaps = control.get("gaps", "").strip()
        if gaps:
            requirement["remarks"] = gaps
        implemented_requirements.append(requirement)

    return {
        "component-definition": {
            "uuid": stable_uuid("component-definition"),
            "metadata": {
                "title": (
                    "Federal LLM Blueprint — NIST SP 800-53 rev5 "
                    "component definition"
                ),
                "version": DOC_VERSION,
                "oscal-version": OSCAL_VERSION,
                "remarks": (
                    "Generated from docs/controls.yaml by "
                    "scripts/generate-oscal.py; do not edit by hand. "
                    "The stack is aligned to controls, evidence pending; "
                    "see CONTROLS.md for vocabulary and evidence status."
                ),
            },
            "components": [
                {
                    "uuid": stable_uuid("component:terraform-stack"),
                    "type": "software",
                    "title": "Federal LLM Blueprint Terraform stack",
                    "description": (
                        "Terraform reference architecture for LLM workloads "
                        "in federal environments: no-egress VPC networking, "
                        "customer-managed KMS encryption, permission-boundary "
                        "IAM, ECS Fargate LLM gateway, pgvector and S3 data "
                        "stores, CloudTrail/Config audit plane, and a "
                        "CloudWatch observability baseline. Eight modules; "
                        f"source at {REPO_URL}."
                    ),
                    "control-implementations": [
                        {
                            "uuid": stable_uuid(
                                "control-implementation:sp800-53-rev5"
                            ),
                            "source": CATALOG_SOURCE,
                            "description": (
                                "NIST SP 800-53 rev5 controls the Terraform "
                                "stack implements or contributes to. "
                                "Responsibility split (stack vs shared) is "
                                "carried in the responsibility prop; deployer "
                                "and AWS-inherited duties appear in each "
                                "requirement's remarks."
                            ),
                            "implemented-requirements": (
                                implemented_requirements
                            ),
                        }
                    ],
                }
            ],
        }
    }


def normalized(document: dict) -> dict:
    """Document with the volatile last-modified field removed."""
    stripped = copy.deepcopy(document)
    stripped["component-definition"]["metadata"].pop("last-modified", None)
    return stripped


def render(document: dict) -> str:
    return json.dumps(document, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--schema", type=Path, default=None)
    args = parser.parse_args()

    new_doc = build_document()

    existing = None
    if OUTPUT.exists():
        existing = json.loads(OUTPUT.read_text())

    if args.check:
        if existing is None:
            print(f"[generate-oscal] FAIL: {OUTPUT.relative_to(REPO_ROOT)} missing; run 'make oscal'")
            return 1
        if normalized(existing) != normalized(new_doc):
            print(
                f"[generate-oscal] FAIL: {OUTPUT.relative_to(REPO_ROOT)} is stale "
                "relative to docs/controls.yaml; run 'make oscal' and commit"
            )
            return 1
        document = existing
    else:
        metadata = new_doc["component-definition"]["metadata"]
        if existing is not None and normalized(existing) == normalized(new_doc):
            # Content unchanged: keep the recorded timestamp, no churn.
            metadata["last-modified"] = existing["component-definition"][
                "metadata"
            ]["last-modified"]
        else:
            metadata["last-modified"] = (
                datetime.datetime.now(datetime.timezone.utc)
                .isoformat(timespec="seconds")
                .replace("+00:00", "Z")
            )
        # Reinsert in schema-conventional order (title, last-modified, ...).
        ordered = {"title": metadata.pop("title")}
        ordered["last-modified"] = metadata.pop("last-modified")
        ordered.update(metadata)
        new_doc["component-definition"]["metadata"] = ordered
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(render(new_doc))
        document = new_doc

    if args.schema:
        try:
            import jsonschema
            import regex
        except ImportError:
            print("[generate-oscal] ERROR: --schema requires jsonschema and regex (pip install jsonschema regex)")
            return 1

        # The NIST schema's datatype patterns use XSD \p{L}/\p{N} classes,
        # which stdlib re rejects; validate "pattern" with the regex module.
        def pattern_keyword(validator, patrn, instance, schema_fragment):
            if validator.is_type(instance, "string") and not regex.search(
                patrn, instance
            ):
                yield jsonschema.exceptions.ValidationError(
                    f"{instance!r} does not match {patrn!r}"
                )

        oscal_validator_cls = jsonschema.validators.extend(
            jsonschema.Draft7Validator, {"pattern": pattern_keyword}
        )
        schema = json.loads(args.schema.read_text())
        oscal_validator_cls(
            schema, format_checker=jsonschema.FormatChecker()
        ).validate(document)
        print(f"[generate-oscal] schema OK against {args.schema.name}")

    count = len(
        document["component-definition"]["components"][0][
            "control-implementations"
        ][0]["implemented-requirements"]
    )
    verb = "consistent" if args.check else "generated"
    print(
        f"[generate-oscal] OK: {count} implemented requirements {verb} "
        f"({OUTPUT.relative_to(REPO_ROOT)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
