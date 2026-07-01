#!/usr/bin/env python3
"""
Private terminal web search for GitHub Codespaces.

What it does:
- Searches the web using DuckDuckGo.
- Prints results only to the terminal.
- Does not write logs.
- Does not save results.
- Does not save search history.
- Deletes temporary cache folders on exit.

Important:
- This script does not save anything locally.
- GitHub Codespaces, DuckDuckGo, and visited websites may still have normal server-side/network logs.
"""

import os
import sys
import shutil
import tempfile
import atexit
from typing import List, Dict

from duckduckgo_search import DDGS


# -----------------------------
# Privacy / no-save setup
# -----------------------------

TEMP_ROOT = tempfile.mkdtemp(prefix="private_web_search_")

os.environ["PYTHONHISTFILE"] = "/dev/null"
os.environ["HISTFILE"] = "/dev/null"
os.environ["XDG_CACHE_HOME"] = TEMP_ROOT
os.environ["PIP_CACHE_DIR"] = os.path.join(TEMP_ROOT, "pip-cache")
os.environ["NO_COLOR"] = "1"


def cleanup() -> None:
    """Delete all temporary files created by this process."""
    try:
        shutil.rmtree(TEMP_ROOT, ignore_errors=True)
    except Exception:
        pass


atexit.register(cleanup)


# -----------------------------
# Search logic
# -----------------------------

def search_web(
    query: str,
    max_results: int = 8,
    region: str = "wt-wt",
    safesearch: str = "moderate",
) -> List[Dict[str, str]]:
    """
    Search DuckDuckGo and return result dictionaries.

    region examples:
    - wt-wt = worldwide / no region
    - de-de = Germany
    - es-es = Spain

    safesearch:
    - on
    - moderate
    - off
    """

    with DDGS(timeout=15) as ddgs:
        results = ddgs.text(
            keywords=query,
            region=region,
            safesearch=safesearch,
            backend="html",
            max_results=max_results,
        )

    return list(results or [])


def print_results(results: List[Dict[str, str]]) -> None:
    if not results:
        print("\nNo results found.\n")
        return

    print("\nResults:\n")

    for index, item in enumerate(results, start=1):
        title = item.get("title", "No title")
        url = item.get("href") or item.get("url") or "No URL"
        body = item.get("body", "").strip()

        print(f"{index}. {title}")
        print(f"   {url}")

        if body:
            print(f"   {body}")

        print()


def main() -> None:
    print("Private Web Search")
    print("Nothing is saved locally. Type 'exit' to close.\n")

    while True:
        try:
            query = input("Search > ").strip()
        except KeyboardInterrupt:
            print("\nClosed.")
            break
        except EOFError:
            print("\nClosed.")
            break

        if not query:
            continue

        if query.lower() in {"exit", "quit", "q"}:
            print("Closed.")
            break

        try:
            results = search_web(query)
            print_results(results)
        except Exception as error:
            print(f"\nSearch failed: {error}\n")


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
