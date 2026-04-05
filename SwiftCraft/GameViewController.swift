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

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let mtkView = self.view as? MTKView else { return }
        
        // 1. 初始化渲染器
        let newRenderer = Renderer(metalKitView: mtkView)
        self.renderer = newRenderer
        mtkView.delegate = newRenderer
        
        // 2. 传递 Camera 引用
        newRenderer?.camera = self.camera
        
        // 3. 核心：绑定每一帧的逻辑更新（只有锁定状态下才更新相机位置）
        newRenderer?.onUpdate = { [weak self] in
            guard let self = self else { return }
            if self.isCursorLocked {
                self.updateCamera()
            }
        }
        
        // 4. 监听鼠标点击以锁定光标
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            
            // 如果点击在视图内，且当前还没锁定，则进入锁定模式
            let location = event.locationInWindow
            if self.view.hitTest(location) != nil && !self.isCursorLocked {
                self.lockCursor()
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
}
