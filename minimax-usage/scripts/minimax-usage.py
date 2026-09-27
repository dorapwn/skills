#!/usr/bin/env python3
"""
Fetch MiniMax API usage and report with precise time calculations.
"""

import argparse
import functools
import json
import os
import sys
import urllib.request
import urllib.error
import zoneinfo
import yaml
from datetime import datetime, timezone
from time_calc import get_current_interval, get_next_reset_time, get_time_until_reset

STATUS_SUCCESS = 0


class ApiKeyNotFoundError(Exception):
    pass


class NetworkError(Exception):
    pass


class HTTPError(Exception):
    pass


class InvalidResponseError(Exception):
    pass


class NoRedirectsHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "HTTP redirect not followed", headers, None)


def get_local_timezone():
    return datetime.now().astimezone().tzinfo


@functools.lru_cache(maxsize=1)
def get_timezone(tz_name=None, config_path=None, debug=False):
    if tz_name is None:
        if config_path:
            if debug:
                print(f"[DEBUG] Loading timezone from config: {config_path}")
            config = load_config(config_path)
            tz_name = config.get("timezone")
            if debug:
                print(f"[DEBUG]   Found timezone in config: {tz_name}")
        else:
            tz_name = os.environ.get("MINIMAX_TIMEZONE")
            if debug:
                print(f"[DEBUG] Checking MINIMAX_TIMEZONE env var: {tz_name}")
    
    if tz_name is None:
        local_tz = get_local_timezone()
        if debug:
            print(f"[DEBUG] No timezone found, using local: {local_tz}")
        return local_tz
    
    try:
        return zoneinfo.ZoneInfo(tz_name)
    except KeyError:
        print(f"⚠️  Invalid timezone '{tz_name}', falling back to local timezone")
        return get_local_timezone()


def load_config(config_path=None):
    if config_path:
        if os.path.exists(config_path):
            try:
                with open(config_path, "r") as f:
                    return yaml.safe_load(f) or {}
            except yaml.YAMLError:
                return {}
        return {}

    script_dir = os.path.dirname(os.path.realpath(__file__))
    project_root = os.path.dirname(script_dir)
    user_config = os.path.expanduser("~/.minimax_config.yml")
    cwd_config = "config.yml"

    for path in [cwd_config, user_config]:
        if os.path.exists(path):
            try:
                with open(path, "r") as f:
                    return yaml.safe_load(f) or {}
            except yaml.YAMLError:
                return {}

    in_project = project_root in os.getcwd()
    is_executed = not hasattr(sys, 'frozen') and sys.argv[0] and os.path.basename(sys.argv[0]) in ('minimax-usage.py', 'minimax-usage')

    if in_project or is_executed:
        script_config = os.path.join(project_root, "config.yml")
        if os.path.exists(script_config):
            try:
                with open(script_config, "r") as f:
                    return yaml.safe_load(f) or {}
            except yaml.YAMLError:
                return {}
    return {}

def now_utc8(config_path=None, debug=False):
    return datetime.now(timezone.utc).astimezone(get_timezone(config_path=config_path, debug=debug))


def load_api_key(config_path=None, debug=False):
    if config_path:
        if debug:
            print(f"[DEBUG] Loading api_key from config: {config_path}")
        if not os.path.exists(config_path):
            return None
        with open(config_path, "r") as f:
            config = yaml.safe_load(f) or {}
        if "api_key" in config and config["api_key"]:
            if debug:
                print(f"[DEBUG]   Found api_key in config")
            return config["api_key"]
        return None

    api_key = os.environ.get("MINIMAX_API_KEY", "")
    if api_key:
        if debug:
            print(f"[DEBUG] Found api_key in MINIMAX_API_KEY env var")
        return api_key
    if debug:
        print(f"[DEBUG] No api_key in MINIMAX_API_KEY env var")

    config = load_config(config_path)
    if "api_key" in config and config["api_key"]:
        if debug:
            print(f"[DEBUG] Found api_key in default config file")
        return config["api_key"]

    return None


def fetch_usage(config_path=None, debug=False):
    api_key = load_api_key(config_path, debug=debug)
    if not api_key:
        raise ApiKeyNotFoundError(
            "No API key found. Set MINIMAX_API_KEY env var, or create config.yml with api_key"
        )

    req = urllib.request.Request(
        "https://www.minimaxi.com/v1/token_plan/remains",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        },
        method="GET"
    )
    no_redirect_opener = urllib.request.build_opener(NoRedirectsHandler)
    try:
        with no_redirect_opener.open(req, timeout=30) as response:
            result = response.read().decode("utf-8")
            if debug:
                try:
                    beautified = json.dumps(json.loads(result), indent=4)
                    print(f"[DEBUG] Raw API Response:\n{beautified}")
                except Exception:
                    print(f"[DEBUG] Raw API Response (unparsed):\n{result}")
    except urllib.error.HTTPError as e:
        raise HTTPError(f"HTTP error {e.code}. API key may be invalid.")
    except urllib.error.URLError as e:
        raise NetworkError(f"Network error: {e.reason}. Please check your internet connection.")

    if not result.strip():
        raise InvalidResponseError("Failed to fetch usage data. API key may be invalid.")

    try:
        return json.loads(result)
    except json.JSONDecodeError:
        raise InvalidResponseError("Invalid response from API. API key may be invalid.")

