#!/usr/bin/env python3
# Strips comments from the .lua, .xml and .toc files under the given directory
# (default: the repo root) in place. The release workflow runs it right before
# the packager, so the comments stay in the repo but not in the published zip.
# Line numbers are preserved: a comment becomes nothing on the same line, a
# multi-line comment becomes the same number of line breaks.
import os
import re
import sys

SKIP_DIRS = {".git", ".github", ".vscode"}


def strip_lua(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:  # long comment --[==[ ... ]==]
                close = "]" + m.group(1) + "]"
                end = src.find(close, i + m.end())
                end = n if end == -1 else end + len(close)
                out.append("\n" * src.count("\n", i, end))
            else:  # line comment, keep the newline
                end = src.find("\n", i)
                end = n if end == -1 else end
            i = end
            continue
        if c == '"' or c == "'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c:
                    j += 1
                    break
                if src[j] == "\n":  # unterminated string, leave it alone
                    break
                j += 1
            out.append(src[i:j])
            i = j
            continue
        if c == "[":
            m = re.match(r"\[(=*)\[", src[i:])
            if m:  # long string [==[ ... ]==]
                close = "]" + m.group(1) + "]"
                end = src.find(close, i + m.end())
                end = n if end == -1 else end + len(close)
                out.append(src[i:end])
                i = end
                continue
        out.append(c)
        i += 1
    return rstrip_lines("".join(out))


def strip_xml(src):
    return rstrip_lines(re.sub(r"<!--.*?-->", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S))


def strip_toc(src):
    # a line starting with a single # is a comment, ## is a directive
    return "".join(line for line in src.splitlines(keepends=True) if not re.match(r"#(?!#)", line))


def rstrip_lines(text):
    return "\n".join(line.rstrip() for line in text.split("\n"))


STRIPPERS = {".lua": strip_lua, ".xml": strip_xml, ".toc": strip_toc}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    changed = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            strip = STRIPPERS.get(os.path.splitext(name)[1].lower())
            if not strip:
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8", newline="") as f:
                src = f.read()
            out = strip(src)
            if out != src:
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write(out)
                changed += 1
    print(f"strip-comments: {changed} file(s) changed under {root}")


if __name__ == "__main__":
    main()
