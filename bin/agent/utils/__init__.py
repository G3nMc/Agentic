import sys as _sys
_sys.dont_write_bytecode = True

# Context-free infrastructure modules. Nothing in this package should
# import from agent.tools, agent.backends, or agent.loop — keep the
# dependency arrow strictly one-way.
