"""Selection: which catalog groups a candidate change requires, and why.

``build_plan`` composes the other planner modules' answers — each group's
derived inputs, the changed paths, the request, platform applicability, and the
candidate's identities — into the plan document every later tool reads. See
``docs/validation.md`` for the selection policy and the plan's structure.
"""

from __future__ import annotations

import receipts
from plan_cabal import Package, component_inputs
from plan_identity import digest
from plan_repository import GitTree, PlannerError, changed_paths, matches_class, matches_input
from plan_request import ALL_HSPEC

PLAN_SCHEMA_VERSION = receipts.PLAN_SCHEMA_VERSION


# --------------------------------------------------------------------------
# Planning


def build_plan(
    root: str,
    base: GitTree,
    head: GitTree,
    candidate: GitTree,
    identity: dict,
    catalog: dict,
    catalog_source: str,
    request_ids: list[str],
    request_all_hspec: bool,
    request_source: str | None,
    base_packages: dict[str, Package],
    head_packages: dict[str, Package],
    base_catalog: dict | None,
    base_catalog_state: str,
    catalog_override: str | None,
    candidate_catalog: dict,
    workers: list[dict] | None,
) -> dict:
    groups = catalog["groups"]
    groups_by_id = {group["id"]: group for group in groups}

    base_inputs: dict[str, list[str]] = {}
    base_policy_inputs: list[str] = []
    if base_catalog is not None:
        base_policy_inputs = base_catalog["policy_inputs"]
        base_inputs = {group["id"]: group["inputs"] for group in base_catalog["groups"]}

    # Inputs are derived from both revisions so a removed or relocated source,
    # or an input a group used to declare, still counts for that group. Policy
    # inputs reach every group, optional ones included: an optional group's
    # definition can change without selecting it, and a downstream consumer must
    # not read that as an unchanged execution definition.
    inputs_by_group: dict[str, set[str]] = {}
    for group in groups:
        derived = component_inputs(head_packages, group["component"])
        derived |= component_inputs(base_packages, group["component"])
        derived |= set(group["inputs"])
        derived |= set(base_inputs.get(group["id"], []))
        derived |= set(catalog["policy_inputs"])
        derived |= set(base_policy_inputs)
        inputs_by_group[group["id"]] = derived

    for identifier in request_ids:
        if identifier not in groups_by_id:
            raise PlannerError(
                f"{request_source}: requested group {identifier!r} is not registered in {catalog_source}"
            )
    requested = set(request_ids)
    if request_all_hspec:
        hspec = [group["id"] for group in groups if group["framework"] == "hspec"]
        if not hspec:
            raise PlannerError(
                f"{request_source}: '{ALL_HSPEC}' matched no Hspec group in {catalog_source}"
            )
        requested.update(hspec)

    changes = changed_paths(root, base, head)
    affected: set[str] = set()
    classified: list[dict] = []
    unknown_inputs: list[str] = []
    for change in changes:
        path = change["path"]
        consumers = sorted(
            identifier
            for identifier, entries in inputs_by_group.items()
            if any(matches_input(path, entry) for entry in entries)
        )
        if consumers:
            # An explicitly consumed input outranks a non-affecting class, so a
            # test-consumed Markdown file still invalidates its consumers.
            classification = "consumed"
            affected.update(consumers)
        elif any(matches_class(path, pattern) for pattern in catalog["non_affecting_paths"]):
            classification = "non-affecting"
        else:
            classification = "unknown"
            unknown_inputs.append(path)
        classified.append({**change, "classification": classification, "consumers": consumers})

    floor = set(catalog["floor"])
    fallback = bool(unknown_inputs)

    runner_os = identity["runner_os"]

    entries: list[dict] = []
    for group in groups:
        identifier = group["id"]
        optional = group["optional"]
        platforms = group.get("platforms")
        changed = identifier in affected
        if not optional and fallback:
            # Uncertainty must never reach a downstream consumer as equivalence.
            changed = True
        # Platform eligibility is asked first, and it is the one answer a
        # request cannot argue with. A group whose command targets components
        # this platform does not build has no execution available to it, so
        # selecting it would produce either a plan no worker can route or a
        # command that fails before any probe runs. Naming it here, with a
        # reason of its own, is what keeps that omission distinguishable from
        # one this platform merely did not need — and from a pass.
        #
        # `changed` is decided above and deliberately left alone: what a
        # candidate touches is a property of the candidate, so an inapplicable
        # group still reports its changed inputs, and the unknown-input
        # fallback still marks it, exactly as it does on the platform that
        # builds it.
        if platforms is not None and runner_os not in platforms:
            selected = False
            reason = receipts.PLATFORM_INAPPLICABLE
        elif optional:
            selected = identifier in requested
            reason = "requested" if selected else "optional-unrequested"
        else:
            selected = True
            if identifier in floor:
                reason = "floor"
            elif identifier in affected:
                reason = "affected"
            elif identifier in requested:
                reason = "requested"
            elif fallback:
                reason = "unknown-input"
            else:
                selected = False
                reason = "unaffected"
        entries.append(
            {
                "id": identifier,
                "description": group["description"],
                "selected": selected,
                "inputs_changed": changed,
                "reason": reason,
                "optional": optional,
                # `null` for a group applicable everywhere, so a consumer reads
                # the declaration rather than inferring it from the reason.
                "platforms": list(platforms) if platforms is not None else None,
                "framework": group["framework"],
                "category": group["category"],
                "runner": group["runner"],
                "timeout_seconds": group["timeout_seconds"],
                "command": list(group["command"]),
                # `null` for a group whose command is its whole execution.
                "preparation": (
                    {
                        "command": list(group["preparation"]["command"]),
                        "timeout_seconds": group["preparation"]["timeout_seconds"],
                    }
                    if "preparation" in group
                    else None
                ),
            }
        )

    # Routing is decided here, once, against the groups this plan selected. A
    # plan that nobody could execute is refused before it exists rather than
    # discovered by a worker that cannot run it or an aggregate missing a
    # receipt. Without declarations the plan is an inspection of selection
    # alone, and every tool that would act on it refuses it.
    routed = None
    if workers is not None:
        routed = receipts.normalized_workers(workers, entries)
        problems = receipts.worker_assignment_problems(routed, entries)
        if problems:
            raise PlannerError("the worker declarations cannot route this plan: " + "; ".join(problems))

    return {
        "schema_version": PLAN_SCHEMA_VERSION,
        # The catalog's declared revision stays an integer a person can read,
        # and is the one recorded here under its own name. `policy_version` is
        # the digest reuse compares, because a classification change that never
        # touches the declared revision still has to invalidate evidence.
        "catalog_policy_version": catalog["policy_version"],
        "policy_version": identity["policy_version"],
        "input_identity": identity["input_identity"],
        "toolchain": dict(identity["toolchain"]),
        # The platform an execution's result is a claim about. A receipt from
        # another operating system describes another machine's behaviour.
        "runner_os": identity["runner_os"],
        # The descriptor of the image Linux workers run, read from the
        # candidate and already checked against it, or null when the plan has
        # no image. Its digest and native manifest are also in `toolchain`,
        # which is what every compatibility comparison reads.
        "ci_image": identity["ci_image"],
        # `override` and `candidate_digest` describe the classification the
        # runner has to reproduce before it can judge its own checkout: which
        # catalog decided this candidate's inputs, and exactly what that catalog
        # said. A fixture catalog lives on the mutable filesystem rather than in
        # the candidate's tree, so naming the path alone would let it be
        # rewritten between planning and execution; the digest is what binds its
        # contents. The path itself stays out of `plan_identity`, which
        # deliberately omits run-local filenames.
        "catalog": {
            "source": catalog_source,
            "override": catalog_override,
            "candidate_digest": digest(candidate_catalog),
            "groups": len(groups),
        },
        "base": {"revision": base.revision, "commit": base.commit, "tree": base.tree},
        "head": {"revision": head.revision, "commit": head.commit, "tree": head.tree},
        # Selection compares the contribution; execution happens on the
        # integration candidate, and that is the tree identity fingerprints.
        "candidate": {
            "revision": candidate.revision,
            "commit": candidate.commit,
            "tree": candidate.tree,
        },
        "base_package_metadata": "present" if base_packages else "absent",
        "base_catalog": base_catalog_state,
        "request": {
            "source": request_source,
            "ids": sorted(request_ids),
            "all_hspec": request_all_hspec,
            "resolved": sorted(requested),
        },
        "changed_paths": classified,
        "unknown_inputs": sorted(unknown_inputs),
        "groups": entries,
        "selected": [entry["id"] for entry in entries if entry["selected"]],
        "workers": routed,
    }
