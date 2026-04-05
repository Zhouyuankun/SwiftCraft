#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position;
    float2 texCoord; // 必须匹配 Swift 中的顺序
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float4x4 mvp;
};

vertex VertexOut vertex_main(constant VertexIn *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]],
                             uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = uniforms.mvp * float4(vertices[vid].position, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]]) {
    // 关键：开启 Nearest 采样，保持像素颗粒感，不模糊
    sampler textureSampler(mag_filter::nearest, min_filter::nearest);
    
    float4 color = tex.sample(textureSampler, in.texCoord);
    
    return color;
}
