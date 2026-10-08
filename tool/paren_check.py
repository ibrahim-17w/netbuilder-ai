"""Paren-balance scanner for a Dart file region: finds where depth goes
negative or what depth remains. Used to locate bracket bugs the analyzer
only points at with a confusing line number."""
import sys


def scan(path, start_marker, span):
    src = open(path, encoding='utf-8').read()
    lines = src.split('\n')
    start = next(
        i for i, l in enumerate(lines) if start_marker in l
    )
    depth = 0
    i = start
    end = min(start + span, len(lines))
    while i < end:
        line = lines[i]
        clean = []
        in_str = None
        j = 0
        while j < len(line):
            ch = line[j]
            if in_str:
                if ch == '\\':
                    j += 2
                    continue
                if ch == in_str:
                    in_str = None
            else:
                if ch in ("'", '"'):
                    in_str = ch
                elif ch == '/' and j + 1 < len(line) and line[j + 1] == '/':
                    break
                elif ch in '({[':
                    depth += 1
                elif ch in ')}]':
                    depth -= 1
                    if depth < 0:
                        print(f'NEGATIVE at line {i + 1}: {line.strip()[:80]}')
                        return
            j += 1
        i += 1
    print(f'depth at end of region (line {i}): {depth}')


if __name__ == '__main__':
    scan(sys.argv[1], sys.argv[2], int(sys.argv[3]))
