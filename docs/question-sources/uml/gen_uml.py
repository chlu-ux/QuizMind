"""Draws the diagrams of the UML special bank (software-designer.u01-uml.*).

Run from this folder:  python3 gen_uml.py     -> writes the *.svg files next to it.
The SVGs are the sources; devseed uploads them to the server when the bank is imported.
"""
import os
from svglib import *

OUT = os.path.dirname(os.path.abspath(__file__))


def out(c, name, title):
    save(c, os.path.join(OUT, name + ".svg"), title)


# =============================================================================================
# 类图
# =============================================================================================
def class_notation():
    c = Canvas(680, 270)
    c.class_box(20, 20, 200, "学生", ["- id: int", "+ name: String", "# score: float", "~ level: int"],
                ["+ study(): void", "- calc(): int"])
    c.class_box(250, 20, 190, "Shape", ["# color: String"], ["+ draw()", "+ area(): double"], italic=True)
    c.class_box(470, 20, 190, "Drawable", None, ["+ draw(): void", "+ resize(k: int)"], stereo="interface", show_attrs=False)
    label(c, 120, 222, "普通类", 13, fill=NOTE)
    label(c, 345, 222, "抽象类：类名用斜体", 13, fill=NOTE)
    label(c, 565, 222, "接口：«interface»", 13, fill=NOTE)
    label(c, 340, 252, "可见性：+ 公有    - 私有    # 受保护    ~ 包内可见", 13)
    out(c, "class-notation", "类的表示与可见性")


def rel_pair(name, title, kind):
    c = Canvas(330, 100)
    c.simple_box(20, 25, 90, 50, "A")
    c.simple_box(220, 25, 90, 50, "B")
    y = 50
    pts = [(110, y), (220, y)]
    spec = {
        "dependency": dict(end="open", dash="6 4"),
        "association": dict(),
        "directed": dict(end="open"),
        "aggregation": dict(start="dia"),
        "composition": dict(start="fdia"),
        "generalization": dict(end="tri"),
        "realization": dict(end="tri", dash="6 4"),
    }[kind]
    connect(c, pts, **spec)
    out(c, name, title)


def class_school():
    c = Canvas(780, 450)
    c.class_box(30, 20, 150, "学校", ["name: String"], [])
    c.class_box(30, 190, 150, "院系", ["name: String"], [])
    c.class_box(290, 190, 150, "教师", ["title: String"], ["teach()"])
    c.class_box(520, 20, 170, "人员", ["name: String"], [], italic=True)
    c.class_box(590, 190, 150, "学生", ["no: String"], ["enrol()"])
    c.class_box(400, 350, 150, "课程", ["code: String"], [])
    # 学校 ◆── 院系 : composition
    connect(c, [(105, 98), (105, 190)], start="fdia")
    label(c, 92, 120, "1", anchor="end"); label(c, 92, 184, "1..*", anchor="end")
    # 院系 ◇── 教师 : aggregation
    connect(c, [(180, 229), (290, 229)], start="dia")
    label(c, 190, 221, "1", anchor="start"); label(c, 282, 221, "1..*", anchor="end")
    # 教师、学生 ──▷ 人员 : generalization
    connect(c, [(365, 190), (365, 150), (605, 150), (605, 98)], end="tri")
    connect(c, [(665, 190), (665, 150), (605, 150)])
    # 教师 ── 课程, 学生 ── 课程 : association
    connect(c, [(365, 270), (365, 380), (400, 380)])
    label(c, 353, 330, "讲授", anchor="end"); label(c, 372, 290, "1..*", anchor="start"); label(c, 392, 372, "*", anchor="end")
    connect(c, [(665, 270), (665, 380), (550, 380)])
    label(c, 677, 330, "选修", anchor="start"); label(c, 677, 290, "*", anchor="start"); label(c, 558, 372, "*", anchor="start")
    out(c, "class-school", "学校类图：组合、聚合、泛化与关联")


