# Testing Guide

## Running Tests

Run all tests:

```sh
busybox ash scripts/test.sh
```

Run a single test:

```sh
busybox ash scripts/test.sh tests/unit/scaffold/test_directory_tree.sh
```

## Test Organization

| Directory | Purpose |
|-----------|---------|
| `tests/unit/<module>/` | Unit tests for a specific module |
| `tests/integration/` | Cross-module integration tests |
| `tests/fixtures/` | Shared test data files |
| `tests/manual/` | Manual validation checklists (device-dependent) |

## Writing Tests

### File Naming

- Test files: `test_<description>.sh`
- Place in `tests/unit/<module>/` matching the source module
- Name should describe the behavior, not the implementation

### Template

```sh
#!/bin/sh
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# Test: <describe what this validates>

# ... test logic ...

# Exit 0 = pass, non-zero = fail
```

### Rules

- **Shell target:** BusyBox ash. Use `#!/bin/sh` and avoid bashisms.
- **Self-contained:** Create temp directories for scratch work, clean up after.
- **No side effects:** Tests must not modify repo files or leave state behind.
- **One concern per test file:** Each test file validates one behavior or contract.
- **Exit code is the result:** Exit 0 for pass, non-zero for fail.
- **Errors to stderr:** Use `>&2` for diagnostic output so the runner can suppress stdout.

### BusyBox Compatibility

Avoid these constructs (they fail in BusyBox ash):

- `[[ ... ]]` — use `[ ... ]`
- `local var=$(cmd)` — split into `local var; var=$(cmd)`
- `${var//pat/rep}` — use `sed`
- Arrays, here-strings, process substitution
- `echo -e` — use `printf`

See CLAUDE.md "BusyBox Ash Compatibility" for the full table.

### Syntax Check

Before committing, verify your test passes the BusyBox syntax checker:

```sh
busybox ash -n tests/unit/module/test_something.sh
```

## How the Test Runner Works

`scripts/test.sh` discovers tests by finding files named `test_*.sh` under `tests/unit/` and `tests/integration/`. Each file is executed with `busybox ash`. A test passes if it exits 0, fails otherwise.

Output format:

```text
[PASS] tests/unit/scaffold/test_directory_tree.sh
[FAIL] tests/unit/other/test_broken.sh

Results: 1 passed, 1 failed, 2 total
```

The runner exits 0 if all tests pass, 1 if any fail.
