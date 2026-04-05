import Cocoa
import MetalKit

class GameViewController: NSViewController {
    
    var renderer: Renderer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let mtkView = self.view as? MTKView else { return }
        
        // 初始化 Renderer 并将其设为 MTKView 的代理
        renderer = Renderer(metalKitView: mtkView)
        mtkView.delegate = renderer
    }
}
