# AutoTouch 微信解锁（atunblock）—— 完整技术文档

> 一个越狱插件，让 AutoTouch 能在微信上跑脚本。
> **不修改 ATTweak.dylib 本体**，全部在运行时完成。

---

## 一、问题是什么

AutoTouch 在支付宝、抖音上都能正常跑脚本，**唯独微信不行**，弹：

```
Alert
You can not use AutoTouch upon this app!
```

排查过程中排除的因素（都不是原因）：

| 排查项 | 结论 |
|---|---|
| 免费版 5 分钟播放限额 | 不是——支付宝能跑 |
| 授权文件缺失 | 不是——那是另一套逻辑 |
| 触摸 ID（3/5/6） | 不是——都能正常工作的脚本里出现过 |
| 触摸模式（无 touchMove） | 不是——抖音脚本也没有，能跑 |
| 脚本新旧 | 不是——今天新录的支付宝脚本能跑 |
| 数据目录权限 | 不是——修了也没用 |
| `crackATT.dylib` | 不是——它是 arm64 单切片，注入不进 arm64e 的 SpringBoard，**从来没执行过** |
| dpkg 检查失败 | 不是——从安装第一天就在失败，只是噪音 |
| 微信插件冲突 | 不是——禁用后照样报错 |

**唯一变量：目标 App 是微信。**

---

## 二、根因：硬编码黑名单

反汇编 `ATTweak.dylib` 找到的完整逻辑链：

```objc
// 类 Playing 的方法（IMP 静态地址 0xf808e8）
- (void)doPlay {
    ...
    if (check() != 0) {                                    // ← doPlay 开头第 14 条指令
        alert(@"You can not use AutoTouch upon this app!"); // ← 0xf80944
        return;                                            // ← 直接返回，一行触摸都不注入
    }
    ... 正常播放
}

check() = f8b9a8( f8b928() );
     f8b928()  →  取当前【前台 App】的 bundle id
     f8b9a8()  →  拿 @"com.tencent.xin" 去比对
                  非 0 → 报错
```

**那句报错的字符串常量位置**：`__DATA,__cfstring @ 0x15e2558`（arm64 切片）
**微信 bundle id 常量位置**：`__DATA,__cfstring @ 0x15e3898`

**AutoTouch 把微信的 bundle id 写死在代码里，专门把它排除在外。**

### 为什么"以前能用"

你的 `Records/` 目录里，在今天之前**没有任何微信脚本**：

```
抖音点赞.lua            2024-08-09    抖音
支付宝佛珠.lua           2024-09-03    支付宝
支付宝浏览广告.lua        2024-09-22    支付宝
支付宝喂鱼敲木鱼.lua      2025-01-01    支付宝
2026-01-16 14:35:11.lua  2026-01-16   支付宝
2026-09-29 17:57:42.lua  2026-09-29   ★ 微信 ← 第一次
```

**AutoTouch 在微信上从来没成功过。今天是第一次试。**

---

## 三、⚠️ 为什么不能直接改文件

**这是本项目最重要的一条经验。**

### 试过的方案：直接改 `ATTweak.dylib` 里的字符串

把 `com.tencent.xin` 改成 `com.Tencent.xin`（1 个字节 × 2 切片），让比对失败。

**结果：SpringBoard 崩溃循环。**

```
termination: { "namespace": "CODESIGNING", "code": 2 }
exception:   SIGKILL - CODESIGNING

调用栈:
  dlopen → libinjector.dylib injection_init → dyld → 内核 SIGKILL
```

### 关键事实

```
原始 ATTweak.dylib:  49,108,848 字节 · 【没有任何 LC_CODE_SIGNATURE】
```

**原文件本来就没签名，但 Dopamine 的 `libinjector.dylib` 对它有一套信任机制。
一旦文件被改动，这个信任就失效，内核直接 SIGKILL 掉整个 SpringBoard。**

### 加了签名行不行？不行

用 Theos 工具链的 ldid 重签后：

- SpringBoard 不崩了
- **但 AutoTouch 的控制面板调不出来了**

原因：原文件无签名时，系统给它继承宿主进程的权限；加了 **空 entitlements 的 adhoc 签名**后权限被限制，**挂不进 backboardd**。

### 结论

