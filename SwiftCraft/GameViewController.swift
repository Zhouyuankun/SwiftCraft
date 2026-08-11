import Cocoa
import MetalKit

// 在类顶部定义一个集合来记录当前按下的键
var activeKeys = Set<UInt16>()

// 键盘映射常量
let kVK_W: UInt16 = 13
let kVK_S: UInt16 = 1
let kVK_A: UInt16 = 0
let kVK_D: UInt16 = 2
let kVK_Space: UInt16 = 49
let kVK_Shift: UInt16 = 56
let kVK_Escape: UInt16 = 53

class GameViewController: NSViewController {
    var renderer: Renderer?
    var camera = Camera()

    // 状态位：控制是否处于“游戏操作模式”
    var isCursorLocked = false

    // --- HUD：屏幕右上角显示绝对位置、朝向和区块编号 ---
    private var positionLabel: NSTextField!
    private var facingLabel: NSTextField!
    private var chunkLabel: NSTextField!
    private var blockLabel: NSTextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let mtkView = self.view as? MTKView else { return }
        
        // 1. 初始化渲染器
        let newRenderer = Renderer(metalKitView: mtkView)
        self.renderer = newRenderer
        mtkView.delegate = newRenderer
        
        // 2. 传递 Camera 引用
        newRenderer?.camera = self.camera
        
        // 3. 核心：绑定每一帧的逻辑更新（只有锁定状态下才更新相机位置，HUD 每帧刷新）
        newRenderer?.onUpdate = { [weak self] in
            guard let self = self else { return }
            if self.isCursorLocked {
                self.updateCamera()
            }
            self.updateHUD()
        }

        // 4. 初始化屏幕右上角的坐标 HUD
        setupHUD()
        setupCrosshair()

