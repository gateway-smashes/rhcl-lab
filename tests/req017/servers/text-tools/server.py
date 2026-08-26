"""RHCL text-tools MCP server — small string helpers for demos."""

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "rhcl-text-tools",
    instructions="Lightweight text utilities for Gen AI playground tool-calling demos.",
    host="0.0.0.0",
    port=8080,
)


@mcp.tool()
def uppercase(text: str) -> str:
    """Convert the input text to upper case."""
    return text.upper()


@mcp.tool()
def word_count(text: str) -> dict:
    """Count words and characters in the input text."""
    words = [part for part in text.split() if part]
    return {"words": len(words), "characters": len(text)}


@mcp.tool()
def reverse_text(text: str) -> str:
    """Return the input text reversed character by character."""
    return text[::-1]


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
