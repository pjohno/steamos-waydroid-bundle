#!/usr/bin/env bash
set -euo pipefail

binder_dir="${1:?Binder source directory is required}"

python - "$binder_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace_once(path, old, new):
    p = root / path
    text = p.read_text()

    if old not in text:
        raise SystemExit(f"{path}: expected source pattern not found")

    p.write_text(text.replace(old, new, 1))


replace_once(
    "binder.c",
    '#include "binder_trace.h"\n',
    '#include "binder_trace.h"\n#include "deps.h"\n',
)

replace_once(
    "binder.c",
    '''\
\tconst struct binder_debugfs_entry *db_entry;

\tret = binder_alloc_shrinker_init();
''',
    '''\
\tconst struct binder_debugfs_entry *db_entry;

\tret = binder_deps_init();
\tif (ret)
\t\treturn ret;

\tret = binder_alloc_shrinker_init();
''',
)

p = root / "binder.c"
text = p.read_text()
marker = '#define CREATE_TRACE_POINTS\n#include "binder_trace.h"\n'
if marker not in text:
    raise SystemExit("binder.c: trace footer not found")
text = text.replace(
    marker,
    marker + '\nMODULE_LICENSE("GPL v2");\n'
             'MODULE_DESCRIPTION("Android Binder IPC Driver");\n',
    1,
)
p.write_text(text)

replace_once(
    "binder_alloc.c",
    "module_param_named(debug_mask, binder_alloc_debug_mask,\n",
    "module_param_named(alloc_debug_mask, binder_alloc_debug_mask,\n",
)

replace_once(
    "binderfs.c",
    '#include "binder_internal.h"\n',
    '#include "binder_internal.h"\n#include "deps.h"\n',
)

p = root / "binderfs.c"
text = p.read_text()
old = "(info->ipc_ns == &init_ipc_ns)"
count = text.count(old)
if count != 2:
    raise SystemExit(
        f"binderfs.c: expected 2 init_ipc_ns comparisons, found {count}"
    )
p.write_text(text.replace(old, "(info->ipc_ns == binder_get_init_ipc_ns())"))
PY