        // 5. 监听鼠标点击以锁定光标
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            
            // 第一次点击进入锁定模式；锁定后的左键用于破坏准心选中的方块。
            let location = event.locationInWindow
            if self.view.hitTest(location) != nil {
                if self.isCursorLocked {
                    self.renderer?.removeTargetedBlock()
                } else {
                    self.lockCursor()
                }
            }
            return event
        }
    }
    
    // --- 光标管理逻辑 ---
    
    func lockCursor() {
        isCursorLocked = true
        self.view.window?.makeFirstResponder(self)
        CGAssociateMouseAndMouseCursorPosition(0) // 隐藏并锁定物理光标位置
        NSCursor.hide()
    }
    
    func unlockCursor() {
        isCursorLocked = false
        // 清空当前按键状态，防止解锁后角色还在自动跑
        activeKeys.removeAll()
        CGAssociateMouseAndMouseCursorPosition(1) // 恢复物理光标位置关联
        NSCursor.unhide()
    }

    // 追踪区域设置：确保 mouseMoved 能够被系统触发
    override func viewDidLayout() {
        super.viewDidLayout()
        for area in self.view.trackingAreas {
            self.view.removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved]
        let trackingArea = NSTrackingArea(rect: self.view.bounds, options: options, owner: self, userInfo: nil)
        self.view.addTrackingArea(trackingArea)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 启动时不自动锁定，等待用户点击
        self.view.window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { return true }

    // --- 输入处理 ---

    override func mouseMoved(with event: NSEvent) {
        // 核心：只有在锁定模式下才处理视角旋转
        guard isCursorLocked else { return }
        
        let sensitivity: Float = 0.15
        camera.yaw += Float(event.deltaX) * sensitivity
        camera.pitch -= Float(event.deltaY) * sensitivity
        
        // 限制俯仰角，防止视角垂直翻转
        camera.pitch = max(-89.0, min(89.0, camera.pitch))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape {
            unlockCursor() // 按 ESC 键调用解锁逻辑
            return
        }
        
        // 只有锁定时才记录按键，避免干扰系统其他操作
        if isCursorLocked {
            activeKeys.insert(event.keyCode)
        }
    }

    override func keyUp(with event: NSEvent) {
        activeKeys.remove(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        // 实时监测 Shift 键状态
        if isCursorLocked {
            if event.modifierFlags.contains(.shift) {
                activeKeys.insert(kVK_Shift)
            } else {
                activeKeys.remove(kVK_Shift)
            }
        }
        super.flagsChanged(with: event)
    }
    
    // --- 逻辑更新 (由 Renderer 每一帧驱动) ---

    func updateCamera() {
        let speed: Float = 0.15
        let forward = camera.lookAt
        
        // 计算水平方向向量，保证在地面上平移
        var flattenedForward = simd_float3(forward.x, 0, forward.z)
        if length(flattenedForward) > 0 {
            flattenedForward = normalize(flattenedForward)
        }
        
        let right = normalize(cross(flattenedForward, [0, 1, 0]))

        if activeKeys.contains(kVK_W) { camera.position += flattenedForward * speed }
        if activeKeys.contains(kVK_S) { camera.position -= flattenedForward * speed }
        if activeKeys.contains(kVK_A) { camera.position -= right * speed }
        if activeKeys.contains(kVK_D) { camera.position += right * speed }
        
        if activeKeys.contains(kVK_Space) { camera.position.y += speed }
        if activeKeys.contains(kVK_Shift) { camera.position.y -= speed }
    }

    // --- HUD 逻辑 ---

    private func setupHUD() {
        positionLabel = GameViewController.makeHUDLabel()
        facingLabel = GameViewController.makeHUDLabel()
        chunkLabel = GameViewController.makeHUDLabel()
        blockLabel = GameViewController.makeHUDLabel()

        view.addSubview(positionLabel)
        view.addSubview(facingLabel)
        view.addSubview(chunkLabel)
        view.addSubview(blockLabel)

        NSLayoutConstraint.activate([
            positionLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            positionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            facingLabel.topAnchor.constraint(equalTo: positionLabel.bottomAnchor, constant: 2),
            facingLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            chunkLabel.topAnchor.constraint(equalTo: facingLabel.bottomAnchor, constant: 2),
            chunkLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            blockLabel.topAnchor.constraint(equalTo: chunkLabel.bottomAnchor, constant: 2),
            blockLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])
    }

    private static func makeHUDLabel() -> NSTextField {
        let label = NSTextField()
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = .white
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// 在视图正中央绘制固定十字准心，不参与鼠标事件。
    private func setupCrosshair() {
        let horizontal = makeCrosshairBar()
        let vertical = makeCrosshairBar()
        view.addSubview(horizontal)
        view.addSubview(vertical)

        NSLayoutConstraint.activate([
            horizontal.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            horizontal.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            horizontal.widthAnchor.constraint(equalToConstant: 16),
            horizontal.heightAnchor.constraint(equalToConstant: 2),

            vertical.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            vertical.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            vertical.widthAnchor.constraint(equalToConstant: 2),
            vertical.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func makeCrosshairBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        bar.layer?.shadowColor = NSColor.black.cgColor
        bar.layer?.shadowOpacity = 0.8
        bar.layer?.shadowRadius = 1
        return bar
    }

    func updateHUD() {
        let p = camera.position
        let chunk = World.worldToChunkCoord(p)

        let posText = String(format: "Position  (%.1f, %.1f, %.1f)", p.x, p.y, p.z)
        let facingText = "Facing  \(facingText())"
        let chunkText = "Chunk  (\(chunk.x), \(chunk.z))"
        let targetedBlockType = renderer?.targetedBlockType ?? .air
        let blockText = "Block  \(String(describing: targetedBlockType))"

        // 只在内容变化时更新，避免无谓的重绘
        if positionLabel.stringValue != posText { positionLabel.stringValue = posText }
        if facingLabel.stringValue != facingText { facingLabel.stringValue = facingText }
        if chunkLabel.stringValue != chunkText { chunkLabel.stringValue = chunkText }
        if blockLabel.stringValue != blockText { blockLabel.stringValue = blockText }
    }

    /// 计算朝向文本。
    /// 水平前进方向由 yaw 决定：forward = (cos(yaw), 0, sin(yaw))。
    /// 返回向前走时会增大的坐标轴及其符号，例如 "+X+Z" 表示向前走时 X、Z 都增大。
    private func facingText() -> String {
        let yawRad = camera.yaw.radians
        let fx = cos(yawRad) // 前进方向的 X 分量
        let fz = sin(yawRad) // 前进方向的 Z 分量

        // 阈值：分量接近 0（正对坐标轴方向）时省略该轴，避免符号抖动
        let threshold: Float = 0.01
        var text = ""
        if fx > threshold { text += "+X" }
        else if fx < -threshold { text += "-X" }
        if fz > threshold { text += "+Z" }
        else if fz < -threshold { text += "-Z" }

        return text.isEmpty ? "·" : text
    }
}
