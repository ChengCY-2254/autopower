# Project Agent Instructions

This file provides guidance to AI agents (Codewhale, Claude Code, etc.) when working with code in this repository.

## File Location

Save this file as `AGENTS.md` in your project root so the CLI can load it automatically.

## 工作准则

- 第一性原理：任何修改前先追问项目要解决的根本问题，避免偏离“自动低电量模式”这一核心目标。
- 对抗式审查：对每个方案自我批判，主动寻找反例和边界条件；不默认现有实现正确。
- 消融实验：当不确定某模块、逻辑或参数是否必要时，尝试拿掉它，观察功能是否仍满足需求；不必要则删除。
- 奥卡姆剃刀：如无必要，勿增实体。注释、代码、文档、配置项均适用。
- 列出不自信点：在 PR 描述或分析中明确列出当前方案中不确定、需验证的部分，不得隐瞒。
- 保持独立思考：不迎合已有设计或指令；如发现不合理，直接指出并提供依据。
- 批判性思维：先质疑，再推理，后解答。任何改动前先问“为什么需要这个”。
- 高内聚低耦合：每个模块只做一件事，模块间通过清晰接口交互，禁止跨层直接调用。

## Build and Development Commands

```bash
# Build（需要 Theos 环境）
make                         # 编译 tweak 和 preferences bundle
make clean                   # 清理编译产物
make package                 # 打包为 .deb

# 安装到真机（需要 SSH 配置）
make install                 # 编译并安装到设备

# 开发模式
make DEBUG=1                 # 调试模式编译
make FINALPACKAGE=1          # 发布包编译（禁用日志）
```

## Architecture Overview

AutoPower 是一个 iOS Theos tweak（iOS 18+），用于自动开启低电量模式。采用**分层事件驱动架构**，通过状态机统一决策，确保逻辑清晰且易于扩展。

### Key Components

#### 1. **入口层** (`Tweak.x`)
- 集成点：使用 Logos 宏进行 hook
- 职责：%ctor 中调用 `APSPlugin.start()` 初始化插件
- 特点：最小化 Logos 逻辑，业务下沉到协调层

#### 2. **协调层** (`APSPlugin`)
- 职责：装配各模块、管理通知注册、调度同步和重置
- 关键方法：
  - `start()`: 注册 Darwin 通知、启动输入源、初始同步
  - `initialSync()`: 根据当前模式从指定输入源同步状态
  - `performReset()`: 作废在途链、清状态、关闭低电量、重新同步
- 通知处理：
  - `com.apple.system.lowpowermode`: 低电量模式被外部关闭时清理标志
  - `io.cheng.autopower.reset`: 一键重置通知（跨进程，由设置页触发）

#### 3. **决策层** (`APSStateMachine`)
- 职责：去抖、模式匹配、统一决策逻辑
- 核心方法：
  - `currentModeSource()`: 根据配置确定当前触发模式（熄屏/锁屏/关闭）
  - `handleTriggerActive()`: 处理输入源事件的主入口（去抖记忆 → 模式匹配 → 执行决策）
  - `handleExternalLowPowerOff()`: 处理外部关闭低电量模式
  - `handleReset()`: 清理所有内部状态
- 设计思想：
  - **纯函数化决策**：快照全部依赖 → 纯函数决策 → 映射为副作用
  - **去抖机制**：通过 `lastTriggerActive` 三态记忆（Unknown/No/Yes）实现
  - **并发安全**：全主队列约定，无需锁

#### 4. **配置层** (`APSConfig`)
- 职责：统一的配置和内部标志读写接口
- 用户配置（任意线程可读）：
  - `Enabled`: 是否启用插件（默认 YES）
  - `IgnoreUserLowPower`: 忽略用户手动开启的低电量（默认 YES）
  - `ScreenOffMode`: 屏幕熄灭模式开关（默认 NO）
  - `LockedMode`: 设备锁定模式开关（默认 YES）
- 内部标志（仅主队列读写）：
  - `PluginFlagged`: 插件是否认为低电量由自己开启
  - `ResetRequested`: 一键重置标记（设置页写入）
- 配置域：`io.cheng.autopower`

#### 5. **能力层**（Provider 系列）

