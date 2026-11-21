#!/usr/bin/env python3
"""Add a release to the Sparkle appcast.

usage: appcast.py APPCAST VERSION ZIP_URL SIGNATURE_ATTRIBUTES NOTES_MD [MIN_MACOS]

SIGNATURE_ATTRIBUTES is the line printed by Sparkle's sign_update, e.g.
  sparkle:edSignature="..." length="1234"
NOTES_MD is a Markdown file: paragraphs and "- " list items are turned into the HTML Sparkle shows.
The new item goes first in the channel; an item with the same version is replaced.
"""
import html
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Squeeze7z</title>
    <link>https://github.com/Camponotus-vagus/Squeeze7z</link>
    <description>Updates of Squeeze7z.</description>
    <language>en</language>
  </channel>
</rss>
"""


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)


def notes_html(markdown: str) -> str:
    out, items, para = [], [], []

    def flush() -> None:
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith("- "):
            if para:
                flush()
            items.append(stripped[2:])
        elif items and line.startswith("  "):
            items[-1] += " " + stripped
        else:
            if items:
                flush()
            para.append(stripped)
    flush()
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) not in (6, 7):
        sys.exit(__doc__)
    appcast, version, url, signature, notes = sys.argv[1:6]
    min_macos = sys.argv[6] if len(sys.argv) == 7 else "26.0"
    if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', signature.strip()):
        sys.exit(f"unexpected signature attributes: {signature!r}")
    path = Path(appcast)
    xml = path.read_text() if path.exists() else EMPTY
    # Drop an earlier item for the same version.
    xml = re.sub(r"\s*<item>(?:(?!</item>).)*?<sparkle:version>" + re.escape(version)
                 + r"</sparkle:version>.*?</item>", "", xml, flags=re.S)
    item = f"""
    <item>
      <title>Squeeze7z {html.escape(version)}</title>
      <pubDate>{format_datetime(datetime.now(timezone.utc))}</pubDate>
      <sparkle:version>{html.escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(min_macos)}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{notes_html(Path(notes).read_text()).replace("]]>", "]]&gt;")}
      ]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {signature.strip()} />
    </item>"""
    marker = "<language>en</language>"
    if marker not in xml:
        sys.exit("appcast has no <language> element to insert after")
    path.write_text(xml.replace(marker, marker + item, 1))


if __name__ == "__main__":
    main()
