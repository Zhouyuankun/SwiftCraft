# SwiftCraft

A Minecraft-style voxel game built with Metal for macOS.

![Platform](https://img.shields.io/badge/platform-macOS%2026+-blue)
![Metal](https://img.shields.io/badge/metal-3.0-green)
![Swift](https://img.shields.io/badge/swift-6.0-orange)

## 开发进度 (Development Roadmap)

### ✅ 已完成 (Completed)

| 里程碑 | 内容 | 状态 |
|--------|------|------|
| **M1** | 环境搭建 - Metal 渲染窗口 | ✅ 完成 |
| **M2** | 渲染三角形 - Metal 图形管线 | ✅ 完成 |
| **M3** | MVP 矩阵 + 立方体渲染 | ✅ 完成 |
| **M4** | 第一人称相机 + WASD 移动 + 鼠标视角 | ✅ 完成 |
| **M5** | Chunk 区块系统 + 面剔除优化 | ✅ 完成 |

### 🔄 正在开发 (In Progress)

| 功能 | 描述 |
|------|------|
| **多区块流式加载** | 相机移动时动态加载/卸载周围区块 |

### 📋 待开发 (To Do)

| 里程碑 | 内容 | 优先级 |
|--------|------|--------|
| **M6** | 噪声地形生成 - 起伏山脉 | P0 |
| **M7** | 方块破坏/放置交互 | P0 |
| **M8** | 光照与阴影系统 | P1 |
| **M9** | 物品栏 UI + 方块选择 | P1 |
| **M10** | 碰撞检测 + 重力 | P2 |
| **M11** | 存档/加载世界 | P2 |

## 当前功能 (Current Features)

- **Metal 3D 渲染** — 完整的 Metal 渲染管线
- **Voxel Chunk 系统** — 5x5x5 区块，面剔除优化
- **纹理图集** — 4x4 Minecraft 风格 terrain atlas
- **第一人称相机** — WASD 移动 + 鼠标视角
- **三种方块类型** — 石头、泥土、草方块

## 操作说明 (Controls)

| 按键 | 动作 |
|------|------|
| **点击窗口** | 锁定光标 / 进入游戏模式 |
| **W/A/S/D** | 前进/左移/后退/右移 |
| **Space** | 上升 |
| **Shift** | 下降 |
| **Escape** | 释放光标 / 退出游戏模式 |

## 项目结构 (Project Structure)

```
SwiftCraft/
├── AppDelegate.swift          # macOS 应用入口
├── GameViewController.swift   # 输入处理、相机控制
├── Renderer.swift             # Metal 渲染管线设置
├── Camera.swift               # 第一人称相机 (LookAt)
├── Blocks.swift               # 方块类型、Chunk 数据、几何生成
├── Math.swift                 # 矩阵数学 (透视、位移、旋转)
├── Types.swift                # Vertex 和 Uniforms 结构体
├── Shaders.metal              # 顶点/片元着色器
└── Assets.xcassets/           # 纹理资源 (terrain_atlas)
```

## 核心概念 (Key Concepts)

### Metal 着色器

- **顶点着色器** (`vertex_main`) — MVP 矩阵变换，传递 UV 坐标
- **片元着色器** (`fragment_main`) — 最近邻采样，保持像素风格的清晰纹理

### 面剔除 (Face Culling)

只渲染可见面。面可见的条件：
1. 位于 Chunk 边界，或
2. 相邻方块为空气

### 纹理图集 (Texture Atlas)

`terrain_atlas` 使用 4x4 网格布局，Block 面 UV 坐标映射到对应图集区域。

### 第一人称相机

- **Yaw/Pitch** — 鼠标移动控制水平/垂直视角
- **WASD** — 沿视角方向水平移动
- **LookAt 矩阵** — 标准观察矩阵变换

## 技术栈 (Tech Stack)

| 组件 | 技术选型 |
|------|----------|
| 语言 | Swift 6.0 |
| 图形 API | Metal (MetalKit) |
| IDE | Xcode 17+ |
| 平台 | macOS 26.0+ |

## 构建 (Building)

1. 克隆仓库
2. 用 Xcode 打开 `SwiftCraft.xcodeproj`
3. 选择 SwiftCraft scheme
4. Cmd+R 编译运行

## 未来计划 (Future Plans)

- [ ] 无限世界流式加载
- [ ] 环境光遮蔽 (Ambient Occlusion)
- [ ] 雾效 / 距离渐隐
- [ ] 更多方块类型
- [ ] 方向光 + 阴影
- [ ] Mipmap 纹理采样

## License

MIT License