**永远不要改 `ATTweak.dylib` 的文件。** 加不加签名都是死路。

---

## 四、正确做法：运行时 hook

**完全不碰 ATTweak.dylib，写一个独立插件。**

```
1. 注入 SpringBoard / backboardd（自己的 plist，跟 ATTweak 一样）
2. 运行时找到类 Playing 的 -doPlay 方法
3. 读它 IMP 开头的机器码，找「bl X 紧跟 cbz/cbnz w0」这个模式
4. MSHookFunction 那个检查函数，让它永远返回 0
```

### 为什么用「模式匹配」而不是硬编码地址

静态分析时 arm64e 切片用了**链式修复（chained fixups）**，地址算不出来。
但**运行时 `bl` 的目标地址就写在机器码里**，直接读即可——两个切片通吃。

### ★ 最大的坑：arm64e 的 PAC

```c
IMP imp = method_getImplementation(m);
// 实测值: 0x6667bc810864ec5c
//         ^^^^^^^^^^ 这是指针认证(PAC)签名，不是地址！
uint32_t *code = (uint32_t *)imp;   // ← 读到未映射内存 → SIGBUS 崩溃
```

**`objc_msgSend` 调用时 CPU 会自动认证签名，所以直接调用没事；
但要【读内存】必须先剥掉签名。**

剥法（v4 实现）：

```c
static void *strip_pac(void *p) {
    uintptr_t v = (uintptr_t)p;
    if (is_in_loaded_image(v)) return p;          // 已经是有效地址
    static const uintptr_t masks[] = {
        0x0000000FFFFFFFFFULL,   // 36 位
        0x0000FFFFFFFFFFFFULL,   // 48 位
        0x00000000FFFFFFFFULL,   // 32 位
        0x000001FFFFFFFFFFULL,   // 41 位
    };
    for (int i = 0; i < 4; i++) {
        uintptr_t cand = v & masks[i];
        if (cand && is_in_loaded_image(cand)) return (void *)cand;
    }
    return p;
}
```

实测：`0x6667bc810864ec5c & 0xFFFFFFFFF` = **`0x10864ec5c`** ✓（与 ATTweak 镜像 base `0x1076d8000` 同一区域）

### 静态分析与运行时的一致性验证

| | 静态分析（arm64 切片） | 运行时（arm64e） |
|---|---|---|
| 检查调用位置 | 第 **13** 条指令 | 第 **14** 条指令 |
| 后面跟的指令 | `cbz w0` | `cbz w0` ✓ |

**差 1 条正是预期的**——arm64e 的序言多一条 PAC 指令，代码整体后移一位。理论完全自洽。

---

## 五、踩坑记录（4 次迭代，每次都靠崩溃日志定位）

| 版本 | 崩溃现象 | 根因 | 修法 |
|---|---|---|---|
| **v1** | 构造函数里 SIGBUS | 在 dylib `__attribute__((constructor))` 里调 `NSProcessInfo` / `writeToFile`——**那时 Foundation 还没初始化完** | 所有 ObjC 操作延迟到 `dispatch_after` 里 |
| **v2** | `objc_msgSend` 收到野指针 | `ALog()` 用了 `[NSString stringWithFormat:]`，varargs 在注入环境里不稳定 | **整个插件不用 Foundation**，日志改 `vsnprintf` + `fopen` |
| **v3** | SIGBUS，日志显示 `IMP=0xa04e960109e4ec5c` | **IMP 带 PAC 签名**，当数据指针读机器码 | 剥 PAC + 已加载镜像范围校验 |
| **v4** | — | — | **成功** |

### 三个可复用的教训

1. **dylib 构造函数里绝不能碰 Foundation** —— 延迟执行
2. **注入型插件尽量纯 C** —— 不 import Foundation，用 libobjc 的 C API
3. **arm64e 上读 IMP 必须先剥 PAC** —— 调用不需要，读内存需要

---

## 六、部署与自检

插件文件：

```
/var/jb/usr/lib/TweakInject/atunblock.dylib
/var/jb/usr/lib/TweakInject/atunblock.plist   → { Filter = { Bundles = (springboard, backboardd) } }
```

> ⚠️ `/var/jb/Library/MobileSubstrate/DynamicLibraries` 是 `/var/jb/usr/lib/TweakInject` 的**符号链接**，两者是同一个目录。

