# Local orchestrator package — split out of the original monolithic
# bin/orchestrator.py. The entry point at bin/orchestrator.py is now a
# thin shim that wires the pieces together; everything else lives here.
import sys as _sys

# Belt-and-braces: keep .pyc files from being written anywhere under this
# package. The entry point sets the same flag before importing us, but if
# something pulls `agent` in via a different path we still want clean dirs.
_sys.dont_write_bytecode = True
