"""Importing this module removes ambient SHEPHERD_* and PI_* variables from the test process.

A Shepherd agent thread exports variables such as SHEPHERD_BUILD_WRAPPER that scripts/ read, so
exact-command assertions would otherwise depend on who runs the suite. Tests about one of these
variables set it themselves (patch.dict). Import this first in every test_*.py.
"""
import os

# Variables a runner sets on purpose. release-build.yml sets SHEPHERD_ENGINE_SMOKE for test_pi_engine_sdk.py.
RUNNER_ALLOWED = {"SHEPHERD_ENGINE_SMOKE"}

for _name in [n for n in os.environ if n.startswith(("SHEPHERD_", "PI_")) and n not in RUNNER_ALLOWED]:
    del os.environ[_name]
