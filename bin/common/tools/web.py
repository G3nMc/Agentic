"""Web / internet tools — fetch URLs and search the web."""

from __future__ import annotations

import json
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request

# Content-types we are willing to decode as text.
_TEXT_TYPES = (
    "text/",
    "application/json",
    "application/xml",
    "application/xhtml",
    "application/javascript",
)


def _is_text_content_type(content_type: str) -> bool:
    ct = content_type.lower().split(";")[0].strip()
    return any(ct.startswith(t) for t in _TEXT_TYPES)


def _strip_html(html: str) -> str:
    """Very lightweight HTML-to-text: remove tags, collapse whitespace."""
    # Remove <script> and <style> blocks entirely.
    text = re.sub(
        r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.DOTALL | re.IGNORECASE
    )
    # Remove all remaining tags.
    text = re.sub(r"<[^>]+>", " ", text)
    # Decode common HTML entities.
    text = (
        text.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
    )
    # Collapse whitespace.
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _decode_ddg_url(href: str) -> str:
    """Unwrap DuckDuckGo redirect URLs (/l/?uddg=...) to the real target URL."""
    if not href:
        return href
    # Normalize: add scheme if protocol-relative.
    if href.startswith("//"):
        href = "https:" + href
    parsed = urllib.parse.urlparse(href)
    if "duckduckgo.com" in parsed.netloc and parsed.path.startswith("/l/"):
        qs = urllib.parse.parse_qs(parsed.query)
        uddg = qs.get("uddg", [None])[0]
        if uddg:
            return urllib.parse.unquote(uddg)
    return href