**低电量模式**（`APSLowPowerProvider`）:
- 使用私有 API `_PMLowPowerMode`（iOS 18）
- 通过注册表惰性加载、单例缓存
- 接口：`isLowPowerOn()` 读取，`setLowPowerOn:()` 控制

**屏幕状态**（`APSScreenProvider`）:
- 适配器：`APSSBBacklightController`（私有 API）
- 接口：`screenIsOn()` 读取屏幕开关状态
- 兜底方案：支持亮度采样判断（通过 `kBrightnessActiveThreshold` 阈值）

**锁屏状态**（`APSLockProvider`）:
- 双适配器设计（优先级递减）：
  - `APSAggregatorLockProvider`: 使用 `SBLockStateAggregator.lockState`（主判）
  - `APSUILockProvider`: 回退链（isUILocked → isLocked → isDeviceLocked → ...）
- 返回值：`APSLockStatus` 枚举（Unknown/Unlocked/Locked/Transient）
- 私有单例惰性初始化，安全约束同低电量层

#### 6. **输入源层**（InputSource 系列）

**屏幕输入源**（`APSScreenInputSource`）:
- 职责：监听屏幕通知、采样确认、上报触发状态
- 双确认机制：屏幕通知 + SBBacklight 状态读取
- 可选的亮度采样兜底

**锁屏输入源**（`APSLockInputSource`）:
- 职责：监听锁屏通知、提供者判定、上报触发状态

**代际机制**（并发安全）:
- 每次 reset 递增代际号，作废在途判定链
- 残留的异步判定自动检查版本号，丢弃过期结果

#### 7. **偏好设置层**（`AutopowerPrefsController`）
- 职责：提供 Preferences UI 界面
- 读写配置：通过 NSUserDefaults 与 Tweak 进程共享配置
- 触发重置：写入 `ResetRequested` 标记，由 Darwin 通知唤醒 Tweak 进程
- 可选诊断：日志查看、调试信息展示

## Data Flow

### 工作流程图

```
系统事件（屏幕/锁屏/低电量通知）
    ↓
APSPlugin 中的 Darwin 通知回调
    ↓ [跳到主队列]
InputSource（屏幕/锁屏）处理事件
    ↓
APSStateMachine.handleTriggerActive()
    ↓
[决策过程] 快照配置 + 提供者状态 → 纯函数决策 → 执行决策
    ├─ applyDecision() 映射为副作用：
    │  ├─ 调用 LowPowerProvider.setLowPowerOn:()
    │  ├─ 更新 APSConfig 的 pluginFlagged
    │  └─ 输出日志
    ↓
插件状态持久化到 NSUserDefaults（APSConfig.plist）
    ↓
Settings 应用或偏好设置 UI 读取配置并刷新界面
```

### 跨进程通信

**Tweak 进程 ↔ Preferences 进程**:
- 配置共享：NSUserDefaults 套件 `io.cheng.autopower`
- 一键重置：Preferences 写入 `ResetRequested` → Darwin 通知 → Tweak 处理
- 低电量状态同步：每次状态改变时持久化 `PluginFlagged`

### 并发安全模型

**主队列约定**:
- 所有方法必须从主队列调用
- Darwin 通知回调由 APSPlugin 统一转发到主队列
- 输入源的异步链全部在主队列调度
- 状态机内部无需加锁

**时序约束**:
- 重置时递增输入源代际号，作废在途判定
- 1s 后的 resync 由 APSPlugin 调度（幂等性）

## Configuration Files

### 编译配置

**`Makefile`**:
- 目标平台：iPhone（arm64e 架构）
- 最低 iOS 版本：14.0
- Hook 目标进程：SpringBoard
- Tweak 名称：autopower
- Preferences Bundle：autopowerprefs
- 编译标志：-fobjc-arc（自动引用计数）、-O3 优化（发布包）

### 运行时配置

**`autopower.plist`** / `layout/Library/PreferenceLoader/Preferences/autopower.plist`**:
- Hook 过滤器：仅在 SpringBoard 进程中加载
- 格式：Darwin 通知兼容的 plist

**`autopowerprefs/Resources/AutopowerSettings.plist`**:
- Preferences Bundle 的设置项定义
- 包含用户配置界面元素（开关、模式选择等）

