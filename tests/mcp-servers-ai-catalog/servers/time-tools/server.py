"""RHCL time-tools MCP server — UTC clock helpers."""

from datetime import datetime, timedelta, timezone

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "rhcl-time-tools",
    instructions="UTC time helpers for scheduling and timestamp demos.",
    host="0.0.0.0",
    port=8080,
)


@mcp.tool()
def now_utc() -> str:
    """Return the current UTC timestamp in ISO-8601 format."""
    return datetime.now(timezone.utc).isoformat()


@mcp.tool()
def format_timestamp(unix_seconds: int) -> str:
    """Format a Unix epoch (seconds) as an ISO-8601 UTC timestamp."""
    return datetime.fromtimestamp(unix_seconds, tz=timezone.utc).isoformat()


@mcp.tool()
def add_minutes(minutes: int) -> dict:
    """Return UTC now and the same instant shifted forward by the given minutes."""
    base = datetime.now(timezone.utc)
    shifted = base + timedelta(minutes=minutes)
    return {
        "now": base.isoformat(),
        "after_minutes": shifted.isoformat(),
        "minutes_added": minutes,
    }


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
