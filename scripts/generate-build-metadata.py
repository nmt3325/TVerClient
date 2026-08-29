#!/usr/bin/env python3
"""Generate a minimal CycloneDX SBOM and an in-toto/SLSA provenance statement."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import zipfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--workflow-ref", required=True)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--xcodegen-version", required=True)
    return parser.parse_args()


def write_json(path: Path, document: dict, *, json_lines: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if json_lines:
        path.write_text(json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n")
    else:
        path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


def main() -> None:
    args = parse_args()
    ipa_bytes = args.ipa.read_bytes()
    ipa_sha256 = hashlib.sha256(ipa_bytes).hexdigest()

    with zipfile.ZipFile(args.ipa) as archive:
        plist_names = [
            name
            for name in archive.namelist()
            if name.startswith("Payload/")
            and name.count("/") == 2
            and name.endswith(".app/Info.plist")
        ]
        if len(plist_names) != 1:
            raise SystemExit(f"expected one app Info.plist, found {len(plist_names)}")
        app_info = plistlib.loads(archive.read(plist_names[0]))

    bundle_id = str(app_info["CFBundleIdentifier"])
    version = str(app_info.get("CFBundleShortVersionString", app_info.get("CFBundleVersion", "unknown")))
    repo_url = "https:" + f"//github.com/{args.repository}"
    component_ref = f"pkg:generic/{args.repository.split('/')[-1]}@{version}"

    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": component_ref,
                "name": "TVerClient",
                "version": version,
                "purl": component_ref,
                "properties": [
                    {"name": "apple:bundle-identifier", "value": bundle_id},
                    {"name": "github:commit", "value": args.commit},
                ],
                "hashes": [{"alg": "SHA-256", "content": ipa_sha256}],
                "externalReferences": [
                    {"type": "vcs", "url": f"{repo_url}/tree/{args.commit}"}
                ],
            },
            "tools": {
                "components": [
                    {"type": "application", "name": "Xcode", "version": args.xcode_version},
                    {"type": "application", "name": "XcodeGen", "version": args.xcodegen_version},
                ]
            },
        },
        "components": [],
        "dependencies": [{"ref": component_ref, "dependsOn": []}],
    }

    provenance = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": args.ipa.name, "digest": {"sha256": ipa_sha256}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": "https://github.com/Attestations/GitHubActionsWorkflow@v1",
                "externalParameters": {
                    "repository": repo_url,
                    "ref": args.ref,
                    "workflow": args.workflow_ref,
                },
                "internalParameters": {},
                "resolvedDependencies": [
                    {"uri": f"git+{repo_url}@{args.ref}", "digest": {"gitCommit": args.commit}}
                ],
            },
            "runDetails": {
                "builder": {
                    "id": f"{repo_url}/actions/runs/{args.run_id}/attempts/{args.run_attempt}"
                },
                "metadata": {"invocationId": f"{args.run_id}.{args.run_attempt}"},
                "byproducts": [],
            },
        },
    }

    write_json(args.output_dir / "TVerClient.cdx.json", sbom)
    write_json(
        args.output_dir / "TVerClient-build-provenance.intoto.jsonl",
        provenance,
        json_lines=True,
    )
    print(f"Generated SBOM and provenance for SHA-256 {ipa_sha256}")


if __name__ == "__main__":
    main()