def multiplicity():
    c = Canvas(760, 190)
    c.simple_box(20, 60, 120, 50, "顾客")
    c.simple_box(320, 60, 120, 50, "订单")
    c.simple_box(620, 60, 120, 50, "订单项")
    connect(c, [(140, 85), (320, 85)])
    label(c, 148, 76, "1", anchor="start"); label(c, 312, 76, "0..*", anchor="end")
    label(c, 230, 106, "下单", 12, fill=NOTE)
    connect(c, [(440, 85), (620, 85)], start="fdia")
    label(c, 466, 76, "1", anchor="start"); label(c, 612, 76, "1..*", anchor="end")
    c.simple_box(320, 140, 120, 40, "优惠券", size=14)
    connect(c, [(380, 110), (380, 140)])
    label(c, 390, 130, "0..1", 12, anchor="start")
    out(c, "multiplicity", "多重度")


def class_zoo():
    c = Canvas(720, 300)
    c.class_box(190, 15, 190, "动物", ["# name: String"], ["+ eat()"], italic=True)
    c.class_box(40, 190, 150, "猫", [], ["+ eat()"])
    c.class_box(250, 190, 170, "狗", [], ["+ eat()", "+ bark()"])
    c.class_box(500, 190, 190, "Pet", None, ["+ play()"], stereo="interface", show_attrs=False)
    # 猫、狗 ──▷ 动物 (solid line, hollow triangle)
    connect(c, [(115, 190), (115, 150), (285, 150), (285, 108)], end="tri")
    connect(c, [(335, 190), (335, 150), (285, 150)])
    # 狗 ┄┄▷ Pet (dashed line, hollow triangle)
    connect(c, [(420, 250), (500, 250)], end="tri", dash="6 4")
    out(c, "class-zoo", "泛化与实现")


def class_code():
    c = Canvas(740, 230)
    c.simple_box(30, 30, 110, 46, "汽车")
    c.simple_box(260, 30, 110, 46, "发动机")
    c.simple_box(30, 140, 110, 46, "司机")
    c.simple_box(260, 140, 110, 46, "地图")
    connect(c, [(140, 53), (260, 53)], start="fdia")
    connect(c, [(140, 163), (260, 163)], end="open", dash="6 4")
    label(c, 400, 48, "汽车创建时一并创建发动机，", 13, anchor="start")
    label(c, 400, 68, "汽车销毁时发动机随之销毁", 13, anchor="start")
    label(c, 400, 158, "司机的方法只在参数里临时用到地图，", 13, anchor="start")
    label(c, 400, 178, "并不保存地图的引用", 13, anchor="start")
    out(c, "class-code", "由描述画出类间关系")


# =============================================================================================
# 用例图
# =============================================================================================
def usecase():
    c = Canvas(780, 480)
    c.rect(180, 20, 440, 440, fill="#ffffff", rx=6)
    label(c, 400, 46, "图书管理系统", 15)
    stick(c, 70, 120, "读者")
    stick(c, 70, 330, "VIP 读者")
    stick(c, 710, 190, "管理员")
    connect(c, [(70, 330), (70, 212)], end="tri")            # VIP 读者 ──▷ 读者

    def uc(cx, cy, name, w=62, h=26):
        c.ellipse(cx, cy, w, h, fill=BOX2)
        c.ctext(cx, cy, name, 14)
    uc(400, 100, "查询图书")
    uc(300, 190, "借书"); uc(300, 300, "还书"); uc(300, 410, "缴纳罚款", w=68)
    uc(520, 190, "登录"); uc(520, 330, "维护图书", w=68)
    # actor ── use case : association
    connect(c, [(86, 152), (340, 112)])
    connect(c, [(86, 152), (238, 190)])
    connect(c, [(86, 152), (240, 292)])
    connect(c, [(694, 222), (588, 322)])
    connect(c, [(694, 222), (458, 112)])
    # «include»: 基用例 ┄┄> 被包含用例
    connect(c, [(362, 190), (458, 190)], end="open", dash="6 4")
    label(c, 410, 182, "«include»", 12)
    connect(c, [(335, 276), (485, 214)], end="open", dash="6 4")
    label(c, 440, 262, "«include»", 12, anchor="start")
    # «extend»: 扩展用例 ┄┄> 基用例
    connect(c, [(300, 384), (300, 326)], end="open", dash="6 4")
    label(c, 312, 360, "«extend»", 12, anchor="start")
    label(c, 312, 376, "[逾期]", 12, anchor="start")
    out(c, "usecase", "图书管理系统用例图")