def format_time_remaining(hours, minutes, seconds):
    if hours > 0:
        return f"{hours}h {minutes}m"
    elif minutes > 0:
        return f"{minutes}m {seconds}s"
    else:
        return f"{seconds}s"

def time_bar(elapsed_hours, total_hours, block="█", width=20, label="", emoji="⏱️", remaining_pct=None):
    """Draw bar for time elapsed. e.g. ███████░░░░░░░░░░░░░ Time: 36% (3h 10m) ⏱️"""
    if total_hours <= 0:
        return block * width + " (N/A)" + (f" {label}" if label else "")
    if remaining_pct is not None:
        filled = min(round((remaining_pct / 100) * width), width)
        empty = width - filled
        pct = remaining_pct
        remaining_mins = int((total_hours * (100 - pct) / 100) * 60)
        if remaining_mins >= 60:
            remaining = f"{remaining_mins // 60}h {remaining_mins % 60}m"
        else:
            remaining = f"{remaining_mins}m"
        label_str = f"{label} " if label else ""
        emoji_str = f" {emoji}" if emoji else ""
        return block * filled + "░" * empty + f" {label_str}{pct}% ({remaining}){emoji_str}"
    filled = round((elapsed_hours / total_hours) * width)
    empty = width - filled
    pct = int((elapsed_hours / total_hours) * 100)
    remaining_mins = int((total_hours - elapsed_hours) * 60)
    if remaining_mins >= 60:
        remaining = f"{remaining_mins // 60}h {remaining_mins % 60}m"
    else:
        remaining = f"{remaining_mins}m"
    label_str = f"{label} " if label else ""
    emoji_str = f" {emoji}" if emoji else ""
    return block * filled + "░" * empty + f" {label_str}{pct}% ({remaining}){emoji_str}"

def ascii_bar(used, total, block="█", width=20, label=""):
    """Draw a horizontal ASCII bar chart. Each block = 5% (20 blocks for 100%)."""
    if total == 0:
        return block * width + " " + "(N/A)" + (f" {label}" if label else "")
    used = max(0, used)
    total = max(0, total)
    pct = min((used / total) * 100, 100) if total > 0 else 0
    filled = min(round((used / total) * width), width) if total > 0 else 0
    empty = width - filled
    bar = block * filled + "░" * empty
    label_str = f"{label} " if label else ""
    return f"{bar} {label_str}{pct:.0f}% ({used}/{total})"