def register(registry) -> None:
    # ------------------------------------------------------------------
    # web_fetch
    # ------------------------------------------------------------------
    def web_fetch(url: str, timeout: int = 15) -> str:
        """Fetch a URL and return its text content (up to 100 KB)."""
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "web_fetch is disabled in sandbox mode.",
                    }
                )

            parsed = urllib.parse.urlparse(url)
            if parsed.scheme not in ("http", "https"):
                return json.dumps(
                    {
                        "status": "error",
                        "message": (
                            f"Unsupported URL scheme: '{parsed.scheme}'. "
                            "Only http/https allowed."
                        ),
                    }
                )

            ctx = ssl.create_default_context()
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": "AgenticDev/1.0 (AI coding agent; tool-call)",
                    "Accept": "text/plain, text/html, application/json",
                },
            )

            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                content_type = resp.headers.get("Content-Type", "")

                if not _is_text_content_type(content_type):
                    return json.dumps(
                        {
                            "status": "error",
                            "message": (
                                f"Unsupported content type '{content_type}'. "
                                "Only text-based responses are supported."
                            ),
                            "url": url,
                        }
                    )

                raw = resp.read(102_400)  # 100 KB cap
                truncated = len(raw) == 102_400 and bool(resp.read(1))
                text = raw.decode("utf-8", errors="replace")

                # Strip HTML markup so the model receives readable prose.
                ct_lower = content_type.lower()
                if "html" in ct_lower or "xhtml" in ct_lower:
                    text = _strip_html(text)

                return json.dumps(
                    {
                        "status": "success",
                        "url": url,
                        "content_type": content_type,
                        "size_bytes": len(raw),
                        "truncated": truncated,
                        "text": text,
                    }
                )

        except urllib.error.HTTPError as e:
            return json.dumps(
                {
                    "status": "error",
                    "message": f"HTTP {e.code}: {e.reason}",
                    "url": url,
                }
            )
        except urllib.error.URLError as e:
            return json.dumps(
                {
                    "status": "error",
                    "message": f"URL error: {e.reason}",
                    "url": url,
                }
            )
        except Exception as e:
            return json.dumps(
                {
                    "status": "error",
                    "message": str(e),
                    "url": url,
                }
            )

    registry.tools["web_fetch"] = web_fetch
    registry.definitions.append(
        {
            "type": "function",
            "function": {
                "name": "web_fetch",
                "description": (
                    "Fetch a URL and return its text content (up to 100 KB). "
                    "Use for reading documentation pages, API references, or any "
                    "publicly accessible web resource. Only http/https URLs are allowed."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "url": {
                            "type": "string",
                            "description": "Full URL to fetch (must start with http:// or https://)",
                        },
                        "timeout": {
                            "type": "integer",
                            "description": "Request timeout in seconds (default 15)",
                        },
                    },
                    "required": ["url"],
                },
            },
        }
    )

    # ------------------------------------------------------------------
    # web_search
    # ------------------------------------------------------------------
    def web_search(query: str, max_results: int = 10, timeout: int = 15) -> str:
        """Search the web using DuckDuckGo's HTML interface and return results."""
        try:
            if registry.security_config.sandbox_mode:
                return json.dumps(
                    {
                        "status": "error",
                        "message": "web_search is disabled in sandbox mode.",
                    }
                )

            if not query or not query.strip():
                return json.dumps(
                    {
                        "status": "error",
                        "message": "Query must not be empty.",
                    }
                )

            encoded = urllib.parse.quote_plus(query)
            search_url = f"https://html.duckduckgo.com/html/?q={encoded}"

            ctx = ssl.create_default_context()
            req = urllib.request.Request(
                search_url,
                headers={
                    "User-Agent": "AgenticDev/1.0 (AI coding agent; tool-call)",
                    "Accept": "text/html",
                },
            )

            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                raw = resp.read(102_400)
                html = raw.decode("utf-8", errors="replace")

            results = _parse_ddg_html(html, max_results)

            return json.dumps(
                {
                    "status": "success",
                    "query": query,
                    "results": results,
                    "count": len(results),
                }
            )

        except urllib.error.HTTPError as e:
            return json.dumps(
                {
                    "status": "error",
                    "message": f"HTTP {e.code}: {e.reason}",
                    "query": query,
                }
            )
        except urllib.error.URLError as e:
            return json.dumps(
                {
                    "status": "error",
                    "message": f"URL error: {e.reason}",
                    "query": query,
                }
            )
        except Exception as e:
            return json.dumps(
                {
                    "status": "error",
                    "message": str(e),
                    "query": query,
                }
            )

    registry.tools["web_search"] = web_search
    registry.definitions.append(
        {
            "type": "function",
            "function": {
                "name": "web_search",
                "description": (
                    "Search the web using DuckDuckGo and return a list of results "
                    "(title, snippet, URL). No API key required. Use when you need "
                    "to look up current information, documentation, or answers "
                    "that are not in the local codebase."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query string",
                        },
                        "max_results": {
                            "type": "integer",
                            "description": "Maximum number of results to return (default 10, max 20)",
                        },
                        "timeout": {
                            "type": "integer",
                            "description": "Request timeout in seconds (default 15)",
                        },
                    },
                    "required": ["query"],
                },
            },
        }
    )


def _parse_ddg_html(html: str, max_results: int) -> list[dict]:
    """Extract search results from DuckDuckGo HTML page."""
    results: list[dict] = []
    max_results = min(max(max_results, 1), 20)

    link_pattern = re.compile(
        r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
        re.DOTALL | re.IGNORECASE,
    )
    snippet_pattern = re.compile(
        r'<a[^>]*class="result__snippet"[^>]*>(.*?)</a>',
        re.DOTALL | re.IGNORECASE,
    )

    links = link_pattern.findall(html)
    snippets = snippet_pattern.findall(html)

    for i, (href, title) in enumerate(links):
        if i >= max_results:
            break
        title_clean = re.sub(r"<[^>]+>", "", title).strip()
        if not title_clean:
            continue
        # Unwrap DDG redirect to get the real target URL.
        real_url = _decode_ddg_url(href)
        snippet = ""
        if i < len(snippets):
            snippet = re.sub(r"<[^>]+>", "", snippets[i]).strip()
        results.append(
            {
                "title": title_clean,
                "url": real_url,
                "snippet": snippet,
            }
        )

    return results