def uc_pair(name, title, kind):
    c = Canvas(430, 110)
    c.ellipse(70, 55, 62, 26, fill=BOX2); c.ctext(70, 55, "用例 P", 14)
    c.ellipse(360, 55, 62, 26, fill=BOX2); c.ctext(360, 55, "用例 Q", 14)
    if kind == "include":
        connect(c, [(132, 55), (298, 55)], end="open", dash="6 4")
        label(c, 215, 45, "«include»", 12)
    elif kind == "extend":
        connect(c, [(132, 55), (298, 55)], end="open", dash="6 4")
        label(c, 215, 45, "«extend»", 12)
    elif kind == "extend-rev":
        connect(c, [(298, 55), (132, 55)], end="open", dash="6 4")
        label(c, 215, 45, "«extend»", 12)
    elif kind == "generalization":
        connect(c, [(132, 55), (298, 55)], end="tri")
    out(c, name, title)


# =============================================================================================
# 顺序图
# =============================================================================================
def lifeline_head(c, cx, name, y=20):
    w = max(tw(name, 14) + 24, 80)
    c.rect(cx - w / 2, y, w, 34, fill=BOX2)
    c.ctext(cx, y + 17, name, 14)


def sequence():
    c = Canvas(780, 530)
    xs = {"用户": 70, "登录界面": 240, "认证服务": 420, "用户库": 620}
    for n, x in xs.items():
        lifeline_head(c, x, n)
        c.line(x, 54, x, 515, dash="6 4", sw=1.2)
    c.rect(xs["登录界面"] - 6, 100, 12, 400, fill="#ffffff")
    c.rect(xs["认证服务"] - 6, 140, 12, 320, fill="#ffffff")
    c.rect(xs["用户库"] - 6, 190, 12, 50, fill="#ffffff")

    def msg(x1, x2, y, text, ret=False):
        d = 1 if x2 > x1 else -1
        connect(c, [(x1 + 6 * d, y), (x2 - 6 * d, y)], end="open" if ret else "filled", dash="6 4" if ret else None)
        label(c, (x1 + x2) / 2, y - 7, text, 13)
    msg(70, 240, 100, "1: 登录(账号, 口令)")
    msg(240, 420, 140, "2: 验证(账号, 口令)")
    msg(420, 620, 190, "3: 查询用户(账号)")
    msg(620, 420, 240, "用户信息", ret=True)
    c.polyline([(426, 266), (470, 266), (470, 288), (426, 288)])
    end_shape(c, "filled", (426, 288), (470, 288))
    label(c, 478, 282, "4: 校验口令()", 13, anchor="start")
    # alt combined fragment
    c.rect(310, 310, 440, 150, fill="none", sw=1.2)
    c.polygon([(310, 310), (352, 310), (360, 320), (360, 332), (310, 332)], fill="#ffffff", sw=1.2)
    label(c, 334, 326, "alt", 12)
    label(c, 368, 326, "[口令正确]", 12, anchor="start")
    msg(420, 240, 366, "返回令牌", ret=True)
    c.line(310, 392, 750, 392, dash="6 4", sw=1.2)
    label(c, 318, 408, "[口令错误]", 12, anchor="start")
    msg(420, 240, 440, "返回错误", ret=True)
    msg(240, 70, 490, "显示登录结果", ret=True)
    out(c, "seq-login", "登录顺序图")


def seq_notation_q():
    c = Canvas(560, 310)
    lifeline_head(c, 100, "对象 X")
    lifeline_head(c, 440, "对象 Y")
    c.line(100, 54, 100, 290, dash="6 4", sw=1.2)
    c.line(440, 54, 440, 250, dash="6 4", sw=1.2)
    c.rect(94, 100, 12, 150, fill="#ffffff")
    c.rect(434, 120, 12, 90, fill="#ffffff")
    connect(c, [(106, 120), (434, 120)], end="filled")
    connect(c, [(434, 200), (106, 200)], end="open", dash="6 4")
    c.line(428, 250, 452, 274, sw=2.5); c.line(452, 250, 428, 274, sw=2.5)

    def tag(x, y, n):
        c.circle(x, y, 11, fill="#fde68a", stroke=ACCENT); c.ctext(x, y, str(n), 13, bold=True)
    tag(270, 100, 1); tag(270, 180, 2); tag(76, 160, 3); tag(100, 80, 4); tag(412, 262, 5)
    out(c, "seq-notation-q", "顺序图符号编号图")


