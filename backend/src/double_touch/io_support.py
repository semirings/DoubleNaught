"""Shared URL handling for nodes with a URL-labeled field (Load File, Save
File, and any future one) — see ``UX_UI/GLOBAL_UX_CONTRACT.md`` §6.

A plain namespace of static helpers, not a base class nodes inherit from:
neither ``LoadFileNode`` nor ``SaveFileNode`` exist as Python classes here
(unlike e.g. ``AstExtractNode``), so there is no class hierarchy for
``IOSupport`` to sit inside on this side. The name is what the spec calls
this concern regardless of shape — see the Flutter side
(``frontend/lib/widgets/nodes/base/io_support.dart``) for the class
form, where ``LoadFileNode``'s widget state already exists to mix it into.
"""

from __future__ import annotations

import urllib.parse


class IOSupport:
    """The scheme allow-list rule every URL-labeled field follows."""

    ALLOWED_SCHEMES = frozenset({"file", "http", "https"})

    @staticmethod
    def parse_url(url: str) -> urllib.parse.ParseResult:
        """Parse *url* and validate its scheme against ``ALLOWED_SCHEMES``.

        A schemeless string is treated as a local path — matching
        ``load_file()``'s long-standing behavior and every direct caller
        (including its own test suite) that passes a bare OS path rather
        than a ``file://`` URL. Requiring an explicit scheme is the
        *frontend*'s stricter rule (``GLOBAL_UX_CONTRACT.md`` §6), enforced
        before a request is ever sent to gate Execute; this is the backend's
        more tolerant final-authority check, same as it already was.
        """
        parsed = urllib.parse.urlparse(url)
        scheme = parsed.scheme or "file"
        if scheme not in IOSupport.ALLOWED_SCHEMES:
            raise ValueError(f"Unsupported URL scheme: {parsed.scheme!r}")
        return parsed

    @staticmethod
    def local_path(url: str) -> str:
        """The filesystem path *url* resolves to.

        Raises ``ValueError`` if *url*'s scheme is not ``file`` (or absent).
        """
        parsed = IOSupport.parse_url(url)
        if parsed.scheme not in ("file", ""):
            raise ValueError(
                f"local_path() requires a local path, got scheme {parsed.scheme!r}"
            )
        return urllib.parse.unquote(parsed.path or url)