### 日志文件（开发模式）

**`/var/mobile/Library/Preferences/autopower.log`**:
- 仅在编译时未定义 `APSLOG_DISABLED` 时启用
- 发布包 (`FINALPACKAGE=1`) 会禁用日志系统以减小体积
- 由 Preferences UI 中的"查看日志"功能读取

## Extension Points

### 添加新的触发模式（输入源）

1. **在 `APSStateMachine.h` 中扩展枚举**:
   ```c
   typedef NS_ENUM(NSInteger, APSInputSourceType) {
       APSInputSourceNone   = 0,
       APSInputSourceScreen = 1,
       APSInputSourceLock   = 2,
       APSInputSourceXXX    = 3,   // 新增
   };
   ```

2. **创建新的 InputSource 类**（如 `APSCustomInputSource.h/m`）:
   - 实现 `APSInputSource` 协议
   - 注册系统通知并转发到主队列
   - 实现 `syncToStateMachine:` 初始同步
   - 实现 `reset` 和代际机制

3. **在 `APSPlugin.m` 中集成**:
   - 创建实例并注册通知
   - 在 `initialSync()` 中按模式调用

4. **在 `APSConfig.m` 中添加配置开关**:
   - 定义 Key 常量
   - 添加配置读写方法

5. **在偏好设置 UI 中暴露开关** (`AutopowerPrefsController.m`)

### 支持新的 iOS 版本

#### 低电量模式（新私有 API）

1. 在 `APSLowPowerProvider.m` 中探测新类/方法
2. 创建新的 Provider 适配器（如 `APSNewPMProvider`）
3. 在 `APSLowPowerProviderRegistry` 中注册
4. 编译时测试可用性

#### 屏幕状态（新 API）

1. 在 `APSScreenProvider.m` 中探测新类
2. 创建适配器实现 `APSScreenProviding` 协议
3. 在 `APSScreenProviderRegistry.current` 中调整优先级

#### 锁屏状态（新 API）

1. 在 `APSLockProvider.m` 中探测新类
2. 创建适配器实现 `APSLockProviding` 协议
3. 注意 `APSLockStatus` 枚举值的真机校准
4. 在 `APSLockProviderRegistry` 中按优先级注册

### 修改决策逻辑

1. 编辑 `APSStateMachine.m` 中的纯函数决策部分（`APSDecide*` 方法）
2. 核心决策原则保持不变：
   - 输入：当前状态 + 事件 + 上下文快照
   - 输出：新状态 + 执行动作
3. 修改后的决策会自动由 `applyDecision()` 映射为副作用

### 添加诊断功能

1. 在 `APSLog.h/m` 中定义新的日志宏
2. 在 `APSPlugin.m` 的 `runDiagnostics()` 中添加诊断代码
3. 在 `AutopowerPrefsController.m` 中暴露诊断信息

## Commit Messages

- Use conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`

- 提交消息使用简体中文

## 注释规范

### 代码注释
- 注释只写 **非显而易见的原因** (non-obvious reason)，禁止保留开发过程中的中间尝试或调试代码。
- 每个头文件顶部需简要说明该文件的职责与整体作用；每个公开函数（或关键内部函数）必须注释其功能、主要参数及返回值。
- 所有注释只描述 **最终实现行为**，不得包含开发时的临时思路、备选方案或废弃逻辑。

### PR描述
- PR只陈述最终行为，**不提及**diff中已可见的实现细节。
- 禁止讨论diff中无法体现的取舍过程（如曾考虑过的替代方案），也禁止提及从未合入过的中间状态。

## 人机交互指南（非常重要）

### 防止纠结

在模型内部推理过程中，出现以下两种情况之一时，请立即中断当前思考：

1.对用户意图或某个核心概念的理解存在明显歧义，且已在内部推理中反复推敲、无法自洽；
2.在同一问题上进行了连续两段以上（每段约200～300字）的密集思考，仍未形成稳定结论，思维呈现来回摇摆。

此时，禁止继续来回摇摆，应立刻：

- 梳理出当前最不明确的 1～3 个关键点；
- 将这些点转化为面向用户的澄清性问题或需要用户抉择的选项；
- 用简洁、条理化的方式向用户提问，等待外部输入后再继续推进。
