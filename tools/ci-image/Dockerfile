# The Linux CI image: pinned GHC and Cabal, the C build prerequisites, the X11
# and Wayland development libraries GLFW's two Linux backends need, the compiled
# private GLFW prefix, the Xvfb server and Openbox window manager the native
# worker's X11 display helper starts, and the pinned Weston compositor and
# wayland-info client its Wayland helper starts. Nothing in the image starts a
# display or a compositor, and it carries no project source, project build
# output, captures, or Vulkan SDK.
#
# Build it only through the ci-image builder, which stages exactly the recipe
# inputs the fingerprint covers as the build context and supplies that
# fingerprint. See docs/validation.md.
FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

ARG RECIPE_FINGERPRINT

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    CABAL_DIR=/opt/hetoimasia/cabal \
    HETOIMASIA_NATIVE_PREFIX=/opt/hetoimasia/native/glfw \
    PKG_CONFIG_PATH=/opt/hetoimasia/native/glfw/lib/pkgconfig \
    PATH=/opt/hetoimasia/ghc/bin:/opt/hetoimasia/cabal-install/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY tools/ci-image/ /opt/hetoimasia/recipe/tools/ci-image/
COPY tools/native/ /opt/hetoimasia/recipe/tools/native/

RUN /opt/hetoimasia/recipe/tools/ci-image/provision.sh packages
RUN /opt/hetoimasia/recipe/tools/ci-image/provision.sh toolchain
RUN /opt/hetoimasia/recipe/tools/ci-image/provision.sh cabal
RUN /opt/hetoimasia/recipe/tools/ci-image/provision.sh glfw
RUN /opt/hetoimasia/recipe/tools/ci-image/provision.sh stamp "$RECIPE_FINGERPRINT"

LABEL org.opencontainers.image.source="https://github.com/coghex/hetoimasia" \
      org.opencontainers.image.description="Hetoimasia Linux validation environment"
