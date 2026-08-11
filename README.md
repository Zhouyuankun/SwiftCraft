# SwiftCraft

SwiftCraft 是一个使用 Swift、AppKit、MetalKit 和 Metal Shading Language 编写的 macOS 体素渲染 Demo。当前程序会生成由平坦区块组成的世界，玩家可以使用第一人称自由相机在其中移动；世界会围绕玩家动态创建、加载和卸载区块网格。

本文档以当前代码为准，用于帮助后续开发者快速理解项目。它描述的是已经实现的行为，不是产品规划。

## 当前运行效果

程序启动后显示一个由草方块、泥土和石头组成的平坦体素世界。初始相机位于区块 `(0, 0)` 上方。点击窗口后进入操作模式，可以在世界中自由飞行；右上角 HUD 会显示相机位置、朝向和当前区块坐标。

渲染器始终保留玩家周围 `3 × 3` 个区块的 GPU 网格。跨越区块边界时，新的区块网格会被创建，离开渲染距离的网格会被释放。

## 已实现功能

- Metal 渲染设备、命令队列、渲染管线和逐帧绘制循环
- 透视投影、LookAt 视图矩阵、深度测试和背面剔除
- 空气以及 12 种可渲染方块类型，包含天然方块、建材、原木和两种熔炉状态
- 4 × 4 像素风格纹理图集，不同方块面可选择不同图块
- `5 × 8 × 5` 的 Chunk 方块数据结构
- 将整个 Chunk 合并成一个顶点缓冲区
- Chunk 内部及相邻 Chunk 之间的不可见面剔除
- 以玩家为中心的 `3 × 3` 多区块动态加载和 GPU 网格卸载
- 支持负世界坐标到 Chunk 坐标的正确转换
- WASD、Space、Shift 和鼠标控制的第一人称自由飞行相机
- 点击锁定光标、Escape 解锁光标
- 基于视线方向的天空、地平线和地面渐变背景
- 显示位置、朝向、Chunk 坐标和准心目标方块类型的调试 HUD
- 屏幕中心十字准心，以及准心射线命中方块时的偏白高亮
- 左键破坏准心命中的方块，并持久保留本次运行期间的修改
- 加载纹理时自动生成 mipmap（当前采样器尚未启用 mip 级过滤）

## 操作方式

| 输入 | 行为 |
| --- | --- |
| 未锁定时点击窗口 | 锁定并隐藏光标，进入操作模式 |
| 锁定后点击左键 | 破坏准心命中的方块 |
| 鼠标移动 | 转动视角 |
| W / A / S / D | 水平前后左右移动 |
| Space | 上升 |
| Shift | 下降 |
| Escape | 解锁并显示光标，同时清除当前按键状态 |

相机目前是自由飞行相机，没有重力、碰撞、跳跃或地面行走限制。移动量按帧计算，而不是按时间计算，因此实际移动速度会受到帧率影响。

## 世界和区块模型

### Chunk 尺寸

每个 Chunk 的尺寸固定为：

```text
width  = 5
height = 8
depth  = 5
```

方块数据存储为 `map[x][y][z]`。当前所有新区块都由 `Chunk.init()` 生成相同的八层平坦地形：

```text
y = 7       草方块（1 层）
y = 4...6   泥土（3 层）
y = 1...3   石头（3 层）
y = 0       基岩（1 层）
```

当前没有噪声、高度图、随机生成或生物群系，所以所有区块的地形完全相同，世界高度也固定为 8。

### 世界坐标

`ChunkCoord` 只包含水平的 `x`、`z` 坐标。世界暂时不存在垂直 Chunk。

世界坐标转换为区块坐标时使用向下取整：

```swift
chunkX = floor(worldX / Chunk.width)
chunkZ = floor(worldZ / Chunk.depth)
```

因此负坐标也能正确归属，例如 `x = -1` 会进入 `chunkX = -1`，而不是区块 0。

### 加载和存储策略

`World` 内部有两层数据：

- `chunkData`：保存所有访问过的 Chunk 方块数据，离开渲染距离后不会删除。
- `loadedChunks`：只保存渲染距离内已经上传到 GPU 的 `ChunkMesh`。

`World.renderDistance` 当前为 1，因此目标加载集合是以相机所在区块为中心的 `3 × 3` 区域。只有目标集合改变时才会执行加载和卸载。

需要注意：当前只是 GPU 网格流式加载。持续探索时，`loadedChunks` 通常维持 9 个，但 `chunkData` 会一直增长，并不具备无限世界所需的内存淘汰或磁盘持久化机制。

## 网格生成和面剔除

`GeometryFactory.generateChunkMesh` 遍历 Chunk 中的每个非空气方块，并依次检查前、后、右、左、上、下六个方向：

