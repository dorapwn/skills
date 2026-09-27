#!/usr/bin/env python3
"""
Unit tests for weekly limit feature in fetch_usage.py
"""

import unittest
from unittest.mock import patch, MagicMock
from datetime import datetime, timezone
from io import StringIO

import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from run import main, ascii_bar, time_bar


class TestWeeklyLimit(unittest.TestCase):

    def _run_main_with_data(self, mock_data):
        captured = StringIO()
        with patch('run.fetch_usage', return_value=mock_data):
            with patch('run.now_utc8') as mock_now:
                mock_now.return_value = datetime(2026, 5, 2, 0, 0, tzinfo=timezone.utc).astimezone(
                    timezone.utc
                )
                with patch('sys.stdout', captured):
                    main()
        return captured.getvalue()

    def test_weekly_limit_present(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "MiniMax-M*",
                "current_interval_total_count": 600,
                "current_interval_usage_count": 300,
                "current_weekly_total_count": 6000,
                "current_weekly_usage_count": 3000,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("Usage:", output)
        self.assertIn("Week quota Next reset:", output)

    def test_weekly_total_zero_skips_weekly_section(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "MiniMax-M*",
                "current_interval_total_count": 600,
                "current_interval_usage_count": 300,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertNotIn("Week quota", output)

    def test_weekly_fully_used(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "MiniMax-M*",
                "current_interval_total_count": 600,
                "current_interval_usage_count": 600,
                "current_weekly_total_count": 6000,
                "current_weekly_usage_count": 6000,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("100%", output)
        self.assertIn("6000/6000", output)

    def test_weekly_zero_usage(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "MiniMax-M*",
                "current_interval_total_count": 600,
                "current_interval_usage_count": 0,
                "current_weekly_total_count": 6000,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("0%", output)
        self.assertIn("0/6000", output)

    def test_non_minimax_star_model_skipped(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "Other-Model",
                "current_interval_total_count": 100,
                "current_interval_usage_count": 50,
                "current_weekly_total_count": 1000,
                "current_weekly_usage_count": 500,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertNotIn("Other-Model", output)

    def test_count_based_format_exact_output(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "MiniMax-M*",
                "current_interval_total_count": 600,
                "current_interval_usage_count": 200,
                "current_weekly_total_count": 6000,
                "current_weekly_usage_count": 5905,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("**MiniMax-M***", output)
        self.assertIn("Usage: 33% (200/600)", output)
        self.assertIn("Time:", output)
        self.assertIn("Next reset:", output)
        self.assertIn("Usage: 98% (5905/6000)", output)
        self.assertIn("Week quota Next reset:", output)

    def test_time_based_no_counts_format(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "general",
                "remains_time": 3600000,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": 50,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
                "current_weekly_remaining_percent": 75,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("**general**", output)
        self.assertIn("Time:", output)
        self.assertIn("Next reset:", output)
        self.assertIn("Week quota Next reset:", output)

    def test_time_based_shows_percentage_not_counts(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "general",
                "remains_time": 0,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": 50,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
                "current_weekly_remaining_percent": 75,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertNotIn("(200/600)", output)
        self.assertNotIn("(5905/6000)", output)
        self.assertIn("Usage: 50%", output)
        self.assertIn("Usage: 25%", output)

    def test_time_based_response_video_model_skipped(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "video",
                "remains_time": 7200000,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": 100,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
                "current_weekly_remaining_percent": 100,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertNotIn("video", output)

    def test_time_based_response_100_percent(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "general",
                "remains_time": 7200000,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": 100,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
                "current_weekly_remaining_percent": 100,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("Usage: 0%", output)

    def test_time_based_response_total_zero(self):
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "general",
                "remains_time": 0,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": 50,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
                "current_weekly_remaining_percent": 75,
            }]
        }
        output = self._run_main_with_data(mock_data)
        self.assertIn("Usage: 50%", output)
        self.assertIn("Usage: 25%", output)


class TestAsciiBar(unittest.TestCase):

    def test_zero_total(self):
        result = ascii_bar(0, 0)
        self.assertIn("N/A", result)

    def test_full_usage(self):
        result = ascii_bar(100, 100)
        self.assertIn("100%", result)
        self.assertIn("100/100", result)

    def test_half_usage(self):
        result = ascii_bar(50, 100)
        self.assertIn("50%", result)
        self.assertIn("50/100", result)

    def test_negative_used_clamped_to_zero(self):
        result = ascii_bar(-10, 100)
        self.assertNotIn("-", result)


class TestTimeBar(unittest.TestCase):

    def test_zero_total_hours(self):
        result = time_bar(5, 0)
        self.assertIn("N/A", result)

    def test_normal_time_bar(self):
        result = time_bar(3, 10)
        self.assertIn("%", result)


class TestGetTimezoneKwarg(unittest.TestCase):
    """Regression test: get_timezone(config_path=...) must accept the config path
    as a keyword argument, not positionally. Positionally, the first arg is
    `tz_name` and would be passed to zoneinfo.ZoneInfo() as the timezone
    identifier. This previously caused a cryptic error in the weekly-limit
    display branch:
        ZoneInfo keys may not be absolute paths, got: /path/to/config.yml
    """

    def setUp(self):
        # lru_cache on get_timezone means tests share results within a run;
        # clear it so each test starts fresh with its own config.
        from run import get_timezone
        get_timezone.cache_clear()

    def _write_config(self, tmp_dir, timezone_name):
        import yaml as _yaml
        path = os.path.join(tmp_dir, "config.yml")
        with open(path, "w") as f:
            _yaml.safe_dump({"api_key": "fake", "timezone": timezone_name}, f)
        return path

    def test_get_timezone_accepts_config_path_kwarg(self):
        """The fix: get_timezone(config_path=<abs path>) returns a ZoneInfo
        for the timezone named inside the config file. Before the fix, the
        config path was being passed positionally as `tz_name`, which made
        ZoneInfo treat it as a timezone identifier and raise KeyError."""
        import tempfile
        import zoneinfo
        with tempfile.TemporaryDirectory() as tmp:
            cfg = self._write_config(tmp, "Asia/Hong_Kong")
            from run import get_timezone
            tz = get_timezone(config_path=cfg)
            self.assertIsNotNone(tz)
            # Compare against a fresh ZoneInfo("Asia/Hong_Kong") to confirm
            # the function read the config correctly (not just returned None).
            self.assertEqual(
                tz.utcoffset(None),
                zoneinfo.ZoneInfo("Asia/Hong_Kong").utcoffset(None),
            )

    def test_get_timezone_positional_path_raises(self):
        """Document the bug: passing the config path positionally is wrong.
        This test pins the current (broken) behaviour so that a future
        refactor can't silently regress to it without someone noticing."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cfg = self._write_config(tmp, "Asia/Hong_Kong")
            from run import get_timezone
            get_timezone.cache_clear()
            with self.assertRaises((KeyError, ValueError)):
                # Positional arg = tz_name. ZoneInfo keys cannot be absolute
                # paths, so this raises (KeyError on stdlib <3.13, ValueError
                # on >=3.13 — accept either).
                get_timezone(cfg)

    def test_weekly_branch_does_not_crash_with_config(self):
        """End-to-end: when weekly_total > 0 AND a config file is supplied
        via -c, the script must not raise. Previously, the positional kwarg
        bug caused an exception that aborted the script mid-render."""
        mock_data = {
            "base_resp": {"status_code": 0},
            "model_remains": [{
                "model_name": "MiniMax-M*",
                "current_interval_total_count": 600,
                "current_interval_usage_count": 300,
                "current_weekly_total_count": 6000,
                "current_weekly_usage_count": 3000,
                "weekly_start_time": 1777219200000,
                "weekly_end_time": 1777824000000,
            }]
        }
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            cfg = self._write_config(tmp, "Asia/Hong_Kong")
            from run import main, get_timezone
            get_timezone.cache_clear()
            captured = StringIO()
            with patch('run.fetch_usage', return_value=mock_data):
                with patch('sys.stdout', captured):
                    main(cfg)  # pass config_path positionally — main() takes
                               # it as the first positional arg, so this is fine
            output = captured.getvalue()
            self.assertNotIn("Unexpected error", output)
            self.assertIn("Week quota Next reset:", output)


if __name__ == "__main__":
    unittest.main()