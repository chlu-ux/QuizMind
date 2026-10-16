"""结构型模式：适配器、桥接、组合、装饰器、外观、代理。"""
from common import Blank, Code, Pattern, box

PATTERNS = []

JAVA_IMPL = "Java 中类实现接口用 implements，类继承类用 extends"
CPP_INH = "C++ 的继承写成 class 子类 : public 基类"
CPP_VIRTUAL = "C++ 里抽象类通过纯虚函数实现，写法是 virtual 返回类型 函数名() = 0"

# ------------------------------------------------------------------------------------------------ 适配器
PATTERNS.append(Pattern(
    key="adapter", sec="T6.8", name="适配器", en="Adapter",
    diagram=dict(
        boxes={
            "Client": box("Client", [], ["+show(p: Printer)"]),
            "Printer": box("Printer", [], ["+print(text: String)"], stereo="interface"),
            "Adapter": box("Adapter", ["-legacy: LegacyPrinter"], ["+print(text: String)"]),
            "LegacyPrinter": box("LegacyPrinter", [], ["+printLine(line: String)"]),
        },
        rows=[[("Client", 0), ("Printer", 1.5)], [("Adapter", 1.5), ("LegacyPrinter", 3)]],
        edges=[("Client", "Printer", "assoc", ""), ("Adapter", "Printer", "real", ""), ("Adapter", "LegacyPrinter", "assoc", "")],
    ),
    java=Code(
        scene="客户端只会调用打印接口 Printer 的 print 方法，但手头有一个已有的旧打印类 LegacyPrinter，它只有 printLine 方法，不能改动它的源码，用（对象）适配器让两者协同工作。",
        src=r"""interface Printer {
    void print(String text);
}

class LegacyPrinter {
    public void printLine(String line) { System.out.println("legacy: " + line); }
}

class Adapter @@1@@ Printer {
    private @@2@@ legacy;

    public Adapter(LegacyPrinter legacy) { this.legacy = legacy; }

    public void print(String text) {
        legacy.@@3@@(text);
    }
}

class Client {
    public void show(Printer p) { p.print("hello"); }
}""",
        blanks={
            1: Blank("implements", ["extends", "inherits", "adapts"], "关键字",
                     "适配器要让客户端把它当成目标接口 Printer 使用，所以实现目标接口，用 implements。",
                     "适配器实现客户端期望的目标接口，并持有被适配的对象", 1),
            2: Blank("LegacyPrinter", ["Printer", "Adapter", "Client"], "类名",
                     "对象适配器通过组合持有被适配者（Adaptee）LegacyPrinter 的对象。如果类型写成 Printer，构造函数传入 LegacyPrinter 就无法赋值。",
                     "适配器实现客户端期望的目标接口，并持有被适配的对象", 2),
            3: Blank("printLine", ["print", "println", "printText"], "方法",
                     "适配器把对目标接口 print 方法的调用转换成对被适配者已有方法 printLine 的调用。LegacyPrinter 里没有 print 方法。",
                     "适配器在目标接口的方法里，把调用转发给被适配者已有的方法", 2),
        },
        main=r"""        Client c = new Client();
        c.show(new Adapter(new LegacyPrinter()));""",
    ),
    cpp=Code(
        scene="客户端只会调用打印接口 Printer 的 print 方法，但手头有一个已有的旧打印类 LegacyPrinter，它只有 printLine 方法，不能改动它的源码，用（对象）适配器让两者协同工作。",
        src=r"""class Printer {
public:
    virtual void print(const string& text) = 0;
    virtual ~Printer() { }
};

class LegacyPrinter {
public:
    void printLine(const string& line) { cout << "legacy: " << line << endl; }
};

class Adapter : public Printer {
    LegacyPrinter* legacy;
public:
    Adapter(LegacyPrinter* l) { legacy = l; }
    void print(const string& text) {
        @@1@@;
    }
};

class Client {
public:
    void show(@@2@@ p) { p->print("hello"); }
};""",
        blanks={
            1: Blank("legacy->printLine(text)", ["legacy.printLine(text)", "legacy->print(text)", "LegacyPrinter::printLine(text)"], "逻辑",
                     "legacy 是指针，用 -> 调用成员函数；被适配者的方法名是 printLine，不是 print；LegacyPrinter::printLine 是非静态函数，不能这样不带对象地调用。",
                     "适配器在目标接口的方法里，把调用转发给被适配者已有的方法", 3),
            2: Blank("Printer*", ["LegacyPrinter*", "string", "void"], "类名",
                     "客户端只依赖目标接口 Printer，用基类指针接收适配器对象，才能通过 -> 多态调用 print。",
                     "客户端只依赖目标接口，不知道被适配者的存在", 1),
        },
        main=r"""    LegacyPrinter lp;
    Adapter a(&lp);
    Client c;
    c.show(&a);""",
    ),
))