- 邻居是实心方块：不生成该面。
- 邻居是空气：生成该面。
- 邻居越过 Chunk 边界：通过 `World.blockAtWorld` 查询相邻 Chunk。
- 相邻 Chunk 尚未生成或垂直坐标超出世界高度：按空气处理，保留边界面。

每个可见面由两个三角形组成，共生成 6 个非索引顶点。所有顶点在 CPU 上直接转换成世界坐标，然后合并进该 Chunk 的一个 `MTLBuffer`；渲染时不再使用单独的模型矩阵。

当新的相邻 Chunk 首次生成时，已有 Chunk 可能需要重建网格，以移除原来暴露、现在已被新邻居遮挡的边界面。

## 方块和纹理

`BlockType` 当前定义了空气和 12 种可渲染方块。图集坐标以左上角为 `(row: 0, col: 0)`：

| 原始值 | 类型 | 各面纹理 |
| ---: | --- | --- |
| 0 | `air` | 不渲染 |
| 1 | `stone` | 六面 `(0, 0)` |
| 2 | `dirt` | 六面 `(0, 1)`；同一图块也用于草方块底面 |
| 3 | `grass` | 侧面 `(0, 2)`、顶部 `(1, 3)`、底面 `(0, 1)` |
| 4 | `coalOre` | 六面 `(0, 3)` |
| 5 | `planks` | 六面 `(1, 0)` |
| 6 | `log` | 侧面 `(1, 1)`、顶底 `(1, 2)` |
| 7 | `cobblestone` | 六面 `(2, 0)` |
| 8 | `bedrock` | 六面 `(2, 1)` |
| 9 | `sand` | 六面 `(2, 2)` |
| 10 | `bricks` | 六面 `(2, 3)` |
| 11 | `furnace` | 正面 `(3, 0)`、背面及侧面 `(3, 1)`、顶底 `(3, 3)` |
| 12 | `litFurnace` | 正面 `(3, 2)`、背面及侧面 `(3, 1)`、顶底 `(3, 3)` |

主纹理资源是 `Assets.xcassets/terrain_atlas.imageset/Blocks.png`，图片尺寸为 64 × 64，代码按 4 × 4 网格计算 UV，每个图块为 16 × 16。

纹理加载时会生成 mipmap。地形片元着色器使用最近邻放大和缩小过滤，以保持清晰的像素边缘；采样器没有设置 `mip_filter`，因此当前渲染并未实际使用生成的 mip 层级。目前没有光照计算、法线、阴影、透明方块或颜色雾化。

## 渲染流程

`Renderer.draw(in:)` 每帧按以下顺序执行：

1. 调用 `onUpdate`，处理相机移动并刷新 HUD。
2. 获取当前 drawable、Render Pass 和相机。
3. 创建 45° 视野、0.1 近裁剪面、100 远裁剪面的投影矩阵。
4. 使用全屏三角形绘制天空渐变，不写入深度。
5. 根据相机位置调用 `World.update(center:)` 更新区块集合。
6. 设置地形管线、深度测试、逆时针正面和背面剔除。
7. 遍历 `world.loadedChunks`，逐个提交非索引三角形绘制。
8. 提交命令缓冲并显示当前帧。

天空片元着色器通过逆 View-Projection 矩阵重建每个像素对应的世界空间视线，再根据视线的 Y 分量混合天顶蓝、地平线浅蓝和地面深色。

## 输入和相机

`GameViewController` 维护全局按键集合，并通过 Renderer 的 `onUpdate` 回调每帧更新相机。

- 初始位置：`(2.5, 10.0, 2.5)`
- 初始 yaw：`-90°`，即面向 `-Z`
- 初始 pitch：`0°`
- 鼠标灵敏度：`0.15`
- 每帧移动步长：`0.15`
- pitch 范围：`-89°...89°`

WASD 使用去除 Y 分量后的水平前方向移动；Space 和 Shift 直接修改世界坐标 Y。视图矩阵由相机位置、视线方向和世界上方向 `(0, 1, 0)` 计算。

## HUD

`GameViewController` 在运行时创建三个 `NSTextField`，固定在视图右上角，显示：

- `Position`：相机的 X、Y、Z，保留一位小数。
- `Facing`：水平视线在坐标轴上的符号组合，例如 `+X-Z`。
- `Chunk`：相机当前所在区块的 X、Z。
- `Block`：准心命中的 `BlockType` 枚举名称；未命中时显示 `air`。

文本内容没有变化时不会重复赋值。

视图中央还有一个由两条白色矩形组成的固定十字准心。渲染器每帧从相机位置沿视线方向执行 3D DDA 体素射线检测，选择 6 格内的第一个非空气方块。命中后，地形片元着色器会将该方块颜色向白色混合 38%；未命中时不启用高亮。选取逻辑只依赖世界方块查询，不依赖当前固定平坦地形的生成规则。