# =============================================================================================
# 状态图
# =============================================================================================
def state():
    c = Canvas(790, 330)
    c.circle(30, 120, 9, fill=LINE)
    for x, name, y in ((90, "待付款", 90), (290, "已付款", 90), (490, "已发货", 90)):
        c.rect(x, y, 110, 60, fill=BOX2, rx=14); c.ctext(x + 55, y + 30, name, 15, bold=True)
    c.rect(660, 210, 100, 56, fill=BOX2, rx=14); c.ctext(710, 238, "已完成", 15, bold=True)
    c.rect(90, 230, 110, 60, fill=BOX2, rx=14); c.ctext(145, 260, "已取消", 15, bold=True)
    connect(c, [(39, 120), (90, 120)], end="filled")
    connect(c, [(200, 120), (290, 120)], end="filled")
    label(c, 245, 76, "支付成功", 12); label(c, 245, 92, "/ 通知仓库", 12)
    connect(c, [(400, 120), (490, 120)], end="filled")
    label(c, 445, 108, "发货", 12)
    connect(c, [(545, 150), (545, 238), (660, 238)], end="filled")
    label(c, 555, 196, "确认收货", 12, anchor="start")
    connect(c, [(145, 150), (145, 230)], end="filled")
    label(c, 153, 184, "超时 [超过 30 分钟]", 12, anchor="start")
    c.circle(710, 308, 10, fill="#ffffff"); c.circle(710, 308, 5.5, fill=LINE)
    connect(c, [(710, 266), (710, 298)], end="filled")
    c.circle(30, 260, 10, fill="#ffffff"); c.circle(30, 260, 5.5, fill=LINE)
    connect(c, [(90, 260), (40, 260)], end="filled")
    label(c, 400, 312, "转换标注：事件 [监护条件] / 动作", 13, fill=NOTE)
    out(c, "state-order", "订单状态图")


# =============================================================================================
# 活动图
# =============================================================================================
def activity():
    c = Canvas(720, 570)
    c.rect(20, 20, 280, 530, fill="#ffffff"); c.rect(300, 20, 400, 530, fill="#ffffff")
    c.rect(20, 20, 280, 30, fill=BOX2); c.rect(300, 20, 400, 30, fill=BOX2)
    c.ctext(160, 35, "客户", 15, bold=True); c.ctext(500, 35, "系统", 15, bold=True)

    def act(cx, cy, name, w=110):
        c.rect(cx - w / 2, cy - 22, w, 44, fill=BOX, rx=20); c.ctext(cx, cy, name, 14)
    c.circle(160, 82, 9, fill=LINE)
    connect(c, [(160, 91), (160, 108)], end="filled")
    act(160, 130, "提交订单")
    connect(c, [(215, 130), (440, 130), (440, 168)], end="filled")
    act(440, 190, "检查库存")
    connect(c, [(440, 212), (440, 244)], end="filled")
    c.polygon([(440, 244), (462, 266), (440, 288), (418, 266)], fill="#ffffff")
    label(c, 470, 262, "[有货]", 12, anchor="start")
    label(c, 410, 262, "[缺货]", 12, anchor="end")
    # no stock
    connect(c, [(418, 266), (350, 266), (350, 318)], end="filled")
    act(350, 340, "通知缺货", w=100)
    connect(c, [(350, 362), (350, 400)], end="filled")
    c.circle(350, 410, 10, fill="#ffffff"); c.circle(350, 410, 5.5, fill=LINE)
    # in stock: fork
    connect(c, [(462, 266), (580, 266), (580, 312)], end="filled")
    c.rect(480, 312, 200, 7, fill=LINE)
    connect(c, [(525, 319), (525, 350)], end="filled"); connect(c, [(640, 319), (640, 350)], end="filled")
    act(525, 372, "扣减库存", w=100); act(640, 372, "生成支付单", w=100)
    connect(c, [(525, 394), (525, 430)], end="filled"); connect(c, [(640, 394), (640, 430)], end="filled")
    c.rect(480, 430, 200, 7, fill=LINE)
    # join -> 支付 (客户) -> 发货 (系统) -> 终止
    connect(c, [(580, 437), (580, 480), (215, 480)], end="filled")
    act(160, 480, "支付")
    connect(c, [(160, 502), (160, 525), (440, 525)], end="filled")
    act(500, 525, "发货", w=100)
    connect(c, [(550, 525), (610, 525)], end="filled")
    c.circle(622, 525, 10, fill="#ffffff"); c.circle(622, 525, 5.5, fill=LINE)
    out(c, "activity-order", "订单处理活动图")


