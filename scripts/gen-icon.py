#!/usr/bin/env python3
"""gen-icon.py — 도트(픽셀아트) damson 아이콘을 그려 Resources/icon-source.svg 생성.

32×32 픽셀 스프라이트(셀당 32px → 1024×1024 master). Tokyo Night 팔레트의
보라 자두 + 잎/줄기 + 윙크 표정 + 에이전트 느낌의 스파크. build-icon.sh가
이 SVG를 .icns로 변환한다.

수정 후:  python3 scripts/gen-icon.py && bash scripts/build-icon.sh
"""
import math
import os

N = 32          # 그리드 한 변(셀 수)
CELL = 1024 // N  # 셀 픽셀 크기

# ── 팔레트 ──────────────────────────────────────────────────────────────
BG     = "#1a1b26"   # Tokyo Night 배경
RIM    = "#3b2766"   # 자두 외곽/그림자
P_DK   = "#6b4caf"   # 어두운 보라
P_MID  = "#8a68cf"   # 중간 보라
P_LT   = "#ab88e6"   # 밝은 보라
P_HI   = "#d3c2f4"   # 하이라이트
LEAF_D = "#4f7a2c"   # 잎 진초록
LEAF_L = "#9ece6a"   # 잎 연초록
STEM   = "#6b4a32"   # 줄기 갈색
EYE    = "#241f33"   # 눈/입 (거의 검정)
WHITE  = "#ffffff"   # 눈 반짝임 / 스파크
BLUSH  = "#f7768e"   # 볼터치

grid = [[None] * N for _ in range(N)]


def put(x, y, c):
    if 0 <= x < N and 0 <= y < N:
        grid[y][x] = c


# ── 자두 몸통(타원) + 음영 램프 ────────────────────────────────────────
cx, cy = 15.5, 18.0      # 중심
rx, ry = 10.0, 10.5      # 반지름
hx, hy = 12.0, 13.5      # 하이라이트 중심(좌상단)

for y in range(N):
    for x in range(N):
        ex = (x + 0.5 - cx) / rx
        ey = (y + 0.5 - cy) / ry
        e = ex * ex + ey * ey          # 1.0 = 외곽
        if e > 1.0:
            continue
        d = math.hypot(x - hx, y - hy)  # 하이라이트로부터 거리
        if e > 0.80:
            c = RIM
        elif d < 2.2:
            c = P_HI
        elif d < 4.4:
            c = P_LT
        elif d < 7.2:
            c = P_MID
        else:
            c = P_DK
        grid[y][x] = c

# ── 가운데 골(cleft): 살짝 굽은 어두운 세로선 ─────────────────────────
for y in range(9, 28):
    bend = round(1.2 * math.sin((y - 9) / 19 * math.pi))
    xx = 16 + bend
    if grid[y][xx] not in (None, RIM):
        grid[y][xx] = P_DK
        # 골 옆 한 칸은 밝게
        if grid[y][xx + 1] not in (None, RIM):
            grid[y][xx + 1] = P_LT

# ── 줄기 + 잎 ──────────────────────────────────────────────────────────
put(16, 8, STEM)
put(17, 7, STEM)
leaf = [
    (18, 6), (19, 5), (20, 5), (21, 5),
    (19, 6), (20, 6), (21, 6), (22, 6),
    (20, 7), (21, 7), (22, 7),
]
for (x, y) in leaf:
    grid[y][x] = LEAF_L
for (x, y) in [(19, 5), (20, 5), (21, 6), (22, 6), (22, 7)]:
    grid[y][x] = LEAF_D

# ── 좌상단 반짝임(작은 광택 점) ────────────────────────────────────────
put(11, 12, P_HI)
put(12, 12, P_HI)
put(11, 13, P_HI)

# ── 표정: 왼쪽 동그란 눈 + 오른쪽 윙크 ────────────────────────────────
# 왼쪽 눈
for (x, y) in [(11, 18), (12, 18), (11, 19), (12, 19)]:
    grid[y][x] = EYE
put(11, 18, WHITE)            # 반짝임
# 오른쪽 윙크(아래로 굽은 선)
for (x, y) in [(19, 19), (20, 18), (21, 18), (22, 19)]:
    grid[y][x] = EYE
# 볼터치
for (x, y) in [(10, 21), (20, 21), (21, 21)]:
    grid[y][x] = BLUSH
# 방긋 웃는 입(위로 굽은 선)
for (x, y) in [(13, 22), (14, 23), (15, 23), (16, 23), (17, 23), (18, 22)]:
    grid[y][x] = EYE

# ── 에이전트 스파크(4갈래 별 두 개) ───────────────────────────────────
def sparkle(x, y, big=True):
    put(x, y, WHITE)
    put(x - 1, y, WHITE); put(x + 1, y, WHITE)
    put(x, y - 1, WHITE); put(x, y + 1, WHITE)
    if big:
        put(x - 2, y, P_HI); put(x + 2, y, P_HI)
        put(x, y - 2, P_HI); put(x, y + 2, P_HI)

sparkle(25, 12, big=True)
sparkle(7, 25, big=False)

# ── SVG 출력 ───────────────────────────────────────────────────────────
rects = []
for y in range(N):
    for x in range(N):
        c = grid[y][x]
        if c is None:
            continue
        rects.append(
            f'  <rect x="{x*CELL}" y="{y*CELL}" width="{CELL}" height="{CELL}" fill="{c}"/>'
        )

svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<!--
  damson app icon — 도트(픽셀아트) 자두 캐릭터 + 에이전트 스파크.
  scripts/gen-icon.py 가 생성. 직접 수정하지 말고 스크립트를 고칠 것.
  build: python3 scripts/gen-icon.py && bash scripts/build-icon.sh
-->
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges">
  <rect width="1024" height="1024" rx="180" ry="180" fill="{BG}"/>
{chr(10).join(rects)}
</svg>
'''

out = os.path.join(os.path.dirname(__file__), "..", "Resources", "icon-source.svg")
with open(os.path.normpath(out), "w") as f:
    f.write(svg)
print("wrote", os.path.normpath(out), f"({len(rects)} cells)")
