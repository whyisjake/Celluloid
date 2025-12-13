//
//  BlackMistShader.metal
//  Celluloid
//
//  Custom Metal kernel for Black Pro-Mist filter effect
//  Combines exposure boost, soft light blend, alpha mix, and color adjustments
//  into a single GPU pass for optimal performance.
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

/// Black Mist blend kernel
/// Combines 5 filter operations into a single GPU pass:
/// 1. Exposure boost on blurred input
/// 2. Soft light blend
/// 3. Alpha mix with original
/// 4. Contrast adjustment
/// 5. Saturation adjustment
///
/// Parameters:
/// - src: Original image sample
/// - blurred: Pre-blurred image sample (Gaussian blur done separately)
/// - strength: Blend strength (0.0 - 1.0)
/// - exposureBoost: EV adjustment for bloom effect
/// - contrast: Final contrast (1.0 = neutral)
/// - brightness: Final brightness offset
/// - saturation: Final saturation (1.0 = neutral)
extern "C" float4 blackMistBlend(coreimage::sample_t src,
                                  coreimage::sample_t blurred,
                                  float strength,
                                  float exposureBoost,
                                  float contrast,
                                  float brightness,
                                  float saturation) {
    // 1. Apply exposure boost to blurred sample (simulate highlight bloom)
    float exposureMultiplier = pow(2.0f, exposureBoost);
    float3 brightBlur = blurred.rgb * exposureMultiplier;

    // 2. Soft light blend between brightened blur and original
    float3 base = src.rgb;
    float3 blend = brightBlur;
    float3 softLight;

    // Soft light formula per channel
    // if (base < 0.5) result = 2 * base * blend
    // else result = 1 - 2 * (1 - base) * (1 - blend)
    softLight.r = (base.r < 0.5f) ? (2.0f * base.r * blend.r) : (1.0f - 2.0f * (1.0f - base.r) * (1.0f - blend.r));
    softLight.g = (base.g < 0.5f) ? (2.0f * base.g * blend.g) : (1.0f - 2.0f * (1.0f - base.g) * (1.0f - blend.g));
    softLight.b = (base.b < 0.5f) ? (2.0f * base.b * blend.b) : (1.0f - 2.0f * (1.0f - base.b) * (1.0f - blend.b));

    // 3. Mix original and soft-light result based on strength
    float3 mixed = mix(base, softLight, strength);

    // 4. Apply contrast (around mid-gray) and brightness
    float3 contrasted = (mixed - 0.5f) * contrast + 0.5f + brightness;

    // 5. Apply saturation adjustment
    float luminance = dot(contrasted, float3(0.2126f, 0.7152f, 0.0722f));
    float3 result = mix(float3(luminance), contrasted, saturation);

    return float4(clamp(result, 0.0f, 1.0f), src.a);
}
