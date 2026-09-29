"""Configuration, read once from the environment.

Nothing here has a default that could reach a real system by accident: every
value is required and the process refuses to start without it. A sync that
silently pointed at the wrong Supabase project would be discovered by its
damage rather than by an error.
"""

import os
from dataclasses import dataclass
from pathlib import Path


class MissingConfig(RuntimeError):
    """A required environment variable is absent or empty."""


def load_env(path: Path | None = None) -> None:
    """Read sync/.env into the environment, if it exists.

    Hand-rolled rather than pulling in python-dotenv: this needs to handle
    KEY=value, blank lines and # comments, and nothing else. A real environment
    variable always wins, so a scheduler that injects secrets directly is not
    overridden by a stale file someone left on the box.
    """
    path = path or Path(__file__).resolve().parent.parent / ".env"
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def _require(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        raise MissingConfig(
            f"{name} is not set. Copy sync/.env.example to sync/.env and fill it in."
        )
    return value


@dataclass(frozen=True)
class Settings:
    engine_url: str
    engine_key: str
    supabase_url: str
    # The SERVICE ROLE key, not the anon key: this process writes, and row
    # level security denies the anon role every table it touches. It is also
    # why nothing in this package may ever be shipped to a browser.
    supabase_key: str
    timezone: str = "Asia/Baghdad"

    @classmethod
    def from_env(cls) -> "Settings":
        load_env()
        return cls(
            engine_url=_require("ENGINE_URL").rstrip("/"),
            engine_key=_require("ENGINE_API_KEY"),
            supabase_url=_require("SUPABASE_URL").rstrip("/"),
            supabase_key=_require("SUPABASE_SERVICE_KEY"),
            timezone=os.environ.get("TIMEZONE", "Asia/Baghdad"),
        )