def notation_nodes(numbered, name):
    c = Canvas(720, 190 if numbered else 210)
    items = [("init", "初始节点"), ("final", "活动终止节点"), ("flow", "流终止节点"), ("dec", "判定节点"), ("fork", "分叉 / 汇合")]
    if numbered:
        items = [items[3], items[0], items[4], items[1], items[2]]
    for i, (kind, cap) in enumerate(items):
        cx = 70 + i * 145
        cy = 70
        if kind == "init":
            c.circle(cx, cy, 11, fill=LINE)
        elif kind == "final":
            c.circle(cx, cy, 13, fill="#ffffff"); c.circle(cx, cy, 7, fill=LINE)
        elif kind == "flow":
            c.circle(cx, cy, 13, fill="#ffffff")
            c.line(cx - 8, cy - 8, cx + 8, cy + 8, sw=2); c.line(cx + 8, cy - 8, cx - 8, cy + 8, sw=2)
        elif kind == "dec":
            c.polygon([(cx, cy - 20), (cx + 26, cy), (cx, cy + 20), (cx - 26, cy)], fill="#ffffff")
        else:
            c.rect(cx - 40, cy - 4, 80, 8, fill=LINE)
        if numbered:
            c.circle(cx, 140, 12, fill="#fde68a", stroke=ACCENT); c.ctext(cx, 140, str(i + 1), 14, bold=True)
        else:
            label(c, cx, 130, cap, 13)
    out(c, name, "活动图与状态图中的控制节点")


# =============================================================================================
# 通信图
# =============================================================================================
def comm():
    c = Canvas(760, 380)
    objs = {"用户": (90, 200), "订单": (360, 200), "库存": (640, 80), "支付": (640, 320)}
    for n, (x, y) in objs.items():
        c.rect(x - 55, y - 22, 110, 44, fill=BOX2)
        c.underlined(x, y, f":{n}", 15, bold=True)
    links = [("用户", "订单"), ("订单", "库存"), ("订单", "支付")]
    for a, b in links:
        (x1, y1), (x2, y2) = objs[a], objs[b]
        # attach to box edges
        c.line(x1 + (55 if x2 > x1 else -55), y1, x2 - (55 if x2 > x1 else -55), y2)
    import math

    def msg(a, b, text, off=-18):
        (x1, y1), (x2, y2) = objs[a], objs[b]
        sx, sy = x1 + 55, y1
        ex, ey = x2 - 55, y2
        mx, my = (sx + ex) / 2, (sy + ey) / 2
        dx, dy = ex - sx, ey - sy
        n = math.hypot(dx, dy)
        ux, uy = dx / n, dy / n
        nx, ny = uy, -ux
        # small arrow beside the link, pointing in the message direction
        px, py = mx + nx * off * 0.5, my + ny * off * 0.5
        end_shape(c, "filled", (px + ux * 14, py + uy * 14), (px - ux * 14, py - uy * 14))
        c.line(px - ux * 14, py - uy * 14, px + ux * 8, py + uy * 8, sw=1.5)
        c.text(mx + nx * off * 1.6, my + ny * off * 1.6 + 4, text, size=13, anchor="middle")
    msg("用户", "订单", "1: 提交订单()", off=-26)
    msg("订单", "库存", "1.1: 检查库存()", off=26)
    msg("订单", "支付", "2: 支付()", off=-26)
    out(c, "comm-order", "订单通信图")


# =============================================================================================
# 构件图 / 部署图 / 包图 / 对象图
# =============================================================================================
def component_box(c, x, y, w, h, name):
    c.rect(x, y, w, h, fill=BOX)
    c.rect(x - 10, y + 14, 20, 10, fill=BOX)
    c.rect(x - 10, y + 32, 20, 10, fill=BOX)
    c.ctext(x + w / 2 + 6, y + 22, "«component»", 12, fill=NOTE)
    c.ctext(x + w / 2 + 6, y + 50, name, 15, bold=True)


