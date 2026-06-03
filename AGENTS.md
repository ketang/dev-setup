# Agent Instructions

Read README.md before taking any action in this repo. It documents what gets
installed, how the playbook is structured, and how to check and apply state.

## Checking Machine Drift

To check whether the current machine matches the declared playbook state, use
the dedicated script:

```bash
scripts/drift-check.sh
```

Do not use `ansible-playbook --check` or `ansible-playbook --diff` as a drift
check. Those commands have check-mode limitations (e.g. tasks that register
command output are skipped, producing false positives) and generate noisy diffs
that obscure real drift. `scripts/drift-check.sh` is authoritative.

## Applying Changes

To converge the machine after drift is confirmed or after playbook changes:

```bash
ansible-playbook playbook.yml -e "user=<username> git_name='...' git_email='...'"
```

## Pull Requests

- Do not create pull requests.
- Do not use the GitHub CLI (`gh` command).
- Work is complete once the branch is pushed to origin.
