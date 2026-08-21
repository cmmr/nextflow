"""MkDocs hooks.

Stages the repository's shared images into docs/ so the site can use them, then
rewrites links: docs/ pages reference repository files by relative path, which is
correct when the markdown is read on GitHub but meaningless on the rendered site,
so those targets become links to the file on GitHub.
"""

import shutil
import re
from pathlib import Path

ROOT = Path(__file__).parent
DOCS = ROOT / "docs"
BLOB = "https://github.com/cmmr/nextflow/blob/main/"

# Root-level directories copied into docs/ as site assets.
STAGED_DIRS = ["images"]

LINK_RE = re.compile(r"(?P<pre>\]\()(?P<target>[^)\s]+)(?P<post>[)\s])")
SRC_RE = re.compile(r"""(?P<pre>\ssrc=")(?P<target>[^"]+)(?P<post>")""")


def on_pre_build(config, **kwargs):
    for dir_name in STAGED_DIRS:
        src = ROOT / dir_name
        dest = DOCS / dir_name
        for path in src.rglob("*"):
            if not path.is_file():
                continue
            target = dest / path.relative_to(src)
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or target.stat().st_mtime < path.stat().st_mtime:
                shutil.copy2(path, target)


def _resolve(target: str, page_dir: Path) -> str:
    if re.match(r"^(?:[a-z][a-z0-9+.-]*:|//|#|/)", target, re.I):
        return target

    path, _, anchor = target.partition("#")
    if not path:
        return target

    # A target that lands inside docs/ is a page; anything else is a repo file.
    resolved = (page_dir / path).resolve()
    try:
        resolved.relative_to(DOCS.resolve())
        return target
    except ValueError:
        pass

    repo_path = resolved.relative_to(ROOT.resolve()).as_posix()
    return BLOB + repo_path + ("#" + anchor if anchor else "")


def on_page_markdown(markdown, page, config, files, **kwargs):
    page_dir = (DOCS / page.file.src_uri).parent

    def sub(match):
        return (
            match.group("pre")
            + _resolve(match.group("target"), page_dir)
            + match.group("post")
        )

    markdown = LINK_RE.sub(sub, markdown)
    return SRC_RE.sub(sub, markdown)