# ------------------------------------------------------------------------------------------------ 桥接
PATTERNS.append(Pattern(
    key="bridge", sec="T6.9", name="桥接", en="Bridge",
    diagram=dict(
        boxes={
            "Shape": box("Shape", ["#color: Color"], ["+draw()"], abstract=True),
            "Color": box("Color", [], ["+name(): String"], stereo="interface"),
            "Circle": box("Circle", [], ["+draw()"]),
            "Square": box("Square", [], ["+draw()"]),
            "Red": box("Red", [], ["+name(): String"]),
            "Blue": box("Blue", [], ["+name(): String"]),
        },
        rows=[[("Shape", 0.5), ("Color", 2.5)],
              [("Circle", 0), ("Square", 1), ("Red", 2), ("Blue", 3)]],
        edges=[("Shape", "Color", "assoc", ""), ("Circle", "Shape", "gen", ""), ("Square", "Shape", "gen", ""),
               ("Red", "Color", "real", ""), ("Blue", "Color", "real", "")],
    ),
    java=Code(
        scene="图形有圆形、方形两种形状，颜色有红、蓝两种，两个维度各自独立变化，用桥接模式把「形状」和「颜色」分开，避免产生 2×2 个子类。",
        src=r"""interface Color {
    String name();
}

class Red implements Color { public String name() { return "red"; } }
class Blue implements Color { public String name() { return "blue"; } }

abstract class Shape {
    protected @@1@@ color;

    protected Shape(Color color) { this.color = color; }

    public abstract void draw();
}

class Circle @@2@@ Shape {
    public Circle(Color color) {
        @@3@@(color);
    }
    public void draw() { System.out.println("circle in " + color.name()); }
}

class Square extends Shape {
    public Square(Color color) { super(color); }
    public void draw() { System.out.println("square in " + color.name()); }
}""",
        blanks={
            1: Blank("Color", ["Red", "Shape", "Circle"], "类名",
                     "抽象部分（Shape）持有实现部分的抽象接口 Color，这就是「桥」：形状通过它使用任意一种颜色。写成具体的 Red 就只能画红色了。",
                     "桥接模式中抽象部分持有实现部分的抽象接口，两者通过组合连接", 2),
            2: Blank("extends", ["implements", "inherits", "instanceof"], "关键字",
                     "Shape 是抽象类，Circle 是它的子类，类继承类用 extends。",
                     JAVA_IMPL, 1),
            3: Blank("super", ["this", "Shape", "base"], "关键字",
                     "子类构造函数用 super(参数) 调用父类的构造函数，并且必须写在第一行；Java 没有 base 关键字，this(color) 调用的是本类自己的构造函数，会递归。",
                     "Java 的子类构造函数用 super(参数) 调用父类的构造函数", 2),
        },
        main=r"""        new Circle(new Red()).draw();
        new Square(new Blue()).draw();""",
    ),
    cpp=Code(
        scene="图形有圆形、方形两种形状，颜色有红、蓝两种，两个维度各自独立变化，用桥接模式把「形状」和「颜色」分开，避免产生 2×2 个子类。",
        src=r"""class Color {
public:
    virtual string name() = 0;
    virtual ~Color() { }
};

class Red : public Color { public: string name() { return "red"; } };
class Blue : public Color { public: string name() { return "blue"; } };

class Shape {
protected:
    @@1@@ color;
public:
    Shape(Color* c) : color(c) { }
    virtual void draw() = 0;
    virtual ~Shape() { }
};

class Circle : public Shape {
public:
    Circle(Color* c) : @@2@@(c) { }
    void draw() { cout << "circle in " << @@3@@ << endl; }
};

class Square : public Shape {
public:
    Square(Color* c) : Shape(c) { }
    void draw() { cout << "square in " << color->name() << endl; }
};""",
        blanks={
            1: Blank("Color*", ["Color", "Red*", "Shape*"], "类名",
                     "桥接要用抽象的 Color 指针来持有实现部分，这样才能多态地使用任意颜色；Color 是抽象类，不能定义成按值的成员。",
                     "桥接模式中抽象部分持有实现部分的抽象接口，两者通过组合连接", 2),
            2: Blank("Shape", ["Circle", "color", "super"], "类名",
                     "C++ 子类在构造函数的初始化列表里调用基类的构造函数，写法是「基类名(参数)」。C++ 没有 super 关键字，也不能在子类的初始化列表里直接初始化基类的成员 color。",
                     "C++ 的子类在构造函数的初始化列表里调用基类的构造函数，写法是 基类名(参数)", 3),
            3: Blank("color->name()", ["color.name()", "color::name()", "name()"], "逻辑",
                     "color 是指针，通过 -> 调用成员函数 name()，由于 name 是虚函数，实际调用的是 Red 或 Blue 的版本。",
                     "C++ 通过指针调用成员函数用 ->，通过对象或引用调用用 .", 2),
        },
        main=r"""    Red r;
    Blue b;
    Circle c(&r);
    Square s(&b);
    c.draw();
    s.draw();""",
    ),
))

