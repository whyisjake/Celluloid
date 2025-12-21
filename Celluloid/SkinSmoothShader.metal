//
//  SkinSmoothShader.metal
//  Celluloid
//
//  Custom Metal kernel for skin smoothing effect
//  Uses skin tone detection and frequency separation for natural-looking smoothing
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

/// Detect if a pixel is likely skin tone using multiple color space checks
/// Returns a value 0.0-1.0 indicating skin probability
inline float detectSkin(float3 rgb) {
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    // RGB rule-based skin detection (works well for most skin tones)
    // Based on peer-reviewed research on skin color segmentation

    // Rule 1: R > G > B (warm tone requirement)
    bool rgbOrder = (r > g) && (g > b);

    // Rule 2: Sufficient color difference (not gray)
    float maxRGB = max(r, max(g, b));
    float minRGB = min(r, min(g, b));
    bool hasColor = (maxRGB - minRGB) > 0.05f;

    // Rule 3: Not too dark or too bright
    bool goodLuminance = (r > 0.15f) && (r < 0.95f) && (g > 0.10f) && (b > 0.05f);

    // Rule 4: Red-green ratio typical of skin
    float rgRatio = (g > 0.01f) ? (r / g) : 10.0f;
    bool goodRGRatio = (rgRatio > 1.0f) && (rgRatio < 1.8f);

    // Rule 5: Red dominance check
    bool redDominant = (r > 0.35f) && (r > b * 1.3f);

    // Combine rules - must pass most of them
    float score = 0.0f;
    if (rgbOrder) score += 0.3f;
    if (hasColor) score += 0.15f;
    if (goodLuminance) score += 0.15f;
    if (goodRGRatio) score += 0.25f;
    if (redDominant) score += 0.15f;

    // Apply threshold - need high confidence to be considered skin
    // Use smoothstep for soft edges
    return smoothstep(0.7f, 0.85f, score);
}

/// Skin Smooth blend kernel
/// Combines skin detection with frequency separation smoothing
///
/// Parameters:
/// - src: Original image sample
/// - blurred: Pre-blurred image sample (Gaussian blur done separately)
/// - strength: Smoothing strength (0.0 - 1.0)
/// - skinDetectStrength: How strictly to detect skin (0.0 = smooth everything, 1.0 = only skin)
/// - detailPreserve: How much high-frequency detail to preserve (0.0 - 1.0)
extern "C" float4 skinSmoothBlend(coreimage::sample_t src,
                                   coreimage::sample_t blurred,
                                   float strength,
                                   float skinDetectStrength,
                                   float detailPreserve) {
    float3 original = src.rgb;
    float3 smooth = blurred.rgb;

    // Calculate high-frequency details (original - blurred)
    float3 details = original - smooth;

    // Detect skin in original image
    float skinMask = detectSkin(original);

    // Mix between full smoothing (skin areas) and no smoothing (non-skin areas)
    // skinDetectStrength controls how selective we are
    float smoothAmount = mix(1.0f, skinMask, skinDetectStrength);

    // Apply smoothing: blend between original and smoothed based on skin mask
    float3 smoothed = mix(original, smooth, smoothAmount * strength);

    // Add back some high-frequency details to preserve texture
    // detailPreserve controls how much detail we keep
    float3 result = smoothed + details * detailPreserve * smoothAmount;

    return float4(clamp(result, 0.0f, 1.0f), src.a);
}