def ball(c, cx, cy, name=None):
    c.circle(cx, cy, 8, fill="#ffffff")
    if name:
        label(c, cx - 4, cy - 22, name, 12)


def socket(c, cx, cy):
    c.path(f"M {cx},{cy - 15} A 15 15 0 0 0 {cx},{cy + 15}")


def component():
    c = Canvas(800, 230)
    component_box(c, 40, 60, 150, 100, "前端")
    component_box(c, 330, 60, 160, 100, "订单服务")
    component_box(c, 630, 60, 140, 100, "库存服务")
    # 订单服务 provides IOrder; 前端 requires it
    c.line(190, 120, 252, 120)
    socket(c, 262, 120)
    ball(c, 262, 120, "IOrder")
    c.line(270, 120, 330, 120)
    # 库存服务 provides IStock; 订单服务 requires it
    c.line(490, 120, 552, 120)
    socket(c, 562, 120)
    ball(c, 562, 120, "IStock")
    c.line(570, 120, 630, 120)
    label(c, 400, 205, "○ 提供接口（棒棒糖）      ⊂ 需要接口（插座）", 13, fill=NOTE)
    out(c, "component", "构件图")


def node3d(c, x, y, w, h, name, stereo, artifacts=()):
    d = 16
    c.polygon([(x, y + d), (x + d, y), (x + w + d, y), (x + w, y + d)], fill="#f3f4f6")
    c.polygon([(x + w, y + d), (x + w + d, y), (x + w + d, y + h), (x + w, y + h + d)], fill="#e5e7eb")
    c.rect(x, y + d, w, h, fill=BOX)
    c.ctext(x + w / 2, y + d + 16, f"«{stereo}»", 12, fill=NOTE)
    c.ctext(x + w / 2, y + d + 38, name, 15, bold=True)
    for i, a in enumerate(artifacts):
        ay = y + d + 58 + i * 40
        c.rect(x + 18, ay, w - 36, 34, fill="#ffffff")
        c.ctext(x + w / 2, ay + 9, "«artifact»", 11, fill=NOTE)
        c.ctext(x + w / 2, ay + 24, a, 13)


def deployment():
    c = Canvas(820, 280)
    node3d(c, 20, 40, 190, 170, "用户手机", "device", ["shop.apk"])
    node3d(c, 310, 40, 190, 170, "Web 服务器", "server", ["shop.war", "config.xml"])
    node3d(c, 600, 40, 190, 170, "数据库服务器", "server", ["shop.db"])
    c.line(210, 140, 310, 140); label(c, 260, 130, "«HTTPS»", 12)
    c.line(500, 140, 600, 140); label(c, 550, 130, "«JDBC»", 12)
    out(c, "deployment", "部署图")


def package_shape(c, x, y, w, h, name):
    c.rect(x, y, 70, 16, fill=BOX2)
    c.rect(x, y + 16, w, h, fill=BOX2)
    c.ctext(x + w / 2, y + 16 + h / 2, name, 15, bold=True)


def package():
    c = Canvas(720, 330)
    package_shape(c, 40, 40, 170, 70, "表现层")
    package_shape(c, 270, 40, 170, 70, "业务层")
    package_shape(c, 500, 40, 170, 70, "数据层")
    package_shape(c, 270, 220, 170, 70, "公共工具")
    connect(c, [(210, 91), (270, 91)], end="open", dash="6 4")
    connect(c, [(440, 91), (500, 91)], end="open", dash="6 4")
    connect(c, [(125, 126), (125, 255), (270, 255)], end="open", dash="6 4")
    connect(c, [(355, 126), (355, 220)], end="open", dash="6 4")
    connect(c, [(585, 126), (585, 255), (440, 255)], end="open", dash="6 4")
    out(c, "package", "包图")


def object_diagram():
    c = Canvas(760, 270)

    def obj(x, y, w, name, attrs):
        h = 34 + len(attrs) * 22 + 8
        c.rect(x, y, w, h, fill=BOX)
        c.underlined(x + w / 2, y + 17, name, 14, bold=True)
        c.line(x, y + 34, x + w, y + 34)
        for i, a in enumerate(attrs):
            c.text(x + 10, y + 34 + 20 + i * 22, a, size=13, anchor="start")
        return h
    obj(30, 30, 190, "张三 : 教师", ['title = "教授"', "age = 45"])
    obj(30, 170, 190, "李四 : 教师", ['title = "讲师"', "age = 31"])
    obj(500, 90, 230, "计算机系 : 院系", ['name = "计算机系"'])
    c.line(220, 70, 500, 120); label(c, 360, 82, "任教", 12)
    c.line(220, 200, 500, 135); label(c, 360, 190, "任教", 12)
    out(c, "object", "对象图")


