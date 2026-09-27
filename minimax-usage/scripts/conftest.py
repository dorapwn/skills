"""conftest.py — pytest configuration for the minimax-usage skill tests.

Adds the scripts/ directory to sys.path so test files can do
``from time_calc import ...`` and ``from run import ...`` without each
test module having to insert the path manually.

This makes `python -m pytest` work from the parent minimax-usage/
directory (the CI working dir), not just from inside scripts/.

Without this file, the existing scripts/test_time_calc.py fails at
collection time with ``ModuleNotFoundError: No module named 'time_calc'``
because its top-level import can't find time_calc.py when the working
directory is minimax-usage/ rather than minimax-usage/scripts/.
"""
import os
import sys

# Make the scripts/ directory importable as a package root.
sys.path.insert(0, os.path.dirname(__file__))