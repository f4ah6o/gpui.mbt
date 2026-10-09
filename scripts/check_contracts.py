#!/usr/bin/env python3
"""Validate contract documents, package imports, and release evidence.

This standard-library-only checker verifies document structure, cross-links,
and release-ledger evidence references. A successful default run says nothing
about runtime tests or production readiness. Use --require-ready for a release
decision; it fails while any required evidence is pending or blocked.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


REQUIRED_GATE_IDS = (
    "compatibility",
    "correctness",
    "platform_tier1",
    "text",
    "performance",
    "stability",
    "api",
    "dependencies",
    "supply_chain",
    "diagnostics",
    "security_boundaries",
    "clean_consumer",
)
GATE_STATUSES = {"pending", "blocked", "pass"}
RELEASE_STATUSES = {"pending", "blocked", "ready"}
EVIDENCE_TYPES = {"ci-report", "artifact-manifest", "audit"}
REQUIRED_DOCUMENTS = (
    "docs/product.md",
    "docs/architecture.md",
    "docs/compatibility.md",
    "docs/platform.md",
    "docs/provenance.md",
    "docs/testing.md",
    "docs/release.md",
    "docs/performance.md",
    "docs/upstream.json",
    "docs/release-gates.json",
    ".github/workflows/contracts.yml",
)
REQUIRED_HEADINGS = {
    "docs/testing.md": (
        "Test layers",
        "Determinism and workload budgets",
        "Reference-model strategy",
        "Fixture and visual-artifact contract",
        "Mutation ratchet",
        "CI split",
    ),
    "docs/release.md": (
        "Gate states and evidence",
        "Required 1.0 gates",
        "Release-candidate sequence",
        "Post-1.0 maintenance",
    ),
    "docs/performance.md": (
        "Representative workloads",
        "Baseline and regression policy",
        "Reporting and release evidence",
    ),
}
COMPATIBILITY_COLUMNS = (
    "concept",
    "status",
    "contract",
    "upstream reference",
    "deviation",
    "evidence",
)
COMPATIBILITY_STATUSES = {
    "compatible",
    "compatible with documented deviation",
    "planned",
    "intentionally unsupported",
}
REQUIRED_CONCEPT_TOKENS = (
    "entity",
    "render",
    "window",
    "layout",
    "scene",
    "text",
    "task",
    "accessibility",
)
MARKDOWN_LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)
MOON_IMPORT_BLOCK_RE = re.compile(
    r'(?ms)^\s*import\s*\{([^}]*)\}\s*(?:for\s+"([^"]+)")?'
)
PACKAGE_STRING_RE = re.compile(r'"([^"\\]+)"')
PACKAGE_IMPORTS_RE = re.compile(
    r'\s*(?:"[^"\\]+"(?:\s+@[A-Za-z_][A-Za-z0-9_]*)?\s*'
    r'(?:,\s*"[^"\\]+"(?:\s+@[A-Za-z_][A-Za-z0-9_]*)?\s*)*,?)?\s*'
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ContractError(ValueError):
    """Raised when a machine-readable contract cannot be parsed."""


def load_json(path: Path) -> object:
    def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ContractError(f"duplicate JSON object key {key!r}")
            result[key] = value
        return result

    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=reject_duplicate_keys)
    except FileNotFoundError as exc:
        raise ContractError(f"missing JSON file: {path}") from exc
    except (OSError, UnicodeError, json.JSONDecodeError, ContractError) as exc:
        raise ContractError(f"invalid JSON in {path}: {exc}") from exc


def _inside_root(root: Path, relative_path: str) -> Path:
    """Resolve a repository-relative evidence path without permitting escape."""
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise ContractError("evidence path must be a non-empty repository-relative string")
    pure = PurePosixPath(relative_path)
    if pure.is_absolute() or ".." in pure.parts or "\\" in relative_path:
        raise ContractError(f"evidence path must stay inside the repository: {relative_path!r}")
    resolved_root = root.resolve()
    resolved_path = (resolved_root / Path(*pure.parts)).resolve()
    try:
        resolved_path.relative_to(resolved_root)
    except ValueError as exc:
        raise ContractError(f"evidence path escapes the repository: {relative_path!r}") from exc
    return resolved_path


def _validate_evidence(evidence: object, root: Path, gate_id: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(evidence, list):
        return [f"gate {gate_id}: evidence must be an array"]
    for index, item in enumerate(evidence):
        label = f"gate {gate_id} evidence[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{label}: expected an object")
            continue
        if set(item) != {"type", "path", "sha256"}:
            errors.append(f"{label}: fields must be exactly type, path, and sha256")
            continue
        if not isinstance(item["type"], str) or item["type"] not in EVIDENCE_TYPES:
            errors.append(f"{label}: unsupported evidence type {item['type']!r}")
        digest = item["sha256"]
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            errors.append(f"{label}: sha256 must be 64 lowercase hexadecimal characters")
            continue
        try:
            path = _inside_root(root, item["path"])
        except ContractError as exc:
            errors.append(f"{label}: {exc}")
            continue
        if not path.is_file():
            errors.append(f"{label}: evidence file does not exist: {item['path']!r}")
            continue
        try:
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as exc:
            errors.append(f"{label}: cannot read evidence file {item['path']!r}: {exc}")
            continue
        if actual != digest:
            errors.append(f"{label}: checksum mismatch for {item['path']!r}")
    return errors


def validate_release_gates(document: object, root: Path) -> list[str]:
    """Validate release-gates.json structure, state consistency, and proof files."""
    if not isinstance(document, dict):
        return ["release ledger must be a JSON object"]
    required_top_level = {"schema_version", "release", "status", "candidate_revision", "gates"}
    errors: list[str] = []
    missing_top_level = sorted(required_top_level - set(document))
    unknown_top_level = sorted(set(document) - required_top_level)
    if missing_top_level:
        errors.append(f"release ledger is missing fields: {', '.join(missing_top_level)}")
    if unknown_top_level:
        errors.append(f"release ledger has unknown fields: {', '.join(unknown_top_level)}")
    if type(document.get("schema_version")) is not int or document.get("schema_version") != 1:
        errors.append("release ledger schema_version must be 1")
    if document.get("release") != "1.0":
        errors.append("release ledger release must be '1.0'")
    release_status = document.get("status")
    if not isinstance(release_status, str) or release_status not in RELEASE_STATUSES:
        errors.append(f"release ledger status must be one of {sorted(RELEASE_STATUSES)}")
    candidate_revision = document.get("candidate_revision")
    if candidate_revision is not None and (
        not isinstance(candidate_revision, str)
        or not re.fullmatch(r"[0-9a-f]{40}", candidate_revision)
    ):
        errors.append("release ledger candidate_revision must be null or a 40-character lowercase commit SHA")

    gates = document.get("gates")
    if not isinstance(gates, list):
        return errors + ["release ledger gates must be an array"]
    by_id: dict[str, dict[str, object]] = {}
    for index, gate in enumerate(gates):
        label = f"gates[{index}]"
        if not isinstance(gate, dict):
            errors.append(f"{label}: expected an object")
            continue
        gate_id = gate.get("id")
        if not isinstance(gate_id, str) or not gate_id.strip():
            errors.append(f"{label}: id must be a non-empty string")
            continue
        if gate_id in by_id:
            errors.append(f"duplicate release gate id: {gate_id}")
            continue
        by_id[gate_id] = gate
        allowed_fields = {"id", "status", "evidence", "blocker"}
        unknown_fields = set(gate) - allowed_fields
        missing_fields = {"id", "status", "evidence"} - set(gate)
        if unknown_fields:
            errors.append(f"gate {gate_id}: unknown fields {sorted(unknown_fields)}")
        if missing_fields:
            errors.append(f"gate {gate_id}: missing fields {sorted(missing_fields)}")
        status = gate.get("status")
        if not isinstance(status, str) or status not in GATE_STATUSES:
            errors.append(f"gate {gate_id}: status must be one of {sorted(GATE_STATUSES)}")
        errors.extend(_validate_evidence(gate.get("evidence"), root, gate_id))
        evidence = gate.get("evidence")
        if status == "pass" and isinstance(evidence, list) and not evidence:
            errors.append(f"gate {gate_id}: pass requires at least one checksum-verified evidence file")
        if status == "pass" and (
            not isinstance(candidate_revision, str)
            or not re.fullmatch(r"[0-9a-f]{40}", candidate_revision)
        ):
            errors.append(f"gate {gate_id}: pass requires a pinned candidate_revision")
        if status == "pass" and isinstance(evidence, list):
            for index, item in enumerate(evidence):
                if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                    continue
                try:
                    evidence_path = _inside_root(root, item["path"])
                    manifest = load_json(evidence_path)
                except ContractError as exc:
                    errors.append(f"gate {gate_id} evidence[{index}]: {exc}")
                    continue
                errors.extend(_validate_evidence_manifest(manifest, gate_id, candidate_revision, item["path"]))
        if status == "blocked":
            blocker = gate.get("blocker")
            if not isinstance(blocker, str) or not blocker.strip():
                errors.append(f"gate {gate_id}: blocked status requires a non-empty blocker")
        elif "blocker" in gate:
            errors.append(f"gate {gate_id}: blocker is only valid for blocked status")

    missing = sorted(set(REQUIRED_GATE_IDS) - set(by_id))
    extra = sorted(set(by_id) - set(REQUIRED_GATE_IDS))
    if missing:
        errors.append(f"release ledger is missing required gates: {', '.join(missing)}")
    if extra:
        errors.append(f"release ledger has unknown gates: {', '.join(extra)}")

    if set(by_id) == set(REQUIRED_GATE_IDS):
        statuses = [gate.get("status") for gate in by_id.values()]
        if any(status == "blocked" for status in statuses):
            expected = "blocked"
        elif all(status == "pass" for status in statuses):
            expected = "ready"
        else:
            expected = "pending"
        if isinstance(release_status, str) and release_status in RELEASE_STATUSES and release_status != expected:
            errors.append(f"release ledger status is {release_status!r}, but gate states require {expected!r}")
        if release_status == "ready" and (
            not isinstance(candidate_revision, str)
            or not re.fullmatch(r"[0-9a-f]{40}", candidate_revision)
        ):
            errors.append("ready release ledger requires a pinned candidate_revision")
    return errors


def _validate_evidence_manifest(
    manifest: object,
    gate_id: str,
    candidate_revision: str,
    manifest_path: str,
) -> list[str]:
    label = f"gate {gate_id} evidence manifest {manifest_path!r}"
    if not isinstance(manifest, dict):
        return [f"{label}: expected a JSON object"]
    required = {"schema_version", "gate_id", "result", "candidate_revision", "toolchain", "target", "run", "artifacts"}
    missing = sorted(required - set(manifest))
    unknown = sorted(set(manifest) - required)
    if missing:
        return [f"{label}: missing fields {missing}"]
    errors: list[str] = []
    if unknown:
        errors.append(f"{label}: unknown fields {unknown}")
    if type(manifest.get("schema_version")) is not int or manifest.get("schema_version") != 1:
        errors.append(f"{label}: schema_version must be 1")
    if manifest.get("gate_id") != gate_id:
        errors.append(f"{label}: gate_id must match {gate_id!r}")
    if manifest.get("result") != "pass":
        errors.append(f"{label}: result must be 'pass'")
    if manifest.get("candidate_revision") != candidate_revision:
        errors.append(f"{label}: candidate_revision does not match the release ledger")
    for field in ("toolchain", "target", "run"):
        value = manifest.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{label}: {field} must be a non-empty string")
        elif field == "run":
            parsed = urlsplit(value)
            if parsed.scheme != "https" or not parsed.netloc:
                errors.append(f"{label}: run must be a traceable HTTPS URL")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        errors.append(f"{label}: artifacts must be a non-empty array")
    else:
        for index, artifact in enumerate(artifacts):
            artifact_label = f"{label} artifacts[{index}]"
            if not isinstance(artifact, dict):
                errors.append(f"{artifact_label}: expected an object")
                continue
            unknown_fields = sorted(set(artifact) - {"name", "uri", "sha256"})
            missing_fields = sorted({"name", "uri", "sha256"} - set(artifact))
            if unknown_fields:
                errors.append(f"{artifact_label}: unknown fields {unknown_fields}")
            if missing_fields:
                errors.append(f"{artifact_label}: missing fields {missing_fields}")
            for field in ("name", "uri", "sha256"):
                value = artifact.get(field)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{artifact_label}: {field} must be a non-empty string")
            digest = artifact.get("sha256")
            if isinstance(digest, str) and not SHA256_RE.fullmatch(digest):
                errors.append(f"{artifact_label}: sha256 must be 64 lowercase hexadecimal characters")
            uri = artifact.get("uri")
            if isinstance(uri, str):
                parsed = urlsplit(uri)
                if parsed.scheme != "https" or not parsed.netloc:
                    errors.append(f"{artifact_label}: uri must be HTTPS")
    return errors


def _markdown_links(path: Path, root: Path) -> list[str]:
    errors: list[str] = []
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read {path.relative_to(root)}: {exc}"]
    for match in MARKDOWN_LINK_RE.finditer(content):
        destination = match.group(1).strip().split(maxsplit=1)[0].strip("<>")
        if not destination or destination.startswith("#"):
            continue
        if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", destination):
            continue
        target = unquote(destination.split("#", 1)[0])
        if not target:
            continue
        resolved = (path.parent / target).resolve()
        try:
            resolved.relative_to(root.resolve())
        except ValueError:
            errors.append(f"{path.relative_to(root)}: local link escapes repository: {destination}")
            continue
        if not resolved.exists():
            errors.append(f"{path.relative_to(root)}: broken local link: {destination}")
    return errors


def _validate_compatibility(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return [f"cannot read {path}: {exc}"]
    table_index = None
    header: list[str] | None = None
    for index, line in enumerate(lines):
        if line.lstrip().startswith("|"):
            cells = [cell.strip().lower() for cell in line.strip().strip("|").split("|")]
            if all(column in cells for column in COMPATIBILITY_COLUMNS):
                table_index = index
                header = cells
                break
    if table_index is None or header is None:
        return ["docs/compatibility.md: missing compatibility table with columns " + ", ".join(COMPATIBILITY_COLUMNS)]
    if header != list(COMPATIBILITY_COLUMNS):
        return ["docs/compatibility.md: compatibility table columns must be ordered as " + ", ".join(COMPATIBILITY_COLUMNS)]

    concepts: list[str] = []
    for line in lines[table_index + 1 :]:
        if not line.lstrip().startswith("|"):
            if concepts:
                break
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells and all(re.fullmatch(r"[:\- ]+", cell or " ") for cell in cells):
            continue
        if len(cells) < len(header):
            errors.append("docs/compatibility.md: table row has fewer cells than the header")
            continue
        row = dict(zip(header, cells))
        concept = row.get("concept", "").strip()
        if not concept:
            errors.append("docs/compatibility.md: compatibility row has an empty concept")
            continue
        normalized = concept.casefold()
        if normalized in concepts:
            errors.append(f"docs/compatibility.md: duplicate compatibility concept {concept!r}")
        concepts.append(normalized)
        status = row.get("status", "").strip()
        if status not in COMPATIBILITY_STATUSES:
            errors.append(f"docs/compatibility.md: invalid status {status!r} for {concept!r}")
        for column in ("contract", "upstream reference", "deviation", "evidence"):
            if not row.get(column, "").strip():
                errors.append(f"docs/compatibility.md: {concept!r} has empty {column}")
    missing_areas = [
        token for token in REQUIRED_CONCEPT_TOKENS
        if not any(token in concept for concept in concepts)
    ]
    if missing_areas:
        errors.append("docs/compatibility.md: missing concepts covering " + ", ".join(missing_areas))
    return errors


def _validate_upstream_manifest(path: Path) -> list[str]:
    """Validate the pinned source and record shape used by docs/provenance.md."""
    try:
        document = load_json(path)
    except ContractError as exc:
        return [str(exc)]
    if not isinstance(document, dict):
        return ["docs/upstream.json: expected an object"]
    errors: list[str] = []
    if type(document.get("schema_version")) is not int or document.get("schema_version") != 1:
        errors.append("docs/upstream.json: schema_version must be 1")
    target = document.get("compatibility_target")
    if not isinstance(target, dict):
        errors.append("docs/upstream.json: compatibility_target must be an object")
    else:
        required = {"repository", "project", "revision", "observed_ref", "verified_on", "scope"}
        for key in sorted(required - set(target)):
            errors.append(f"docs/upstream.json: compatibility_target is missing {key}")
        repository = target.get("repository")
        if not isinstance(repository, str) or not repository.startswith("https://github.com/"):
            errors.append("docs/upstream.json: compatibility_target.repository must be a GitHub HTTPS URL")
        revision = target.get("revision")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
            errors.append("docs/upstream.json: compatibility_target.revision must be a 40-character lowercase commit SHA")
        for field in ("project", "observed_ref", "verified_on", "scope"):
            value = target.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"docs/upstream.json: compatibility_target.{field} must be a non-empty string")
    licenses = document.get("license_evidence")
    if not isinstance(licenses, list) or not licenses:
        errors.append("docs/upstream.json: license_evidence must be a non-empty array")
    else:
        for index, item in enumerate(licenses):
            if not isinstance(item, dict):
                errors.append(f"docs/upstream.json: license_evidence[{index}] must be an object")
                continue
            for field in ("path", "url", "evidence"):
                if not isinstance(item.get(field), str) or not item[field].strip():
                    errors.append(f"docs/upstream.json: license_evidence[{index}].{field} must be a non-empty string")
            if isinstance(item.get("url"), str) and not item["url"].startswith("https://"):
                errors.append(f"docs/upstream.json: license_evidence[{index}].url must be HTTPS")
    record_schema = document.get("record_schema")
    record_fields = {
        "upstream_repository",
        "upstream_revision",
        "upstream_paths",
        "license_expression",
        "license_evidence",
        "destination_paths",
        "method",
        "material_deviations",
    }
    if not isinstance(record_schema, dict):
        errors.append("docs/upstream.json: record_schema must be an object")
        allowed_methods: set[str] = set()
    else:
        required_fields = record_schema.get("required")
        if (
            not isinstance(required_fields, list)
            or not all(isinstance(value, str) for value in required_fields)
            or set(required_fields) != record_fields
        ):
            errors.append("docs/upstream.json: record_schema.required must define the provenance record fields")
        methods = record_schema.get("method_values")
        if not isinstance(methods, list) or not methods or not all(isinstance(value, str) for value in methods):
            errors.append("docs/upstream.json: record_schema.method_values must be a non-empty string array")
            allowed_methods = set()
        else:
            allowed_methods = set(methods)
    if allowed_methods != {"translated", "adapted", "independent_from_behavior"}:
        errors.append("docs/upstream.json: record_schema.method_values must list translated, adapted, and independent_from_behavior")
    records = document.get("records")
    if not isinstance(records, list):
        errors.append("docs/upstream.json: records must be an array")
    else:
        for index, record in enumerate(records):
            label = f"docs/upstream.json: records[{index}]"
            if not isinstance(record, dict):
                errors.append(f"{label} must be an object")
                continue
            missing = sorted(record_fields - set(record))
            if missing:
                errors.append(f"{label} is missing fields {missing}")
            for field in ("upstream_repository", "license_expression"):
                if field in record and (not isinstance(record[field], str) or not record[field].strip()):
                    errors.append(f"{label}.{field} must be a non-empty string")
            revision = record.get("upstream_revision")
            if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
                errors.append(f"{label}.upstream_revision must be a 40-character lowercase commit SHA")
            for field in ("upstream_paths", "destination_paths", "material_deviations"):
                value = record.get(field)
                if not isinstance(value, list) or not all(isinstance(item, str) and item.strip() for item in value):
                    errors.append(f"{label}.{field} must be an array of non-empty strings")
            license_evidence = record.get("license_evidence")
            license_entries = license_evidence if isinstance(license_evidence, list) else [license_evidence]
            if not license_entries or not all(isinstance(item, dict) for item in license_entries):
                errors.append(f"{label}.license_evidence must be an evidence object or a non-empty evidence array")
            else:
                for evidence_index, evidence in enumerate(license_entries):
                    for field in ("path", "url", "evidence"):
                        value = evidence.get(field)
                        if not isinstance(value, str) or not value.strip():
                            errors.append(f"{label}.license_evidence[{evidence_index}].{field} must be a non-empty string")
                    if isinstance(evidence.get("url"), str) and not evidence["url"].startswith("https://"):
                        errors.append(f"{label}.license_evidence[{evidence_index}].url must be HTTPS")
            method = record.get("method")
            if not isinstance(method, str) or method not in allowed_methods:
                errors.append(f"{label}.method must be one of {sorted(allowed_methods)}")
            extra_fields = sorted(set(record) - record_fields)
            if extra_fields:
                errors.append(f"{label} has unknown fields {extra_fields}")
    return errors


def _parse_package_imports(path: Path) -> tuple[list[str], list[str], list[str]]:
    """Read runtime and test-only imports from a MoonBit package manifest."""
    errors: list[str] = []
    if path.suffix == ".json":
        try:
            manifest = load_json(path)
        except ContractError as exc:
            return [], [], [str(exc)]
        if not isinstance(manifest, dict):
            return [], [], [f"{path}: package manifest must be an object"]

        def normalize(value: object, field: str) -> list[str]:
            if value is None:
                return []
            if isinstance(value, dict):
                values = list(value.keys())
            elif isinstance(value, list):
                values = value
            else:
                errors.append(f"{path}: {field} must be an array or object")
                return []
            if not all(isinstance(item, str) and item.strip() for item in values):
                errors.append(f"{path}: {field} entries must be non-empty strings")
                return []
            return values

        runtime = normalize(manifest.get("import"), "import")
        test = normalize(manifest.get("test_import", manifest.get("test-import")), "test_import")
        return runtime, test, errors

    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [], [], [f"cannot read {path}: {exc}"]
    # Package manifests use // comments. Strip them before counting import
    # declarations so commented-out examples cannot satisfy the audit.
    content = "\n".join(line.split("//", 1)[0] for line in content.splitlines())
    runtime_imports: list[str] = []
    test_imports: list[str] = []
    blocks = list(MOON_IMPORT_BLOCK_RE.finditer(content))
    declarations = len(re.findall(r"^\s*import\s*\{", content, re.MULTILINE))
    if declarations != len(blocks):
        errors.append(f"{path}: malformed import block")
    for block in blocks:
        import_text = block.group(1)
        if not PACKAGE_IMPORTS_RE.fullmatch(import_text):
            errors.append(f"{path}: malformed import list")
            continue
        imports = PACKAGE_STRING_RE.findall(import_text)
        scope = block.group(2)
        if scope is None:
            runtime_imports.extend(imports)
        elif scope in {"test", "wbtest"}:
            test_imports.extend(imports)
        else:
            errors.append(f"{path}: unsupported import scope {scope!r}")
    return runtime_imports, test_imports, errors


def validate_runtime_dependencies(root: Path) -> list[str]:
    """Audit every MoonBit package manifest against the approved runtime layer graph.

    Packages below tests/ are test-only. In every other package, runtime imports
    must be MoonBit core or an explicitly allowed first-party layer edge.
    QuickCheck is permitted only in a test-scoped import block.
    """
    root = root.resolve()
    module_name: str | None = None
    module_path = root / "moon.mod"
    module_json = root / "moon.mod.json"
    if module_path.is_file():
        try:
            content = module_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            return [f"cannot read moon.mod: {exc}"]
        match = re.search(r'^\s*name\s*=\s*"([^"]+)"\s*$', content, re.MULTILINE)
        if match:
            module_name = match.group(1)
    elif module_json.is_file():
        try:
            document = load_json(module_json)
        except ContractError as exc:
            return [str(exc)]
        if isinstance(document, dict) and isinstance(document.get("name"), str):
            module_name = document["name"]
    if not module_name:
        return ["missing or invalid MoonBit module manifest (moon.mod or moon.mod.json)"]

    allowed_internal_edges = {
        "primitives": set(),
        # Shared semantics stay independent from layout, capabilities, and OS leaves.
        "accessibility": {"primitives"},
        # Text editing semantics stay portable and depend only on core values.
        "text": set(),
        # Intrinsic layout results are portable values layered over text and
        # finite primitives; shaping and native handles remain in platform leaves.
        "text_layout": {"text", "primitives"},
        # Reusable editing/paint state consumes portable layout results; native
        # shaping, raster admission and clipboard ownership remain in leaves.
        "controls/text_field": {"text", "text_layout", "primitives", "scene", "element"},
        # Reusable button state stays portable above hit-testing and scene data.
        "controls/button": {"primitives", "element", "scene"},
        "controls/command_palette": {"text", "text_layout", "primitives", "element", "controls/text_field", "capability", "diagnostics", "scene"},
        "diagnostics": {"primitives"},
        "core": {"primitives", "diagnostics"},
        "layout": {"primitives"},
        "scene": {"primitives"},
        "platform": {"primitives", "diagnostics", "scene"},
        "platform/macos": {"platform", "primitives", "diagnostics", "scene", "platform/testing"},
        "platform/linux_text": {"text_layout", "text", "primitives"},
        "platform/windows_text": {"text", "text_layout", "primitives"},
        # Native text measurers are platform leaves. The frame-readback seam is
        # portable in shape and depends only on the shared platform contract.
        "platform/macos_text": {"text_layout", "text", "primitives"},
        "platform/testing": {"platform", "diagnostics"},
        "examples/native_macos": {"platform/macos", "platform", "primitives", "diagnostics", "scene"},
        "ubuntu": {
            "accessibility", "platform", "platform/linux_text", "platform/testing",
            "text", "primitives", "diagnostics", "scene",
        },
        "examples/ubuntu": {
            "ubuntu", "platform", "platform/linux_text", "text", "primitives", "diagnostics", "scene",
        },
        # The Ubuntu button fixture owns its portable semantic projection; its
        # native executable remains a leaf above that headless fixture.
        "examples/ubuntu_button/fixture": {
            "accessibility", "controls/button", "element", "primitives", "scene",
        },
        "examples/ubuntu_button": {
            "ubuntu", "platform", "diagnostics", "primitives", "examples/ubuntu_button/fixture",
        },
        # The native macOS sample is a leaf above the portable Button fixture.
        "examples/macos_button": {
            "diagnostics", "examples/ubuntu_button/fixture", "platform",
            "platform/macos", "platform/testing", "primitives", "scene",
        },
        "examples/linux_text_field": {
            "ubuntu", "platform", "platform/linux_text", "controls/text_field",
            "text", "text_layout", "element", "primitives", "scene", "diagnostics", "controls/command_palette", "capability",
        },
        "windows": {
            "platform", "primitives", "diagnostics", "scene", "text",
            "platform/windows_text", "platform/testing",
        },
        "examples/windows": {"windows", "platform", "primitives", "diagnostics", "scene"},
        "examples/windows_text_field": {
            "windows", "platform/windows_text", "platform",
            "controls/text_field", "text", "text_layout", "element",
            "primitives", "scene", "diagnostics",
        },
        "element": {"core", "primitives", "layout", "scene"},
        # Semantic capabilities are portable application-facing contracts. The
        # optional MCP adapter is a leaf above them and owns no domain state.
        "capability": {"core", "diagnostics"},
        "mcp": {"capability", "diagnostics"},
        # Electron/Tauri migrations use a portable request/completion contract;
        # the host transport remains in target-specific leaf adapters.
        "migration/host_services": {"capability", "diagnostics"},
        "examples/headless": {"core", "diagnostics", "primitives"},
        # Portable browser fixture consumes framework layers only. Browser host
        # code is a target-specific leaf above that fixture and shared values.
        "examples/browser_app": {
            "core", "diagnostics", "element", "layout", "platform", "primitives", "scene",
            "capability", "mcp",
        },
        "examples/browser": {
            "examples/browser_app", "diagnostics", "platform", "primitives",
        },
        # The task-board demo has the same portable-model / JS-leaf boundary.
        "examples/task_board": {
            "capability", "core", "element", "layout", "platform", "primitives", "scene",
        },
        "examples/browser_board": {"examples/task_board"},
        "examples/mcp_stdio": {"capability", "diagnostics", "mcp"},
    }
    required_runtime_packages = {
        "primitives",
        "accessibility",
        "diagnostics",
        "core",
        "layout",
        "scene",
        "element",
    }
    errors: list[str] = []
    module_prefix = module_name + "/"

    excluded_directories = {".git", "_build", "build", "target", "node_modules"}
    manifests = [
        path for pattern in ("moon.pkg", "moon.pkg.json") for path in root.rglob(pattern)
        if not any(part in excluded_directories for part in path.relative_to(root).parts)
    ]
    by_directory: dict[Path, list[Path]] = {}
    for manifest in manifests:
        by_directory.setdefault(manifest.parent, []).append(manifest)

    found_runtime_packages: set[str] = set()
    for directory, package_manifests in sorted(by_directory.items()):
        relative_directory = directory.relative_to(root).as_posix()
        package = "" if relative_directory == "." else relative_directory
        if len(package_manifests) != 1:
            errors.append(f"{package or '.'}: multiple package manifests are ambiguous")
            continue
        manifest_path = package_manifests[0]
        imports, test_imports, parse_errors = _parse_package_imports(manifest_path)
        errors.extend(parse_errors)
        if package.split("/", 1)[0] in {"tests", "testing"}:
            # These are harnesses and fixtures, never published runtime packages.
            continue

        if package not in allowed_internal_edges:
            errors.append(f"{package or '.'}: runtime package has no approved dependency layer")
            continue
        found_runtime_packages.add(package)
        for imported in test_imports:
            if imported == "moonbitlang/core/quickcheck" or imported.startswith("moonbitlang/core/quickcheck/"):
                continue
            if imported == "moonbitlang/core" or imported.startswith("moonbitlang/core/"):
                continue
            if imported == module_name or imported.startswith(module_prefix):
                continue
            errors.append(f"{package}/: unapproved test-only import: {imported!r}")
        for imported in imports:
            if imported == "moonbitlang/core/quickcheck" or imported.startswith("moonbitlang/core/quickcheck/"):
                errors.append(f"{package}/: QuickCheck must be a test-only import, not a runtime import")
            elif imported == "moonbitlang/core" or imported.startswith("moonbitlang/core/"):
                continue
            if imported.startswith(module_prefix):
                relative = imported[len(module_prefix) :]
                if relative not in allowed_internal_edges[package]:
                    errors.append(f"{package}/: forbidden runtime package edge to {imported!r}")
            else:
                errors.append(f"{package}/: third-party runtime import is forbidden: {imported!r}")

    for required_package in required_runtime_packages:
        if required_package not in found_runtime_packages:
            errors.append(f"missing package manifest for runtime package {required_package!r}")
    return errors


def _validate_workflow(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        workflow_text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return [f"cannot read .github/workflows/contracts.yml: {exc}"]
    required_commands = (
        "python3 -m unittest discover -s tests -p 'test_*.py'",
        "python3 scripts/check_contracts.py",
        "moon version --all",
        "moon fmt --check",
        "moon check --target all --deny-warn",
        "moon test --target all --deny-warn",
    )
    for command in required_commands:
        if command not in workflow_text:
            errors.append(f".github/workflows/contracts.yml: missing required command {command!r}")
    action_refs = re.findall(
        r"^[ \t]*(?:-[ \t]*)?uses:[ \t]*([^\s#]+)",
        workflow_text,
        flags=re.MULTILINE,
    )
    if not action_refs:
        errors.append(".github/workflows/contracts.yml: no pinned actions found")
    for expected_action in ("actions/checkout", "hustcer/setup-moonbit"):
        if not any(ref.startswith(expected_action + "@") for ref in action_refs):
            errors.append(f".github/workflows/contracts.yml: missing required action {expected_action!r}")
    for action_ref in action_refs:
        if not re.search(r"@[0-9a-f]{40}$", action_ref):
            errors.append(f".github/workflows/contracts.yml: action is not pinned to a full commit SHA: {action_ref}")
    return errors


def validate_contracts(root: Path) -> tuple[list[str], str | None]:
    root = root.resolve()
    errors: list[str] = []
    for relative in REQUIRED_DOCUMENTS:
        if not (root / relative).is_file():
            errors.append(f"missing required contract file: {relative}")

    for relative, required_headings in REQUIRED_HEADINGS.items():
        path = root / relative
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        headings = set(HEADING_RE.findall(content))
        for heading in required_headings:
            if heading not in headings:
                errors.append(f"{relative}: missing section heading {heading!r}")

    for path in sorted((root / "docs").glob("*.md")) if (root / "docs").is_dir() else []:
        errors.extend(_markdown_links(path, root))

    compatibility_path = root / "docs/compatibility.md"
    if compatibility_path.is_file():
        errors.extend(_validate_compatibility(compatibility_path))

    upstream_path = root / "docs/upstream.json"
    if upstream_path.is_file():
        errors.extend(_validate_upstream_manifest(upstream_path))

    errors.extend(validate_runtime_dependencies(root))

    release_path = root / "docs/release-gates.json"
    release_status: str | None = None
    if release_path.is_file():
        try:
            release_document = load_json(release_path)
            errors.extend(validate_release_gates(release_document, root))
            if isinstance(release_document, dict):
                status = release_document.get("status")
                if isinstance(status, str):
                    release_status = status
        except ContractError as exc:
            errors.append(str(exc))

    workflow = root / ".github/workflows/contracts.yml"
    if workflow.is_file():
        errors.extend(_validate_workflow(workflow))

    return errors, release_status


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="repository root")
    parser.add_argument(
        "--require-ready",
        action="store_true",
        help="fail unless all 1.0 gates have checksum-verified evidence and ledger status is ready",
    )
    args = parser.parse_args(argv)

    errors, release_status = validate_contracts(args.root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Contract document check failed with {len(errors)} error(s).", file=sys.stderr)
        return 1

    if release_status != "ready":
        print(f"Contract documents valid; production release evidence is {release_status or 'unknown'}.")
        if args.require_ready:
            print("Release readiness failed: all required gates need valid evidence.", file=sys.stderr)
            return 2
        return 0
    print("Contract documents valid; production release evidence is ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
