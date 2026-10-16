"""行为型模式：策略、观察者、模板方法、状态、命令、责任链、迭代器、访问者、备忘录、中介者。"""
from common import Blank, Code, Pattern, box

PATTERNS = []

JAVA_IMPL = "Java 中类实现接口用 implements，类继承类用 extends"
CPP_INH = "C++ 的继承写成 class 子类 : public 基类"
CPP_VIRTUAL = "C++ 里抽象类通过纯虚函数实现，写法是 virtual 返回类型 函数名() = 0"
CPP_ARROW = "C++ 通过指针调用成员函数用 ->，通过对象或引用调用用 ."

# ------------------------------------------------------------------------------------------------ 策略
PATTERNS.append(Pattern(
    key="strategy", sec="T6.14", name="策略", en="Strategy",
    diagram=dict(
        boxes={
            "Cart": box("Cart", ["-strategy: DiscountStrategy"], ["+setStrategy(s: DiscountStrategy)", "+checkout(price: double): double"]),
            "DiscountStrategy": box("DiscountStrategy", [], ["+calculate(price: double): double"], stereo="interface"),
            "NormalDiscount": box("NormalDiscount", [], ["+calculate(price: double): double"]),
            "VipDiscount": box("VipDiscount", [], ["+calculate(price: double): double"]),
        },
        rows=[[("Cart", 0.5), ("DiscountStrategy", 2.7)], [("NormalDiscount", 2), ("VipDiscount", 3.4)]],
        edges=[("Cart", "DiscountStrategy", "assoc", ""), ("NormalDiscount", "DiscountStrategy", "real", ""),
               ("VipDiscount", "DiscountStrategy", "real", "")],
    ),
    java=Code(
        scene="购物车结算时，普通用户按原价，VIP 用户打八折，以后还可能增加其他折扣算法，用策略模式把每种折扣算法封装成独立的类，运行时可以替换。",
        src=r"""interface DiscountStrategy {
    double calculate(double price);
}

class NormalDiscount implements DiscountStrategy {
    public double calculate(double price) { return price; }
}

class VipDiscount @@1@@ DiscountStrategy {
    public double calculate(double price) { return price * 0.8; }
}

class Cart {
    private @@2@@ strategy;

    public void setStrategy(DiscountStrategy strategy) { this.strategy = strategy; }

    public double checkout(double price) {
        return strategy.@@3@@(price);
    }
}""",
        blanks={
            1: Blank("implements", ["extends", "inherits", "uses"], "关键字",
                     "每个具体策略都实现抽象策略接口 DiscountStrategy，类实现接口用 implements。",
                     "策略模式中每个具体策略都实现同一个抽象策略接口，上下文持有抽象策略的引用", 1),
            2: Blank("DiscountStrategy", ["VipDiscount", "NormalDiscount", "Cart"], "类名",
                     "上下文（Cart）持有的是抽象策略 DiscountStrategy 的引用，这样 setStrategy 才能在运行时换成任何一种折扣算法；写成具体的 VipDiscount，就没法放入 NormalDiscount 了。",
                     "策略模式中每个具体策略都实现同一个抽象策略接口，上下文持有抽象策略的引用", 2),
            3: Blank("calculate", ["setStrategy", "checkout", "discount"], "方法",
                     "上下文把计算工作委托给当前策略对象的算法方法 calculate()，自己并不关心具体的折扣规则。",
                     "上下文把算法的执行委托给当前持有的策略对象，运行时可以更换策略", 1),
        },
        main=r"""        Cart cart = new Cart();
        cart.setStrategy(new NormalDiscount());
        System.out.println(cart.checkout(100));
        cart.setStrategy(new VipDiscount());
        System.out.println(cart.checkout(100));""",
    ),
    cpp=Code(
        scene="购物车结算时，普通用户按原价，VIP 用户打八折，以后还可能增加其他折扣算法，用策略模式把每种折扣算法封装成独立的类，运行时可以替换。",
        src=r"""class DiscountStrategy {
public:
    virtual double calculate(double price) = 0;
    virtual ~DiscountStrategy() { }
};

class NormalDiscount : public DiscountStrategy {
public:
    double calculate(double price) { return price; }
};

class VipDiscount : @@1@@ DiscountStrategy {
public:
    double calculate(double price) { return price * 0.8; }
};

class Cart {
    @@2@@ strategy;
public:
    void setStrategy(DiscountStrategy* s) { strategy = s; }
    double checkout(double price) {
        return @@3@@;
    }
};""",
        blanks={
            1: Blank("public", ["extends", "implements", "virtual"], "关键字", "C++ 里具体策略继承抽象策略，写成「: public DiscountStrategy」。", CPP_INH, 1),
            2: Blank("DiscountStrategy*", ["DiscountStrategy", "VipDiscount*", "Cart*"], "类名",
                     "上下文持有抽象策略的指针，才能通过它多态地调用任意具体策略。DiscountStrategy 是抽象类，不能直接定义对象成员。",
                     "策略模式中每个具体策略都实现同一个抽象策略接口，上下文持有抽象策略的引用", 2),
            3: Blank("strategy->calculate(price)", ["strategy.calculate(price)", "calculate(price)", "DiscountStrategy::calculate(price)"], "逻辑",
                     "strategy 是指针，用 -> 调用虚函数，实际执行的是当前具体策略的版本。DiscountStrategy::calculate 是纯虚函数，不能这样调用。",
                     "上下文把算法的执行委托给当前持有的策略对象，运行时可以更换策略", 3),
        },
        main=r"""    Cart cart;
    NormalDiscount n;
    VipDiscount v;
    cart.setStrategy(&n);
    cout << cart.checkout(100) << endl;
    cart.setStrategy(&v);
    cout << cart.checkout(100) << endl;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 观察者
PATTERNS.append(Pattern(
    key="observer", sec="T6.15", name="观察者", en="Observer",
    diagram=dict(
        boxes={
            "WeatherStation": box("WeatherStation", ["-temp: float", "-observers: List"], ["+attach(o: Observer)", "+setTemp(t: float)", "-notifyObservers()"]),
            "Observer": box("Observer", [], ["+update(temp: float)"], stereo="interface"),
            "PhoneDisplay": box("PhoneDisplay", [], ["+update(temp: float)"]),
            "WindowDisplay": box("WindowDisplay", [], ["+update(temp: float)"]),
        },
        rows=[[("WeatherStation", 0.5), ("Observer", 2.7)], [("PhoneDisplay", 2), ("WindowDisplay", 3.4)]],
        edges=[("WeatherStation", "Observer", "assoc", "*"), ("PhoneDisplay", "Observer", "real", ""),
               ("WindowDisplay", "Observer", "real", "")],
    ),
    java=Code(
        scene="气象站的温度变化时，要自动通知所有订阅了它的显示设备（手机、窗口），气象站不需要知道有哪些设备，用观察者模式建立一对多的依赖。",
        src=r"""import java.util.*;

interface Observer {
    void update(float temp);
}

class WeatherStation {
    private List<@@1@@> observers = new ArrayList<>();
    private float temp;

    public void attach(Observer o) { observers.@@2@@(o); }

    public void setTemp(float temp) {
        this.temp = temp;
        notifyObservers();
    }

    private void notifyObservers() {
        for (Observer o : observers) {
            o.@@3@@(temp);
        }
    }
}

class PhoneDisplay implements Observer {
    public void update(float temp) { System.out.println("phone: " + temp); }
}

class WindowDisplay implements Observer {
    public void update(float temp) { System.out.println("window: " + temp); }
}""",
        blanks={
            1: Blank("Observer", ["PhoneDisplay", "WeatherStation", "Object"], "类名",
                     "主题保存的是抽象观察者 Observer 的列表，手机、窗口等任何实现了 Observer 的对象都能订阅；写成 PhoneDisplay 就只能订阅手机了。",
                     "主题（Subject）维护一个抽象观察者的列表，状态改变时遍历列表逐个通知", 2),
            2: Blank("add", ["append", "push", "insert"], "方法",
                     "java.util.List 添加元素的方法是 add(e)；append、push 是其他语言（或其他容器）里的名字，List 没有这样的方法。",
                     "主题的 attach 方法把观察者加入列表，detach 方法把观察者从列表移除", 1),
            3: Blank("update", ["notify", "notifyObservers", "refresh"], "方法",
                     "主题通知观察者就是调用每个观察者的 update() 方法，并把新状态传过去。notifyObservers 是主题自己的方法；Object.notify() 不能带参数。",
                     "状态改变时，主题遍历观察者列表，调用每个观察者的 update 方法", 2),
        },
        main=r"""        WeatherStation ws = new WeatherStation();
        ws.attach(new PhoneDisplay());
        ws.attach(new WindowDisplay());
        ws.setTemp(25.5f);""",
    ),
    cpp=Code(
        scene="气象站的温度变化时，要自动通知所有订阅了它的显示设备（手机、窗口），气象站不需要知道有哪些设备，用观察者模式建立一对多的依赖。",
        src=r"""class Observer {
public:
    @@1@@ void update(float temp) = 0;
    virtual ~Observer() { }
};

class WeatherStation {
    vector<@@2@@> observers;
    float temp;
    void notifyObservers() {
        for (size_t i = 0; i < observers.size(); i++) {
            observers[i]->@@3@@(temp);
        }
    }
public:
    void attach(Observer* o) { observers.push_back(o); }
    void setTemp(float t) {
        temp = t;
        notifyObservers();
    }
};

class PhoneDisplay : public Observer {
public:
    void update(float temp) { cout << "phone: " << temp << endl; }
};

class WindowDisplay : public Observer {
public:
    void update(float temp) { cout << "window: " << temp << endl; }
};""",
        blanks={
            1: Blank("virtual", ["static", "abstract", "friend"], "关键字",
                     "update 是由具体观察者实现的抽象方法，在 C++ 里写成纯虚函数：virtual void update(float temp) = 0;。",
                     CPP_VIRTUAL, 1),
            2: Blank("Observer*", ["Observer", "PhoneDisplay*", "WeatherStation*"], "类名",
                     "主题保存抽象观察者的指针 Observer*，才能存放不同类型的观察者并多态地调用 update；Observer 是抽象类，vector<Observer> 无法按值保存。",
                     "主题（Subject）维护一个抽象观察者的列表，状态改变时遍历列表逐个通知", 3),
            3: Blank("update", ["notify", "notifyObservers", "refresh"], "方法",
                     "主题通知观察者就是对列表里每个观察者指针调用 update(temp)。", 
                     "状态改变时，主题遍历观察者列表，调用每个观察者的 update 方法", 2),
        },
        main=r"""    WeatherStation ws;
    PhoneDisplay p;
    WindowDisplay w;
    ws.attach(&p);
    ws.attach(&w);
    ws.setTemp(25.5f);""",
    ),
))

# ------------------------------------------------------------------------------------------------ 模板方法
PATTERNS.append(Pattern(
    key="template-method", sec="T6.16", name="模板方法", en="Template Method",
    diagram=dict(
        boxes={
            "Beverage": box("Beverage", [], ["+prepare()", "-boilWater()", "-pourInCup()", "#brew()", "#addCondiments()"], abstract=True),
            "Tea": box("Tea", [], ["#brew()", "#addCondiments()"]),
            "Coffee": box("Coffee", [], ["#brew()", "#addCondiments()"]),
        },
        rows=[[("Beverage", 1)], [("Tea", 0.2), ("Coffee", 1.8)]],
        edges=[("Tea", "Beverage", "gen", ""), ("Coffee", "Beverage", "gen", "")],
    ),
    java=Code(
        scene="泡茶和冲咖啡的流程相同：烧水、冲泡、倒入杯中、加调料，只有「冲泡」和「加调料」两步不同，用模板方法在父类里固定流程，把可变的步骤留给子类实现。",
        src=r"""abstract class Beverage {
    public @@1@@ void prepare() {
        boilWater();
        brew();
        pourInCup();
        addCondiments();
    }

    private void boilWater() { System.out.println("boil water"); }
    private void pourInCup() { System.out.println("pour in cup"); }

    protected @@2@@ void brew();
    protected abstract void addCondiments();
}

class Tea @@3@@ Beverage {
    protected void brew() { System.out.println("steep tea"); }
    protected void addCondiments() { System.out.println("add lemon"); }
}

class Coffee extends Beverage {
    protected void brew() { System.out.println("drip coffee"); }
    protected void addCondiments() { System.out.println("add milk"); }
}""",
        blanks={
            1: Blank("final", ["abstract", "static", "private"], "关键字",
                     "模板方法定义了算法的骨架和步骤顺序，不允许子类修改，所以通常声明为 final。abstract 表示没有方法体；private 外部无法调用；static 方法里不能调用非静态的步骤。",
                     "模板方法是父类中定义算法骨架的普通方法，通常声明为 final，不允许子类重写", 3),
            2: Blank("abstract", ["final", "static", "virtual"], "关键字",
                     "子类必须实现的步骤在父类中声明为抽象方法：abstract 修饰、没有方法体。final 的方法不能被重写；Java 没有 virtual 关键字。",
                     "父类中把需要子类实现的步骤声明为抽象方法，Java 用 abstract，C++ 用纯虚函数", 2),
            3: Blank("extends", ["implements", "inherits", "override"], "关键字",
                     "Tea 是抽象类 Beverage 的子类，类继承类用 extends。",
                     JAVA_IMPL, 1),
        },
        main=r"""        new Tea().prepare();
        new Coffee().prepare();""",
    ),
    cpp=Code(
        scene="泡茶和冲咖啡的流程相同：烧水、冲泡、倒入杯中、加调料，只有「冲泡」和「加调料」两步不同，用模板方法在父类里固定流程，把可变的步骤留给子类实现。",
        src=r"""class Beverage {
public:
    void prepare() {
        boilWater();
        @@1@@;
        pourInCup();
        addCondiments();
    }
    virtual ~Beverage() { }
protected:
    void boilWater() { cout << "boil water" << endl; }
    void pourInCup() { cout << "pour in cup" << endl; }
    @@2@@ void brew() = 0;
    virtual void addCondiments() = 0;
};

class Tea : @@3@@ Beverage {
protected:
    void brew() { cout << "steep tea" << endl; }
    void addCondiments() { cout << "add lemon" << endl; }
};

class Coffee : public Beverage {
protected:
    void brew() { cout << "drip coffee" << endl; }
    void addCondiments() { cout << "add milk" << endl; }
};""",
        blanks={
            1: Blank("brew()", ["Beverage::brew()", "Tea::brew()", "this.brew()"], "逻辑",
                     "模板方法直接调用抽象步骤 brew()，由于它是虚函数，运行时会执行子类 Tea 或 Coffee 的版本。写成 Beverage::brew() 会绕开多态去调用纯虚函数；父类里也不知道 Tea；this 是指针，要用 this->。",
                     "模板方法在父类中按固定顺序调用各个步骤，其中抽象步骤由子类实现", 3),
            2: Blank("virtual", ["static", "abstract", "friend"], "关键字",
                     "纯虚函数的写法是 virtual 返回类型 函数名() = 0;，没有 virtual 就不能 = 0。",
                     CPP_VIRTUAL, 1),
            3: Blank("public", ["extends", "implements", "virtual"], "关键字", "C++ 的继承写成「: public 基类」。", CPP_INH, 1),
        },
        main=r"""    Tea t;
    t.prepare();
    Coffee c;
    c.prepare();""",
    ),
))

# ------------------------------------------------------------------------------------------------ 状态
PATTERNS.append(Pattern(
    key="state", sec="T6.17", name="状态", en="State",
    diagram=dict(
        boxes={
            "Order": box("Order", ["-state: State"], ["+setState(s: State)", "+next()"]),
            "State": box("State", [], ["+handle(order: Order)"], stereo="interface"),
            "NewState": box("NewState", [], ["+handle(order: Order)"]),
            "PaidState": box("PaidState", [], ["+handle(order: Order)"]),
        },
        rows=[[("Order", 0.5), ("State", 2.7)], [("NewState", 2), ("PaidState", 3.4)]],
        edges=[("Order", "State", "assoc", ""), ("NewState", "State", "real", ""), ("PaidState", "State", "real", "")],
    ),
    java=Code(
        scene="订单有「新建」和「已付款」两种状态，每种状态下对订单的处理不同，状态之间会自动转换，用状态模式把每种状态的行为封装到一个状态类里。",
        src=r"""interface State {
    void handle(Order order);
}

class NewState implements State {
    public void handle(Order order) {
        System.out.println("pay");
        order.setState(@@1@@);
    }
}

class PaidState implements State {
    public void handle(Order order) {
        System.out.println("ship");
    }
}

class Order {
    private @@2@@ state = new NewState();

    public void setState(State state) { this.state = state; }

    public void next() {
        state.@@3@@(this);
    }
}""",
        blanks={
            1: Blank("new PaidState()", ["new NewState()", "PaidState", "new State()"], "逻辑",
                     "状态模式的特点是由具体状态负责切换到下一个状态：NewState 处理完付款后，把订单切换到 PaidState。写成 new NewState() 状态就永远不变；State 是接口，不能 new。",
                     "状态模式中状态转换由具体状态类完成：处理完后调用上下文的 setState 切换到下一个状态", 3),
            2: Blank("State", ["NewState", "PaidState", "Order"], "类名",
                     "上下文持有抽象状态 State 的引用，才能在运行时切换为任意一种具体状态；写成 NewState 就无法再设置为 PaidState。",
                     "状态模式的上下文持有抽象状态的引用，把行为委托给当前状态对象", 2),
            3: Blank("handle", ["setState", "next", "pay"], "方法",
                     "上下文把请求委托给当前状态对象的 handle() 方法，并把自己（this）传进去，状态类才能调用 setState 切换状态。",
                     "状态模式的上下文持有抽象状态的引用，把行为委托给当前状态对象", 2),
        },
        main=r"""        Order o = new Order();
        o.next();
        o.next();""",
    ),
    cpp=Code(
        scene="订单有「新建」和「已付款」两种状态，每种状态下对订单的处理不同，状态之间会自动转换，用状态模式把每种状态的行为封装到一个状态类里。",
        src=r"""class @@1@@;

class State {
public:
    virtual void handle(Order* order) = 0;
    virtual ~State() { }
};

class Order {
    State* state;
public:
    Order();
    void setState(State* s) { state = s; }
    void next() { state->handle(@@2@@); }
};

class NewState : public State {
public:
    void handle(Order* order);
};

class PaidState : public State {
public:
    void handle(Order* order) { cout << "ship" << endl; }
};

void NewState::handle(Order* order) {
    cout << "pay" << endl;
    order->setState(@@3@@);
}

Order::Order() { state = new NewState(); }""",
        blanks={
            1: Blank("Order", ["State", "NewState", "Context"], "类名",
                     "State 的 handle 参数用到了 Order 指针，而 Order 又在后面才定义，所以要先做前向声明：class Order;，告诉编译器 Order 是一个类。",
                     "C++ 里两个类相互引用时，要先对其中一个做前向声明，写成 class 类名;", 3),
            2: Blank("this", ["*this", "Order", "&this"], "逻辑",
                     "handle 的参数类型是 Order*，在成员函数里 this 就是指向当前对象的指针，直接传 this；*this 是对象，类型不匹配。",
                     "状态模式的上下文持有抽象状态的引用，把行为委托给当前状态对象", 3),
            3: Blank("new PaidState()", ["new NewState()", "PaidState", "new State()"], "逻辑",
                     "由 NewState 把订单切换到下一个状态 PaidState：setState 的参数是 State*，要 new 一个 PaidState 对象并传其指针。State 是抽象类，不能 new。",
                     "状态模式中状态转换由具体状态类完成：处理完后调用上下文的 setState 切换到下一个状态", 3),
        },
        main=r"""    Order o;
    o.next();
    o.next();""",
    ),
))

# ------------------------------------------------------------------------------------------------ 命令
PATTERNS.append(Pattern(
    key="command", sec="T6.18", name="命令", en="Command",
    diagram=dict(
        boxes={
            "RemoteControl": box("RemoteControl", ["-command: Command"], ["+setCommand(c: Command)", "+pressButton()"]),
            "Command": box("Command", [], ["+execute()"], stereo="interface"),
            "LightOnCommand": box("LightOnCommand", ["-light: Light"], ["+execute()"]),
            "LightOffCommand": box("LightOffCommand", ["-light: Light"], ["+execute()"]),
            "Light": box("Light", [], ["+on()", "+off()"]),
        },
        rows=[[("RemoteControl", 0.5), ("Command", 2.7)],
              [("LightOnCommand", 1.8), ("LightOffCommand", 3.5)],
              [("Light", 2.7)]],
        edges=[("RemoteControl", "Command", "assoc", ""), ("LightOnCommand", "Command", "real", ""),
               ("LightOffCommand", "Command", "real", ""), ("LightOnCommand", "Light", "assoc", ""),
               ("LightOffCommand", "Light", "assoc", "")],
    ),
    java=Code(
        scene="遥控器上的按钮可以绑定不同的操作（开灯、关灯），遥控器不需要知道灯是怎么工作的，用命令模式把请求封装成对象，使调用者（遥控器）和接收者（灯）解耦。",
        src=r"""interface Command {
    void execute();
}

class Light {
    public void on() { System.out.println("light on"); }
    public void off() { System.out.println("light off"); }
}

class LightOnCommand @@1@@ Command {
    private Light light;
    public LightOnCommand(Light light) { this.light = light; }
    public void execute() { light.@@2@@(); }
}

class LightOffCommand implements Command {
    private Light light;
    public LightOffCommand(Light light) { this.light = light; }
    public void execute() { light.off(); }
}

class RemoteControl {
    private @@3@@ command;
    public void setCommand(Command command) { this.command = command; }
    public void pressButton() { command.execute(); }
}""",
        blanks={
            1: Blank("implements", ["extends", "inherits", "executes"], "关键字",
                     "具体命令实现抽象命令接口 Command，类实现接口用 implements。",
                     "命令模式把请求封装成对象：抽象命令声明 execute 方法，具体命令持有接收者并在 execute 中调用它的方法", 1),
            2: Blank("on", ["off", "execute", "switchOn"], "方法",
                     "LightOnCommand 的 execute() 调用接收者 Light 的 on() 方法来开灯；off() 是 LightOffCommand 用的。",
                     "命令模式把请求封装成对象：抽象命令声明 execute 方法，具体命令持有接收者并在 execute 中调用它的方法", 1),
            3: Blank("Command", ["Light", "LightOnCommand", "RemoteControl"], "类名",
                     "调用者（遥控器）持有抽象命令 Command 的引用，按下按钮时调用 command.execute()，不知道具体是哪个命令、哪个接收者。",
                     "命令模式的调用者只持有抽象命令，通过 execute 触发请求，不依赖具体接收者", 2),
        },
        main=r"""        Light light = new Light();
        RemoteControl remote = new RemoteControl();
        remote.setCommand(new LightOnCommand(light));
        remote.pressButton();
        remote.setCommand(new LightOffCommand(light));
        remote.pressButton();""",
    ),
    cpp=Code(
        scene="遥控器上的按钮可以绑定不同的操作（开灯、关灯），遥控器不需要知道灯是怎么工作的，用命令模式把请求封装成对象，使调用者（遥控器）和接收者（灯）解耦。",
        src=r"""class Light {
public:
    void on() { cout << "light on" << endl; }
    void off() { cout << "light off" << endl; }
};

class Command {
public:
    virtual void execute() = 0;
    virtual ~Command() { }
};

class LightOnCommand : public Command {
    Light* light;
public:
    LightOnCommand(@@1@@ l) : light(l) { }
    void execute() { @@2@@; }
};

class LightOffCommand : public Command {
    Light* light;
public:
    LightOffCommand(Light* l) : light(l) { }
    void execute() { light->off(); }
};

class RemoteControl {
    Command* command;
public:
    void setCommand(Command* c) { command = c; }
    void pressButton() { command->@@3@@(); }
};""",
        blanks={
            1: Blank("Light*", ["Light", "Command*", "RemoteControl*"], "类名",
                     "命令持有接收者的指针 Light*，构造函数用接收者的指针初始化成员 light；传 Light 值会复制一份灯，操作的就不是同一盏灯了。",
                     "命令模式把请求封装成对象：抽象命令声明 execute 方法，具体命令持有接收者并在 execute 中调用它的方法", 2),
            2: Blank("light->on()", ["light.on()", "light->off()", "Light::on()"], "逻辑",
                     "light 是指针，用 -> 调用接收者的 on() 方法；light->off() 是关灯，属于另一个命令；Light::on() 是非静态函数，不能不带对象调用。",
                     "命令模式把请求封装成对象：抽象命令声明 execute 方法，具体命令持有接收者并在 execute 中调用它的方法", 2),
            3: Blank("execute", ["on", "run", "pressButton"], "方法",
                     "调用者只通过抽象命令的 execute() 触发请求，不依赖具体接收者。",
                     "命令模式的调用者只持有抽象命令，通过 execute 触发请求，不依赖具体接收者", 1),
        },
        main=r"""    Light light;
    LightOnCommand on(&light);
    LightOffCommand off(&light);
    RemoteControl remote;
    remote.setCommand(&on);
    remote.pressButton();
    remote.setCommand(&off);
    remote.pressButton();""",
    ),
))

# ------------------------------------------------------------------------------------------------ 责任链
PATTERNS.append(Pattern(
    key="chain", sec="T6.19", name="责任链", en="Chain of Responsibility",
    diagram=dict(
        boxes={
            "Handler": box("Handler", ["#next: Handler"], ["+setNext(h: Handler)", "+handle(days: int)"], abstract=True),
            "TeamLeader": box("TeamLeader", [], ["+handle(days: int)"]),
            "Manager": box("Manager", [], ["+handle(days: int)"]),
            "Director": box("Director", [], ["+handle(days: int)"]),
        },
        rows=[[("Handler", 1.5)], [("TeamLeader", 0.4), ("Manager", 1.5), ("Director", 2.6)]],
        edges=[("TeamLeader", "Handler", "gen", ""), ("Manager", "Handler", "gen", ""), ("Director", "Handler", "gen", "")],
    ),
    java=Code(
        scene="请假审批：2 天以内由组长批准，5 天以内由经理批准，更长的由总监批准。申请沿着「组长 → 经理 → 总监」传递，直到有人处理，用责任链模式把处理者连成一条链。",
        src=r"""abstract class Handler {
    protected @@1@@ next;

    public void setNext(Handler next) { this.next = next; }

    public abstract void handle(int days);
}

class TeamLeader extends Handler {
    public void handle(int days) {
        if (days <= 2) {
            System.out.println("leader approves " + days);
        } else if (next != null) {
            @@2@@;
        }
    }
}

class Manager extends Handler {
    public void handle(int days) {
        if (days <= @@3@@) {
            System.out.println("manager approves " + days);
        } else if (next != null) {
            next.handle(days);
        }
    }
}

class Director extends Handler {
    public void handle(int days) {
        System.out.println("director approves " + days);
    }
}""",
        blanks={
            1: Blank("Handler", ["TeamLeader", "Manager", "Director"], "类名",
                     "每个处理者持有的后继是抽象处理者 Handler，这样才能把任何处理者连到链上，客户端也只需要和链头打交道。",
                     "责任链中每个处理者持有指向下一个抽象处理者的引用，处理不了的请求转发给后继", 2),
            2: Blank("next.handle(days)", ["handle(days)", "this.handle(days)", "next.setNext(days)"], "逻辑",
                     "自己处理不了时，把请求转发给后继：next.handle(days)。直接写 handle(days) 或 this.handle(days) 是自己调用自己，会无限递归；setNext 的参数是处理者而不是天数。",
                     "责任链中每个处理者持有指向下一个抽象处理者的引用，处理不了的请求转发给后继", 2),
            3: Blank("5", ["2", "3", "7"], "逻辑",
                     "经理能批 5 天以内的申请；超过 5 天的转给总监。",
                     "责任链中每个处理者只处理自己权限范围内的请求，超出范围就交给后继", 1),
        },
        main=r"""        Handler leader = new TeamLeader();
        Handler manager = new Manager();
        Handler director = new Director();
        leader.setNext(manager);
        manager.setNext(director);
        leader.handle(1);
        leader.handle(4);
        leader.handle(6);
        leader.handle(8);""",
    ),
    cpp=Code(
        scene="请假审批：2 天以内由组长批准，5 天以内由经理批准，更长的由总监批准。申请沿着「组长 → 经理 → 总监」传递，直到有人处理，用责任链模式把处理者连成一条链。",
        src=r"""class Handler {
protected:
    @@1@@ next;
public:
    Handler() : next(nullptr) { }
    void setNext(Handler* n) { next = n; }
    virtual void handle(int days) = 0;
    virtual ~Handler() { }
};

class TeamLeader : @@2@@ Handler {
public:
    void handle(int days) {
        if (days <= 2) cout << "leader approves " << days << endl;
        else if (next != nullptr) next->handle(days);
    }
};

class Manager : public Handler {
public:
    void handle(int days) {
        if (days <= 5) cout << "manager approves " << days << endl;
        else if (next != nullptr) @@3@@;
    }
};

class Director : public Handler {
public:
    void handle(int days) { cout << "director approves " << days << endl; }
};""",
        blanks={
            1: Blank("Handler*", ["Handler", "TeamLeader*", "Manager*"], "类名",
                     "后继是抽象处理者的指针 Handler*：它可以指向任何一种处理者，并且可以为空（nullptr）表示链的末尾。Handler 是抽象类，不能按值作为成员。",
                     "责任链中每个处理者持有指向下一个抽象处理者的引用，处理不了的请求转发给后继", 3),
            2: Blank("public", ["extends", "implements", "virtual"], "关键字", "C++ 的继承写成「: public 基类」。", CPP_INH, 1),
            3: Blank("next->handle(days)", ["next.handle(days)", "handle(days)", "Handler::handle(days)"], "逻辑",
                     "next 是指针，用 -> 把请求转发给后继。直接写 handle(days) 是自己调用自己，会无限递归；Handler::handle 是纯虚函数，不能这样调用。",
                     "责任链中每个处理者持有指向下一个抽象处理者的引用，处理不了的请求转发给后继", 3),
        },
        main=r"""    TeamLeader leader;
    Manager manager;
    Director director;
    leader.setNext(&manager);
    manager.setNext(&director);
    leader.handle(1);
    leader.handle(4);
    leader.handle(6);
    leader.handle(8);""",
    ),
))

# ------------------------------------------------------------------------------------------------ 迭代器
PATTERNS.append(Pattern(
    key="iterator", sec="T6.20", name="迭代器", en="Iterator",
    diagram=dict(
        boxes={
            "Container": box("Container", [], ["+getIterator(): Iterator"], stereo="interface"),
            "Iterator": box("Iterator", [], ["+hasNext(): boolean", "+next(): String"], stereo="interface"),
            "NameRepository": box("NameRepository", ["-names: String[]"], ["+getIterator(): Iterator"]),
            "NameIterator": box("NameIterator", ["-index: int"], ["+hasNext(): boolean", "+next(): String"]),
        },
        rows=[[("Container", 0.5), ("Iterator", 2.5)], [("NameRepository", 0.5), ("NameIterator", 2.5)]],
        edges=[("Container", "Iterator", "dep", ""), ("NameRepository", "Container", "real", ""),
               ("NameIterator", "Iterator", "real", ""), ("NameRepository", "NameIterator", "dep", "")],
    ),
    java=Code(
        scene="名字仓库内部用数组保存数据，客户端想依次访问每个名字，又不想知道仓库是用数组还是链表保存的，用迭代器模式提供统一的遍历接口。",
        src=r"""interface Iterator {
    boolean hasNext();
    String next();
}

interface Container {
    Iterator getIterator();
}

class NameRepository implements Container {
    private String[] names = {"Tom", "Amy", "Bob"};

    public Iterator getIterator() { return new NameIterator(); }

    private class NameIterator @@1@@ Iterator {
        int index = 0;

        public boolean hasNext() { return index < names.@@2@@; }

        public String next() { return hasNext() ? names[@@3@@] : null; }
    }
}""",
        blanks={
            1: Blank("implements", ["extends", "inherits", "iterates"], "关键字",
                     "具体迭代器实现抽象迭代器接口 Iterator，类实现接口用 implements。",
                     "迭代器模式把遍历的职责从聚合对象中分离出来，聚合对象的 getIterator 方法返回一个迭代器对象", 1),
            2: Blank("length", ["length()", "size()", "size"], "逻辑",
                     "Java 数组的长度是属性 length，不带括号；length() 是 String 的方法，size() 是集合的方法。",
                     "Java 数组的长度用属性 length 表示，不带括号", 2),
            3: Blank("index++", ["index", "++index", "index--"], "逻辑",
                     "next() 返回当前元素并让下标后移一位，所以用后缀 index++：先取 names[index] 再加一。++index 会先加一，跳过第一个元素；写 index 则不会前进，hasNext() 永远为真。",
                     "迭代器的 next 方法返回当前元素，并把游标移到下一个元素", 3),
        },
        main=r"""        Container repo = new NameRepository();
        for (Iterator it = repo.getIterator(); it.hasNext(); ) {
            System.out.println(it.next());
        }""",
    ),
    cpp=Code(
        scene="名字仓库内部用数组保存数据，客户端想依次访问每个名字，又不想知道仓库是用数组还是链表保存的，用迭代器模式提供统一的遍历接口。",
        src=r"""class Iterator {
public:
    virtual bool hasNext() = 0;
    virtual string next() = 0;
    virtual ~Iterator() { }
};

class Container {
public:
    virtual Iterator* getIterator() = 0;
    virtual ~Container() { }
};

class NameRepository : public Container {
    vector<string> names;
public:
    NameRepository() {
        names.push_back("Tom");
        names.push_back("Amy");
        names.push_back("Bob");
    }

    class NameIterator : @@1@@ Iterator {
        NameRepository* repo;
        size_t index;
    public:
        NameIterator(NameRepository* r) : repo(r), index(0) { }
        bool hasNext() { return index < repo->names.size(); }
        string next() { return repo->names[@@2@@]; }
    };

    Iterator* getIterator() { return @@3@@; }
};""",
        blanks={
            1: Blank("public", ["extends", "implements", "virtual"], "关键字", "C++ 的继承写成「: public 基类」。", CPP_INH, 1),
            2: Blank("index++", ["index", "++index", "index--"], "逻辑",
                     "next() 返回当前元素并让下标后移一位，所以用后缀 index++：先取 names[index] 再加一。",
                     "迭代器的 next 方法返回当前元素，并把游标移到下一个元素", 3),
            3: Blank("new NameIterator(this)", ["new NameIterator(*this)", "new NameIterator()", "NameIterator(this)"], "逻辑",
                     "迭代器要知道遍历哪个仓库，构造函数的参数类型是 NameRepository*，在成员函数里 this 就是当前对象的指针；返回类型是 Iterator*，所以要用 new 创建并返回指针。",
                     "迭代器模式把遍历的职责从聚合对象中分离出来，聚合对象的 getIterator 方法返回一个迭代器对象", 3),
        },
        main=r"""    NameRepository repo;
    Iterator* it = repo.getIterator();
    while (it->hasNext()) {
        cout << it->next() << endl;
    }
    delete it;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 访问者
PATTERNS.append(Pattern(
    key="visitor", sec="T6.21", name="访问者", en="Visitor",
    diagram=dict(
        boxes={
            "Item": box("Item", [], ["+accept(v: Visitor)"], stereo="interface"),
            "Visitor": box("Visitor", [], ["+visit(b: Book)", "+visit(f: Fruit)"], stereo="interface"),
            "Book": box("Book", ["+price: int"], ["+accept(v: Visitor)"]),
            "Fruit": box("Fruit", ["+price: int"], ["+accept(v: Visitor)"]),
            "PriceVisitor": box("PriceVisitor", ["+total: int"], ["+visit(b: Book)", "+visit(f: Fruit)"]),
        },
        rows=[[("Item", 0.5), ("Visitor", 2.7)], [("Book", 0), ("Fruit", 1), ("PriceVisitor", 2.7)]],
        edges=[("Item", "Visitor", "dep", ""), ("Book", "Item", "real", ""), ("Fruit", "Item", "real", ""),
               ("PriceVisitor", "Visitor", "real", "")],
    ),
    java=Code(
        scene="购物车里有书和水果两种商品，现在要统计总价，以后还可能增加「打印清单」等新操作，用访问者模式把对元素的操作放到访问者里，增加操作时不用修改商品类。",
        src=r"""interface Visitor {
    void visit(Book book);
    void visit(Fruit fruit);
}

interface Item {
    void accept(Visitor visitor);
}

class Book implements Item {
    int price = 50;
    public void accept(Visitor visitor) { visitor.visit(@@1@@); }
}

class Fruit implements Item {
    int price = 10;
    public void accept(Visitor visitor) { visitor.visit(this); }
}

class PriceVisitor @@2@@ Visitor {
    int total = 0;
    public void visit(Book book) { total += book.price; }
    public void visit(Fruit fruit) { total += @@3@@; }
}""",
        blanks={
            1: Blank("this", ["Book", "book", "visitor"], "逻辑",
                     "元素的 accept 方法把自己（this）传给访问者的 visit 方法，这就是「双分派」：先根据元素的类型选择 accept，再根据 this 的静态类型 Book 选择 visit(Book)。",
                     "访问者模式的 accept 方法调用访问者的 visit 方法，并把元素自己（this）作为参数传入", 2),
            2: Blank("implements", ["extends", "inherits", "visits"], "关键字",
                     "具体访问者实现抽象访问者接口 Visitor，类实现接口用 implements。",
                     JAVA_IMPL, 1),
            3: Blank("fruit.price", ["price", "this.price", "Fruit.price"], "逻辑",
                     "visit(Fruit fruit) 要累加参数 fruit 的价格：fruit.price。访问者类里没有 price 成员，所以不能直接写 price 或 this.price；price 也不是静态成员，不能用类名访问。",
                     "访问者通过 visit 方法的参数访问元素的数据，对不同类型的元素做不同的处理", 2),
        },
        main=r"""        Item[] items = { new Book(), new Fruit(), new Book() };
        PriceVisitor pv = new PriceVisitor();
        for (Item item : items) {
            item.accept(pv);
        }
        System.out.println(pv.total);""",
    ),
    cpp=Code(
        scene="购物车里有书和水果两种商品，现在要统计总价，以后还可能增加「打印清单」等新操作，用访问者模式把对元素的操作放到访问者里，增加操作时不用修改商品类。",
        src=r"""class Book;
class Fruit;

class Visitor {
public:
    virtual void visit(Book* book) = 0;
    virtual void visit(Fruit* fruit) = 0;
    virtual ~Visitor() { }
};

class Item {
public:
    virtual void accept(@@1@@ visitor) = 0;
    virtual ~Item() { }
};

class Book : public Item {
public:
    int price = 50;
    void accept(Visitor* visitor);
};

class Fruit : public Item {
public:
    int price = 10;
    void accept(Visitor* visitor);
};

void Book::accept(Visitor* visitor) { visitor->visit(@@2@@); }
void Fruit::accept(Visitor* visitor) { visitor->visit(this); }

class PriceVisitor : public Visitor {
public:
    int total = 0;
    void visit(Book* book) { total += book->price; }
    void visit(Fruit* fruit) { total += @@3@@; }
};""",
        blanks={
            1: Blank("Visitor*", ["Visitor", "Visitor&&", "PriceVisitor*"], "类名",
                     "accept 接收抽象访问者的指针 Visitor*，这样任何具体访问者都能访问元素。Visitor 是抽象类，不能按值传递。",
                     "访问者模式的 accept 方法调用访问者的 visit 方法，并把元素自己（this）作为参数传入", 2),
            2: Blank("this", ["*this", "Book", "book"], "逻辑",
                     "visit(Book*) 的参数是指针，在成员函数里 this 就是指向当前 Book 的指针，直接传 this；*this 是对象，类型不匹配。",
                     "访问者模式的 accept 方法调用访问者的 visit 方法，并把元素自己（this）作为参数传入", 3),
            3: Blank("fruit->price", ["fruit.price", "price", "Fruit::price"], "逻辑",
                     "fruit 是指针，用 -> 访问成员 price；. 用于对象或引用。访问者类里没有 price 成员，price 也不是静态成员，不能用 Fruit::price 访问。",
                     "访问者通过 visit 方法的参数访问元素的数据，对不同类型的元素做不同的处理", 2),
        },
        main=r"""    Book b1, b2;
    Fruit f;
    Item* items[] = { &b1, &f, &b2 };
    PriceVisitor pv;
    for (Item* item : items) {
        item->accept(&pv);
    }
    cout << pv.total << endl;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 备忘录
PATTERNS.append(Pattern(
    key="memento", sec="T6.22", name="备忘录", en="Memento",
    diagram=dict(
        boxes={
            "Editor": box("Editor", ["-text: String"], ["+type(s: String)", "+save(): Memento", "+restore(m: Memento)"]),
            "Memento": box("Memento", ["-text: String"], ["+getText(): String"]),
            "History": box("History", ["-memento: Memento"], ["+push(m: Memento)", "+pop(): Memento"]),
        },
        rows=[[("Editor", 0), ("Memento", 1.5), ("History", 3)]],
        edges=[("Editor", "Memento", "dep", ""), ("History", "Memento", "assoc", "")],
    ),
    java=Code(
        scene="文本编辑器要支持撤销：保存编辑器某一时刻的内容，以后可以恢复，但不能破坏编辑器的封装。用备忘录模式：发起人（Editor）创建备忘录，管理者（History）只负责保管它。",
        src=r"""class Memento {
    private final String text;
    public Memento(String text) { this.text = text; }
    public String getText() { return text; }
}

class Editor {
    private String text = "";

    public void type(String s) { text += s; }
    public String getText() { return text; }

    public Memento save() { return @@1@@; }
    public void restore(@@2@@ m) { text = m.getText(); }
}

class History {
    private Memento memento;
    public void push(Memento m) { memento = m; }
    public Memento pop() { return memento; }
}

class Client {
    public static void run() {
        Editor editor = new Editor();
        History history = new History();
        editor.type("abc");
        history.push(editor.save());
        editor.type("def");
        editor.restore(history.@@3@@());
        System.out.println(editor.getText());
    }
}""",
        blanks={
            1: Blank("new Memento(text)", ["new Memento()", "this", "text"], "逻辑",
                     "备忘录由发起人创建：把发起人当前的状态（text）保存进一个新的 Memento 对象。Memento 没有无参构造函数；返回 this 或 text 的类型都不是 Memento。",
                     "备忘录模式中发起人创建备忘录保存自己的内部状态，需要时用备忘录恢复", 2),
            2: Blank("Memento", ["String", "Editor", "History"], "类名",
                     "恢复状态时，发起人接收一个 Memento 对象，并从中取出之前保存的状态。",
                     "备忘录模式中发起人创建备忘录保存自己的内部状态，需要时用备忘录恢复", 1),
            3: Blank("pop", ["push", "save", "restore"], "方法",
                     "管理者的 push 保存备忘录，pop 取出备忘录，把它交给发起人的 restore；管理者只保管备忘录，不查看也不修改它的内容。",
                     "备忘录模式的管理者只负责保存和提供备忘录，不检查也不修改备忘录的内容", 2),
        },
        main=r"""        Client.run();""",
    ),
    cpp=Code(
        scene="文本编辑器要支持撤销：保存编辑器某一时刻的内容，以后可以恢复，但不能破坏编辑器的封装。用备忘录模式：发起人（Editor）创建备忘录，管理者（History）只负责保管它。",
        src=r"""class Memento {
    string text;
public:
    Memento(string t) : text(t) { }
    string getText() { return text; }
};

class Editor {
    string text;
public:
    void type(string s) { text += s; }
    string getText() { return text; }

    Memento* save() { return new Memento(@@1@@); }
    void restore(Memento* m) { text = m->@@2@@(); }
};

class History {
    Memento* memento;
public:
    History() : memento(nullptr) { }
    void push(@@3@@ m) { memento = m; }
    Memento* pop() { return memento; }
};""",
        blanks={
            1: Blank("text", ["this", "*this", "Editor"], "逻辑",
                     "备忘录保存发起人当前的状态（text 字符串），Memento 的构造函数参数是 string。传 this 或 *this 的类型都不是 string。",
                     "备忘录模式中发起人创建备忘录保存自己的内部状态，需要时用备忘录恢复", 2),
            2: Blank("getText", ["text", "get", "getMemento"], "方法",
                     "m 是 Memento 指针，用 -> 调用它的公有方法 getText() 取出保存的状态；text 是私有成员，不能直接访问，也不是函数。",
                     "备忘录模式中发起人创建备忘录保存自己的内部状态，需要时用备忘录恢复", 2),
            3: Blank("Memento*", ["Memento", "Editor*", "string"], "类名",
                     "管理者保存的是备忘录的指针，push 的参数类型与成员 memento 一致，都是 Memento*。",
                     "备忘录模式的管理者只负责保存和提供备忘录，不检查也不修改备忘录的内容", 2),
        },
        main=r"""    Editor editor;
    History history;
    editor.type("abc");
    history.push(editor.save());
    editor.type("def");
    Memento* m = history.pop();
    editor.restore(m);
    cout << editor.getText() << endl;
    delete m;""",
    ),
))

# ------------------------------------------------------------------------------------------------ 中介者
PATTERNS.append(Pattern(
    key="mediator", sec="T6.23", name="中介者", en="Mediator",
    diagram=dict(
        boxes={
            "Mediator": box("Mediator", [], ["+send(msg: String, from: User)"], stereo="interface"),
            "User": box("User", ["-name: String", "-mediator: Mediator"], ["+send(msg: String)", "+receive(msg: String)"]),
            "ChatRoom": box("ChatRoom", ["-users: List"], ["+register(u: User)", "+send(msg: String, from: User)"]),
        },
        rows=[[("Mediator", 0.5), ("User", 2.5)], [("ChatRoom", 0.5)]],
        edges=[("ChatRoom", "Mediator", "real", ""), ("User", "Mediator", "assoc", ""), ("ChatRoom", "User", "assoc", "*")],
    ),
    java=Code(
        scene="聊天室里的用户不直接互相发消息，而是都把消息交给聊天室，由聊天室转发给其他用户，用中介者模式把多对多的复杂关系变成星形结构。",
        src=r"""import java.util.*;

interface Mediator {
    void send(String msg, User from);
}

class ChatRoom implements Mediator {
    private List<User> users = new ArrayList<>();

    public void register(User u) { users.add(u); }

    public void send(String msg, User from) {
        for (User u : users) {
            if (u != @@1@@) {
                u.receive(msg);
            }
        }
    }
}

class User {
    private String name;
    private @@2@@ mediator;

    public User(String name, Mediator mediator) {
        this.name = name;
        this.mediator = mediator;
    }

    public void send(String msg) { mediator.@@3@@(msg, this); }
    public void receive(String msg) { System.out.println(name + " got " + msg); }
}""",
        blanks={
            1: Blank("from", ["this", "null", "msg"], "逻辑",
                     "中介者把消息转发给除发送者以外的所有同事，所以要跳过 from。this 是聊天室本身，与 User 类型不可比较；null 会让发送者也收到自己的消息。",
                     "中介者把同事发来的消息转发给除发送者以外的其他同事", 3),
            2: Blank("Mediator", ["ChatRoom", "User", "Object"], "类名",
                     "同事持有抽象中介者 Mediator 的引用，只和中介者通信，不依赖具体的聊天室类，也不认识其他用户。",
                     "同事对象只持有中介者的引用，通过中介者与其他同事通信，彼此互不引用", 2),
            3: Blank("send", ["receive", "register", "broadcast"], "方法",
                     "用户发消息，就是调用中介者的 send(msg, this)，把自己作为发送者一起交给中介者；receive 是中介者调用用户用的。",
                     "同事对象只持有中介者的引用，通过中介者与其他同事通信，彼此互不引用", 2),
        },
        main=r"""        ChatRoom room = new ChatRoom();
        User a = new User("A", room);
        User b = new User("B", room);
        User c = new User("C", room);
        room.register(a);
        room.register(b);
        room.register(c);
        a.send("hi");""",
    ),
    cpp=Code(
        scene="聊天室里的用户不直接互相发消息，而是都把消息交给聊天室，由聊天室转发给其他用户，用中介者模式把多对多的复杂关系变成星形结构。",
        src=r"""class User;

class Mediator {
public:
    virtual void send(const string& msg, User* from) = 0;
    virtual ~Mediator() { }
};

class User {
    string name;
    Mediator* mediator;
public:
    User(string n, Mediator* m) : name(n), mediator(m) { }
    void send(const string& msg) { mediator->@@1@@(msg, this); }
    void receive(const string& msg) { cout << name << " got " << msg << endl; }
};

class ChatRoom : @@2@@ Mediator {
    vector<User*> users;
public:
    void registerUser(User* u) { users.push_back(u); }
    void send(const string& msg, User* from) {
        for (size_t i = 0; i < users.size(); i++) {
            if (users[i] != @@3@@) users[i]->receive(msg);
        }
    }
};""",
        blanks={
            1: Blank("send", ["receive", "registerUser", "broadcast"], "方法",
                     "用户发消息，就是调用中介者的 send(msg, this)，把自己作为发送者一起交给中介者。",
                     "同事对象只持有中介者的引用，通过中介者与其他同事通信，彼此互不引用", 2),
            2: Blank("public", ["extends", "implements", "virtual"], "关键字", "C++ 的继承写成「: public 基类」。", CPP_INH, 1),
            3: Blank("from", ["this", "nullptr", "name"], "逻辑",
                     "中介者把消息转发给除发送者以外的所有同事，所以要跳过 from。this 是聊天室指针，与 User* 不能比较；nullptr 会让发送者也收到自己的消息。",
                     "中介者把同事发来的消息转发给除发送者以外的其他同事", 3),
        },
        main=r"""    ChatRoom room;
    User a("A", &room), b("B", &room), c("C", &room);
    room.registerUser(&a);
    room.registerUser(&b);
    room.registerUser(&c);
    a.send("hi");""",
    ),
))