# ------------------------------------------------------------------------------------------------ 组合
PATTERNS.append(Pattern(
    key="composite", sec="T6.10", name="组合", en="Composite",
    diagram=dict(
        boxes={
            "Component": box("Component", ["#name: String"], ["+show(depth: int)"], abstract=True),
            "FileItem": box("FileItem", [], ["+show(depth: int)"]),
            "Folder": box("Folder", ["-children: List"], ["+add(c: Component)", "+show(depth: int)"]),
        },
        rows=[[("Component", 1.5)], [("FileItem", 0.5), ("Folder", 2.5)]],
        edges=[("FileItem", "Component", "gen", ""), ("Folder", "Component", "gen", ""), ("Folder", "Component", "agg", "*")],
    ),
    java=Code(
        scene="文件系统里的文件夹可以包含文件，也可以包含子文件夹，客户端希望用同样的方式对待单个文件和整个文件夹，用组合模式表示这种「部分—整体」的树形结构。",
        src=r"""import java.util.*;

abstract class Component {
    protected String name;
    public Component(String name) { this.name = name; }
    public abstract void show(int depth);
}

class FileItem extends Component {
    public FileItem(String name) { super(name); }
    public void show(int depth) { System.out.println("-".repeat(depth) + name); }
}

class Folder @@1@@ Component {
    private List<@@2@@> children = new ArrayList<>();

    public Folder(String name) { super(name); }
    public void add(Component c) { children.add(c); }

    public void show(int depth) {
        System.out.println("-".repeat(depth) + name);
        for (Component c : children) {
            c.@@3@@(depth + 2);
        }
    }
}""",
        blanks={
            1: Blank("extends", ["implements", "aggregates", "contains"], "关键字",
                     "Folder（组合节点）和 FileItem（叶子节点）都是抽象构件 Component 的子类，类继承类用 extends。",
                     "组合模式中叶子节点和组合节点都继承同一个抽象构件", 1),
            2: Blank("Component", ["FileItem", "Folder", "Object"], "类名",
                     "组合节点的子节点列表保存的是抽象构件 Component，既可以放叶子 FileItem，也可以放别的 Folder；写成 FileItem 就放不下子文件夹了。",
                     "组合节点保存的子节点是抽象构件类型，既可以是叶子也可以是组合节点", 2),
            3: Blank("show", ["display", "add", "draw"], "方法",
                     "组合节点遍历所有子节点并调用它们的 show()；对叶子是直接显示，对 Folder 是递归地显示它的子节点。这就是「统一对待叶子和组合」。",
                     "组合节点通过遍历子节点并调用它们的同名方法实现递归", 2),
        },
        main=r"""        Folder root = new Folder("root");
        root.add(new FileItem("a.txt"));
        Folder sub = new Folder("sub");
        sub.add(new FileItem("b.txt"));
        root.add(sub);
        root.show(0);""",
    ),
    cpp=Code(
        scene="文件系统里的文件夹可以包含文件，也可以包含子文件夹，客户端希望用同样的方式对待单个文件和整个文件夹，用组合模式表示这种「部分—整体」的树形结构。",
        src=r"""class Component {
protected:
    string name;
public:
    Component(string n) : name(n) { }
    virtual void show(int depth) = 0;
    virtual ~Component() { }
};

class FileItem : public Component {
public:
    FileItem(string n) : Component(n) { }
    void show(int depth) { cout << string(depth, '-') << name << endl; }
};

class Folder : public Component {
    vector<@@1@@> children;
public:
    Folder(string n) : Component(n) { }
    void add(Component* c) { children.@@2@@(c); }
    void show(int depth) {
        cout << string(depth, '-') << name << endl;
        for (size_t i = 0; i < children.size(); i++) {
            @@3@@(depth + 2);
        }
    }
};""",
        blanks={
            1: Blank("Component*", ["Component", "FileItem*", "Folder*"], "类名",
                     "子节点列表保存抽象构件的指针 Component*：既能放 FileItem 也能放 Folder，又能多态调用。Component 是抽象类，vector<Component> 不能按值保存。",
                     "组合节点保存的子节点是抽象构件类型，既可以是叶子也可以是组合节点", 3),
            2: Blank("push_back", ["add", "append", "insert"], "方法",
                     "std::vector 在末尾追加元素的方法是 push_back。vector 没有 add 和 append 方法，insert 需要位置参数。",
                     "C++ 的 vector 在末尾追加元素用 push_back", 1),
            3: Blank("children[i]->show", ["children[i].show", "children.show", "show"], "逻辑",
                     "children[i] 是 Component 指针，用 -> 调用虚函数 show，递归地显示子节点。直接写 show 调用的是 Folder 自己，会无限递归。",
                     "组合节点通过遍历子节点并调用它们的同名方法实现递归", 3),
        },
        main=r"""    Folder root("root");
    FileItem a("a.txt");
    root.add(&a);
    Folder sub("sub");
    FileItem b("b.txt");
    sub.add(&b);
    root.add(&sub);
    root.show(0);""",
    ),
))

