"""T6.1 Java / C++ 的写法对照：不依赖具体模式的语法要点。"""

JAVA_SECTION = "T6.1 Java 的类、接口、继承与多态写法"
CPP_SECTION = "T6.1 C++ 的类、虚函数与继承写法"


def q(stem, ans, wrong, why, quote, diff, topic, kind):
    return dict(stem=stem, ans=ans, wrong=wrong, why=why, quote=quote, diff=diff, topic=topic, kind=kind)


def j(stem, ans, why, quote, diff, topic, kind="关键字"):
    return dict(stem=stem, judge=True, ans=ans, why=why, quote=quote, diff=diff, topic=topic, kind=kind)


def questions():
    allq = [
        q("Java 中，接口 B 要继承接口 A，应该写成：\n\n```java\ninterface B ______ A { }\n```\n\n空缺处应填入：",
          "extends", ["implements", "inherits", "interface"],
          "接口继承接口用 extends（而且可以同时继承多个接口）；类实现接口才用 implements。",
          "Java 中类实现接口用 implements，类继承类用 extends，接口继承接口也用 extends", 1, "Java 语法", "关键字"),
        j("在 Java 中，一个类可以同时实现多个接口，但只能继承一个父类。", True,
          "Java 是单继承：extends 后面只能跟一个类；但 implements 后可以跟多个接口，用逗号隔开。",
          "一个类只能继承一个类，但可以实现多个接口", 1, "Java 语法"),
        q("Java 中，下面抽象类里的抽象方法缺少哪个关键字？\n\n```java\nabstract class Shape {\n    public ______ void draw();\n}\n```\n\n空缺处应填入：",
          "abstract", ["final", "static", "virtual"],
          "没有方法体的方法必须用 abstract 声明，包含抽象方法的类也必须声明为抽象类。Java 没有 virtual 关键字；final 表示不能被重写，与抽象矛盾。",
          "Java 中用 abstract 声明抽象类和抽象方法，抽象方法没有方法体", 1, "Java 语法", "关键字"),
        q("Java 中，子类构造函数要调用父类的带参构造函数，应该写成：\n\n```java\nclass B extends A {\n    B(int x) {\n        ______(x);\n    }\n}\n```\n\n空缺处应填入：",
          "super", ["this", "base", "A"],
          "子类用 super(参数) 调用父类的构造函数，并且必须写在构造函数的第一行。this(x) 调用的是本类的另一个构造函数；Java 没有 base 关键字，也不能直接写类名调用。",
          "Java 中用 super 调用父类的构造函数和被重写的方法，子类构造函数里 super(参数) 必须写在第一行", 1, "Java 语法", "关键字"),
        q("Java 中，要让一个方法不能被子类重写，应该用哪个关键字修饰它？",
          "final", ["static", "abstract", "private static"],
          "final 修饰的方法不能被子类重写，final 修饰的类不能被继承。abstract 恰好相反，要求子类实现。",
          "Java 中用 final 修饰的方法不能被子类重写，final 修饰的类不能被继承", 1, "Java 语法", "关键字"),
        q("Java 的接口中声明的方法 `void f();`，默认的访问修饰符和性质是：",
          "public abstract", ["private", "protected abstract", "public final"],
          "接口中的方法默认是 public abstract，所以实现类里重写它时必须写 public，缩小成默认的包访问权限会编译出错。",
          "Java 接口中声明的方法默认是 public abstract 的", 2, "Java 语法", "关键字"),
        q("Java 中，标注一个方法重写了父类方法、让编译器检查是否真的重写了的注解是：\n\n```java\n______\npublic String toString() { return \"x\"; }\n```",
          "@Override", ["@Overload", "@Inherit", "@Abstract"],
          "@Override 注解会让编译器检查该方法是否真的重写了父类（或接口）的方法，签名写错时直接报错，避免写成了一个新方法。",
          "Java 中用 @Override 注解标注一个方法重写了父类的方法，编译器会检查是否真的重写", 1, "Java 语法", "方法"),
        q("C++ 中，把成员函数声明为纯虚函数，应该写成：\n\n```cpp\nvirtual void draw() ______;\n```\n\n空缺处应填入：",
          "= 0", ["= NULL", "= nullptr", "= virtual"],
          "纯虚函数的写法固定是在声明后加 = 0；没有 = 0 的虚函数是普通虚函数。含有纯虚函数的类就是抽象类。",
          "纯虚函数的写法是 virtual 返回类型 函数名(参数) = 0", 2, "C++ 语法", "关键字"),
        j("在 C++ 中，含有纯虚函数的类不能用来创建对象。", True,
          "含有纯虚函数的类是抽象类，不能实例化，只能作为基类；但可以定义抽象类的指针或引用指向子类对象。",
          "含有纯虚函数的类不能创建对象", 1, "C++ 语法"),
        j("C++ 有 interface 关键字，用它声明接口。", False,
          "C++ 没有 interface 关键字。接口用只含纯虚函数的抽象类表示，Java 才有 interface 关键字。",
          "C++ 没有 interface 关键字，抽象类用至少含一个纯虚函数的类表示", 2, "C++ 语法"),
        q("C++ 中，基类的析构函数应该声明成什么，才能保证通过基类指针 delete 子类对象时调用到子类的析构函数？\n\n```cpp\nclass Shape {\npublic:\n    ______ ~Shape() { }\n};\n```\n\n空缺处应填入：",
          "virtual", ["static", "abstract", "explicit"],
          "析构函数不是虚函数时，delete 基类指针只会调用基类的析构函数，子类部分的资源就泄漏了。所以有多态的基类的析构函数要声明为 virtual。",
          "C++ 中基类的析构函数要声明为 virtual，这样通过基类指针 delete 子类对象时才会调用子类的析构函数", 3, "C++ 语法", "关键字"),
        q("C++ 中，调用 Config 类的静态成员函数 getInstance()，应该写成：\n\n```cpp\nConfig* c = ______;\n```\n\n空缺处应填入：",
          "Config::getInstance()", ["Config.getInstance()", "Config->getInstance()", "config::getInstance()"],
          "访问静态成员和类作用域用 ::；. 用于对象或引用，-> 用于指针。静态函数通过类名调用，不需要对象。",
          "通过指针调用成员用 ->，通过对象或引用调用用 .，访问静态成员和类作用域用 ::", 2, "C++ 语法", "逻辑"),
        q("C++ 中，下面用 new 创建的对象，用完后应该怎样释放？\n\n```cpp\nShape* s = new Circle();\n// ... 使用 s ...\n______ s;\n```\n\n空缺处应填入：",
          "delete", ["free", "release", "remove"],
          "C++ 用 new 创建的对象要用 delete 释放；free 与 malloc 配对，用于 C 风格的内存。C++ 里没有 release、remove 这样的释放关键字。",
          "C++ 中 new 创建的对象要用 delete 释放", 1, "C++ 语法", "关键字"),
        q("C++11 起，在子类里重写基类的虚函数时，可以在函数声明后加什么，让编译器检查是否真的重写了？\n\n```cpp\nvoid draw() ______ { }\n```\n\n空缺处应填入：",
          "override", ["@Override", "virtual", "abstract"],
          "C++11 的 override 写在函数声明的后面；@Override 是 Java 的注解；virtual 要写在返回类型前面，写在后面是语法错误。",
          "C++11 起可以在子类重写的虚函数声明后加 override，让编译器检查是否真的重写了基类的虚函数", 3, "C++ 语法", "关键字"),
        q("关于 C++ 的多态，下列说法正确的是：",
          "通过基类的指针或引用调用虚函数时，实际执行子类的版本",
          ["通过基类的对象调用虚函数时，实际执行子类的版本", "只要子类和基类有同名函数就会产生多态", "不需要把基类的函数声明为 virtual 就能多态"],
          "多态要同时满足两点：基类函数是 virtual；通过基类的指针或引用调用。把子类对象按值赋给基类对象会发生「切片」，丢掉子类部分，调用的就是基类版本。",
          "C++ 的多态必须通过基类的指针或引用调用虚函数才能实现", 3, "C++ 语法", "逻辑"),
        j("Java 中被 final 修饰的类仍然可以被其他类继承。", False,
          "final 修饰的类不能被继承（例如 String），final 修饰的方法不能被重写。",
          "final 修饰的类不能被继承", 1, "Java 语法"),
    ]
    java = [x for x in allq if x["topic"] == "Java 语法"]
    cpp = [x for x in allq if x["topic"] == "C++ 语法"]
    return [("java", (JAVA_SECTION, java)), ("cpp", (CPP_SECTION, cpp))]
