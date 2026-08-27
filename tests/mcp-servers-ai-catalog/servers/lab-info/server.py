"""RHCL lab-info MCP server — metadata about the PoC lab."""

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "rhcl-lab-info",
    instructions="Read-only tools that describe the RHCL PoC lab topology and requirements.",
    host="0.0.0.0",
    port=8080,
)


@mcp.tool()
def get_lab_name() -> str:
    """Return the official RHCL PoC lab name."""
    return "RHCL Proof of Concept Lab"


@mcp.tool()
def list_target_zones() -> list[str]:
    """List the multicloud zones referenced by the PoC planning material."""
    return ["CCT1", "CCT2", "Azure", "Google Cloud"]


@mcp.tool()
def ping(message: str = "hello") -> dict:
    """Echo a message and identify this MCP server."""
    return {"server": "rhcl-lab-info", "echo": message}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
