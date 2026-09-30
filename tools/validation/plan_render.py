"""The human-readable rendering of a validation plan.

It reads only the plan document ``plan_selection.build_plan`` produced, so the
prose and the JSON can never describe two different plans.
"""

from __future__ import annotations


def render_prose(plan: dict) -> str:
    lines = ["Validation plan"]
    lines.append(f"  base     {plan['base']['revision']} ({plan['base']['commit'][:12]})")
    lines.append(f"  head     {plan['head']['revision']} ({plan['head']['commit'][:12]})")
    lines.append(f"  candidate {plan['candidate']['revision']} ({plan['candidate']['commit'][:12]})")
    lines.append(
        f"  catalog  {plan['catalog']['source']} "
        f"({plan['catalog']['groups']} groups, policy version {plan['catalog_policy_version']})"
    )
    lines.append(f"  policy   {plan['policy_version'][:12]}")
    lines.append(f"  inputs   {plan['input_identity'][:12]}")
    declared = ", ".join(f"{name} {version}" for name, version in sorted(plan["toolchain"].items()))
    lines.append(f"  pinned   {declared or 'no toolchain'} on {plan['runner_os']}")
    if plan["ci_image"]:
        lines.append(f"  image    {plan['ci_image']['reference']}@{plan['ci_image']['digest']}")
    request = plan["request"]
    if request["resolved"]:
        lines.append(f"  request  {', '.join(request['resolved'])} (from {request['source']})")
    else:
        lines.append("  request  none")
    if plan["base_package_metadata"] == "absent":
        lines.append("  note     the base revision carries no package metadata; head inputs alone were derived")
    if plan["base_catalog"] == "absent":
        lines.append("  note     the base revision carries no catalog; head declarations alone were read")

    lines.append("")
    if plan["changed_paths"]:
        lines.append(f"Changed paths ({len(plan['changed_paths'])})")
        width = max(len(change["path"]) for change in plan["changed_paths"])
        for change in plan["changed_paths"]:
            lines.append(
                f"  {change['status']:<9} {change['path']:<{width}}  {change['classification']}"
            )
    else:
        lines.append("Changed paths (0)")
    if plan["unknown_inputs"]:
        lines.append("")
        lines.append("Unknown inputs select every non-optional group:")
        for path in plan["unknown_inputs"]:
            lines.append(f"  {path}")

    lines.append("")
    lines.append("Groups")
    width = max(len(entry["id"]) for entry in plan["groups"])
    # Widened from the reasons actually present rather than pinned to the
    # longest one the policy can produce, so adding a reason cannot silently
    # ragged the column.
    reason_width = max(len(entry["reason"]) for entry in plan["groups"])
    owners = {
        identifier: worker["name"]
        for worker in plan["workers"] or []
        for identifier in worker["groups"]
    }
    owner_width = max((len(name) for name in owners.values()), default=1)
    for entry in plan["groups"]:
        mark = "run " if entry["selected"] else "skip"
        lines.append(
            f"  [{mark}] {entry['id']:<{width}}  {entry['reason']:<{reason_width}} "
            f"inputs changed: {'yes' if entry['inputs_changed'] else 'no':<3}  "
            f"runner: {entry['runner']:<7}  worker: {owners.get(entry['id'], '-'):<{owner_width}}  "
            f"{' '.join(entry['command'])}"
        )
        if entry["preparation"] is not None:
            # The line below the group says what is built before it, and that
            # its own budget measures the command alone.
            lines.append(
                f"         prepared first, under {entry['preparation']['timeout_seconds']}s: "
                f"{' '.join(entry['preparation']['command'])}; "
                f"the command alone is watched for {entry['timeout_seconds']}s"
            )

    lines.append("")
    if plan["workers"] is None:
        lines.append("Workers: none declared; this plan is for inspection only and cannot be executed.")
    else:
        lines.append("Workers")
        for worker in plan["workers"]:
            lines.append(
                f"  {worker['name']} ({'+'.join(worker['runner_classes'])}): {', '.join(worker['groups'])}"
            )

    omitted = [entry for entry in plan["groups"] if not entry["selected"]]
    lines.append("")
    lines.append(
        f"Selected {len(plan['selected'])} of {len(plan['groups'])} groups; "
        f"{len(omitted)} explained omission{'' if len(omitted) == 1 else 's'}."
    )
    return "\n".join(lines)
