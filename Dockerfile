##### Args passed by GHA:
# OPENWRT_GIT_URL=${{ matrix.git_url }}
# OPENWRT_BRANCH=${{ matrix.branch }}
# RELEASE_ID=${{matrix.id}}
# OPENWRT_REVISION==${{ steps.gitinfo.outputs.sha1 }}
# OPENWRT_CONFIG=${{ matrix.config }}
# RELEASE_VERSION=${{needs.prepare.outputs.created}}
FROM debian:stable AS build

# Install dependencies for building OpenWRT
ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt -y install build-essential git make tree

WORKDIR /src
ARG OPENWRT_GIT_URL
ARG OPENWRT_BRANCH
RUN git clone --branch ${OPENWRT_BRANCH} ${OPENWRT_GIT_URL} openwrt

WORKDIR /src/openwrt

### <TO-BE-REPLAYED>
RUN ./scripts/feeds update -a && ./scripts/feeds install -a

ARG OPENWRT_CONFIG
RUN cp -v ${OPENWRT_CONFIG} .config && make defconfig

# Download sources; as this can fail due to network issues, we retry a few times with decreasing parallelism
RUN make download -j4 || make download -j2 || make download || make download

# Now lets build parts of OpenWRT, we can't build everything in one go as caches would grow too big
# Build the toolchain first
RUN make toolchain/install $(($(nproc)+2))

# Build the kernel
RUN make target/linux/compile $(($(nproc)+2))

# Build the packages
RUN make package/compile $(($(nproc)+2))

# Build the firmware
RUN make $(($(nproc)+2))
### </TO-BE-REPLAYED>

## Ok, now we've a built firmware. Let's fetch from the repo and checkout the specific commit, then build everything again.
# This should now massively hit on the caches previously built and only update the changed parts.
ARG OPENWRT_REVISION
RUN git fetch origin ${OPENWRT_BRANCH} && git checkout ${OPENWRT_REVISION}

### <REPLAYED>
RUN ./scripts/feeds update -a && ./scripts/feeds install -a

ARG OPENWRT_CONFIG
RUN cp -v ${OPENWRT_CONFIG} .config && make defconfig

# Download sources; as this can fail due to network issues, we retry a few times with decreasing parallelism
RUN make download -j4 || make download -j2 || make download || make download

# Now lets build parts of OpenWRT, we can't build everything in one go as caches would grow too big
# Build the toolchain first
RUN make toolchain/install $(($(nproc)+2))

# Build the kernel
RUN make target/linux/compile $(($(nproc)+2))

# Build the packages
RUN make package/compile $(($(nproc)+2))

# Build the firmware
RUN make $(($(nproc)+2))
### </REPLAYED>

# Finally, let's output the build artifacts into /dist
WORKDIR /dist
RUN cp -v bin/targets/*/*/*.img.gz /dist

# Finally the output stage
FROM alpine:3
WORKDIR /out
COPY --from=build /dist/* /out/