光标锁定后点击左键会将目标方块设为 `air`。修改直接写入 `World.chunkData`，随后立即重建当前 Chunk 的 GPU 网格；若被破坏方块位于 Chunk 水平边界，也会重建对应的相邻 Chunk，使新暴露的面正常出现。离开渲染距离只会释放 GPU 网格，不会删除修改后的方块数据，因此本次程序运行期间返回该区域仍能看到破坏结果。当前尚未把修改写入磁盘，重新启动应用后世界会恢复初始状态。

## 代码结构

```text
SwiftCraft/
├── AppDelegate.swift          macOS 应用入口和窗口生命周期
├── GameViewController.swift   输入、光标锁定、相机更新和 HUD
├── Renderer.swift             Metal 初始化、天空和地形逐帧渲染
├── Camera.swift               相机状态、视线方向和 LookAt 矩阵
├── Blocks.swift               方块、Chunk、World、网格和 UV 生成
├── Math.swift                 透视、位移和旋转矩阵工具
├── Types.swift                CPU 侧 Vertex 和 Uniform 数据结构
├── Shaders.metal              地形及天空的 Metal 着色器
├── ShaderTypes.h              早期共享类型文件，当前 Swift 渲染代码未使用
├── MetalBeginnerGuide.md      Metal 学习说明，不参与程序运行
├── Base.lproj/Main.storyboard 主窗口、菜单和 MTKView
└── Assets.xcassets/           应用图标、颜色和纹理资源
```

主要调用关系：

```text
AppDelegate / Main.storyboard
          │
          ▼
GameViewController ── 输入、Camera、HUD
          │ onUpdate / camera
          ▼
       Renderer ───── 天空管线、地形管线
          │
          ▼
        World ─────── Chunk 数据、加载集合、GPU 网格
          │
          ▼
 GeometryFactory ─── 可见面和顶点生成
```

## 工程配置

- 工程类型：Xcode macOS App
- UI：AppKit Storyboard
- 图形 API：Metal / MetalKit
- 数学类型：Apple SIMD
- 工程 `SWIFT_VERSION`：5.0
- App Target 部署目标：macOS 26.0
- Bundle Identifier：`com.celeglow.SwiftCraft`
- 工程当前只有一个应用 Target，没有 XCTest 或 UI Test Target
- 没有 Swift Package Manager 或其他第三方依赖

构建方式：

1. 使用 Xcode 打开 `SwiftCraft.xcodeproj`。
2. 选择 `SwiftCraft` scheme 和兼容的 macOS 运行目标。
3. 使用 Command-R 构建运行。

## 当前未实现

以下能力目前不存在于代码中：

- 噪声地形、山脉、生物群系和树木
- 树叶等更多方块类型
- 方块放置
- 物品栏、准星或游戏菜单
- 重力、碰撞、跳跃和玩家实体
- 光照、法线、阴影和环境光遮蔽
- 雾效和距离渐隐
- 方块数据磁盘存档和加载
- Chunk 数据内存淘汰
- 多线程网格生成
- 索引缓冲、贪心网格或视锥剔除
- 自动化测试和性能基准

## 已知限制和后续修改注意事项

- `chunkData` 不会卸载；若扩大探索范围，需要增加数据淘汰或存档机制。
- 网格生成和 GPU Buffer 创建发生在渲染线程；更大的 Chunk 或渲染距离可能导致卡顿。
- 移动速度依赖帧率；应引入 delta time 后再实现稳定的角色控制。
- `World.update` 在每帧编码过程中同步执行，不适合昂贵的地形生成。
- 当前网格使用重复顶点，没有索引缓冲，内存效率有限。
- 世界只有一个固定高度层级，没有垂直 Chunk。
- 添加方块编辑后，需要提供修改 `chunkData` 和重建本区块/边界相邻区块网格的接口。
- 修改 `Vertex`、`Uniforms` 或 `SkyUniforms` 时，必须同步保持 Swift 与 Metal 两侧的字段顺序和内存布局一致。
- `grass_top.imageset` 不是当前地形渲染器加载的纹理；实际使用的是 `terrain_atlas`。
- `GeometryFactory.createCube`、位移矩阵和旋转矩阵目前未被主渲染流程调用，但仍保留在源码中。

## 推荐的下一步

在现有结构上继续开发时，比较自然的顺序是：

1. 将相机和移动更新改为基于 delta time。
2. 把固定 `Chunk.init()` 替换为基于世界坐标的确定性高度生成。
3. 为 `World` 增加方块查询、修改和网格失效接口。
4. 实现从屏幕中心发射的体素射线检测及方块破坏/放置。
5. 增加玩家碰撞、重力和地面移动。
6. 将 Chunk 生成和网格构建移出渲染线程。
7. 增加测试 Target，优先覆盖负坐标换算、跨区块查询和网格面数。
