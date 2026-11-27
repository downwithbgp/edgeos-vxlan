#!/usr/bin/env python3
"""Validate candidate-bound IPv6-only qualification evidence.

This validator is intended to be called by the trusted release candidate
builder/gate after it has fetched qualification evidence from a known
workflow run.  It does not trust the summary's self-reported success: it
recomputes evidence hashes and checks source/candidate/workflow identity.

The summary schema is `edgeos-vxlan.ipv6-only-qualification/v1`.  The
candidate manifest mapping is documented in
docs/ipv6-only-qualification-ci-integration.md.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys

SCHEMA = "edgeos-vxlan.ipv6-only-qualification/v1"
REQUIRED_CHECKS = {
    "ipv6-only-isolation",
    "ipv6-only-dataplane",
    "ipv6-only-capture",
    "ipv6-only-reconciler",
}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")


class EvidenceError(Exception):
    pass


def sha256_file(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        raise EvidenceError(f"cannot read evidence file {path}: {exc}") from exc


def evidence_path(evidence_dir, relative):
    if not isinstance(relative, str) or not relative:
        raise EvidenceError("evidence file path is missing")
    path = (evidence_dir / relative).resolve()
    try:
        path.relative_to(evidence_dir.resolve())
    except ValueError as exc:
        raise EvidenceError(f"evidence file escapes the evidence directory: {relative}") from exc
    if not path.is_file():
        raise EvidenceError(f"evidence file is missing: {relative}")
    return path


def require_sha(value, label):
    if not isinstance(value, str) or not HEX64.match(value):
        raise EvidenceError(f"{label} is not a SHA-256: {value!r}")


def require_commit(value, label):
    if not isinstance(value, str) or not HEX40.match(value):
        raise EvidenceError(f"{label} is not a Git commit: {value!r}")


def allowed_skip_id(value):
    if not isinstance(value, str) or ":" not in value:
        return ""
    return value.split(":", 1)[0].strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--evidence-dir")
    parser.add_argument("--expected-source-commit")
    parser.add_argument("--expected-candidate-id")
    parser.add_argument("--expected-package-sha256")
    parser.add_argument("--expected-workflow-run-id")
    parser.add_argument("--expected-workflow-run-attempt")
    parser.add_argument("--expected-workflow-path")
    parser.add_argument("--expected-workflow-ref")
    parser.add_argument("--expected-workflow-commit")
    parser.add_argument("--expected-harness-commit")
    parser.add_argument("--require-workflow-binding", action="store_true")
    parser.add_argument("--require-package-execution", action="store_true")
    parser.add_argument("--allow-skip", action="append", default=[])
    parser.add_argument("--allow-workaround", action="append", default=[])
    args = parser.parse_args()

    summary_path = pathlib.Path(args.summary)
    evidence_dir = pathlib.Path(args.evidence_dir) if args.evidence_dir else summary_path.parent
    try:
        data = json.loads(summary_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise EvidenceError("summary is not a JSON object")
        if data.get("schemaVersion") != SCHEMA:
            raise EvidenceError(f"unsupported schemaVersion: {data.get('schemaVersion')!r}")
        if data.get("result") != "passed":
            raise EvidenceError(f"qualification result is not passed: {data.get('result')!r}")

        counts = data.get("counts")
        if not isinstance(counts, dict):
            raise EvidenceError("counts object is missing")
        for field in ("pass", "fail", "skip"):
            if not isinstance(counts.get(field), int) or counts[field] < 0:
                raise EvidenceError(f"counts.{field} is not a non-negative integer")
        if counts["fail"] != 0:
            raise EvidenceError(f"qualification has {counts['fail']} failure(s)")
        if counts["pass"] == 0:
            raise EvidenceError("qualification has no passing checks")

        checks = data.get("checks")
        if not isinstance(checks, list):
            raise EvidenceError("checks array is missing")
        by_id = {}
        for check in checks:
            if not isinstance(check, dict):
                raise EvidenceError("check entry is not an object")
            check_id = check.get("id")
            if check_id in by_id:
                raise EvidenceError(f"duplicate check id: {check_id}")
            by_id[check_id] = check
        for check_id in sorted(REQUIRED_CHECKS):
            check = by_id.get(check_id)
            if check is None:
                raise EvidenceError(f"required check is missing: {check_id}")
            if check.get("status") != "passed":
                raise EvidenceError(f"required check {check_id} is {check.get('status')!r}")
            require_sha(check.get("evidenceSha256"), f"{check_id}.evidenceSha256")
            path = evidence_path(evidence_dir, check.get("evidenceFile"))
            if sha256_file(path) != check["evidenceSha256"]:
                raise EvidenceError(f"evidence hash mismatch for {check_id}")
        for check_id in sorted(set(by_id) - REQUIRED_CHECKS):
            if by_id[check_id].get("status") not in ("passed", "not-performed"):
                raise EvidenceError(f"unexpected check {check_id} status")
            if by_id[check_id].get("status") == "not-performed":
                raise EvidenceError(f"unexpected unperformed optional check: {check_id}")

        capture = data.get("capture")
        if not isinstance(capture, dict) or capture.get("status") != "executed":
            raise EvidenceError("mandatory packet capture did not execute")
        for field in ("underlaySha256", "overlaySha256", "analysisSha256"):
            require_sha(capture.get(field), f"capture.{field}")
        for relative, field in (
            ("captures/underlay.pcap", "underlaySha256"),
            ("captures/overlay.pcap", "overlaySha256"),
            ("captures/analysis.txt", "analysisSha256"),
        ):
            path = evidence_path(evidence_dir, relative)
            if sha256_file(path) != capture[field]:
                raise EvidenceError(f"evidence hash mismatch for capture {relative}")

        reconciler = data.get("reconciler")
        if not isinstance(reconciler, dict) or reconciler.get("status") != "executed":
            raise EvidenceError("actual reconciler path did not execute")
        require_sha(reconciler.get("evidenceSha256"), "reconciler.evidenceSha256")
        path = evidence_path(evidence_dir, reconciler.get("evidenceFile"))
        if sha256_file(path) != reconciler["evidenceSha256"]:
            raise EvidenceError("evidence hash mismatch for the reconciler log")

        hardware = data.get("hardware")
        if not isinstance(hardware, dict):
            raise EvidenceError("hardware object is missing")
        if hardware.get("status") == "qualified":
            raise EvidenceError("Level B evidence cannot claim hardware qualification")
        if hardware.get("status") not in ("not-qualified", "not-required"):
            raise EvidenceError(f"unexpected hardware status: {hardware.get('status')!r}")

        skips = data.get("skips")
        if not isinstance(skips, list):
            raise EvidenceError("skips array is missing")
        if counts["skip"] != len(skips):
            raise EvidenceError("counts.skip does not match the skips array")
        allowed_skips = set(args.allow_skip)
        for item in skips:
            skip_id = allowed_skip_id(item)
            if not skip_id:
                raise EvidenceError(f"malformed skip entry: {item!r}")
            if skip_id not in allowed_skips:
                raise EvidenceError(f"unexpected skipped check: {skip_id}")

        workarounds = data.get("workarounds")
        if not isinstance(workarounds, list):
            raise EvidenceError("workarounds array is missing")
        allowed_workarounds = set(args.allow_workaround)
        for item in workarounds:
            if not isinstance(item, dict) or not item.get("id"):
                raise EvidenceError("malformed workaround entry")
            if item.get("applied") is not True:
                raise EvidenceError(f"workaround is not applied: {item.get('id')}")
            if item["id"] not in allowed_workarounds:
                raise EvidenceError(f"unexpected applied workaround: {item['id']}")

        candidate = data.get("candidate")
        if not isinstance(candidate, dict):
            raise EvidenceError("candidate object is missing")
        require_commit(candidate.get("sourceCommit"), "candidate.sourceCommit")
        if args.expected_source_commit and candidate["sourceCommit"] != args.expected_source_commit:
            raise EvidenceError(
                f"candidate source commit {candidate['sourceCommit']} != {args.expected_source_commit}"
            )
        if args.expected_candidate_id and candidate.get("id") != args.expected_candidate_id:
            raise EvidenceError(
                f"candidate id {candidate.get('id')!r} != {args.expected_candidate_id}"
            )
        if args.expected_package_sha256:
            if candidate.get("packageSha256") != args.expected_package_sha256:
                raise EvidenceError("candidate package SHA-256 does not match")
        if args.require_package_execution:
            if candidate.get("packageExecuted") is not True:
                raise EvidenceError("candidate package was not executed")
            if not candidate.get("package"):
                raise EvidenceError("candidate package name is missing")
            require_sha(candidate.get("packageSha256"), "candidate.packageSha256")
            require_sha(candidate.get("reconcilerSha256"), "candidate.reconcilerSha256")
            require_sha(candidate.get("addrHelperSha256"), "candidate.addrHelperSha256")
        elif candidate.get("packageExecuted"):
            require_sha(candidate.get("packageSha256"), "candidate.packageSha256")

        workflow = data.get("workflow")
        if not isinstance(workflow, dict):
            raise EvidenceError("workflow object is missing")
        workflow_expectations = {
            "runId": args.expected_workflow_run_id,
            "runAttempt": args.expected_workflow_run_attempt,
            "path": args.expected_workflow_path,
            "ref": args.expected_workflow_ref,
            "commit": args.expected_workflow_commit,
        }
        if args.require_workflow_binding:
            for field in ("runId", "runAttempt", "repository", "path", "ref", "commit"):
                if not workflow.get(field):
                    raise EvidenceError(f"workflow.{field} is missing")
        for field, expected in workflow_expectations.items():
            if expected and workflow.get(field) != expected:
                raise EvidenceError(
                    f"workflow.{field} {workflow.get(field)!r} != {expected!r}"
                )

        harness = data.get("harness")
        if not isinstance(harness, dict):
            raise EvidenceError("harness object is missing")
        require_commit(harness.get("commit"), "harness.commit")
        if harness.get("path") != "test/ipv6-only-netns.sh":
            raise EvidenceError(f"unexpected harness path: {harness.get('path')!r}")
        if args.expected_harness_commit and harness["commit"] != args.expected_harness_commit:
            raise EvidenceError(
                f"harness commit {harness['commit']} != {args.expected_harness_commit}"
            )

        limitations = data.get("limitations")
        if not isinstance(limitations, list) or not limitations:
            raise EvidenceError("explicit limitations are missing")
        if data.get("level") != "B":
            raise EvidenceError(f"unexpected qualification level: {data.get('level')!r}")
    except (OSError, ValueError, EvidenceError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print("IPv6 qualification evidence: PASS")
    print(f"Source commit:   {candidate['sourceCommit']}")
    print(f"Candidate ID:    {candidate.get('id') or '(not supplied)'}")
    print(f"Workflow run:    {workflow.get('runId') or '(not supplied)'} "
          f"attempt {workflow.get('runAttempt') or '(not supplied)'}")
    print(f"Checks:          {', '.join(sorted(REQUIRED_CHECKS))}")
    print(f"Skips allowed:   {', '.join(sorted(set(args.allow_skip))) or '(none)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
