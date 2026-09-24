// What the verification fragment shader reads from its vertex half. The
// location comes from a second include, which is the transitive include the
// shader suite requires the adapter to register.
#include "verification_layout.glsl"

layout(location = VERIFICATION_TAG_LOCATION) flat in uint tag;

vec4 verificationColour(uint value) {
    return vec4(float(value & 0xffu) / 255.0, 0.0, 0.0, 1.0);
}
