"""创建型模式：单例、工厂方法、抽象工厂、建造者、原型。"""
from common import Blank, Code, Pattern, box

PATTERNS = []

# ------------------------------------------------------------------------------------------------ 单例
PATTERNS.append(Pattern(
    key="singleton", sec="T6.3", name="单例", en="Singleton",
    diagram=dict(
        boxes={"Config": box("Config", ["-instance: Config"], ["-Config()", "+getInstance(): Config"])},
        rows=[[("Config", 0)]],
        edges=[],
    ),
    java=Code(
        scene="某系统的全局配置对象 Config 只允许有一个实例，采用懒汉式。",
        src=r"""class Config {
    private static Config instance;

    @@1@@ Config() { }

    public @@2@@ Config getInstance() {
        if (instance == null) {
            instance = @@3@@;
        }
        return instance;
    }
}""",
        blanks={
            1: Blank("private", ["public", "protected", "abstract"], "关键字",
                     "单例要禁止外部创建对象，构造函数必须是私有的，外部只能通过 getInstance() 取得唯一实例。构造函数写成 public 就失去了「只有一个实例」的保证。",
                     "构造函数必须是私有的，外部不能用 new 创建对象", 1),
            2: Blank("static", ["final", "abstract", "volatile"], "关键字",
                     "调用 getInstance() 时还没有对象，所以它必须是静态方法，通过类名 Config.getInstance() 调用；静态方法只能访问静态成员，因此 instance 也是 static。",
                     "获取实例的方法必须是静态方法，因为调用它时还没有对象", 2),
            3: Blank("new Config()", ["Config.getInstance()", "this", "Config"], "逻辑",
                     "懒汉式在第一次调用时才创建实例：instance 为 null 就 new 一个，之后直接返回。写成 Config.getInstance() 会无限递归；静态方法里没有 this。",
                     "第一次调用时才用 new 创建唯一的实例，之后直接返回已有的实例", 2),
        },
        main=r"""        Config a = Config.getInstance();
        Config b = Config.getInstance();
        System.out.println(a == b);""",
    ),
    cpp=Code(
        scene="某系统的全局配置对象 Config 只允许有一个实例，采用懒汉式。",
        src=r"""class Config {
private:
    @@1@@ Config* instance;
    Config() { }
public:
    static Config* getInstance() {
        if (instance == nullptr) {
            instance = @@2@@;
        }
        return instance;
    }
};

Config* @@3@@ = nullptr;""",
        blanks={
            1: Blank("static", ["const", "virtual", "friend"], "关键字",
                     "指向唯一实例的指针由所有对象（以及静态的 getInstance）共享，必须是静态成员变量；静态成员函数只能访问静态成员。",
                     "C++ 里用 static 声明类的静态成员，指向唯一实例的指针也是静态成员", 2),
            2: Blank("new Config()", ["Config()", "this", "&Config"], "逻辑",
                     "实例要放在堆上才能一直存在，所以用 new 创建并把地址赋给 instance。Config() 得到的是临时对象，不是指针；静态函数里没有 this。",
                     "第一次调用时才用 new 创建唯一的实例，之后直接返回已有的实例", 2),
            3: Blank("Config::instance", ["Config.instance", "Config->instance", "instance"], "类名",
                     "C++ 的静态成员变量必须在类外定义并初始化，写成「类型 类名::变量名 = 初值;」，作用域运算符是 ::，不是 . 或 ->。",
                     "C++ 的静态成员变量必须在类外定义并初始化，写成「类型 类名::变量名 = 初值;」", 3),
        },
        main=r"""    Config* a = Config::getInstance();
    Config* b = Config::getInstance();
    cout << (a == b) << endl;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 工厂方法
PATTERNS.append(Pattern(
    key="factory-method", sec="T6.4", name="工厂方法", en="Factory Method",
    diagram=dict(
        boxes={
            "LoggerFactory": box("LoggerFactory", [], ["+createLogger(): Logger", "+write(msg: String)"], abstract=True),
            "Logger": box("Logger", [], ["+log(msg: String)"], stereo="interface"),
            "FileLoggerFactory": box("FileLoggerFactory", [], ["+createLogger(): Logger"]),
            "ConsoleLoggerFactory": box("ConsoleLoggerFactory", [], ["+createLogger(): Logger"]),
            "FileLogger": box("FileLogger", [], ["+log(msg: String)"]),
            "ConsoleLogger": box("ConsoleLogger", [], ["+log(msg: String)"]),
        },
        rows=[[("LoggerFactory", 0.5), ("Logger", 2.5)],
              [("FileLoggerFactory", 0), ("ConsoleLoggerFactory", 1), ("FileLogger", 2), ("ConsoleLogger", 3)]],
        edges=[("FileLoggerFactory", "LoggerFactory", "gen", ""), ("ConsoleLoggerFactory", "LoggerFactory", "gen", ""),
               ("FileLogger", "Logger", "real", ""), ("ConsoleLogger", "Logger", "real", ""),
               ("LoggerFactory", "Logger", "dep", "")],
    ),
    java=Code(
        scene="日志系统需要按需创建不同的日志记录器（写文件、写控制台），用工厂方法让子类决定创建哪种记录器。",
        src=r"""interface Logger {
    void log(String msg);
}

class FileLogger @@1@@ Logger {
    public void log(String msg) { System.out.println("[file] " + msg); }
}

class ConsoleLogger implements Logger {
    public void log(String msg) { System.out.println("[console] " + msg); }
}

abstract class LoggerFactory {
    public abstract @@2@@ createLogger();

    public void write(String msg) {
        Logger logger = @@3@@;
        logger.log(msg);
    }
}

class FileLoggerFactory extends LoggerFactory {
    public Logger createLogger() { return new FileLogger(); }
}

class ConsoleLoggerFactory extends LoggerFactory {
    public Logger createLogger() { return new ConsoleLogger(); }
}""",
        blanks={
            1: Blank("implements", ["extends", "inherits", "interface"], "关键字",
                     "Logger 是接口，类实现接口用 implements；extends 用于类继承类，或者接口继承接口。",
                     "Java 中类实现接口用 implements，类继承类用 extends", 1),
            2: Blank("Logger", ["FileLogger", "LoggerFactory", "void"], "类名",
                     "工厂方法的返回类型是抽象产品 Logger，而不是某个具体产品，这样子类才能决定创建哪一种记录器，调用方也只依赖抽象。",
                     "工厂方法的返回类型是抽象产品，子类重写它并返回具体产品", 2),
            3: Blank("createLogger()", ["new Logger()", "new FileLogger()", "LoggerFactory.createLogger()"], "方法",
                     "write() 是父类里的通用流程，它调用工厂方法 createLogger() 取得产品，具体创建哪个类由子类重写决定。写 new FileLogger() 就把具体产品写死了；接口不能 new。",
                     "抽象工厂里的普通方法调用工厂方法获得产品，不关心具体产品是什么", 3),
        },
        main=r"""        LoggerFactory f = new FileLoggerFactory();
        f.write("hello");
        f = new ConsoleLoggerFactory();
        f.write("hello");""",
    ),
    cpp=Code(
        scene="日志系统需要按需创建不同的日志记录器（写文件、写控制台），用工厂方法让子类决定创建哪种记录器。",
        src=r"""class Logger {
public:
    @@1@@ void log(const string& msg) = 0;
    virtual ~Logger() { }
};

class FileLogger : public Logger {
public:
    void log(const string& msg) { cout << "[file] " << msg << endl; }
};

class ConsoleLogger : public Logger {
public:
    void log(const string& msg) { cout << "[console] " << msg << endl; }
};

class LoggerFactory {
public:
    virtual @@2@@ createLogger() = 0;
    void write(const string& msg) {
        Logger* logger = createLogger();
        logger->log(msg);
        delete logger;
    }
    virtual ~LoggerFactory() { }
};

class FileLoggerFactory : public LoggerFactory {
public:
    Logger* createLogger() { return @@3@@; }
};

class ConsoleLoggerFactory : public LoggerFactory {
public:
    Logger* createLogger() { return new ConsoleLogger(); }
};""",
        blanks={
            1: Blank("virtual", ["static", "abstract", "friend"], "关键字",
                     "C++ 没有 interface 和 abstract 关键字，抽象类靠纯虚函数实现：virtual 返回类型 函数名(参数) = 0;。没有 virtual 就不能写 = 0，也不能多态调用。",
                     "C++ 里抽象类通过纯虚函数实现，写法是 virtual 返回类型 函数名() = 0", 2),
            2: Blank("Logger*", ["Logger", "Logger&", "FileLogger*"], "类名",
                     "工厂方法返回抽象产品的指针 Logger*，多态要靠指针（或引用）。返回 Logger 值类型无法返回抽象类的对象；返回 FileLogger* 则把具体产品写死了。",
                     "工厂方法的返回类型是抽象产品，子类重写它并返回具体产品", 3),
            3: Blank("new FileLogger()", ["new ConsoleLogger()", "new Logger()", "FileLogger()"], "逻辑",
                     "具体工厂 FileLoggerFactory 负责创建对应的具体产品 FileLogger，用 new 返回其指针；Logger 是抽象类不能实例化，ConsoleLogger 属于另一个工厂。",
                     "具体工厂重写工厂方法，返回对应的具体产品对象", 2),
        },
        main=r"""    LoggerFactory* f = new FileLoggerFactory();
    f->write("hello");
    delete f;
    f = new ConsoleLoggerFactory();
    f->write("hello");
    delete f;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 抽象工厂
PATTERNS.append(Pattern(
    key="abstract-factory", sec="T6.5", name="抽象工厂", en="Abstract Factory",
    diagram=dict(
        boxes={
            "GUIFactory": box("GUIFactory", [], ["+createButton()", "+createTextBox()"], stereo="interface"),
            "WinFactory": box("WinFactory", [], ["+createButton()", "+createTextBox()"]),
            "MacFactory": box("MacFactory", [], ["+createButton()", "+createTextBox()"]),
            "Button": box("Button", [], ["+paint()"], stereo="interface"),
            "TextBox": box("TextBox", [], ["+paint()"], stereo="interface"),
            "WinButton": box("WinButton", [], ["+paint()"]),
            "MacButton": box("MacButton", [], ["+paint()"]),
            "WinTextBox": box("WinTextBox", [], ["+paint()"]),
            "MacTextBox": box("MacTextBox", [], ["+paint()"]),
        },
        rows=[[("GUIFactory", 0.5), ("Button", 3)],
              [("WinFactory", 0), ("MacFactory", 1), ("WinButton", 2.5), ("MacButton", 3.5)],
              [("TextBox", 3)],
              [("WinTextBox", 2.5), ("MacTextBox", 3.5)]],
        edges=[("WinFactory", "GUIFactory", "real", ""), ("MacFactory", "GUIFactory", "real", ""),
               ("WinButton", "Button", "real", ""), ("MacButton", "Button", "real", ""),
               ("WinTextBox", "TextBox", "real", ""), ("MacTextBox", "TextBox", "real", "")],
    ),
    java=Code(
        scene="界面库要提供 Windows 和 Mac 两种风格的按钮和文本框，同一种风格的组件必须配套使用，用抽象工厂创建「产品族」。",
        src=r"""interface Button { void paint(); }
interface TextBox { void paint(); }

class WinButton implements Button { public void paint() { System.out.println("win button"); } }
class WinTextBox implements TextBox { public void paint() { System.out.println("win textbox"); } }
class MacButton implements Button { public void paint() { System.out.println("mac button"); } }
class MacTextBox implements TextBox { public void paint() { System.out.println("mac textbox"); } }

interface GUIFactory {
    @@1@@ createButton();
    TextBox createTextBox();
}

class WinFactory @@2@@ GUIFactory {
    public Button createButton() { return new WinButton(); }
    public TextBox createTextBox() { return new WinTextBox(); }
}

class MacFactory implements GUIFactory {
    public Button createButton() { return new MacButton(); }
    public TextBox createTextBox() { return @@3@@; }
}

class Client {
    private Button button;
    private TextBox textBox;
    public Client(@@4@@ factory) {
        button = factory.createButton();
        textBox = factory.createTextBox();
    }
    public void show() { button.paint(); textBox.paint(); }
}""",
        blanks={
            1: Blank("Button", ["WinButton", "GUIFactory", "void"], "类名",
                     "抽象工厂的每个创建方法返回一种抽象产品：createButton() 返回 Button。返回具体产品 WinButton 就只能创建 Windows 风格的按钮了。",
                     "抽象工厂为每一种抽象产品声明一个创建方法，返回类型是抽象产品", 1),
            2: Blank("implements", ["extends", "implement", "inherits"], "关键字",
                     "GUIFactory 是接口，具体工厂实现它，用 implements。",
                     "Java 中类实现接口用 implements，类继承类用 extends", 1),
            3: Blank("new MacTextBox()", ["new WinTextBox()", "new MacButton()", "new TextBox()"], "逻辑",
                     "具体工厂创建自己这个系列的产品：MacFactory 的 createTextBox() 返回 Mac 风格的文本框 MacTextBox。new WinTextBox() 会混入 Windows 风格，破坏产品族的一致性。",
                     "一个具体工厂创建同一个产品族的全部产品，保证风格一致", 3),
            4: Blank("GUIFactory", ["WinFactory", "Button", "Client"], "类名",
                     "客户端只依赖抽象工厂 GUIFactory，传入 WinFactory 或 MacFactory 都能工作，换产品族不用改客户端代码。",
                     "客户端只依赖抽象工厂和抽象产品，不依赖具体类", 2),
        },
        main=r"""        new Client(new WinFactory()).show();
        new Client(new MacFactory()).show();""",
    ),
    cpp=Code(
        scene="界面库要提供 Windows 和 Mac 两种风格的按钮和文本框，同一种风格的组件必须配套使用，用抽象工厂创建「产品族」。",
        src=r"""class Button {
public:
    virtual void paint() = 0;
    virtual ~Button() { }
};
class TextBox {
public:
    virtual void paint() = 0;
    virtual ~TextBox() { }
};

class WinButton : public Button { public: void paint() { cout << "win button" << endl; } };
class WinTextBox : public TextBox { public: void paint() { cout << "win textbox" << endl; } };
class MacButton : public Button { public: void paint() { cout << "mac button" << endl; } };
class MacTextBox : public TextBox { public: void paint() { cout << "mac textbox" << endl; } };

class GUIFactory {
public:
    virtual Button* createButton() = @@1@@;
    virtual TextBox* createTextBox() = 0;
    virtual ~GUIFactory() { }
};

class WinFactory : public GUIFactory {
public:
    Button* createButton() { return new WinButton(); }
    TextBox* createTextBox() { return @@2@@; }
};

class MacFactory : public GUIFactory {
public:
    Button* createButton() { return new MacButton(); }
    TextBox* createTextBox() { return new MacTextBox(); }
};

class Client {
    Button* button;
    TextBox* textBox;
public:
    Client(@@3@@ factory) {
        button = factory->createButton();
        textBox = factory->createTextBox();
    }
    void show() { button->paint(); textBox->paint(); }
    ~Client() { delete button; delete textBox; }
};""",
        blanks={
            1: Blank("0", ["1", "NULL", "void"], "关键字",
                     "纯虚函数的写法是在声明后加 = 0，含有纯虚函数的类是抽象类，不能实例化。",
                     "C++ 里抽象类通过纯虚函数实现，写法是 virtual 返回类型 函数名() = 0", 1),
            2: Blank("new WinTextBox()", ["new MacTextBox()", "new WinButton()", "new TextBox()"], "逻辑",
                     "WinFactory 只创建 Windows 风格的产品，createTextBox() 返回 WinTextBox 的指针。TextBox 是抽象类，不能 new。",
                     "一个具体工厂创建同一个产品族的全部产品，保证风格一致", 2),
            3: Blank("GUIFactory*", ["GUIFactory", "WinFactory*", "Client*"], "类名",
                     "客户端只依赖抽象工厂，用基类指针 GUIFactory* 接收具体工厂对象才能多态；GUIFactory 值类型是抽象类，不能作为参数按值传递。",
                     "客户端只依赖抽象工厂和抽象产品，不依赖具体类", 3),
        },
        main=r"""    WinFactory wf;
    MacFactory mf;
    Client c1(&wf);
    c1.show();
    Client c2(&mf);
    c2.show();""",
    ),
))

# ------------------------------------------------------------------------------------------------ 建造者
PATTERNS.append(Pattern(
    key="builder", sec="T6.6", name="建造者", en="Builder",
    diagram=dict(
        boxes={
            "Director": box("Director", ["-builder: Builder"], ["+construct(): Computer"]),
            "Builder": box("Builder", ["#computer: Computer"], ["+buildCpu()", "+buildMemory()", "+getResult(): Computer"], abstract=True),
            "GamingBuilder": box("GamingBuilder", [], ["+buildCpu()", "+buildMemory()"]),
            "OfficeBuilder": box("OfficeBuilder", [], ["+buildCpu()", "+buildMemory()"]),
            "Computer": box("Computer", ["cpu: String", "memory: String"], []),
        },
        rows=[[("Director", 0), ("Builder", 1.5), ("Computer", 3)],
              [("GamingBuilder", 1), ("OfficeBuilder", 2)]],
        edges=[("Director", "Builder", "agg", ""), ("GamingBuilder", "Builder", "gen", ""), ("OfficeBuilder", "Builder", "gen", ""),
               ("Builder", "Computer", "assoc", "")],
    ),
    java=Code(
        scene="组装电脑要按固定的步骤（先装 CPU，再装内存），但不同配置的零件不同，用建造者把「组装步骤」和「具体零件」分开。",
        src=r"""class Computer {
    String cpu;
    String memory;
    public String toString() { return cpu + "/" + memory; }
}

abstract class Builder {
    protected Computer computer = new Computer();
    public abstract void buildCpu();
    public abstract void buildMemory();
    public Computer getResult() { return computer; }
}

class GamingBuilder @@1@@ Builder {
    public void buildCpu() { computer.cpu = "i9"; }
    public void buildMemory() { computer.memory = "32G"; }
}

class OfficeBuilder extends Builder {
    public void buildCpu() { computer.cpu = "i3"; }
    public void buildMemory() { computer.memory = "8G"; }
}

class Director {
    private Builder builder;
    public Director(@@2@@ builder) { this.builder = builder; }
    public Computer construct() {
        builder.@@3@@();
        builder.buildMemory();
        return builder.getResult();
    }
}""",
        blanks={
            1: Blank("extends", ["implements", "inherits", "instanceof"], "关键字",
                     "Builder 是抽象类，具体建造者继承它，用 extends；implements 只用于实现接口。",
                     "Java 中类实现接口用 implements，类继承类用 extends", 1),
            2: Blank("Builder", ["GamingBuilder", "Computer", "Director"], "类名",
                     "指挥者只依赖抽象建造者 Builder，这样传入 GamingBuilder 或 OfficeBuilder 都能用同一套构建过程得到不同的产品。",
                     "指挥者只依赖抽象建造者，构建的顺序由指挥者控制", 2),
            3: Blank("buildCpu", ["getResult", "construct", "build"], "方法",
                     "指挥者按固定的顺序调用建造者的步骤方法：先 buildCpu()，再 buildMemory()，最后用 getResult() 取出产品。",
                     "指挥者按固定的顺序调用建造者的各个步骤，最后取得产品", 2),
        },
        main=r"""        Director d = new Director(new GamingBuilder());
        System.out.println(d.construct());
        d = new Director(new OfficeBuilder());
        System.out.println(d.construct());""",
    ),
    cpp=Code(
        scene="组装电脑要按固定的步骤（先装 CPU，再装内存），但不同配置的零件不同，用建造者把「组装步骤」和「具体零件」分开。",
        src=r"""class Computer {
public:
    string cpu, memory;
    string str() { return cpu + "/" + memory; }
};

class Builder {
protected:
    Computer* computer;
public:
    Builder() { computer = new Computer(); }
    virtual void buildCpu() = 0;
    virtual void buildMemory() = 0;
    Computer* getResult() { return computer; }
    virtual ~Builder() { delete computer; }
};

class GamingBuilder : @@1@@ Builder {
public:
    void buildCpu() { computer->cpu = "i9"; }
    void buildMemory() { computer->memory = "32G"; }
};

class OfficeBuilder : public Builder {
public:
    void buildCpu() { computer->cpu = "i3"; }
    void buildMemory() { computer->memory = "8G"; }
};

class Director {
    Builder* builder;
public:
    Director(Builder* b) { builder = b; }
    Computer* construct() {
        builder->@@2@@();
        builder->buildMemory();
        return builder->@@3@@();
    }
};""",
        blanks={
            1: Blank("public", ["extends", "implements", "class"], "关键字",
                     "C++ 的继承写成「class 子类 : public 基类」。extends 和 implements 是 Java 的关键字，C++ 里没有。",
                     "C++ 的继承写成 class 子类 : public 基类", 1),
            2: Blank("buildCpu", ["getResult", "construct", "build"], "方法",
                     "指挥者按固定顺序调用步骤方法：先 buildCpu()，再 buildMemory()，最后 getResult()。",
                     "指挥者按固定的顺序调用建造者的各个步骤，最后取得产品", 2),
            3: Blank("getResult", ["construct", "buildCpu", "getComputer"], "方法",
                     "步骤做完后，指挥者调用建造者的 getResult() 取得建造好的产品；注意是用指针 -> 调用。",
                     "指挥者按固定的顺序调用建造者的各个步骤，最后取得产品", 2),
        },
        main=r"""    GamingBuilder g;
    Director d1(&g);
    cout << d1.construct()->str() << endl;
    OfficeBuilder o;
    Director d2(&o);
    cout << d2.construct()->str() << endl;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 原型
PATTERNS.append(Pattern(
    key="prototype", sec="T6.7", name="原型", en="Prototype",
    diagram=dict(
        boxes={
            "Client": box("Client", [], ["+main()"]),
            "Cloneable": box("Cloneable", [], ["+clone(): Object"], stereo="interface"),
            "Resume": box("Resume", ["-name: String", "-company: String"], ["+setCompany(c: String)", "+clone(): Resume"]),
        },
        rows=[[("Client", 0), ("Cloneable", 1.5)], [("Resume", 1.5)]],
        edges=[("Resume", "Cloneable", "real", ""), ("Client", "Resume", "dep", "")],
    ),
    diagram_cpp=dict(
        boxes={
            "Client": box("Client", [], ["+main()"]),
            "Prototype": box("Prototype", [], ["+clone(): Prototype"], stereo="interface"),
            "Resume": box("Resume", ["-name: string", "-company: string"], ["+setCompany(c)", "+clone(): Prototype"]),
        },
        rows=[[("Client", 0), ("Prototype", 1.5)], [("Resume", 1.5)]],
        edges=[("Resume", "Prototype", "real", ""), ("Client", "Resume", "dep", "")],
    ),
    java=Code(
        scene="求职者要向多家公司投递简历，每份简历只有「投递公司」不同，用原型模式复制已有的简历对象。",
        src=r"""class Resume @@1@@ Cloneable {
    private String name;
    private String company;

    public Resume(String name) { this.name = name; }
    public void setCompany(String company) { this.company = company; }

    public @@2@@ clone() {
        try {
            return (Resume) @@3@@;
        } catch (CloneNotSupportedException e) {
            return null;
        }
    }

    public String toString() { return name + "@" + company; }
}""",
        blanks={
            1: Blank("implements", ["extends", "throws", "abstract"], "关键字",
                     "Cloneable 是标记接口，类要支持克隆就必须实现它，用 implements。否则调用 Object.clone() 会抛出 CloneNotSupportedException。",
                     "Java 的原型模式要实现 Cloneable 接口，并调用 Object 的 clone 方法完成复制", 2),
            2: Blank("Resume", ["Object", "void", "Cloneable"], "类名",
                     "重写 clone() 时可以把返回类型改成本类 Resume，这样调用者不用强制转换。返回 void 则得不到副本。",
                     "原型的克隆方法返回的是原对象的副本", 3),
            3: Blank("super.clone()", ["this.clone()", "new Resume(name)", "this"], "逻辑",
                     "super.clone() 调用 Object 的 clone()，复制出一个字段值相同的新对象，再转换成 Resume。this.clone() 会无限递归；new Resume(name) 只复制了姓名，丢了 company；this 返回的是原对象本身，不是副本。",
                     "Java 的原型模式要实现 Cloneable 接口，并调用 Object 的 clone 方法完成复制", 3),
        },
        main=r"""        Resume r1 = new Resume("Tom");
        r1.setCompany("A");
        Resume r2 = r1.clone();
        System.out.println(r1 + " " + r2);
        r2.setCompany("B");
        System.out.println(r1 + " " + r2);""",
    ),
    cpp=Code(
        scene="求职者要向多家公司投递简历，每份简历只有「投递公司」不同，用原型模式复制已有的简历对象。",
        src=r"""class Prototype {
public:
    virtual @@1@@* clone() = 0;
    virtual ~Prototype() { }
};

class Resume : @@2@@ Prototype {
    string name;
    string company;
public:
    Resume(string n) : name(n) { }
    void setCompany(string c) { company = c; }
    Prototype* clone() { return new Resume(@@3@@); }
    string str() { return name + "@" + company; }
};""",
        blanks={
            1: Blank("Prototype", ["Resume", "void", "Object"], "类名",
                     "原型的克隆方法返回抽象原型的指针 Prototype*，调用者不必知道具体类型。此处 Resume 还没有声明，void 则得不到副本，C++ 里也没有 Object 类。",
                     "原型的克隆方法返回的是原对象的副本", 2),
            2: Blank("public", ["extends", "implements", "friend"], "关键字",
                     "Resume 继承抽象原型 Prototype，写成「: public Prototype」。",
                     "C++ 的继承写成 class 子类 : public 基类", 1),
            3: Blank("*this", ["this", "name", "&this"], "逻辑",
                     "C++ 用拷贝构造函数复制对象：new Resume(*this) 用当前对象（*this）初始化新对象，字段全部复制。this 是指针，不能当作 Resume 对象；只传 name 会丢掉 company。",
                     "C++ 的原型模式用拷贝构造函数实现克隆，写成 new 类名(*this)", 3),
        },
        main=r"""    Resume r1("Tom");
    r1.setCompany("A");
    Resume* r2 = (Resume*) r1.clone();
    cout << r1.str() << " " << r2->str() << endl;
    r2->setCompany("B");
    cout << r1.str() << " " << r2->str() << endl;
    delete r2;""",
    ),
))