# =============================================================================================
# 分类与视图
# =============================================================================================
def taxonomy():
    c = Canvas(800, 470)

    def box(x, y, w, h, s, fill=BOX, bold=False):
        c.rect(x, y, w, h, fill=fill, rx=6); c.ctext(x + w / 2, y + h / 2, s, 14, bold=bold)
        return x, y, w, h
    box(20, 215, 90, 40, "UML 图", BOX2, True)
    box(160, 105, 90, 40, "结构图", BOX2, True)
    box(160, 330, 90, 40, "行为图", BOX2, True)
    connect(c, [(110, 235), (135, 235), (135, 125), (160, 125)])
    connect(c, [(110, 235), (135, 235), (135, 350), (160, 350)])
    struct = ["类图", "对象图", "构件图", "组合结构图", "包图", "部署图", "轮廓图"]
    for i, s in enumerate(struct):
        y = 15 + i * 33
        box(310, y, 120, 28, s)
        c.line(250, 125, 285, 125); c.line(285, 28, 285, 28 + 6 * 33); c.line(285, y + 14, 310, y + 14)
    beh = ["用例图", "活动图", "状态机图", "交互图"]
    for i, s in enumerate(beh):
        y = 268 + i * 45
        box(310, y, 120, 30, s)
        c.line(250, 350, 285, 350); c.line(285, 283, 285, 283 + 3 * 45); c.line(285, y + 15, 310, y + 15)
    inter = ["顺序图", "通信图", "交互概览图", "时序图"]
    for i, s in enumerate(inter):
        y = 268 + 2 * 45 + 0 + i * 0
        yy = 300 + i * 40
        box(520, yy, 130, 30, s)
        c.line(430, 403, 470, 403); c.line(470, 315, 470, 315 + 3 * 40); c.line(470, yy + 15, 520, yy + 15)
    out(c, "uml-taxonomy", "UML 的 14 种图")


def views():
    c = Canvas(720, 380)
    c.ellipse(360, 190, 92, 44, fill="#fde68a", stroke=ACCENT)
    c.ctext(360, 190, "用例视图", 16, bold=True)

    def vbox(x, y, name, sub):
        c.rect(x, y, 190, 70, fill=BOX2, rx=8)
        c.ctext(x + 95, y + 24, name, 15, bold=True)
        c.ctext(x + 95, y + 50, sub, 13, fill=NOTE)
    vbox(30, 20, "逻辑视图", "类图、对象图、状态图")
    vbox(500, 20, "进程视图", "并发与同步")
    vbox(30, 290, "实现视图", "构件图")
    vbox(500, 290, "部署视图", "部署图")
    connect(c, [(290, 160), (220, 90)], end="open")
    connect(c, [(430, 160), (500, 90)], end="open")
    connect(c, [(290, 220), (220, 290)], end="open")
    connect(c, [(430, 220), (500, 290)], end="open")
    out(c, "views-4plus1", "UML 的 4+1 视图")


def main():
    class_notation()
    for name, title, kind in [
        ("rel-dependency", "依赖", "dependency"), ("rel-association", "关联", "association"),
        ("rel-directed", "单向关联", "directed"), ("rel-aggregation", "聚合", "aggregation"),
        ("rel-composition", "组合", "composition"), ("rel-generalization", "泛化", "generalization"),
        ("rel-realization", "实现", "realization"),
    ]:
        rel_pair(name, title, kind)
    class_school(); multiplicity(); class_zoo(); class_code()
    usecase()
    for kind in ("include", "extend", "extend-rev", "generalization"):
        uc_pair(f"uc-{kind}", f"用例间的 {kind} 关系", kind)
    sequence(); seq_notation_q()
    state(); activity()
    notation_nodes(False, "nodes"); notation_nodes(True, "nodes-q")
    comm(); component(); deployment(); package(); object_diagram()
    taxonomy(); views()


if __name__ == "__main__":
    main()
