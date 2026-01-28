#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Pre-computed constants matching Swift arrays
constant float F1[13] = {1.1, 1.3, 1.0, 1.4, 0.9, 1.35, 1.15, 1.45, 1.05, 1.25, 0.95, 1.2, 1.08};
constant float F2[13] = {1.7, 2.1, 1.9, 2.3, 1.8, 2.2, 2.0, 2.4, 1.85, 2.15, 1.75, 2.05, 1.95};
constant float F3[13] = {0.6, 0.8, 0.7, 0.85, 0.55, 0.75, 0.65, 0.9, 0.58, 0.72, 0.62, 0.78, 0.68};
constant float SHAPE[13] = {0.3, 0.5, 0.75, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.75, 0.5, 0.3};

// Phase multipliers per bar
constant float P1_MULT = 2.39;
constant float P2_MULT = 1.47;
constant float P3_MULT = 3.82;

// Bar layout constants
constant float BAR_WIDTH = 5.0;
constant float BAR_SPACING = 3.0;
constant float BAR_STRIDE = 8.0;  // BAR_WIDTH + BAR_SPACING
constant float CORNER_RADIUS = 2.0;
constant int NUM_BARS = 13;

// Height constants
constant float BASE_HEIGHT = 6.0;
constant float MAX_HEIGHT = 18.0;
constant float IDLE_HEIGHT = 5.0;
constant float CHAOS_AMPLITUDE = 12.0;
constant float IDLE_WAVE_AMPLITUDE = 6.0;

// Signed distance function for rounded rectangle (single bar)
float sdRoundedBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

[[ stitchable ]] half4 waveformBars(
    float2 position,
    half4 currentColor,
    float time,
    float smoothedLevel,
    float2 bounds
) {
    // Calculate total width of all bars
    float totalBarsWidth = float(NUM_BARS) * BAR_WIDTH + float(NUM_BARS - 1) * BAR_SPACING;
    float startX = (bounds.x - totalBarsWidth) * 0.5;

    // Center Y coordinate
    float centerY = bounds.y * 0.5;

    // Check each bar
    for (int i = 0; i < NUM_BARS; i++) {
        float barCenterX = startX + float(i) * BAR_STRIDE + BAR_WIDTH * 0.5;

        // Phase offsets for this bar
        float p1 = float(i) * P1_MULT;
        float p2 = float(i) * P2_MULT;
        float p3 = float(i) * P3_MULT;

        // 3 overlapping waves for chaos effect
        float wave1 = sin(time * F1[i] + p1);
        float wave2 = sin(time * F2[i] + p2);
        float wave3 = sin(time * F3[i] + p3);
        float combinedWave = wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2;

        // IDLE: Flowing wave offset
        float idleOffset = sin(time * 0.8 * 3.14159265 * 2.0 + float(i) * 0.25) * IDLE_WAVE_AMPLITUDE;

        // ACTIVE: Height calculation with shape multiplier
        float audioBase = MAX_HEIGHT * smoothedLevel;
        float chaos = combinedWave * CHAOS_AMPLITUDE * smoothedLevel;
        float activeHeight = (BASE_HEIGHT + audioBase + chaos) * SHAPE[i];

        // Blend between idle and active states
        float blend = min(smoothedLevel * 3.0, 1.0);
        float height = max(BASE_HEIGHT * 0.3, IDLE_HEIGHT * (1.0 - blend) + activeHeight * blend);
        float yOffset = idleOffset * (1.0 - blend);

        // Bar center with Y offset applied
        float barCenterY = centerY - yOffset;

        // Position relative to bar center
        float2 relPos = float2(position.x - barCenterX, position.y - barCenterY);

        // Half-extents for the rounded rect
        float2 halfSize = float2(BAR_WIDTH * 0.5, height * 0.5);

        // Signed distance to rounded rectangle
        float dist = sdRoundedBox(relPos, halfSize, CORNER_RADIUS);

        // Anti-aliased edge (1 pixel transition)
        if (dist < 0.5) {
            float alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
            // Return red color (matching the Swift Color.red)
            return half4(1.0, 0.0, 0.0, half(alpha));
        }
    }

    // Transparent if not inside any bar
    return half4(0.0, 0.0, 0.0, 0.0);
}