def main(config_path=None, debug=False):
    try:
        if debug:
            print("[DEBUG] Loading timezone...")
        now = now_utc8(config_path, debug=debug)
        if debug:
            print("[DEBUG] Fetching usage data...")
        data = fetch_usage(config_path, debug=debug)
    except ApiKeyNotFoundError as e:
        print(f"❌ {e}")
        sys.exit(1)
    except (NetworkError, HTTPError, InvalidResponseError) as e:
        print(f"❌ {e}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        sys.exit(1)

    try:
        print(f"📊 MiniMax Usage Report — {now.strftime('%Y-%m-%d %H:%M UTC+8')}\n")

        for model in data["model_remains"]:
            model_name = model["model_name"]
            if model_name not in ("MiniMax-M*", "general"):
                continue

            total = model.get("current_interval_total_count", 0)
            used = model.get("current_interval_usage_count", 0)
            remaining = total - used

            remains_time = model.get("remains_time", 0)
            remaining_pct = model.get("current_interval_remaining_percent", 0)
            weekly_remaining_pct = model.get("current_weekly_remaining_percent", 0)

            weekly_total = model.get("current_weekly_total_count", 0)
            weekly_used = model.get("current_weekly_usage_count", 0)

            interval_start, interval_end = get_current_interval(now)
            next_reset = get_next_reset_time(now)
            hours, minutes, seconds = get_time_until_reset(now)

            if interval_end.day != interval_start.day:
                total_interval_hours = 24 - interval_start.hour + interval_end.hour
            else:
                total_interval_hours = interval_end.hour - interval_start.hour

            hours_elapsed = total_interval_hours - (hours + minutes / 60 + seconds / 3600)

            display_name = "MiniMax-M*" if model_name == "MiniMax-M*" else model_name
            print(f"**{display_name}**")

            if total > 0:
                usage_pct = (used / total) * 100 if total > 0 else 0
                remaining_pct = (remaining / total) * 100 if total > 0 else 0
                print(f"  {ascii_bar(used, total, label='Usage:')}")
                print(f"  {time_bar(hours_elapsed, total_interval_hours, label='Time:')}")
            else:
                used_pct = max(0, 100 - remaining_pct)
                usage_filled = min(round((used_pct / 100) * 20), 20)
                usage_empty = 20 - usage_filled
                print(f"  {'█' * usage_filled}{'░' * usage_empty} Usage: {used_pct}%")
                elapsed_pct = max(0, 100 - remaining_pct)
                elapsed_filled = min(round((elapsed_pct / 100) * 20), 20)
                elapsed_empty = 20 - elapsed_filled
                total_secs = hours * 3600 + minutes * 60 + seconds
                if total_secs >= 86400:
                    d = total_secs // 86400
                    h = (total_secs % 86400) // 3600
                    m = (total_secs % 3600) // 60
                    remaining_str = f"{d}d {h}h {m}m"
                elif total_secs >= 3600:
                    remaining_str = f"{hours}h {minutes}m"
                else:
                    remaining_str = f"{minutes}m {seconds}s"
                print(f"  {'█' * elapsed_filled}{'░' * elapsed_empty} Time: {elapsed_pct}% ({remaining_str}) ⏱️")
            print(f"  Next reset: {next_reset.strftime('%H:%M UTC+8')}")

            if weekly_total > 0:
                weekly_start = datetime.fromtimestamp(model["weekly_start_time"] / 1000, tz=timezone.utc).astimezone(get_timezone(config_path=config_path))
                weekly_end = datetime.fromtimestamp(model["weekly_end_time"] / 1000, tz=timezone.utc).astimezone(get_timezone(config_path=config_path))
                weekly_hours = (weekly_end - now).total_seconds() / 3600
                weekly_total_hours = (weekly_end - weekly_start).total_seconds() / 3600
                weekly_elapsed = weekly_total_hours - weekly_hours
                print()
                print(f"  {ascii_bar(weekly_used, weekly_total, label='Usage:')}")
                print(f"  {time_bar(weekly_elapsed, weekly_total_hours, label='Time:')}")
                print(f"  Week quota Next reset: {weekly_end.strftime('%d %H:%M UTC+8')}")
            elif weekly_remaining_pct > 0:
                print()
                weekly_used_pct = max(0, 100 - weekly_remaining_pct)
                weekly_usage_filled = min(round((weekly_used_pct / 100) * 20), 20)
                weekly_usage_empty = 20 - weekly_usage_filled
                print(f"  {'█' * weekly_usage_filled}{'░' * weekly_usage_empty} Usage: {weekly_used_pct}%")
                weekly_elapsed_pct = max(0, 100 - weekly_remaining_pct)
                weekly_elapsed_filled = min(round((weekly_elapsed_pct / 100) * 20), 20)
                weekly_elapsed_empty = 20 - weekly_elapsed_filled
                weekly_end = datetime.fromtimestamp(model["weekly_end_time"] / 1000, tz=timezone.utc).astimezone(get_timezone(config_path=config_path))
                weekly_secs = (weekly_end - now).total_seconds()
                if weekly_secs >= 86400:
                    d = int(weekly_secs // 86400)
                    h = int((weekly_secs % 86400) // 3600)
                    m = int((weekly_secs % 3600) // 60)
                    weekly_remaining_str = f"{d}d {h}h {m}m"
                elif weekly_secs >= 3600:
                    weekly_remaining_str = f"{int(weekly_secs // 3600)}h {int((weekly_secs % 3600) // 60)}m"
                else:
                    weekly_remaining_str = f"{int(weekly_secs // 60)}m"
                print(f"  {'█' * weekly_elapsed_filled}{'░' * weekly_elapsed_empty} Time: {weekly_elapsed_pct}% ({weekly_remaining_str}) ⏱️")
                print(f"  Week quota Next reset: {weekly_end.strftime('%d %H:%M UTC+8')}")

            if remaining_pct < 10 and total > 0:
                print(f"  ⚠️  Warning: Usage nearly exhausted ({remaining_pct:.0f}%)")
            print()
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fetch MiniMax API usage and report")
    parser.add_argument("-c", "--config", dest="config_path", help="Path to config file")
    parser.add_argument("-d", "--debug", action="store_true", help="Enable debug logging")
    args = parser.parse_args()
    main(args.config_path, debug=args.debug)