### 安全部署脚本（`deploy-atunblock.sh`）

**带自动回滚**：部署 → respring → 记录崩溃日志数 → 再等 15 秒 → 有新增崩溃就自动卸载并恢复。

```sh
# 判定条件（严格：新增任何崩溃都算失败）
if [ "$N2" -gt 0 ] && [ "$NEW2" -eq 0 ]; then
    echo "成功"
else
    sudo rm -f "$TI/atunblock.dylib" "$TI/atunblock.plist"   # 自动卸载
    sudo killall -9 SpringBoard
fi
```

**这个脚本救过两次命。** 早期版本崩溃时它自动清掉了插件，没让我手动介入。

### 日志

```
/var/mobile/atunblock.log
```

正常工作的日志长这样：

```
atunblock v4 启动  pid=7239
PlayingManager 已注册: 是
ATTweak 镜像: base=0x1076d8000  .../ATTweak.dylib
[1] 扫描 75030 个类找 -doPlay ...
    类 Playing  -doPlay  IMP=0x6667bc810864ec5c  mask=0xfffffffff  真实地址=0x10864ec5c
      [14] bl -> 0x10865a41c   下一条=340002e0 <- cbz w0
      *** 命中模式！第 14 条 bl -> 0x10865a41c
      ****** 已 hook 检查函数 @ 0x10865a41c（原函数 0xa934f88100838000）
[1] 结果: -doPlay 类 1 个, bl 1 条, 已装上
[*] check() 被调用 -> 原值 0x1 -> 强制 0            ← ★ 这行是 hook 生效的铁证
```

**`原值 0x1 → 强制 0`**：AutoTouch 认定"当前是微信"（返回 1，会拦），hook 把它摁成 0（放行）。

---

## 七、安装 / 卸载

### 安装

```powershell
cd D:\phone\wechat-adskip
.venv\Scripts\python.exe phone.py push "D:\phone\atunblock\dist\atunblock.dylib" "/tmp/atunblock.dylib"
.venv\Scripts\python.exe phone.py push "D:\phone\atunblock\dist\atunblock.plist" "/tmp/atunblock.plist"
.venv\Scripts\python.exe phone.py push deploy-atunblock.sh "/tmp/deploy-atunblock.sh"
.venv\Scripts\python.exe phone.py run "PHONE_SUDOPASS='1234567t' sh /tmp/deploy-atunblock.sh"
```

### 卸载

```powershell
.venv\Scripts\python.exe phone.py run "PHONE_SUDOPASS='1234567t' sh -c 'sudo rm -f /var/jb/usr/lib/TweakInject/atunblock.dylib /var/jb/usr/lib/TweakInject/atunblock.plist && sudo killall -9 SpringBoard'"
```

**独立插件，删掉就干净**，不影响 ATTweak，也不影响微信去广告插件。

### 重新编译

```powershell
wsl -d Ubuntu-22.04 -- bash /mnt/d/phone/wechat-adskip/build-atunblock.sh
```

---

## 八、如果 AutoTouch 以后更新了

检查日志里这几行：

| 日志现象 | 含义 | 怎么办 |
|---|---|---|
| `未命中` / `扫描...找 -doPlay` 后再无输出 | 类名或方法名变了 | 用静态分析重新找（方法：搜报错字符串的 CFString → 反查引用它的方法） |
| `剥不出有效地址` | IMP 布局变了 | 调整 `strip_pac` 的掩码 |
| `bl` 后面跟的不是 `cbz w0` | 检查逻辑改写了 | 反汇编 doPlay 重新找门控分支 |
| 日志里没有 `check() 被调用` | hook 装上了但没被触发 | AutoTouch 可能换了检查方式 |

**判定方法**：改动后看日志里有没有 `[*] check() 被调用 -> 原值 0x1 -> 强制 0`。

---

## 九、性质说明

本插件做的唯一一件事：**让 `doPlay` 里那个硬编码的「当前是微信就拒绝」判断失效。**

- ✅ 没有动授权逻辑（付费版买的是"无限播放时间"，那部分代码一行没碰）
- ✅ 没有动任何其他 App 的行为
- ✅ 没有修改 AutoTouch 的任何文件
- ✅ 独立插件，随时可完整卸载