# ------------------------------------------------------------------------------------------------ 装饰器
PATTERNS.append(Pattern(
    key="decorator", sec="T6.11", name="装饰器", en="Decorator",
    diagram=dict(
        boxes={
            "Beverage": box("Beverage", [], ["+description(): String", "+cost(): double"], stereo="interface"),
            "Espresso": box("Espresso", [], ["+description(): String", "+cost(): double"]),
            "CondimentDecorator": box("CondimentDecorator", ["#beverage: Beverage"], [], abstract=True),
            "Milk": box("Milk", [], ["+description(): String", "+cost(): double"]),
            "Mocha": box("Mocha", [], ["+description(): String", "+cost(): double"]),
        },
        rows=[[("Beverage", 1.5)],
              [("Espresso", 0), ("CondimentDecorator", 3)],
              [("Milk", 2.5), ("Mocha", 3.7)]],
        edges=[("Espresso", "Beverage", "real", ""), ("CondimentDecorator", "Beverage", "real", ""),
               ("CondimentDecorator", "Beverage", "agg", ""),
               ("Milk", "CondimentDecorator", "gen", ""), ("Mocha", "CondimentDecorator", "gen", "")],
    ),
    java=Code(
        scene="咖啡店的饮品可以动态地加料（牛奶、摩卡），每种加料都在原饮品的基础上增加描述和价格，用装饰器模式避免为每种组合都写一个子类。",
        src=r"""interface Beverage {
    String description();
    double cost();
}

class Espresso implements Beverage {
    public String description() { return "Espresso"; }
    public double cost() { return 20; }
}

abstract class CondimentDecorator @@1@@ Beverage {
    protected @@2@@ beverage;
    public CondimentDecorator(Beverage beverage) { this.beverage = beverage; }
}

class Milk extends CondimentDecorator {
    public Milk(Beverage b) { super(b); }
    public String description() { return beverage.description() + ", Milk"; }
    public double cost() { return @@3@@ + 5; }
}

class Mocha extends CondimentDecorator {
    public Mocha(Beverage b) { super(b); }
    public String description() { return beverage.description() + ", Mocha"; }
    public double cost() { return beverage.cost() + 8; }
}""",
        blanks={
            1: Blank("implements", ["extends", "inherits", "decorates"], "关键字",
                     "装饰器要和被装饰的对象有相同的接口，才能互相替换，所以 CondimentDecorator 实现 Beverage，用 implements。",
                     "装饰器和被装饰对象实现同一个抽象构件接口，并且持有一个抽象构件的引用", 1),
            2: Blank("Beverage", ["Espresso", "Milk", "CondimentDecorator"], "类名",
                     "装饰器持有的是抽象构件 Beverage 的引用：它可能是 Espresso，也可能是另一个已经被装饰过的 Milk，这样才能层层嵌套。",
                     "装饰器和被装饰对象实现同一个抽象构件接口，并且持有一个抽象构件的引用", 2),
            3: Blank("beverage.cost()", ["cost()", "super.cost()", "Beverage.cost()"], "逻辑",
                     "装饰器的价格 = 被装饰对象的价格 + 自己的价格，通过持有的 beverage 引用委托调用。直接写 cost() 会无限递归；super.cost() 指向的是抽象方法，不能调用。",
                     "装饰器在自己的方法里先调用被装饰对象的方法，再附加自己的功能", 3),
        },
        main=r"""        Beverage b = new Mocha(new Milk(new Espresso()));
        System.out.println(b.description() + " = " + b.cost());""",
    ),
    cpp=Code(
        scene="咖啡店的饮品可以动态地加料（牛奶、摩卡），每种加料都在原饮品的基础上增加描述和价格，用装饰器模式避免为每种组合都写一个子类。",
        src=r"""class Beverage {
public:
    virtual string description() = 0;
    virtual double cost() = 0;
    virtual ~Beverage() { }
};

class Espresso : public Beverage {
public:
    string description() { return "Espresso"; }
    double cost() { return 20; }
};

class CondimentDecorator : public Beverage {
protected:
    @@1@@ beverage;
public:
    CondimentDecorator(Beverage* b) : beverage(b) { }
    virtual ~CondimentDecorator() { delete beverage; }
};

class Milk : public CondimentDecorator {
public:
    Milk(Beverage* b) : @@2@@(b) { }
    string description() { return beverage->description() + ", Milk"; }
    double cost() { return @@3@@ + 5; }
};

class Mocha : public CondimentDecorator {
public:
    Mocha(Beverage* b) : CondimentDecorator(b) { }
    string description() { return beverage->description() + ", Mocha"; }
    double cost() { return beverage->cost() + 8; }
};""",
        blanks={
            1: Blank("Beverage*", ["Beverage", "Espresso*", "Milk*"], "类名",
                     "装饰器持有抽象构件的指针 Beverage*：既能指向 Espresso，也能指向另一个装饰器，才能层层嵌套。Beverage 是抽象类，不能按值定义成员。",
                     "装饰器和被装饰对象实现同一个抽象构件接口，并且持有一个抽象构件的引用", 2),
            2: Blank("CondimentDecorator", ["Beverage", "beverage", "Milk"], "类名",
                     "Milk 在构造函数的初始化列表里调用直接父类 CondimentDecorator 的构造函数，把被装饰对象传上去；不能越过父类去初始化间接基类 Beverage。",
                     "C++ 的子类在构造函数的初始化列表里调用基类的构造函数，写法是 基类名(参数)", 3),
            3: Blank("beverage->cost()", ["beverage.cost()", "cost()", "Beverage::cost()"], "逻辑",
                     "价格 = 被装饰对象的价格 + 自己的价格，通过指针 -> 调用被装饰对象的 cost()。直接写 cost() 会无限递归；Beverage::cost() 是纯虚函数，不能这样调用。",
                     "装饰器在自己的方法里先调用被装饰对象的方法，再附加自己的功能", 3),
        },
        main=r"""    Beverage* b = new Mocha(new Milk(new Espresso()));
    cout << b->description() << " = " << b->cost() << endl;
    delete b;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 外观
PATTERNS.append(Pattern(
    key="facade", sec="T6.12", name="外观", en="Facade",
    diagram=dict(
        boxes={
            "Client": box("Client", [], ["+main()"]),
            "HomeTheater": box("HomeTheater", ["-projector: Projector", "-sound: Sound", "-player: Player"], ["+watchMovie()"]),
            "Projector": box("Projector", [], ["+on()"]),
            "Sound": box("Sound", [], ["+on()"]),
            "Player": box("Player", [], ["+play()"]),
        },
        rows=[[("Client", 0), ("HomeTheater", 1.5)],
              [("Projector", 0.5), ("Sound", 1.5), ("Player", 2.5)]],
        edges=[("Client", "HomeTheater", "assoc", ""), ("HomeTheater", "Projector", "assoc", ""),
               ("HomeTheater", "Sound", "assoc", ""), ("HomeTheater", "Player", "assoc", "")],
    ),
    java=Code(
        scene="家庭影院由投影仪、音响、播放器等多个子系统组成，看电影要依次操作它们，用外观模式提供一个统一的高层接口 watchMovie()，客户端不用了解子系统。",
        src=r"""class Projector {
    public void on() { System.out.println("projector on"); }
}

class Sound {
    public void on() { System.out.println("sound on"); }
}

class Player {
    public void play() { System.out.println("movie playing"); }
}

class HomeTheater {
    private @@1@@ projector = new Projector();
    private Sound sound = new Sound();
    private Player player = new Player();

    public void watchMovie() {
        projector.on();
        sound.@@2@@();
        player.@@3@@();
    }
}""",
        blanks={
            1: Blank("Projector", ["Sound", "Player", "HomeTheater"], "类名",
                     "外观类持有各个子系统对象，由它负责创建并协调子系统；客户端只和 HomeTheater 打交道。",
                     "外观模式为一组子系统提供统一的高层接口，外观类持有各个子系统对象", 1),
            2: Blank("on", ["play", "start", "off"], "方法",
                     "外观的 watchMovie() 按顺序调用子系统的方法：音响是 on()，播放器才是 play()。",
                     "外观类的方法按固定顺序调用各个子系统的方法，客户端不需要知道细节", 1),
            3: Blank("play", ["on", "start", "run"], "方法",
                     "外观按顺序调用子系统的方法：播放器的方法是 play()，它没有 on() 方法。",
                     "外观类的方法按固定顺序调用各个子系统的方法，客户端不需要知道细节", 1),
        },
        main=r"""        new HomeTheater().watchMovie();""",
    ),
    cpp=Code(
        scene="家庭影院由投影仪、音响、播放器等多个子系统组成，看电影要依次操作它们，用外观模式提供一个统一的高层接口 watchMovie()，客户端不用了解子系统。",
        src=r"""class Projector {
public:
    void on() { cout << "projector on" << endl; }
};

class Sound {
public:
    void on() { cout << "sound on" << endl; }
};

class Player {
public:
    void play() { cout << "movie playing" << endl; }
};

class HomeTheater {
    Projector* projector;
    Sound* sound;
    Player* player;
public:
    HomeTheater() {
        projector = new Projector();
        sound = @@1@@;
        player = new Player();
    }
    ~HomeTheater() { delete projector; delete sound; delete player; }

    void watchMovie() {
        projector->on();
        @@2@@;
        player->play();
    }
};""",
        blanks={
            1: Blank("new Sound()", ["Sound()", "new Projector()", "Sound*"], "逻辑",
                     "外观类在构造函数里创建各个子系统对象；成员 sound 是 Sound 指针，要用 new Sound() 创建并赋值。",
                     "外观模式为一组子系统提供统一的高层接口，外观类持有各个子系统对象", 2),
            2: Blank("sound->on()", ["sound.on()", "sound::on()", "Sound.on()"], "逻辑",
                     "sound 是指针，用 -> 调用成员函数；. 用于对象或引用，:: 用于静态成员和作用域。",
                     "C++ 通过指针调用成员函数用 ->，通过对象或引用调用用 .", 2),
        },
        main=r"""    HomeTheater h;
    h.watchMovie();""",
    ),
))

# ------------------------------------------------------------------------------------------------ 代理
PATTERNS.append(Pattern(
    key="proxy", sec="T6.13", name="代理", en="Proxy",
    diagram=dict(
        boxes={
            "Client": box("Client", [], ["+main()"]),
            "Image": box("Image", [], ["+display()"], stereo="interface"),
            "ProxyImage": box("ProxyImage", ["-file: String", "-real: RealImage"], ["+display()"]),
            "RealImage": box("RealImage", ["-file: String"], ["+display()"]),
        },
        rows=[[("Client", 0), ("Image", 1.5)], [("ProxyImage", 0.75), ("RealImage", 2.25)]],
        edges=[("Client", "Image", "assoc", ""), ("ProxyImage", "Image", "real", ""), ("RealImage", "Image", "real", ""),
               ("ProxyImage", "RealImage", "assoc", "")],
    ),
    java=Code(
        scene="加载大图片很耗时，只有真正显示时才需要加载，用（虚拟）代理模式：代理对象和真实图片对象有相同的接口，第一次显示时才创建真实对象。",
        src=r"""interface Image {
    void display();
}

class RealImage implements Image {
    private String file;
    public RealImage(String file) {
        this.file = file;
        System.out.println("loading " + file);
    }
    public void display() { System.out.println("display " + file); }
}

class ProxyImage @@1@@ Image {
    private String file;
    private RealImage real;

    public ProxyImage(String file) { this.file = file; }

    public void display() {
        if (real == null) {
            real = @@2@@;
        }
        real.@@3@@();
    }
}""",
        blanks={
            1: Blank("implements", ["extends", "proxies", "inherits"], "关键字",
                     "代理和真实对象实现同一个接口 Image，客户端才能不加区别地使用它们，类实现接口用 implements。",
                     "代理类和真实主题实现同一个抽象主题接口，代理持有真实主题的引用", 1),
            2: Blank("new RealImage(file)", ["new ProxyImage(file)", "new Image(file)", "this"], "逻辑",
                     "代理在第一次使用时才创建真实对象，这就是延迟加载。ProxyImage 类型不能赋给 RealImage 变量；Image 是接口，不能 new。",
                     "虚拟代理在第一次使用时才创建真实对象，之后复用同一个对象", 2),
            3: Blank("display", ["load", "show", "paint"], "方法",
                     "代理把请求转发给真实对象的同名方法 display()；转发之前或之后还可以增加控制逻辑（如延迟加载、权限检查）。",
                     "代理类把客户端的请求转发给真实主题，并在转发前后做控制", 1),
        },
        main=r"""        Image img = new ProxyImage("a.png");
        System.out.println("created");
        img.display();
        img.display();""",
    ),
    cpp=Code(
        scene="加载大图片很耗时，只有真正显示时才需要加载，用（虚拟）代理模式：代理对象和真实图片对象有相同的接口，第一次显示时才创建真实对象。",
        src=r"""class Image {
public:
    virtual void display() = 0;
    virtual ~Image() { }
};

class RealImage : public Image {
    string file;
public:
    RealImage(string f) : file(f) { cout << "loading " << f << endl; }
    void display() { cout << "display " << file << endl; }
};

class ProxyImage : public Image {
    string file;
    @@1@@* real;
public:
    ProxyImage(string f) : file(f), real(@@2@@) { }
    void display() {
        if (real == nullptr) {
            real = new RealImage(file);
        }
        real->display();
    }
    ~ProxyImage() { @@3@@ real; }
};""",
        blanks={
            1: Blank("RealImage", ["ProxyImage", "string", "Client"], "类名",
                     "代理持有真实主题的指针，类型是 RealImage*，用来在需要时指向 new 出来的真实对象。ProxyImage* 与 new RealImage 的类型不匹配。",
                     "代理类和真实主题实现同一个抽象主题接口，代理持有真实主题的引用", 2),
            2: Blank("nullptr", ["new RealImage(f)", "RealImage(f)", "f"], "逻辑",
                     "代理对象创建时并不创建真实对象，指针先初始化为空，等第一次 display() 时才 new。写成 new RealImage(f) 就变成了立即加载，失去了代理的意义。",
                     "虚拟代理在第一次使用时才创建真实对象，之后复用同一个对象", 2),
            3: Blank("delete", ["free", "release", "remove"], "关键字",
                     "用 new 创建的对象要用 delete 释放；free 只能释放 malloc 分配的内存，C++ 里没有 release 和 remove 这样的关键字。",
                     "C++ 里用 new 创建的对象要用 delete 释放", 2),
        },
        main=r"""    Image* img = new ProxyImage("a.png");
    cout << "created" << endl;
    img->display();
    img->display();
    delete img;""",
    ),
))
